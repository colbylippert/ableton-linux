// SPDX-License-Identifier: GPL-2.0-only
/*
 * wine-trace.bpf.c — kernel side of the Wine interface profiler (libbpf CO-RE).
 *
 * Licensed GPL-2.0 because it uses GPL-only helpers (bpf_probe_read_user,
 * bpf_get_current_task_btf, ...).  The rest of the tracer follows the repo licence.
 *
 * See wine-trace.h for the record/map layouts and
 * ../../../plans/design-B-tracer-and-probes.md §3b–§3c for the design.
 *
 * Programs (attached by wine-trace.c; nothing auto-attaches):
 *   usdt      wine_syscall_entry/exit, wine_unixcall_entry/exit,
 *             wine_server_req_start/end, wine_server_wait_start/end,
 *             pipeasio_block_start/before_live/after_live/end, pipeasio_cycle_start/end
 *   fentry/fexit ntsync_char_ioctl + fentry ntsync_obj_ioctl        (--ntsync fentry)
 *   kprobe/kretprobe ntsync_char_ioctl + kprobe ntsync_obj_ioctl   (--ntsync kprobe)
 *   tracepoint syscalls:sys_enter/exit_ioctl                        (--ntsync tracepoint)
 *   tp_btf    sched_switch, sched_waking (+ irq-aware variant), sched_process_fork,
 *             sched_process_exit, task_rename
 *   perf_event on_perf_sample                                        (--mode sample)
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#define BPF_USDT_MAX_SPEC_CNT 1024   /* 14 probes x up to ~70 traced pids (default 256) */
#include <bpf/usdt.bpf.h>
#include "wine-trace.h"

char LICENSE[] SEC("license") = "GPL";

/* ------------------------------------------------------------------------
 * maps
 * ---------------------------------------------------------------------- */
struct agg_map {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, AGG_ENTRIES);
	__type(key, struct agg_key);
	__type(value, struct agg_val);
};
struct agg_map agg0 SEC(".maps");
struct agg_map agg1 SEC(".maps");
struct agg_map agg2 SEC(".maps");
struct agg_map agg3 SEC(".maps");

/* agg[4]: time ring.  Every key is written at its completion time `now` into
 * agg[(now / AGG_SLOT_NS) & 3] (the key's seq still says which block or window the
 * event belongs to, decided at entry).  While the clock is in slot window W, only
 * agg[W & 3] receives writes, so user space drains agg[(W - 2) & 3] without racing
 * the BPF side (which updates values in place) and merges keys by their seq. */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY_OF_MAPS);
	__uint(max_entries, AGG_SLOTS);
	__type(key, __u32);
	__array(values, struct agg_map);
} agg SEC(".maps") = {
	.values = { [0] = &agg0, [1] = &agg1, [2] = &agg2, [3] = &agg3 },
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_TIDS);
	__type(key, __u32);
	__type(value, struct inflight);
} inflight SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_TIDS);
	__type(key, __u32);
	__type(value, struct sched_ent);
} sched SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_PIDS);
	__type(key, __u32);
	__type(value, __u8);
} pids SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_TIDS);
	__type(key, __u32);
	__type(value, __u8);          /* enum wt_role */
} tids SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct cfg);
} cfg SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct global);
} gl SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, RINGBUF_MB_DEFAULT << 20);   /* overridden by --ringbuf-mb before load */
} rb SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, ST__COUNT);
	__type(key, __u32);
	__type(value, __u64);
} stats SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_UNIXLIBS);
	__type(key, struct unixlib_key);
	__type(value, __u32);
} unixlibs SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, MAX_TRIGGER_IDS);
	__type(key, __u32);
	__type(value, __u8);
} trigger_ids SEC(".maps");

/* ------------------------------------------------------------------------
 * small helpers
 * ---------------------------------------------------------------------- */
static __always_inline __u64 *stat_ptr(__u32 idx)
{
	return bpf_map_lookup_elem(&stats, &idx);
}

static __always_inline void stat_inc(__u32 idx)
{
	__u64 *p = stat_ptr(idx);
	if (p)
		(*p)++;
}

static __always_inline void stat_add(__u32 idx, __u64 n)
{
	__u64 *p = stat_ptr(idx);
	if (p)
		*p += n;
}

/* The consumer polls the ring every 25 ms on its own; waking it for each record would cost a
 * context switch per block phase.  Wake it only when the ring is more than a quarter full. */
static __always_inline __u64 rb_flags(void)
{
	return bpf_ringbuf_query(&rb, BPF_RB_AVAIL_DATA) > bpf_ringbuf_query(&rb, BPF_RB_RING_SIZE) / 4 ?
		BPF_RB_FORCE_WAKEUP : BPF_RB_NO_WAKEUP;
}

static __always_inline struct cfg *cfg_get(void)
{
	__u32 z = 0;
	return bpf_map_lookup_elem(&cfg, &z);
}

static __always_inline struct global *gl_get(void)
{
	__u32 z = 0;
	return bpf_map_lookup_elem(&gl, &z);
}

static __always_inline bool pid_traced(__u32 pid)
{
	return bpf_map_lookup_elem(&pids, &pid) != NULL;
}

/* --roles audio: USDT crossings only for audio-role threads (+ the callback tid) */
static __always_inline bool tid_wanted(const struct cfg *c, const struct global *g, __u32 tid)
{
	__u8 *r;

	if (c->roles == ROLES_ALL)
		return true;
	if (tid == g->callback_tid)
		return true;
	r = bpf_map_lookup_elem(&tids, &tid);
	return r && ROLE_IS_AUDIO(*r);
}

static __always_inline __u32 agg_slot(__u64 now)
{
	return (__u32)((now / AGG_SLOT_NS) & (AGG_SLOTS - 1));
}

/* Block association rule (design B §3b): the block in progress at entry time,
 * else the 100 ms window bucket (flagged between_blocks for the callback thread). */
static __always_inline __u64 assoc_seq(const struct global *g, __u32 tid, __u64 ts, __u16 *flags)
{
	__u64 seq = g->cur_seq;

	if (seq)
		return seq;
	*flags |= AGGF_WINDOW;
	if (tid == g->callback_tid)
		*flags |= AGGF_BETWEEN_BLOCKS;
	return WINDOW_BIT | (ts / WINDOW_NS);
}

