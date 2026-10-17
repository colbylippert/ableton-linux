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
 *
 * STACK RULE (B5 oops, kernel 7.2.9 PREEMPT): since 6.14 the verifier runs every
 * KPROBE-type program (uprobes and USDT included) whose BPF stack is >= 64 bytes on a
 * per-CPU private stack.  Uprobe programs are preemptible and have no recursion guard,
 * so a second thread entering the same program on the same CPU overwrites the
 * preempted run's frame.  Every USDT program therefore keeps its BPF frame (and every
 * subprogram's frame) below 64 bytes, and nothing here is per-CPU scratch: keys and
 * values for map operations live in the thread's own `struct tstate` (hash map keyed by
 * tid), records are built in place in bpf_ringbuf_reserve()d memory, counters are atomic
 * adds on global data.  The loader verifies the JIT prologue of every program before it
 * attaches anything (jit_prologue_class() below).
 */
#ifndef WINE_TRACE_H
#define WINE_TRACE_H

#define WINE_TRACE_VERSION "0.3.1"
#define WINE_TRACE_ABI     4          /* bump when any struct in this file changes */

/* ---- sizing ---------------------------------------------------------- */
#define AGG_SLOTS          4          /* time ring: agg[(completion_ts / AGG_SLOT_NS) & 3] */
#define AGG_SLOT_NS        100000000ULL          /* 100 ms per slot; user space drains slot W-2 */
#define AGG_ENTRIES        65536      /* per slot */
#define INFLIGHT_DEPTH     8          /* nested entries per thread (power of two) */
#define MAX_PIDS           64
#define MAX_TIDS           8192
#define MAX_UNIXLIBS       256
#define MAX_TRIGGER_IDS    64
#define WINDOW_NS          100000000ULL          /* 100 ms non-block buckets */
#define WINDOW_BIT         (1ULL << 63)          /* agg_key.seq = WINDOW_BIT | window_id */
#define STACK_BYTES_MIN    512
#define STACK_BYTES_MAX    4096
#define STACK_BYTES_DEFAULT 1536
#define RINGBUF_MB_DEFAULT 16
#define RINGBUF_MB_DRILLDOWN 64       /* 1/4 stack sampling + every event: ~120 MB/s through the ring */
#define SAMPLE_N_SUMMARY   64
#define SAMPLE_N_DRILLDOWN 4
#define SLACK_THRESH_PCT_DEFAULT 15
#define SLACK_SAMPLES_PER_BLOCK_DEFAULT 16       /* cap of slack-triggered samples per block */
#define OFFCPU_MIN_NS_DEFAULT 50000ULL           /* rec_offcpu threshold (drill-down) */
#define PRIV_STACK_MIN_BYTES 64                  /* kernel BPF_PRIV_STACK_MIN_SIZE */

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
	KIND_CYCLE = 9,        /* reserved (PipeWire cycles travel as REC_BLOCK phases) */
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

/* ---- configuration: .rodata, written by the loader before load ---------
 * The verifier reads frozen .rodata as known constants: dead branches (mode, roles,
 * hit counting) disappear from the JIT image and CFG.stack_bytes is a constant
 * ring-buffer reservation size. */
struct wt_config {
	__u32 mode;             /* enum wt_mode */
	__u32 sample_n;         /* stack sample with probability 1/N per syscall/unix-call entry (0 = never) */
	__u32 stack_bytes;      /* STACK_BYTES_MIN..STACK_BYTES_MAX, multiple of 8 */
	__u32 roles_audio;      /* 1 = USDT crossings of audio-role threads only */
	__u32 slack_thresh_pct; /* also sample once the block is within this % of its period of the deadline */
	__u32 slack_samples;    /* at most this many slack-triggered samples per block */
	__u32 no_exit;          /* 1 = count at entry, exit probes not attached */
	__u32 trigger_count;    /* entries in trigger_ids */
	__u32 offcpu_min_ns;    /* rec_offcpu threshold in drill-down */
	__u32 count_hits;       /* 1 = count probe hits in BPF (no BPF_ENABLE_STATS run_cnt) */
	__u32 fast_args;        /* 1 = read the dispatcher probes' operands straight from the registers
				 * (the loader verified ntdll.so's .note.stapsdt against FAST_ARGS_*) */
	__u32 callback_return_id; /* NtCallbackReturn's syscall id (from the id table; NO_SYSCALL_ID = unknown):
				 * it never returns through its own frame (it resumes the frame of the user
				 * callback's caller), so it is counted, not pushed */
};
#define NO_SYSCALL_ID 0xffffffffu

