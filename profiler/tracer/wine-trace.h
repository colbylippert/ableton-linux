/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * wine-trace.h — structs, kinds and constants shared by the BPF side
 * (wine-trace.bpf.c, included after vmlinux.h) and the loader (wine-trace.c,
 * included after <linux/types.h>).  Only __uNN/__sNN types, no includes.
 *
 * Design: ../../../plans/design-B-tracer-and-probes.md §3b–§3c.
 *
 * Probe argument contract (patch 0108 / pipeasio 0017), all on Linux x86_64:
 *   wine:syscall_entry(id:s32, frame:u64, user_rsp:u64, user_rip:u64)
 *   wine:syscall_exit(status:s32, frame:u64, id:s32, restore_flags:s32)
 *   wine:unixcall_entry(handle:u64, code:s32, frame:u64, caller_rip:u64)
 *   wine:unixcall_exit(status:s32, frame:u64)
 *   wine:server_req_start(req_type:int) / server_req_end(req_type:int, status:uint)
 *   wine:server_wait_start(flags:uint) / server_wait_end(ret:uint)
 *   pipeasio:block_start(seq:u64, nframes:u32, rate:u32, clock_nsec:u64, deadline_ns:u64, flags:u32)
 *   pipeasio:block_before_live(seq:u64) / block_after_live(seq:u64)
 *   pipeasio:block_end(seq:u64, flags:u32, missed:u32)
 *   pipeasio:cycle_start(clock_nsec:u64, next_nsec:u64, duration:u32, position:u64, cycle_flags:u32)
 *   pipeasio:cycle_end(missed:u32, delivered:u32)
 *
 * `frame` points at Wine's struct syscall_frame (dlls/ntdll/unix/signal_x86_64.c:469);
 * bytes 0x00..0x9f are rax rbx rcx rdx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15
 * rip cs eflags rsp ss rbp — copied verbatim into rec_stack.regs[20].
 */
#ifndef WINE_TRACE_H
#define WINE_TRACE_H

#define WINE_TRACE_VERSION "0.2.0"
#define WINE_TRACE_ABI     2          /* bump when any struct in this file changes */

/* ---- sizing ---------------------------------------------------------- */
#define AGG_SLOTS          4          /* time ring: agg[(completion_ts / AGG_SLOT_NS) & 3] */
#define AGG_SLOT_NS        100000000ULL          /* 100 ms per slot; user space drains slot W-2 */
#define AGG_EPOCH_SHIFT    6          /* global.epoch = seq >> 6 (informational) */
#define AGG_ENTRIES        65536      /* per slot */
#define INFLIGHT_DEPTH     4
#define MAX_PIDS           64
#define MAX_TIDS           4096
#define MAX_UNIXLIBS       256
#define MAX_TRIGGER_IDS    64
#define WINDOW_NS          100000000ULL          /* 100 ms non-block buckets */
#define WINDOW_BIT         (1ULL << 63)          /* agg_key.seq = WINDOW_BIT | window_id */
#define STACK_BYTES_MIN    512
#define STACK_BYTES_MAX    4096
#define STACK_BYTES_DEFAULT 1536
#define RINGBUF_MB_DEFAULT 16
#define SAMPLE_N_SUMMARY   64
#define SAMPLE_N_DRILLDOWN 4
#define SLACK_THRESH_PCT_DEFAULT 15
#define OFFCPU_MIN_NS_DEFAULT 50000ULL           /* rec_offcpu threshold (drill-down) */

/* ---- enumerations ---------------------------------------------------- */
enum wt_kind {
	KIND_NONE = 0,
	KIND_SYSCALL = 1,      /* id = full syscall id (0x1000+ = win32u table) */
	KIND_UNIXCALL = 2,     /* id = (unixlib_idx << 16) | (code & 0xffff) */
	KIND_SERVER_REQ = 3,   /* id = enum request */
	KIND_SERVER_WAIT = 4,  /* id = select flags (SELECT_ALERTABLE=1, SELECT_INTERRUPTIBLE=2) */
	KIND_NTSYNC_WAIT = 5,  /* id = NTSYNC_WAIT_ID(all, alert, count) */
	KIND_NTSYNC_WAKE = 6,  /* id = WAKE_* */
	KIND_OFFCPU = 7,       /* id = waker tid (0 = unknown/irq/preempted) */
	KIND_ONCPU = 8,        /* id = 0 */
	KIND_CYCLE = 9,        /* id = 0, full PipeWire cycle on the data-loop thread */
	KIND_PERF = 10,        /* stack records only: id = 0 user sample, 1 kernel-mode sample */
	KIND__COUNT
};