static __always_inline void agg_add(__u64 now, __u64 seq, __u32 tid, __u16 kind, __u16 flags, __u32 id,
				    __u64 dur, __u64 oncpu, __u64 aux, __u32 waker)
{
	struct agg_key k = { .seq = seq, .tid = tid, .kind = kind, .flags = flags, .id = id, .pad = 0 };
	__u32 slot = agg_slot(now);
	struct agg_val *v;
	void *m;

	m = bpf_map_lookup_elem(&agg, &slot);
	if (!m)
		return;
	v = bpf_map_lookup_elem(m, &k);
	if (!v) {
		struct agg_val nv = { .count = 1, .total_ns = dur, .max_ns = dur, .oncpu_ns = oncpu,
				      .aux_ns = aux, .last_waker = waker, .pad = 0 };
		long err = bpf_map_update_elem(m, &k, &nv, BPF_NOEXIST);

		if (err == 0)
			return;
		if (err != -WT_EEXIST) {
			stat_inc(ST_AGG_FULL);
			return;
		}
		v = bpf_map_lookup_elem(m, &k);
		if (!v)
			return;
	}
	/* keys are per tid: only the owning thread (or the CPU switching it in) writes them */
	v->count++;
	v->total_ns += dur;
	if (dur > v->max_ns)
		v->max_ns = dur;
	v->oncpu_ns += oncpu;
	if (aux > v->aux_ns)
		v->aux_ns = aux;
	if (waker)
		v->last_waker = waker;
}

static __always_inline __u16 ntstatus_flags(__u32 st)
{
	if (st == WT_STATUS_TIMEOUT)
		return AGGF_TIMEOUT;
	if (st == WT_STATUS_USER_APC || st == WT_STATUS_ALERTED)
		return AGGF_ALERTED;
	if (st >= WT_STATUS_ABANDONED_WAIT_0 && st < WT_STATUS_ABANDONED_WAIT_0 + 64)
		return AGGF_OWNERDEAD;
	if ((st & 0xC0000000u) == 0xC0000000u)
		return AGGF_ERROR;
	return 0;
}

/* ------------------------------------------------------------------------
 * in-flight stack per tid (depth 4), entry/exit pairing
 * ---------------------------------------------------------------------- */
static __always_inline struct inflight *inflight_get(__u32 tid, bool create)
{
	struct inflight *f = bpf_map_lookup_elem(&inflight, &tid);

	if (f || !create)
		return f;
	{
		struct inflight z = {};

		bpf_map_update_elem(&inflight, &tid, &z, BPF_NOEXIST);
	}
	return bpf_map_lookup_elem(&inflight, &tid);
}

static __always_inline struct inflight_ent *inflight_push(struct inflight *f, __u16 kind, __u16 flags,
							  __u32 id, __u64 frame, __u64 ts, __u64 seq)
{
	__u32 d = f->depth;
	struct inflight_ent *e;

	if (d >= INFLIGHT_DEPTH) {
		f->drops++;
		stat_inc(ST_INFLIGHT_OVERFLOW);
		return NULL;
	}
	e = &f->s[d & (INFLIGHT_DEPTH - 1)];
	e->ts = ts;
	e->seq = seq;
	e->frame = frame;
	e->off_ns = 0;
	e->id = id;
	e->kind = kind;
	e->sampled = 0;
	e->flags = flags;
	f->depth = d + 1;
	return e;
}

/* index of the newest in-flight entry of `kind` (and `frame` when match_frame), or -1 */
static __always_inline int inflight_find(const struct inflight *f, __u16 kind, __u64 frame, bool match_frame)
{
	__u32 d = f->depth;
	int found = -1;
	__u32 i;

#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		if (i < d && f->s[i].kind == kind && (!match_frame || f->s[i].frame == frame))
			found = (int)i;
	}
	return found;
}

static __always_inline __u32 wait_waker(__u32 tid, __u64 entry_ts)
{
	struct sched_ent *s = bpf_map_lookup_elem(&sched, &tid);

	if (s && s->last_wake_ts >= entry_ts)
		return s->last_waker;
	return 0;
}

static __always_inline void emit_event(__u32 tid, __u64 now, const struct inflight_ent *e, __u64 stack_ts,
				       __u16 flags, __s32 status, __u32 waker)
{
	struct rec_event *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		stat_inc(ST_RINGBUF_DROP);
		return;
	}
	r->h.type = REC_EVENT;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = now;
	r->seq = e->seq;
	r->entry_ts = e->ts;
	r->stack_ts = stack_ts;
	r->id = e->id;
	r->kind = e->kind;
	r->flags = flags;
	r->status = status;
	r->waker_tid = waker;
	bpf_ringbuf_submit(r, rb_flags());
}

/* pop entry `idx` (and everything nested above it), aggregate it, emit the drill-down line */
static __always_inline void complete_event(const struct cfg *c, __u32 tid, struct inflight *f, int idx,
					   __u64 now, __u16 extra_flags, __s32 status, __u32 waker)
{
	struct inflight_ent e;
	__u32 abandoned;
	__u64 dur, oncpu;
	__u16 flags;

	idx &= INFLIGHT_DEPTH - 1;
	e = f->s[idx];
	abandoned = f->depth - 1 - (__u32)idx;
	if (abandoned)
		stat_add(ST_ABANDONED_ENTRY, abandoned);
	f->depth = (__u8)idx;

	dur = now - e.ts;
	oncpu = dur > e.off_ns ? dur - e.off_ns : 0;
	flags = e.flags | extra_flags;
	agg_add(now, e.seq, tid, e.kind, flags, e.id, dur, oncpu, 0, waker);

	if (c->mode == MODE_DRILLDOWN) {
		/* this entry's sample, or the nearest enclosing sampled entry (server_req / ntsync
		 * inside a syscall inherit the enclosing stack sample) */
		__u64 stack_ts = e.sampled ? e.ts : 0;
		int i;

#pragma unroll
		for (i = INFLIGHT_DEPTH - 1; i >= 0; i--) {
			if (!stack_ts && i < idx && f->s[i].sampled)
				stack_ts = f->s[i].ts;
		}
		emit_event(tid, now, &e, stack_ts, flags, status, waker);
	}
}

/* ------------------------------------------------------------------------
 * stack sampling (rec_stack) — fixed size classes reserved straight in the
 * ring buffer (uprobe programs are preemptible, so a per-CPU scratch would race)
 * ---------------------------------------------------------------------- */
struct stack_req {
	__u64 ts, seq, frame, rsp, rip;
	const __u64 *regs;      /* NULL: read the 0xa0-byte block from `frame` */
	__u32 tid, id;
	__u16 kind;
	__u16 nbytes;
};