/* patch 0108's operand strings of the four dispatcher probes (the fast path relies on them) */
#define FAST_ARGS_SYSCALL_ENTRY  "-4@176(%rcx) 8@%rcx 8@136(%rcx) 8@112(%rcx)"
#define FAST_ARGS_SYSCALL_EXIT   "-4@%eax 8@%rcx -4@176(%rcx) -4@180(%rcx)"
#define FAST_ARGS_UNIXCALL_ENTRY "8@%r10 -4@%edx 8@%rsp 8@112(%rsp)"
#define FAST_ARGS_UNIXCALL_EXIT  "-4@%eax 8@%rcx"
#define SYSCALL_FRAME_ID_OFF     176     /* frame->syscall_id */
#define SYSCALL_FRAME_RF_OFF     180     /* frame->restore_flags */
#define SYSCALL_FRAME_RIP_OFF    112     /* frame->rip (regs[14]) */
#define SYSCALL_FRAME_RSP_OFF    136     /* frame->rsp (regs[17]) */

/* ---- global data (.bss) ------------------------------------------------ */
/* The block in progress: written by the PipeASIO callback thread's programs only
 * (single writer), read by every program.  Plain scalars: a reader may see a block
 * boundary half-updated, never a pointer. */
struct global {
	__u64 cur_seq;          /* block in progress (0 between blocks) */
	__u64 last_seq;         /* last completed block */
	__u64 block_start_ts;
	__u64 deadline_ns;
	__u64 period_ns;        /* nframes * 1e9 / rate */
	__u64 sample_after_ns;  /* deadline - slack margin: entries after it are slack-sampled */
	__u64 blocks;           /* block_start count */
	__u32 callback_tid;
	__u32 nframes;
	__u32 rate;
	__u32 unixlib_next;     /* handle index allocator (atomic) */
	__u32 trig_used;        /* slack-triggered samples taken in the current block (atomic) */
	__u32 stopping;         /* set by the loader before it detaches: no new block starts (its END
				 * would be lost to the link teardown, which detaches block_start first) */
};

/* counters (.bss, atomic adds; all of them are rare events except CT_STACKS) */
enum wt_counter {
	CT_UNMATCHED_EXIT = 0,     /* exit without a matching entry (NtContinue, callbacks, ...) */
	CT_FIRST_EXIT,             /* first event of a thread is an exit: thread start / entered before tracing */
	CT_ABANDONED,              /* entries popped from below by an outer exit (NtCallbackReturn) or at thread exit */
	CT_INFLIGHT_OVERFLOW,      /* entry not tracked: INFLIGHT_DEPTH entries already open */
	CT_TSTATE_FULL,            /* no per-thread state (MAX_TIDS reached): event not tracked */
	CT_AGG_FULL,               /* completed crossing not aggregated: agg slot full */
	CT_RB_DROP_BLOCK,          /* ring buffer full: block phase record lost */
	CT_RB_DROP_EVENT,          /* ring buffer full: drill-down event record lost */
	CT_RB_DROP_OTHER,          /* ring buffer full: name/task/unixlib/wake/offcpu record lost */
	CT_STACK_DROP,             /* ring buffer full: stack sample lost (the crossing itself is counted) */
	CT_STACK_READ_FAIL,        /* the user stack window could not be read */
	CT_STACKS,                 /* stack samples emitted */
	CT_SAMPLE_RANDOM,          /* ... of them chosen by the 1/N sampler */
	CT_SAMPLE_SLACK,           /* ... by the slack trigger */
	CT_SAMPLE_TRIGGER,         /* ... by --trigger-ids */
	CT_FILTERED,               /* --roles audio: entries of other threads */
	CT_NTSYNC_UNMATCHED,       /* NTSync wait return without an in-flight wait */
	CT_UNIXCALL_SLOW_EXIT,     /* syscall_exit of the unix-call slow path (no syscall entry to match) */
	CT_NTSYNC_WAIT_HITS,       /* NTSync waits of traced processes (the fentry fires for everyone) */
	CT_NTSYNC_WAKE_HITS,       /* NTSync wakes of traced processes */
	CT_OPEN_AT_EXIT,           /* entries still open when their thread exited (NtTerminateProcess, ...) */
	CT_CALLBACK_RETURN,        /* NtCallbackReturn entries (counted as zero-duration crossings, never pushed) */
	CT_NEVER_RETURNED,         /* entries popped by a new syscall / unix call at the same frame (and the
				    * entries above them): they never passed their exit probe */
	CT_ANOMALY_DROP,           /* ring buffer full: drill-down anomaly record lost (diagnostics only) */
	CT__COUNT
};