#define NTSYNC_WAIT_ID(all, alert, count) \
	(((all) ? 1u : 0u) | ((alert) ? 2u : 0u) | (((count) & 0xffu) << 8))

enum wt_wake_id { WAKE_NONE = 0, WAKE_EVENT_SET = 1, WAKE_EVENT_PULSE = 2, WAKE_SEM_RELEASE = 3,
		  WAKE_MUTEX_UNLOCK = 4 };

enum wt_mode { MODE_SUMMARY = 0, MODE_DRILLDOWN = 1, MODE_SAMPLE = 2 };
enum wt_roles { ROLES_ALL = 0, ROLES_AUDIO = 1 };

enum wt_role {
	ROLE_UNKNOWN = 0, ROLE_PIPEASIO_CALLBACK = 1, ROLE_AUDIO_WORKER = 2, ROLE_MAIN = 3,
	ROLE_WINESERVER = 4, ROLE_PIPEASIO_WORKER = 5, ROLE_PIPEASIO_RT = 6, ROLE_LIVE = 7,
	ROLE_PLUGIN = 8, ROLE_WEBVIEW = 9, ROLE_MAX = 10, ROLE_PUSH2 = 11, ROLE__COUNT
};
#define ROLE_IS_AUDIO(r) ((r) == ROLE_PIPEASIO_CALLBACK || (r) == ROLE_AUDIO_WORKER || \
			  (r) == ROLE_PIPEASIO_RT || (r) == ROLE_PIPEASIO_WORKER)

/* agg_key.flags / inflight_ent.flags / rec_event.flags */
#define AGGF_BETWEEN_BLOCKS 0x0001  /* callback thread, outside a block */
#define AGGF_WINDOW         0x0002  /* seq is WINDOW_BIT | window_id */
#define AGGF_TIMEOUT        0x0004  /* STATUS_TIMEOUT / -ETIMEDOUT */
#define AGGF_ALERTED        0x0008  /* STATUS_USER_APC, STATUS_ALERTED, ntsync alert index */
#define AGGF_ERROR          0x0010  /* NTSTATUS severity error / negative ntsync ret */
#define AGGF_OWNERDEAD      0x0020  /* -EOWNERDEAD / STATUS_ABANDONED_WAIT_n */
#define AGGF_INCOMPLETE     0x0040  /* syscall_exit restore_flags had INCOMPLETE_FRAME_CONTEXT */
#define AGGF_PREEMPTED      0x0080  /* offcpu interval started by preemption (prev_state == RUNNING) */
#define AGGF_INTR           0x0100  /* ntsync wait ended -EINTR */

/* ---- maps ------------------------------------------------------------ */
struct agg_key {
	__u64 seq;          /* block seq, or WINDOW_BIT | window_id */
	__u32 tid;
	__u16 kind;
	__u16 flags;
	__u32 id;
	__u32 pad;
};

struct agg_val {
	__u64 count;        /* events (offcpu/oncpu: intervals) */
	__u64 total_ns;     /* sum of durations */
	__u64 max_ns;       /* max duration */
	__u64 oncpu_ns;     /* on-CPU time inside the events; KIND_OFFCPU: sum of run-queue delay */
	__u64 aux_ns;       /* KIND_OFFCPU: max run-queue delay */
	__u32 last_waker;   /* tid of the last sched_waking waker seen for this key (0 = none) */
	__u32 pad;
};

struct inflight_ent {
	__u64 ts;           /* entry timestamp (bpf_ktime_get_ns) */
	__u64 seq;          /* association decided at entry */
	__u64 frame;        /* syscall_frame / unix-call frame; server_req: req type; ntsync: parm */
	__u64 off_ns;       /* off-CPU time accumulated while in flight */
	__u32 id;
	__u16 kind;
	__u16 sampled;      /* 1 = a rec_stack was emitted for this entry */
	__u16 flags;        /* AGGF_* decided at entry */
	__u16 pad[3];
};

struct inflight {
	struct inflight_ent s[INFLIGHT_DEPTH];
	__u8  depth;
	__u8  pad[3];
	__u32 drops;
};