static __always_inline bool want_stack(const struct cfg *c, const struct global *g, __u64 now, __u32 id)
{
	if (c->mode == MODE_SAMPLE)
		return false;
	if (c->trigger_count && bpf_map_lookup_elem(&trigger_ids, &id))
		return true;
	if (c->sample_n) {
		__u64 *ctr = stat_ptr(ST_SAMPLE_CTR);

		if (ctr) {
			__u64 n = (*ctr)++;

			if (n % c->sample_n == 0)
				return true;
		}
	}
	if (c->slack_thresh_pct && g->cur_seq && g->deadline_ns && g->period_ns) {
		__u64 margin = g->period_ns * c->slack_thresh_pct / 100;

		if (now + margin >= g->deadline_ns)
			return true;
	}
	return false;
}

/* fills r; returns the number of stack bytes copied (0 = nothing useful: discard) */
static __always_inline __u32 stack_fill(struct rec_stack *r, const __u32 cap, const struct stack_req *q)
{
	__u32 n, got = 0;
	__u64 rsp;

	r->h.type = REC_STACK;
	r->h.tid = q->tid;
	r->h.ts = q->ts;
	r->seq = q->seq;
	r->frame = q->frame;
	r->rip = q->rip;
	r->id = q->id;
	r->kind = q->kind;
	if (q->regs) {
		__builtin_memcpy(r->regs, q->regs, sizeof(r->regs));
	} else if (!q->frame || bpf_probe_read_user(r->regs, sizeof(r->regs), (const void *)q->frame)) {
		__builtin_memset(r->regs, 0, sizeof(r->regs));
	}
	rsp = q->rsp ? q->rsp : r->regs[17];   /* unix calls: frame->rsp */
	r->rsp = rsp;

	n = q->nbytes;
	if (n > cap)
		n = cap;
	n &= ~7u;
	if (rsp) {
		/* a thread near the top of its stack cannot supply the full window: halve on EFAULT */
		if (n >= 64 && bpf_probe_read_user(r->bytes, n, (const void *)rsp) == 0) {
			got = n;
		} else {
			n >>= 1;
			if (n >= 64 && bpf_probe_read_user(r->bytes, n, (const void *)rsp) == 0) {
				got = n;
			} else {
				n >>= 1;
				if (n >= 64 && bpf_probe_read_user(r->bytes, n, (const void *)rsp) == 0) {
					got = n;
				} else {
					n >>= 1;
					if (n >= 64 && bpf_probe_read_user(r->bytes, n, (const void *)rsp) == 0)
						got = n;
				}
			}
		}
	}
	r->nbytes = (__u16)got;
	r->h.len = (__u16)(sizeof(*r) + got);
	return got;
}

static __always_inline int emit_stack(const struct stack_req *q)
{
	struct rec_stack *r;
	__u32 want = q->nbytes, got;

	/* one reservation per size class (the verifier needs a constant size); a record
	 * whose stack window could not be read at all is discarded, not submitted */
	if (want <= 512) {
		r = bpf_ringbuf_reserve(&rb, sizeof(*r) + 512, 0);
		if (!r)
			goto drop;
		got = stack_fill(r, 512, q);
	} else if (want <= 1024) {
		r = bpf_ringbuf_reserve(&rb, sizeof(*r) + 1024, 0);
		if (!r)
			goto drop;
		got = stack_fill(r, 1024, q);
	} else if (want <= 2048) {
		r = bpf_ringbuf_reserve(&rb, sizeof(*r) + 2048, 0);
		if (!r)
			goto drop;
		got = stack_fill(r, 2048, q);
	} else {
		r = bpf_ringbuf_reserve(&rb, sizeof(*r) + STACK_BYTES_MAX, 0);
		if (!r)
			goto drop;
		got = stack_fill(r, STACK_BYTES_MAX, q);
	}
	if (!got) {
		bpf_ringbuf_discard(r, BPF_RB_NO_WAKEUP);
		stat_inc(ST_STACK_READ_FAIL);
		return -1;
	}
	bpf_ringbuf_submit(r, rb_flags());
	stat_inc(ST_STACKS);
	return 0;
drop:
	stat_inc(ST_RINGBUF_DROP);
	return -1;
}

static __always_inline __u16 clamp_stack_bytes(__u32 v)
{
	if (v < STACK_BYTES_MIN)
		v = STACK_BYTES_MIN;
	if (v > STACK_BYTES_MAX)
		v = STACK_BYTES_MAX;
	return (__u16)v;
}

/* common entry path for syscall / unix-call entries */
static __always_inline int crossing_entry(__u16 kind, __u32 id, __u64 frame, __u64 rsp, __u64 rip)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	const struct global *g;
	struct inflight *f;
	struct inflight_ent *e = NULL;
	__u64 now, seq;
	__u16 fl = 0;

	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	if (!tid_wanted(c, g, tid)) {
		stat_inc(ST_FILTERED);
		return 0;
	}
	now = bpf_ktime_get_ns();
	seq = assoc_seq(g, tid, now, &fl);

	if (c->no_exit) {
		agg_add(now, seq, tid, kind, fl, id, 0, 0, 0, 0);
	} else {
		f = inflight_get(tid, true);
		if (f)
			e = inflight_push(f, kind, fl, id, frame, now, seq);
	}

	/* design B section 3c: stacks only at syscall / unix-call entries.  server_req and
	 * server_wait entries have no frame or user rsp (and would consume the 1/N counter);
	 * their events inherit the enclosing entry's sample.  `kind` is a constant after
	 * inlining, so the stack code drops out of the server_* programs entirely. */
	if ((kind == KIND_SYSCALL || kind == KIND_UNIXCALL) && want_stack(c, g, now, id)) {
		struct stack_req q = {
			.ts = now, .seq = seq, .frame = frame, .rsp = rsp, .rip = rip, .regs = NULL,
			.tid = tid, .id = id, .kind = kind, .nbytes = clamp_stack_bytes(c->stack_bytes),
		};

		if (emit_stack(&q) == 0 && e)
			e->sampled = 1;
	}
	return 0;
}

/* miss_stat: the counter for an exit that matches no in-flight entry (ST_UNMATCHED_EXIT,
 * or ST_UNIXCALL_SLOW_EXIT for the unix-call slow path's syscall_exit) */