/* drill-down rec_anomaly.what */
enum wt_anomaly {
	AN_OVERFLOW = 1,           /* entry not tracked: the in-flight stack was full */
	AN_UNMATCHED_EXIT = 2,     /* exit without an in-flight entry (not the unix-call slow path) */
	AN_NEVER_RETURNED = 3,     /* stale same-frame entries popped by a new entry */
	AN_ABANDONED = 4,          /* entries above the one an exit completed */
};

/* probe hits counted in BPF only when cfg.count_hits (else BPF_ENABLE_STATS run_cnt) */
enum wt_hit {
	HIT_SYSCALL_ENTRY = 0, HIT_SYSCALL_EXIT, HIT_UNIXCALL_ENTRY, HIT_UNIXCALL_EXIT,
	HIT_SERVER_REQ_START, HIT_SERVER_REQ_END, HIT_SERVER_WAIT_START, HIT_SERVER_WAIT_END,
	HIT_BLOCK_START, HIT_BLOCK_BEFORE_LIVE, HIT_BLOCK_AFTER_LIVE, HIT_BLOCK_END,
	HIT_CYCLE_START, HIT_CYCLE_END, HIT__COUNT
};

/* ---- maps ------------------------------------------------------------ */
struct agg_key {
	__u64 seq;          /* block seq, or WINDOW_BIT | window_id */
	__u32 tid;
	__u8  kind;
	__u8  pkind;        /* nested kinds: kind of the enclosing syscall/unix call (0 = none) */
	__u16 flags;
	__u32 id;
	__u32 pid_;         /* nested kinds: id of the enclosing syscall/unix call */
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

/* one key + value under construction (map operations take pointers into this, never into
 * the BPF stack) */
struct aggscratch {
	struct agg_key key;
	struct agg_val val;
	__u32 slot;         /* agg[] index: the outer ARRAY_OF_MAPS key */
	__u32 pad;
};

struct inflight_ent {
	__u64 ts;           /* entry timestamp (bpf_ktime_get_ns) */
	__u64 seq;          /* association decided at entry */
	__u64 frame;        /* pairing key: syscall/unix-call frame; server_req: req type; ntsync: parm */
	__u64 off_ns;       /* off-CPU time accumulated while in flight (sched_switch) */
	__u64 aux;          /* unix call: PE caller rip (drill-down / samples) */
	__u32 id;
	__u32 pid_;         /* nested kinds: id of the enclosing syscall/unix call */
	__u16 flags;        /* AGGF_* decided at entry */
	__u8  kind;
	__u8  pkind;        /* nested kinds: kind of the enclosing syscall/unix call */
	__u8  sampled;      /* 1 = a rec_stack was emitted for this entry */
	__u8  pad[3];
};

struct unixlib_key {
	__u32 pid;
	__u32 pad;
	__u64 handle;
};

/* Per-thread state (hash map keyed by tid).  Only the owning thread's programs write the
 * in-flight stack and `ag`/`arg`/`wa`/`ukey`; the scheduler programs (non-preemptible
 * tp_btf) write the sched fields and use `sg`.  A thread cannot run two of its own
 * programs at once, so none of these scratch areas is shared between concurrent runs. */
struct tstate {
	struct inflight_ent s[INFLIGHT_DEPTH];
	__u32 depth;
	__u32 seen;             /* 1 once a syscall entry or exit of the thread was seen */
	/* per-thread counters (validate.py per_tid scope) */
	__u32 unmatched, first_exit, abandoned, overflow, open_at_exit, never_returned;
	/* scheduler state */
	__u64 off_ts;           /* switch-out time, 0 while on CPU */
	__u64 on_ts;            /* switch-in time, 0 while off CPU */
	__u64 wake_ts;          /* sched_waking during the current off interval */
	__u64 off_seq;          /* block association of the current off interval */
	__u64 last_wake_ts;     /* most recent wake (not cleared) */
	__u32 waker_tid;        /* waker of the current off interval (0 = unknown / irq / self) */
	__u32 last_waker;
	__u16 off_flags;
	__u16 pad16;
	__u32 wakeups;
	/* PipeWire cycle on this thread (pipeasio:cycle_start) */
	__u64 cycle_ts;
	__u64 now0;             /* probe time, taken before the arguments are fetched */
	/* scratch */
	struct aggscratch ag;   /* the thread's own programs */
	struct aggscratch sg;   /* scheduler programs */
	struct unixlib_key ukey;
	__u64 arg[6];           /* USDT arguments land here (bpf_usdt_arg writes 8 bytes) */
	__u64 wa[5];            /* struct nt_wait_args copy */
};

/* ---- ring-buffer records ---------------------------------------------- */
enum wt_rec {
	REC_STACK = 1, REC_BLOCK = 2, REC_WAKE = 3, REC_OFFCPU = 4, REC_NAME = 5,
	REC_EVENT = 6, REC_UNIXLIB = 7, REC_FORK = 8, REC_THREAD = 9, REC_EXIT = 10, REC_ANOMALY = 11
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
	__u32 pid;            /* tgid of the sampled thread */
	__u8  kind;
	__u8  pad8;
	__u16 nbytes;
	__u32 pad32;
	__u64 regs[20];       /* syscall_frame bytes 0x00..0x9f: rax..rbp (read via frame ptr) */
	__u8  bytes[];        /* --stack-bytes (512..4096, default 1536) from user rsp */
};

/* Probe arguments land straight in a[] (8 bytes each: bpf_usdt_arg's result size).
 * Phases of a block whose block_start this tracer did not see (attached mid-block, or started
 * after the loader set gl.stopping) are not emitted.
 *   BLOCK_START: seq, a = {nframes, rate, clock_nsec, deadline_ns, flags}
 *   BEFORE_LIVE / AFTER_LIVE: seq
 *   BLOCK_END: seq, a = {flags, missed, block_start_ts, deadline_ns, nframes | rate << 32} (gl copies,
 *              0 unless gl holds this block: they rebuild a block whose BLOCK_START record was lost)
 *   CYCLE_START: seq = 0, a = {clock_nsec, next_nsec, duration, position, cycle_flags}
 *   CYCLE_END: seq = block that started inside the cycle (0 = none), a = {missed, delivered, cycle_start_ts} */
struct rec_block {
	struct rec_hdr h;
	__u64 seq;
	__u64 a[5];
	__u32 phase;
	__u32 pad;
};

struct rec_wake   { struct rec_hdr h; __u32 wakee_tid, waker_pid, waker_tid; char waker_comm[16]; };
struct rec_offcpu { struct rec_hdr h; __u64 off_ts, on_ts, run_delay_ns; __u32 waker_tid; __u32 pad; };
struct rec_name   { struct rec_hdr h; __u32 pid; char comm[16]; };

/* drill-down per-event record: h.ts = completion time, dur = h.ts - entry_ts,
 * stack_ts = entry ts of this or the nearest enclosing sampled entry (0 = none) */
struct rec_event {
	struct rec_hdr h;
	__u64 seq, entry_ts, stack_ts, aux;
	__u32 id;
	__u32 pid_;
	__u8  kind;
	__u8  pkind;
	__u16 flags;
	__s32 status;
	__u32 waker_tid;
	__u32 pad;
};

struct rec_unixlib { struct rec_hdr h; __u64 handle; __u32 pid, idx; };

/* REC_FORK (new process: pid = child tgid, h.tid = child tid), REC_THREAD (new thread of a
 * traced process), REC_EXIT (flags bit0 = group dead; the thread's own counters) */
struct rec_task {
	struct rec_hdr h;
	__u32 pid, parent_pid, parent_tid, flags;
	char comm[16];
	__u32 unmatched, first_exit, abandoned, overflow, open_at_exit, never_returned;
};

/* drill-down only: one pairing anomaly with the thread's in-flight stack at that moment
 * (kinds/ids/frames[0 .. depth-1], before any pop).  kind/id/frame: the new entry (overflow,
 * never_returned), the exit (unmatched_exit; id 0 when the exit does not carry it) or the entry
 * an exit completed (abandoned).  aux: restore_flags of an unmatched syscall exit, the status
 * of other unmatched exits, the index of the first popped entry (never_returned) or of the
 * completed entry (abandoned). */
struct rec_anomaly {
	struct rec_hdr h;
	__u64 frame;
	__u64 frames[INFLIGHT_DEPTH];
	__u32 ids[INFLIGHT_DEPTH];
	__u32 id;
	__u32 aux;
	__u8  kinds[INFLIGHT_DEPTH];
	__u8  what;           /* enum wt_anomaly */
	__u8  kind;
	__u8  depth;
	__u8  pad;
	__u32 pad2;
};

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

/* ---- user space only: JIT prologue classifier (stack self-check) -------- */
#ifndef __bpf__
/*
 * Classify one JITed BPF function (x86-64 JIT, kernel 6.14+) by decoding its prologue
 * (arch/x86/net/bpf_jit_comp.c: emit_prologue, push_callee_regs, emit_priv_frame_ptr):
 *
 *   [cfi/endbr/nop5/nop3 or xor rax,rax]  push rbp; mov rbp,rsp   (55 48 89 e5, within 32 bytes)
 *   [endbr64]                                                      (f3 0f 1e fa)
 *   sub rsp, imm32                         -> KERNEL, *depth = imm32 (48 81 ec imm32)
 *   [push rbx | push r12..r15]...                                  (53 | 41 54..57)
 *   [movabs r12, imm64]                    (arena base)            (49 bc imm64)
 *   movabs r9, imm64; add r9, gs:[disp32]  -> PRIVATE per-CPU stack (49 b9 imm64; 65 4c 03 0c 25 disp32)
 *   anything else                          -> NONE (no BPF frame was set up)
 *
 * The decoder only walks the instructions the JIT emits there, so body bytes are never
 * mistaken for a prologue.  A function that touches r10 in its xlated code but shows
 * NONE is inconsistent: the loader turns that into JIT_STACK_UNKNOWN (and refuses).
 * `push rbp; mov rbp,rsp` not found -> UNKNOWN.
 */
enum jit_stack_class {
	JIT_STACK_UNKNOWN = 0, JIT_STACK_NONE = 1, JIT_STACK_KERNEL = 2, JIT_STACK_PRIVATE = 3
};
#define JIT_PROLOGUE_SEARCH 32

static inline int jit_prologue_class(const unsigned char *img, unsigned long len, __u32 *depth)
{
	unsigned long i, p = 0;
	int k, found = 0;

	if (depth)
		*depth = 0;
	if (!img || len < 4)
		return JIT_STACK_UNKNOWN;
	for (i = 0; i + 4 <= len && i <= JIT_PROLOGUE_SEARCH; i++) {
		if (img[i] == 0x55 && img[i + 1] == 0x48 && img[i + 2] == 0x89 && img[i + 3] == 0xe5) {
			p = i + 4;
			found = 1;
			break;
		}
	}
	if (!found)
		return JIT_STACK_UNKNOWN;
	if (p + 4 <= len && img[p] == 0xf3 && img[p + 1] == 0x0f && img[p + 2] == 0x1e && img[p + 3] == 0xfa)
		p += 4;                                        /* endbr64 (X86_TAIL_CALL_OFFSET) */
	if (p + 7 <= len && img[p] == 0x48 && img[p + 1] == 0x81 && img[p + 2] == 0xec) {
		if (depth)
			*depth = (__u32)img[p + 3] | ((__u32)img[p + 4] << 8) | ((__u32)img[p + 5] << 16) |
				 ((__u32)img[p + 6] << 24);
		return JIT_STACK_KERNEL;                       /* sub rsp, imm32 */
	}
	for (k = 0; k < 6; k++) {                              /* push_callee_regs / push_r12 */
		if (p + 1 <= len && img[p] == 0x53) {
			p += 1;
			continue;
		}
		if (p + 2 <= len && img[p] == 0x41 && img[p + 1] >= 0x54 && img[p + 1] <= 0x57) {
			p += 2;
			continue;
		}
		break;
	}
	if (p + 10 <= len && img[p] == 0x49 && img[p + 1] == 0xbc)
		p += 10;                                       /* movabs r12, arena_vm_start */
	if (p + 10 <= len && img[p] == 0x49 && img[p + 1] == 0xb9)
		return JIT_STACK_PRIVATE;                      /* movabs r9, priv_frame_ptr (+ add r9, gs:..) */
	return JIT_STACK_NONE;
}

static inline const char *jit_stack_class_name(int c)
{
	switch (c) {
	case JIT_STACK_NONE: return "kernel-stack";      /* no BPF frame at all */
	case JIT_STACK_KERNEL: return "kernel-stack";
	case JIT_STACK_PRIVATE: return "private-stack";
	default: return "unknown";
	}
}

/* xlated (verifier-rewritten) BPF code of one function: does it address its stack through
 * r10, and how deep (largest negative offset of an r10-based access or r10 copy + add)? */
struct wt_bpf_insn { __u8 code; __u8 regs; __s16 off; __s32 imm; };   /* = struct bpf_insn */

static inline int xlated_stack_depth(const struct wt_bpf_insn *insn, unsigned long n, __u32 *depth)
{
	unsigned long i;
	int used = 0;
	__u32 d = 0;

	for (i = 0; i < n; i++) {
		__u8 cls = insn[i].code & 0x07, dst = insn[i].regs & 0x0f, src = (insn[i].regs >> 4) & 0x0f;
		__s32 off = insn[i].off;

		if ((cls == 0x01 && src == 10) || ((cls == 0x02 || cls == 0x03) && dst == 10)) {   /* LDX / ST / STX */
			used = 1;
			if (off < 0 && (__u32)(-off) > d)
				d = (__u32)(-off);
		} else if (cls == 0x07 && (insn[i].code & 0xf0) == 0xb0 && (insn[i].code & 0x08) && src == 10) {
			used = 1;                              /* mov rX, r10: a stack pointer escapes */
			if (i + 1 < n && (insn[i + 1].code == 0x07) && (insn[i + 1].regs & 0x0f) == dst &&
			    insn[i + 1].imm < 0 && (__u32)(-insn[i + 1].imm) > d)
				d = (__u32)(-insn[i + 1].imm);  /* add rX, -N */
		}
		if (cls == 0x00 && insn[i].code == 0x18)       /* ld_imm64 takes two slots */
			i++;
	}
	if (depth)
		*depth = d;
	return used;
}
#endif /* !__bpf__ */

#endif /* WINE_TRACE_H */