struct sched_ent {
	__u64 off_ts;       /* switch-out time, 0 while on CPU */
	__u64 on_ts;        /* switch-in time, 0 while off CPU */
	__u64 wake_ts;      /* sched_waking during the current off interval */
	__u64 off_seq;      /* block association of the current off interval */
	__u64 last_wake_ts; /* most recent wake (not cleared) */
	__u32 waker_tid;    /* waker of the current off interval (0 = unknown / irq / self) */
	__u32 last_waker;
	__u16 off_flags;
	__u16 pad;
	__u32 wakeups;
};

struct global {
	__u64 cur_seq;        /* block in progress (0 between blocks) */
	__u64 last_seq;       /* last completed block */
	__u64 block_start_ts;
	__u64 deadline_ns;
	__u64 epoch;          /* cur_seq >> AGG_EPOCH_SHIFT at the last block_start */
	__u64 period_ns;      /* nframes * 1e9 / rate */
	__u64 blocks;         /* block_start count */
	__u32 callback_tid;
	__u32 cycle_tid;
	__u32 nframes;
	__u32 rate;
	__u32 unixlib_next;   /* handle index allocator */
	__u32 pad;
};

struct cfg {
	__u32 mode;             /* enum wt_mode */
	__u32 sample_n;         /* stack sample every N-th entry (0 = never) */
	__u32 stack_bytes;      /* STACK_BYTES_MIN..STACK_BYTES_MAX */
	__u32 roles;            /* enum wt_roles */
	__u32 slack_thresh_pct; /* sample stacks once the block is within this % of the period */
	__u32 no_exit;          /* 1 = count at entry, exit probes not attached */
	__u32 trigger_count;    /* entries in trigger_ids */
	__u32 offcpu_min_ns;    /* rec_offcpu threshold in drill-down */
};

struct unixlib_key {
	__u32 pid;
	__u32 pad;
	__u64 handle;
};

/* ---- per-CPU statistics (PERCPU_ARRAY of __u64) ----------------------- */
enum wt_stat {
	ST_HIT_SYSCALL_ENTRY = 0, ST_HIT_SYSCALL_EXIT, ST_HIT_UNIXCALL_ENTRY, ST_HIT_UNIXCALL_EXIT,
	ST_HIT_SERVER_REQ_START, ST_HIT_SERVER_REQ_END, ST_HIT_SERVER_WAIT_START, ST_HIT_SERVER_WAIT_END,
	ST_HIT_BLOCK_START, ST_HIT_BLOCK_BEFORE_LIVE, ST_HIT_BLOCK_AFTER_LIVE, ST_HIT_BLOCK_END,
	ST_HIT_CYCLE_START, ST_HIT_CYCLE_END, ST_HIT_NTSYNC_WAIT, ST_HIT_NTSYNC_WAKE,
	ST_HIT_SCHED_SWITCH, ST_HIT_SCHED_WAKING, ST_HIT_PERF_SAMPLE,
	ST_UNMATCHED_EXIT, ST_THREAD_START_EXIT, ST_ABANDONED_ENTRY, ST_INFLIGHT_OVERFLOW,
	ST_AGG_FULL, ST_RINGBUF_DROP, ST_STACK_READ_FAIL, ST_STACKS, ST_FILTERED, ST_NTSYNC_UNMATCHED,
	ST_SAMPLE_CTR,
	ST_UNIXCALL_SLOW_EXIT,  /* syscall_exit of the unix-call slow path (no syscall entry to match) */
	ST__COUNT
};

/* ---- ring-buffer records (design B §3c, verbatim) ---------------------- */
enum wt_rec {
	REC_STACK = 1, REC_BLOCK = 2, REC_WAKE = 3, REC_OFFCPU = 4, REC_NAME = 5,
	REC_EVENT = 6, REC_UNIXLIB = 7, REC_FORK = 8, REC_THREAD = 9, REC_EXIT = 10
};

enum wt_phase {
	PHASE_CYCLE_START = 0, PHASE_BLOCK_START = 1, PHASE_BEFORE_LIVE = 2, PHASE_AFTER_LIVE = 3,
	PHASE_BLOCK_END = 4, PHASE_CYCLE_END = 5
};

struct rec_hdr { __u16 type; __u16 len; __u32 tid; __u64 ts; };                    /* 16 B */

struct rec_stack {
	struct rec_hdr h;
	__u64 seq, frame, rsp, rip;
	__u32 id;
	__u16 kind;
	__u16 nbytes;
	__u64 regs[20];       /* syscall_frame bytes 0x00..0x9f: rax..rbp (read via frame ptr) */
	__u8  bytes[];        /* --stack-bytes (512..4096, default 1536) from user rsp */
};