static __always_inline int crossing_exit(__u16 kind, __u64 frame, bool match_frame, __u16 extra, __s32 status,
					 __u32 miss_stat)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	struct inflight *f;
	int i;

	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	if (!c)
		return 0;
	f = inflight_get(tid, false);
	if (!f) {
		/* init_syscall_frame's tail jumps to the return label: one unmatched exit per thread */
		if (c->roles == ROLES_ALL)
			stat_inc(ST_THREAD_START_EXIT);
		return 0;
	}
	i = inflight_find(f, kind, frame, match_frame);
	if (i < 0) {
		stat_inc(miss_stat);
		return 0;
	}
	{
		__u64 now = bpf_ktime_get_ns();
		__u32 waker = wait_waker(tid, f->s[i & (INFLIGHT_DEPTH - 1)].ts);

		complete_event(c, tid, f, i, now, extra, status, waker);
	}
	return 0;
}

/* ------------------------------------------------------------------------
 * USDT: wine:* (ntdll.so, patch 0108)
 * ---------------------------------------------------------------------- */
SEC("usdt")
int BPF_USDT(wine_syscall_entry, __s32 id, __u64 frame, __u64 user_rsp, __u64 user_rip)
{
	stat_inc(ST_HIT_SYSCALL_ENTRY);
	return crossing_entry(KIND_SYSCALL, (__u32)id, frame, user_rsp, user_rip);
}

SEC("usdt")
int BPF_USDT(wine_syscall_exit, __s32 status, __u64 frame, __s32 id, __s32 restore_flags)
{
	__u16 extra = ntstatus_flags((__u32)status);

	stat_inc(ST_HIT_SYSCALL_EXIT);
	(void)id;
	if ((__u32)restore_flags & WT_RESTORE_FLAGS_INCOMPLETE_FRAME_CONTEXT) {
		/* The unix-call dispatcher marks every unix-call frame INCOMPLETE_FRAME_CONTEXT and
		 * its slow path returns through the syscall dispatcher's return label after
		 * unixcall_exit already popped the KIND_UNIXCALL entry: no syscall entry exists for
		 * it, so a miss is expected and counted apart from the genuine unmatched exits. */
		extra |= AGGF_INCOMPLETE;
		return crossing_exit(KIND_SYSCALL, frame, true, extra, status, ST_UNIXCALL_SLOW_EXIT);
	}
	return crossing_exit(KIND_SYSCALL, frame, true, extra, status, ST_UNMATCHED_EXIT);
}

static __always_inline __u32 unixlib_index(__u32 pid, __u64 handle, __u32 tid, __u64 now)
{
	struct unixlib_key k = { .pid = pid, .pad = 0, .handle = handle };
	struct global *g;
	__u32 *p, idx;

	p = bpf_map_lookup_elem(&unixlibs, &k);
	if (p)
		return *p;
	g = gl_get();
	if (!g)
		return 0xffff;
	idx = __sync_fetch_and_add(&g->unixlib_next, 1) + 1;
	if (idx > 0xfffe)
		return 0xffff;
	if (bpf_map_update_elem(&unixlibs, &k, &idx, BPF_NOEXIST) == 0) {
		struct rec_unixlib *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

		if (r) {
			r->h.type = REC_UNIXLIB;
			r->h.len = sizeof(*r);
			r->h.tid = tid;
			r->h.ts = now;
			r->handle = handle;
			r->pid = pid;
			r->idx = idx;
			bpf_ringbuf_submit(r, rb_flags());
		} else {
			stat_inc(ST_RINGBUF_DROP);
		}
		return idx;
	}
	p = bpf_map_lookup_elem(&unixlibs, &k);
	return p ? *p : 0xffff;
}

SEC("usdt")
int BPF_USDT(wine_unixcall_entry, __u64 handle, __s32 code, __u64 frame, __u64 caller_rip)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	__u32 idx, id;

	stat_inc(ST_HIT_UNIXCALL_ENTRY);
	if (!pid_traced(pid))
		return 0;
	idx = unixlib_index(pid, handle, tid, bpf_ktime_get_ns());
	id = (idx << 16) | ((__u32)code & 0xffff);
	/* rsp = 0: stack_fill takes frame->rsp from the register block */
	return crossing_entry(KIND_UNIXCALL, id, frame, 0, caller_rip);
}

SEC("usdt")
int BPF_USDT(wine_unixcall_exit, __s32 status, __u64 frame)
{
	stat_inc(ST_HIT_UNIXCALL_EXIT);
	return crossing_exit(KIND_UNIXCALL, frame, true, ntstatus_flags((__u32)status), status, ST_UNMATCHED_EXIT);
}

SEC("usdt")
int BPF_USDT(wine_server_req_start, __s32 req_type)
{
	stat_inc(ST_HIT_SERVER_REQ_START);
	return crossing_entry(KIND_SERVER_REQ, (__u32)req_type, (__u32)req_type, 0, 0);
}

SEC("usdt")
int BPF_USDT(wine_server_req_end, __s32 req_type, __s32 status)
{
	stat_inc(ST_HIT_SERVER_REQ_END);
	return crossing_exit(KIND_SERVER_REQ, (__u32)req_type, true, ntstatus_flags((__u32)status), status,
			     ST_UNMATCHED_EXIT);
}

SEC("usdt")
int BPF_USDT(wine_server_wait_start, __s32 flags)
{
	stat_inc(ST_HIT_SERVER_WAIT_START);
	return crossing_entry(KIND_SERVER_WAIT, (__u32)flags, 0, 0, 0);
}

SEC("usdt")
int BPF_USDT(wine_server_wait_end, __s32 ret)
{
	stat_inc(ST_HIT_SERVER_WAIT_END);
	return crossing_exit(KIND_SERVER_WAIT, 0, false, ntstatus_flags((__u32)ret), ret, ST_UNMATCHED_EXIT);
}

/* ------------------------------------------------------------------------
 * USDT: pipeasio:* (pipeasio64.dll.so, patch pipeasio/0017)
 * ---------------------------------------------------------------------- */
static __always_inline void emit_block(__u32 tid, __u64 now, __u8 phase, __u64 seq, __u64 clock_nsec,
				       __u64 deadline_ns, __u32 nframes, __u32 rate, __u32 flags, __u32 missed)
{
	struct rec_block *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		stat_inc(ST_RINGBUF_DROP);
		return;
	}
	r->h.type = REC_BLOCK;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = now;
	r->seq = seq;
	r->clock_nsec = clock_nsec;
	r->deadline_ns = deadline_ns;
	r->nframes = nframes;
	r->rate = rate;
	r->flags = flags;
	r->missed = missed;
	r->phase = phase;
	bpf_ringbuf_submit(r, rb_flags());
}

SEC("usdt")
int BPF_USDT(pipeasio_block_start, __u64 seq, __u32 nframes, __u32 rate, __u64 clock_nsec, __u64 deadline_ns,
	     __u32 flags)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	struct global *g;
	__u64 now;

	stat_inc(ST_HIT_BLOCK_START);
	if (!pid_traced(pid))
		return 0;
	g = gl_get();
	if (!g)
		return 0;
	now = bpf_ktime_get_ns();
	g->cur_seq = seq;
	g->callback_tid = tid;
	g->block_start_ts = now;
	g->deadline_ns = deadline_ns;
	g->epoch = seq >> AGG_EPOCH_SHIFT;
	g->nframes = nframes;
	g->rate = rate;
	g->period_ns = rate ? ((__u64)nframes * 1000000000ULL + rate / 2) / rate : 0;
	g->blocks++;
	emit_block(tid, now, PHASE_BLOCK_START, seq, clock_nsec, deadline_ns, nframes, rate, flags, 0);
	return 0;
}

SEC("usdt")
int BPF_USDT(pipeasio_block_before_live, __u64 seq)
{
	__u64 pt = bpf_get_current_pid_tgid();

	stat_inc(ST_HIT_BLOCK_BEFORE_LIVE);
	if (!pid_traced(pt >> 32))
		return 0;
	emit_block((__u32)pt, bpf_ktime_get_ns(), PHASE_BEFORE_LIVE, seq, 0, 0, 0, 0, 0, 0);
	return 0;
}

SEC("usdt")
int BPF_USDT(pipeasio_block_after_live, __u64 seq)
{
	__u64 pt = bpf_get_current_pid_tgid();

	stat_inc(ST_HIT_BLOCK_AFTER_LIVE);
	if (!pid_traced(pt >> 32))
		return 0;
	emit_block((__u32)pt, bpf_ktime_get_ns(), PHASE_AFTER_LIVE, seq, 0, 0, 0, 0, 0, 0);
	return 0;
}

SEC("usdt")
int BPF_USDT(pipeasio_block_end, __u64 seq, __u32 flags, __u32 missed)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	struct global *g;
	__u64 now;

	stat_inc(ST_HIT_BLOCK_END);
	if (!pid_traced(pid))
		return 0;
	g = gl_get();
	if (!g)
		return 0;
	now = bpf_ktime_get_ns();
	emit_block(tid, now, PHASE_BLOCK_END, seq, g->block_start_ts, g->deadline_ns, g->nframes, g->rate,
		   flags, missed);
	g->last_seq = seq;
	g->cur_seq = 0;
	return 0;
}

SEC("usdt")
int BPF_USDT(pipeasio_cycle_start, __u64 clock_nsec, __u64 next_nsec, __u32 duration, __u64 position,
	     __u32 cycle_flags)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	const struct global *g;
	struct inflight *f;
	__u64 now, seq;
	__u16 fl = 0;

	stat_inc(ST_HIT_CYCLE_START);
	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	now = bpf_ktime_get_ns();
	emit_block(tid, now, PHASE_CYCLE_START, position, clock_nsec, next_nsec, duration, 0, cycle_flags, 0);
	seq = assoc_seq(g, tid, now, &fl);
	if (c->no_exit) {
		/* --no-exit: like every other entry, count at entry instead of pushing an in-flight
		 * entry that nothing may pop (the data-loop thread's stack would fill up) */
		agg_add(now, seq, tid, KIND_CYCLE, fl, 0, 0, 0, 0, 0);
		return 0;
	}
	f = inflight_get(tid, true);
	if (f)
		inflight_push(f, KIND_CYCLE, fl, 0, 0, now, seq);
	return 0;
}

SEC("usdt")
int BPF_USDT(pipeasio_cycle_end, __u32 missed, __u32 delivered)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	const struct global *g;
	struct inflight *f;
	__u64 now, joined = 0;
	int i;

	stat_inc(ST_HIT_CYCLE_END);
	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	now = bpf_ktime_get_ns();
	f = inflight_get(tid, false);
	if (f) {
		i = inflight_find(f, KIND_CYCLE, 0, false);
		if (i >= 0) {
			struct inflight_ent *e = &f->s[i & (INFLIGHT_DEPTH - 1)];

			/* a block that started inside this cycle owns the cycle */
			if (g->block_start_ts >= e->ts) {
				joined = g->cur_seq ? g->cur_seq : g->last_seq;
				if (joined) {
					e->seq = joined;
					e->flags &= (__u16)~(AGGF_WINDOW | AGGF_BETWEEN_BLOCKS);
				}
			}
			complete_event(c, tid, f, i, now, 0, 0, 0);
		}
	}
	emit_block(tid, now, PHASE_CYCLE_END, joined, 0, 0, 0, 0, delivered, missed);
	return 0;
}

/* ------------------------------------------------------------------------
 * NTSync (kernel side, no Wine patch): waits via ntsync_char_ioctl, wakes via
 * ntsync_obj_ioctl.  Three attachment variants share these two helpers.
 * ---------------------------------------------------------------------- */
static __always_inline int ntsync_wait_enter(__u32 cmd, __u64 parm)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	const struct global *g;
	struct nt_wait_args wa;
	struct inflight *f;
	__u64 now, seq;
	__u32 id;
	__u16 fl = 0;

	/* kernel-side probes fire for every process: count the traced ones only (the cost of the
	 * others shows in the program's run_cnt / run_time_ns) */
	if (!pid_traced(pid))
		return 0;
	stat_inc(ST_HIT_NTSYNC_WAIT);
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	if (!tid_wanted(c, g, tid)) {
		stat_inc(ST_FILTERED);
		return 0;
	}
	if (bpf_probe_read_user(&wa, sizeof(wa), (const void *)parm)) {
		wa.count = 0xff;
		wa.alert = 0;
	}
	id = NTSYNC_WAIT_ID(cmd == NTSYNC_IOC_WAIT_ALL, wa.alert, wa.count);
	now = bpf_ktime_get_ns();
	seq = assoc_seq(g, tid, now, &fl);
	if (c->no_exit) {
		agg_add(now, seq, tid, KIND_NTSYNC_WAIT, fl, id, 0, 0, 0, 0);
		return 0;
	}
	f = inflight_get(tid, true);
	if (f)
		inflight_push(f, KIND_NTSYNC_WAIT, fl, id, parm, now, seq);
	return 0;
}