/* phase BLOCK_START: all fields as the probe; BEFORE/AFTER_LIVE: seq only;
 * BLOCK_END: flags/missed from the probe, deadline_ns + nframes/rate from gl,
 * clock_nsec = block_start_ts; CYCLE_START: seq = position, clock_nsec, deadline_ns = next_nsec,
 * nframes = duration, flags = cycle_flags; CYCLE_END: seq = block seq joined (0 = none),
 * missed, flags = delivered. */
struct rec_block {
	struct rec_hdr h;
	__u64 seq, clock_nsec, deadline_ns;
	__u32 nframes, rate, flags, missed;
	__u8  phase;
};

struct rec_wake   { struct rec_hdr h; __u32 wakee_tid, waker_pid, waker_tid; char waker_comm[16]; };
struct rec_offcpu { struct rec_hdr h; __u64 off_ts, on_ts, run_delay_ns; __u32 waker_tid; };
struct rec_name   { struct rec_hdr h; __u32 pid; char comm[16]; };

/* ---- additional records (not in §3c) ---------------------------------- */
/* drill-down per-event line: h.ts = completion time, dur = h.ts - entry_ts,
 * stack_ts = entry ts of this or the nearest enclosing sampled entry (0 = none) */
struct rec_event {
	struct rec_hdr h;
	__u64 seq, entry_ts, stack_ts;
	__u32 id;
	__u16 kind;
	__u16 flags;
	__s32 status;
	__u32 waker_tid;
};

struct rec_unixlib { struct rec_hdr h; __u64 handle; __u32 pid, idx; };

/* REC_FORK (new process: pid = child tgid, h.tid = child tid), REC_THREAD (new thread of a
 * traced process), REC_EXIT (flags bit0 = group dead) */
struct rec_task { struct rec_hdr h; __u32 pid, parent_pid, parent_tid, flags; char comm[16]; };

/* ---- NTSync uapi (copy of include/uapi/linux/ntsync.h, kernel 7.2) ------ */
struct nt_wait_args {
	__u64 timeout;
	__u64 objs;
	__u32 count;
	__u32 index;
	__u32 flags;
	__u32 owner;
	__u32 alert;
	__u32 pad;
};

#define WT_IOC(dir, type, nr, size) (((__u32)(dir) << 30) | ((__u32)(size) << 16) | ((__u32)(type) << 8) | (__u32)(nr))
#define WT_IOC_W 1u
#define WT_IOC_R 2u
#define WT_IOC_RW 3u
#define NTSYNC_IOC_WAIT_ANY     WT_IOC(WT_IOC_RW, 'N', 0x82, 40)   /* 0xc0284e82 */
#define NTSYNC_IOC_WAIT_ALL     WT_IOC(WT_IOC_RW, 'N', 0x83, 40)   /* 0xc0284e83 */
#define NTSYNC_IOC_SEM_RELEASE  WT_IOC(WT_IOC_RW, 'N', 0x81, 4)    /* 0xc0044e81 */
#define NTSYNC_IOC_MUTEX_UNLOCK WT_IOC(WT_IOC_RW, 'N', 0x85, 8)    /* 0xc0084e85 */
#define NTSYNC_IOC_EVENT_SET    WT_IOC(WT_IOC_R,  'N', 0x88, 4)    /* 0x80044e88 */
#define NTSYNC_IOC_EVENT_RESET  WT_IOC(WT_IOC_R,  'N', 0x89, 4)    /* 0x80044e89 */
#define NTSYNC_IOC_EVENT_PULSE  WT_IOC(WT_IOC_R,  'N', 0x8a, 4)    /* 0x80044e8a */
#define NTSYNC_IOC_MAGIC        'N'

/* errno values seen in ntsync returns (vmlinux.h has no errno macros) */
#define WT_EINTR      4
#define WT_EEXIST     17
#define WT_ETIMEDOUT  110
#define WT_EOWNERDEAD 130

/* NTSTATUS values used for flagging */
#define WT_STATUS_ABANDONED_WAIT_0 0x00000080
#define WT_STATUS_USER_APC         0x000000C0
#define WT_STATUS_KERNEL_APC       0x00000100
#define WT_STATUS_ALERTED          0x00000101
#define WT_STATUS_TIMEOUT          0x00000102
#define WT_RESTORE_FLAGS_INCOMPLETE_FRAME_CONTEXT 0x00020000

#endif /* WINE_TRACE_H */