/* strict: the caller knows this return belongs to a WAIT_ANY/WAIT_ALL (fexit sees cmd), so a
 * miss is counted in ST_NTSYNC_UNMATCHED.  The kretprobe and sys_exit_ioctl variants see every
 * ntsync_char_ioctl / ioctl return and pass strict = false: they complete the wait only when it
 * is the innermost in-flight entry of the thread (a thread sits in one ioctl at a time) and
 * return silently otherwise. */
static __always_inline int ntsync_wait_exit(long ret, bool strict)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	struct inflight *f;
	__u16 extra = 0;
	__u64 now;
	__u32 waker;
	int i;

	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	if (!c)
		return 0;
	f = inflight_get(tid, false);
	if (!f)
		return 0;
	i = inflight_find(f, KIND_NTSYNC_WAIT, 0, false);
	if (i < 0) {
		if (strict)
			stat_inc(ST_NTSYNC_UNMATCHED);
		return 0;
	}
	if (!strict && (__u32)i + 1 != f->depth)
		return 0;
	{
		const struct inflight_ent *e = &f->s[i & (INFLIGHT_DEPTH - 1)];

		if (ret == 0) {
			struct nt_wait_args wa;
			__u32 count = (e->id >> 8) & 0xff;

			if (bpf_probe_read_user(&wa, sizeof(wa), (const void *)e->frame) == 0 &&
			    (e->id & 2) && wa.index == count)
				extra = AGGF_ALERTED;
		} else if (ret == -WT_ETIMEDOUT) {
			extra = AGGF_TIMEOUT;
		} else if (ret == -WT_EINTR) {
			extra = AGGF_INTR;
		} else if (ret == -WT_EOWNERDEAD) {
			extra = AGGF_OWNERDEAD;
		} else {
			extra = AGGF_ERROR;
		}
		now = bpf_ktime_get_ns();
		waker = wait_waker(tid, e->ts);
	}
	complete_event(c, tid, f, i, now, extra, (__s32)ret, waker);
	return 0;
}

static __always_inline __u32 wake_id(__u32 cmd)
{
	switch (cmd) {
	case NTSYNC_IOC_EVENT_SET:    return WAKE_EVENT_SET;
	case NTSYNC_IOC_EVENT_PULSE:  return WAKE_EVENT_PULSE;
	case NTSYNC_IOC_SEM_RELEASE:  return WAKE_SEM_RELEASE;
	case NTSYNC_IOC_MUTEX_UNLOCK: return WAKE_MUTEX_UNLOCK;
	default:                      return WAKE_NONE;
	}
}

static __always_inline int ntsync_wake(__u32 cmd)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct global *g;
	__u64 now, seq;
	__u32 id;
	__u16 fl = 0;

	id = wake_id(cmd);
	if (!id)
		return 0;
	if (!pid_traced(pid))
		return 0;
	stat_inc(ST_HIT_NTSYNC_WAKE);
	g = gl_get();
	if (!g)
		return 0;
	now = bpf_ktime_get_ns();
	seq = assoc_seq(g, tid, now, &fl);
	agg_add(now, seq, tid, KIND_NTSYNC_WAKE, fl, id, 0, 0, 0, 0);
	return 0;
}

/* --ntsync fentry (needs /sys/kernel/btf/ntsync) */
SEC("fentry/ntsync_char_ioctl")
int BPF_PROG(fe_ntsync_char_ioctl, struct file *file, unsigned int cmd, unsigned long parm)
{
	(void)file;
	if (cmd == NTSYNC_IOC_WAIT_ANY || cmd == NTSYNC_IOC_WAIT_ALL)
		return ntsync_wait_enter(cmd, parm);
	return 0;
}

SEC("fexit/ntsync_char_ioctl")
int BPF_PROG(fx_ntsync_char_ioctl, struct file *file, unsigned int cmd, unsigned long parm, long ret)
{
	(void)file;
	(void)parm;
	if (cmd == NTSYNC_IOC_WAIT_ANY || cmd == NTSYNC_IOC_WAIT_ALL)
		return ntsync_wait_exit(ret, true);
	return 0;
}

SEC("fentry/ntsync_obj_ioctl")
int BPF_PROG(fe_ntsync_obj_ioctl, struct file *file, unsigned int cmd, unsigned long parm)
{
	(void)file;
	(void)parm;
	return ntsync_wake(cmd);
}

/* --ntsync kprobe (kallsyms names; the kretprobe cannot see cmd, so every
 * ntsync_char_ioctl return is offered, non-strictly, to the in-flight wait entry) */
SEC("kprobe/ntsync_char_ioctl")
int BPF_KPROBE(kp_ntsync_char_ioctl, struct file *file, unsigned int cmd, unsigned long parm)
{
	(void)file;
	if (cmd == NTSYNC_IOC_WAIT_ANY || cmd == NTSYNC_IOC_WAIT_ALL)
		return ntsync_wait_enter(cmd, parm);
	return 0;
}

SEC("kretprobe/ntsync_char_ioctl")
int BPF_KRETPROBE(kr_ntsync_char_ioctl, long ret)
{
	return ntsync_wait_exit(ret, false);
}

SEC("kprobe/ntsync_obj_ioctl")
int BPF_KPROBE(kp_ntsync_obj_ioctl, struct file *file, unsigned int cmd, unsigned long parm)
{
	(void)file;
	(void)parm;
	return ntsync_wake(cmd);
}

/* --ntsync tracepoint (syscalls:sys_enter/exit_ioctl filtered by the 'N' magic) */
SEC("tracepoint/syscalls/sys_enter_ioctl")
int tp_sys_enter_ioctl(struct trace_event_raw_sys_enter *ctx)
{
	__u32 cmd = (__u32)ctx->args[1];

	if (((cmd >> 8) & 0xff) != NTSYNC_IOC_MAGIC)
		return 0;
	if (cmd == NTSYNC_IOC_WAIT_ANY || cmd == NTSYNC_IOC_WAIT_ALL)
		return ntsync_wait_enter(cmd, (__u64)ctx->args[2]);
	return ntsync_wake(cmd);
}

SEC("tracepoint/syscalls/sys_exit_ioctl")
int tp_sys_exit_ioctl(struct trace_event_raw_sys_exit *ctx)
{
	return ntsync_wait_exit(ctx->ret, false);
}

/* ------------------------------------------------------------------------
 * scheduler
 * ---------------------------------------------------------------------- */
static __always_inline struct sched_ent *sched_get(__u32 tid, bool create)
{
	struct sched_ent *s = bpf_map_lookup_elem(&sched, &tid);

	if (s || !create)
		return s;
	{
		struct sched_ent z = {};

		bpf_map_update_elem(&sched, &tid, &z, BPF_NOEXIST);
	}
	return bpf_map_lookup_elem(&sched, &tid);
}

static __always_inline void emit_offcpu(__u32 tid, __u64 now, __u64 off_ts, __u64 run_delay, __u32 waker)
{
	struct rec_offcpu *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		stat_inc(ST_RINGBUF_DROP);
		return;
	}
	r->h.type = REC_OFFCPU;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = now;
	r->off_ts = off_ts;
	r->on_ts = now;
	r->run_delay_ns = run_delay;
	r->waker_tid = waker;
	bpf_ringbuf_submit(r, rb_flags());
}

SEC("tp_btf/sched_switch")
int BPF_PROG(on_sched_switch, bool preempt, struct task_struct *prev, struct task_struct *next,
	     unsigned int prev_state)
{
	const struct cfg *c;
	const struct global *g;
	struct sched_ent *s;
	__u32 ptgid, ptid, ntgid, ntid;
	__u64 now;

	(void)preempt;
	stat_inc(ST_HIT_SCHED_SWITCH);
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	now = bpf_ktime_get_ns();

	ptgid = prev->tgid;
	ptid = prev->pid;
	if (pid_traced(ptgid)) {
		s = sched_get(ptid, true);
		if (s) {
			__u16 fl = 0;

			if (s->on_ts) {
				__u64 on = now - s->on_ts;
				__u64 seq = assoc_seq(g, ptid, now, &fl);

				agg_add(now, seq, ptid, KIND_ONCPU, fl, 0, on, 0, 0, 0);
				fl = 0;
			}
			s->on_ts = 0;
			s->off_ts = now;
			s->off_seq = assoc_seq(g, ptid, now, &fl);
			if (prev_state == 0)
				fl |= AGGF_PREEMPTED;   /* still runnable */
			s->off_flags = fl;
			s->wake_ts = 0;
			s->waker_tid = 0;
		}
	}

	ntgid = next->tgid;
	ntid = next->pid;
	if (pid_traced(ntgid)) {
		s = sched_get(ntid, true);
		if (s) {
			if (s->off_ts) {
				__u64 off = now - s->off_ts;
				__u64 rd;
				struct inflight *f;

				if (s->off_flags & AGGF_PREEMPTED)
					rd = off;
				else
					rd = (s->wake_ts > s->off_ts) ? now - s->wake_ts : 0;
				agg_add(now, s->off_seq, ntid, KIND_OFFCPU, s->off_flags, s->waker_tid, off, rd, rd,
					s->waker_tid);
				f = bpf_map_lookup_elem(&inflight, &ntid);
				if (f) {
					int i;

#pragma unroll
					for (i = 0; i < INFLIGHT_DEPTH; i++) {
						if (i < f->depth)
							f->s[i].off_ns += off;
					}
				}
				if (c->mode == MODE_DRILLDOWN && off >= c->offcpu_min_ns)
					emit_offcpu(ntid, now, s->off_ts, rd, s->waker_tid);
				s->off_ts = 0;
			}
			s->on_ts = now;
		}
	}
	return 0;
}

static __always_inline int sched_waking_common(struct task_struct *p, bool irq)
{
	const struct cfg *c;
	struct sched_ent *s;
	__u32 wtgid, wtid, waker_tid, waker_pid;
	__u64 now, cur;

	stat_inc(ST_HIT_SCHED_WAKING);
	wtgid = p->tgid;
	wtid = p->pid;
	if (!pid_traced(wtgid))
		return 0;
	c = cfg_get();
	if (!c)
		return 0;
	s = sched_get(wtid, true);
	if (!s)
		return 0;
	now = bpf_ktime_get_ns();
	cur = bpf_get_current_pid_tgid();
	waker_tid = (__u32)cur;
	waker_pid = cur >> 32;
	if (irq || waker_tid == wtid) {
		/* interrupt context (timers, I/O completion): `current` is only the interrupted task */
		waker_tid = 0;
		waker_pid = 0;
	}
	s->wake_ts = now;
	s->waker_tid = waker_tid;
	s->last_wake_ts = now;
	s->last_waker = waker_tid;
	s->wakeups++;
	if (c->mode == MODE_DRILLDOWN) {
		struct rec_wake *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

		if (!r) {
			stat_inc(ST_RINGBUF_DROP);
			return 0;
		}
		r->h.type = REC_WAKE;
		r->h.len = sizeof(*r);
		r->h.tid = (__u32)cur;
		r->h.ts = now;
		r->wakee_tid = wtid;
		r->waker_pid = waker_pid;
		r->waker_tid = waker_tid;
		if (irq)
			__builtin_memcpy(r->waker_comm, "<irq>\0\0\0\0\0\0\0\0\0\0", 16);
		else
			bpf_get_current_comm(r->waker_comm, sizeof(r->waker_comm));
		bpf_ringbuf_submit(r, rb_flags());
	}
	return 0;
}

SEC("tp_btf/sched_waking")
int BPF_PROG(on_sched_waking, struct task_struct *p)
{
	return sched_waking_common(p, false);
}

/* Variant that recognises interrupt-context wakeups through the per-CPU preempt
 * count: the complement of the kernel's in_task(), i.e. NMI_MASK (0x00f00000) |
 * HARDIRQ_MASK (0x000f0000) | SOFTIRQ_OFFSET (0x00000100, serving a softirq).  The
 * local_bh_disable() count (SOFTIRQ_DISABLE_OFFSET, bits 9-15) is process context and
 * keeps its waker.  Weak ksym: resolves to NULL on kernels whose BTF lacks the
 * variable; the loader picks this program only when `__preempt_count` is a per-CPU
 * variable in vmlinux BTF. */
extern int __preempt_count __ksym __weak;

SEC("tp_btf/sched_waking")
int BPF_PROG(on_sched_waking_irq, struct task_struct *p)
{
	bool irq = false;

	if (bpf_ksym_exists(&__preempt_count)) {
		int *pc = bpf_this_cpu_ptr(&__preempt_count);

		if (pc && (*pc & 0x00ff0100))
			irq = true;
	}
	return sched_waking_common(p, irq);
}

/* ------------------------------------------------------------------------
 * task lifecycle: fork follow, thread names, exits
 * ---------------------------------------------------------------------- */
static __always_inline void emit_task(__u16 type, __u32 tid, __u64 now, __u32 pid, __u32 ppid, __u32 ptid,
				      __u32 flags, struct task_struct *src)
{
	struct rec_task *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		stat_inc(ST_RINGBUF_DROP);
		return;
	}
	r->h.type = type;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = now;
	r->pid = pid;
	r->parent_pid = ppid;
	r->parent_tid = ptid;
	r->flags = flags;
	if (src)
		BPF_CORE_READ_STR_INTO(&r->comm, src, comm);
	else
		__builtin_memset(r->comm, 0, sizeof(r->comm));
	bpf_ringbuf_submit(r, rb_flags());
}

SEC("tp_btf/sched_process_fork")
int BPF_PROG(on_sched_process_fork, struct task_struct *parent, struct task_struct *child)
{
	__u32 ppid = parent->tgid, ptid = parent->pid;
	__u32 cpid, ctid;

	if (!pid_traced(ppid))
		return 0;
	cpid = child->tgid;
	ctid = child->pid;
	if (cpid != ppid) {
		__u8 one = 1;

		/* new process: trace it kernel-side at once; user space re-attaches the USDTs */
		bpf_map_update_elem(&pids, &cpid, &one, BPF_ANY);
		emit_task(REC_FORK, ctid, bpf_ktime_get_ns(), cpid, ppid, ptid, 0, child);
	} else {
		emit_task(REC_THREAD, ctid, bpf_ktime_get_ns(), cpid, ppid, ptid, 0, child);
	}
	return 0;
}

SEC("tp_btf/sched_process_exit")
int BPF_PROG(on_sched_process_exit, struct task_struct *p, bool group_dead)
{
	__u32 pid = p->tgid, tid = p->pid;
	struct inflight *f;

	if (!pid_traced(pid))
		return 0;
	f = bpf_map_lookup_elem(&inflight, &tid);
	if (f) {
		if (f->depth)
			stat_add(ST_ABANDONED_ENTRY, f->depth);
		bpf_map_delete_elem(&inflight, &tid);
	}
	bpf_map_delete_elem(&sched, &tid);
	bpf_map_delete_elem(&tids, &tid);
	if (group_dead)
		bpf_map_delete_elem(&pids, &pid);
	emit_task(REC_EXIT, tid, bpf_ktime_get_ns(), pid, 0, 0, group_dead ? 1 : 0, NULL);
	return 0;
}

SEC("tp_btf/task_rename")
int BPF_PROG(on_task_rename, struct task_struct *task, const char *comm)
{
	__u32 pid = task->tgid;
	struct rec_name *r;

	if (!pid_traced(pid))
		return 0;
	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		stat_inc(ST_RINGBUF_DROP);
		return 0;
	}
	r->h.type = REC_NAME;
	r->h.len = sizeof(*r);
	r->h.tid = task->pid;
	r->h.ts = bpf_ktime_get_ns();
	r->pid = pid;
	bpf_probe_read_kernel_str(r->comm, sizeof(r->comm), comm);
	bpf_ringbuf_submit(r, rb_flags());
	return 0;
}

/* ------------------------------------------------------------------------
 * --mode sample: cpu-clock perf sampling (per CPU, pid-filtered here)
 * ---------------------------------------------------------------------- */
SEC("perf_event")
int on_perf_sample(struct bpf_perf_event_data *ctx)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 pid = pt >> 32, tid = (__u32)pt;
	const struct cfg *c;
	const struct global *g;
	__u64 regs[20];
	__u64 now, seq, cs;
	__u16 fl = 0;
	bool user;

	if (!pid_traced(pid))
		return 0;
	c = cfg_get();
	g = gl_get();
	if (!c || !g)
		return 0;
	stat_inc(ST_HIT_PERF_SAMPLE);
	if (!tid_wanted(c, g, tid))
		return 0;
	now = bpf_ktime_get_ns();
	cs = ctx->regs.csx;
	user = (cs & 3) == 3;
	if (user) {
		regs[0] = ctx->regs.ax;   regs[1] = ctx->regs.bx;   regs[2] = ctx->regs.cx;
		regs[3] = ctx->regs.dx;   regs[4] = ctx->regs.si;   regs[5] = ctx->regs.di;
		regs[6] = ctx->regs.r8;   regs[7] = ctx->regs.r9;   regs[8] = ctx->regs.r10;
		regs[9] = ctx->regs.r11;  regs[10] = ctx->regs.r12; regs[11] = ctx->regs.r13;
		regs[12] = ctx->regs.r14; regs[13] = ctx->regs.r15; regs[14] = ctx->regs.ip;
		regs[15] = cs;            regs[16] = ctx->regs.flags; regs[17] = ctx->regs.sp;
		regs[18] = ctx->regs.ssx; regs[19] = ctx->regs.bp;
	} else {
		/* kernel-mode sample (thread inside a syscall): the user registers at syscall entry */
		struct task_struct *t = bpf_get_current_task_btf();
		struct pt_regs *u = (struct pt_regs *)bpf_task_pt_regs(t);

		if (!u)
			return 0;
		regs[0] = BPF_CORE_READ(u, ax);   regs[1] = BPF_CORE_READ(u, bx);
		regs[2] = BPF_CORE_READ(u, cx);   regs[3] = BPF_CORE_READ(u, dx);
		regs[4] = BPF_CORE_READ(u, si);   regs[5] = BPF_CORE_READ(u, di);
		regs[6] = BPF_CORE_READ(u, r8);   regs[7] = BPF_CORE_READ(u, r9);
		regs[8] = BPF_CORE_READ(u, r10);  regs[9] = BPF_CORE_READ(u, r11);
		regs[10] = BPF_CORE_READ(u, r12); regs[11] = BPF_CORE_READ(u, r13);
		regs[12] = BPF_CORE_READ(u, r14); regs[13] = BPF_CORE_READ(u, r15);
		regs[14] = BPF_CORE_READ(u, ip);  regs[15] = BPF_CORE_READ(u, csx);
		regs[16] = BPF_CORE_READ(u, flags); regs[17] = BPF_CORE_READ(u, sp);
		regs[18] = BPF_CORE_READ(u, ssx); regs[19] = BPF_CORE_READ(u, bp);
	}
	seq = assoc_seq(g, tid, now, &fl);
	{
		struct stack_req q = {
			.ts = now, .seq = seq, .frame = regs[19], .rsp = regs[17], .rip = regs[14], .regs = regs,
			.tid = tid, .id = user ? 0 : 1, .kind = KIND_PERF,
			.nbytes = clamp_stack_bytes(c->stack_bytes),
		};

		emit_stack(&q);
	}
	return 0;
}
