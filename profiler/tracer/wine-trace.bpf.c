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
 *
 * ---- Why the code looks the way it does (B5: kernel oops, bpftrace aborts) ----------
 * The USDT programs are BPF_PROG_TYPE_KPROBE programs on uprobe(_multi) links.  They run
 * preemptible (migrate_disable only) and without a recursion guard: a second thread can
 * run the same program on the same CPU while the first run is preempted halfway.  Since
 * 6.14 the verifier gives KPROBE programs (and each subprogram) whose BPF stack is >= 64
 * bytes a per-CPU *private* stack, which those two runs then share: a spilled pointer of
 * the preempted run gets overwritten (the B5 oops in wine_syscall_exit).  Any per-CPU
 * map used as scratch has the same problem.  So, in every uprobe program and every
 * subprogram they call:
 *   * the BPF frame stays below 64 bytes: the stack holds only small scalars (a map key,
 *     the syscall id read from the frame); everything else lives in map values or
 *     ring-buffer records;
 *   * per-thread scratch (USDT arguments, NTSync wait arguments, accumulator, in-flight
 *     stack) is in the thread's own `struct tstate`, an array slot claimed by the thread:
 *     no other thread ever writes it (the scheduler programs use their own fields), and a
 *     thread cannot run two of its programs at once;
 *   * ring-buffer records are reserved first and filled in place (bpf_usdt_arg and
 *     bpf_probe_read_user write straight into them; each reservation is private memory);
 *   * counters are atomic adds on global data (no in-flight pointers, no lost updates);
 *   * no per-CPU maps at all.
 * The loader reads the JIT image of every program and subprogram after load and refuses to
 * attach when a uprobe program landed on a private stack (wine-trace.c: stack_self_check).
 * fentry/fexit/tp_btf programs have the kernel's per-program recursion guard and the
 * scheduler tracepoints run non-preemptible; they follow the same rules anyway.
 *
 * ---- Cost per hit (B5c) ---------------------------------------------------------------
 * Live makes ~1000 probe hits per 1.33 ms block, so every program is on a budget of tens of
 * nanoseconds.  `perf record` of a traced Live run (B5c) put the BPF time into: the user
 * reads of bpf_probe_read_user (and page faults of stack windows that ran off the top of a
 * stack), bpf_ktime_get_ns, the tid hash-map lookup (jhash + a bcmp call), the per-crossing
 * agg-map update, and ring-buffer lock contention when every AudioCalc worker flushed at the
 * same moment.  Hence:
 *   * thread state is an array slot (inlined lookup, see struct tstate);
 *   * a completed crossing is folded into the thread's accumulator (hashed slots, one key
 *     and one value line); the accumulator goes to user space as one REC_AGG record per
 *     thread about every second block, at a blocking wait (the workers reach their waits at
 *     different times) rather than at their first commit of a block (they all wake together);
 *   * NTSync hit counts are per-thread fields, not atomic adds on a shared counter;
 *   * the random stack sampler counts down per thread (one prandom per sample); a stack
 *     window stops at the first unreadable page found for the thread (one fault per stack,
 *     not one per sample);
 *   * the slack trigger reads its per-block budget before the atomic add, which has a cache
 *     line of its own (struct global);
 *   * the NTSync programs find a traced thread through its slot and check the pid map only
 *     for threads without one;
 *   * records never force a consumer wakeup (the loader polls every 25 ms).
 * The agg hash maps remain for the scheduler programs (drill-down, --sched on).
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
 * configuration and global data
 * ---------------------------------------------------------------------- */
const volatile struct wt_config CFG = {
	.sample_n = SAMPLE_N_SUMMARY, .stack_bytes = STACK_BYTES_DEFAULT,
	.slack_thresh_pct = SLACK_THRESH_PCT_DEFAULT, .slack_samples = SLACK_SAMPLES_PER_BLOCK_DEFAULT,
	.offcpu_min_ns = OFFCPU_MIN_NS_DEFAULT, .callback_return_id = NO_SYSCALL_ID,
};

struct global gl = {};
__u64 counters[CT__COUNT] = {};
__u64 hits[HIT__COUNT] = {};
/* bumped by the loader after every change of the `tids` map (audio-role threads): a thread
 * re-reads its own entry only then (ts_audio).  A cache line of its own: every wait reads it,
 * the loader writes it when a thread's role changes. */
__u32 role_gen __attribute__((aligned(64))) = 0;

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

/* agg[4]: time ring of the scheduler keys (on-CPU / off-CPU intervals, --sched on; the
 * crossings travel in REC_AGG records).  Every key is written at its completion time `now`
 * into agg[(now / AGG_SLOT_NS) & 3] (the key's seq still says which block or window the
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

/* thread state: MAX_TIDS slots, see struct tstate and ts_find / ts_claim */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, MAX_TIDS);
	__type(key, __u32);
	__type(value, struct tstate);
} tstate SEC(".maps");

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
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, RINGBUF_MB_DEFAULT << 20);   /* overridden by --ringbuf-mb before load */
} rb SEC(".maps");

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
#define cnt(i)        __sync_fetch_and_add(&counters[(i)], 1)
#define cnt_add(i, n) __sync_fetch_and_add(&counters[(i)], (n))
#define hit(i)        do { if (CFG.count_hits) __sync_fetch_and_add(&hits[(i)], 1); } while (0)

/* The consumer polls the ring every 25 ms whatever happens; a forced wakeup per record would
 * cost a context switch, and asking the ring how full it is (two bpf_ringbuf_query calls)
 * reads cache lines that the consumer and every producer write.  At 16 MiB (summary) or
 * 64 MiB (drill-down) the ring holds far more than 25 ms of records. */
#define RB_FLAGS BPF_RB_NO_WAKEUP

/* ---- thread state slots ---- */
static __always_inline struct tstate *ts_slot(__u32 i)
{
	__u32 key = i & (MAX_TIDS - 1);

	return bpf_map_lookup_elem(&tstate, &key);
}

/* the thread's slot, or NULL; never claims (scheduler programs, exits) */
static __always_inline struct tstate *ts_find(__u32 tid)
{
	__u32 h = (tid * TSTATE_HASH) >> (32 - MAX_TIDS_BITS);
	struct tstate *t;
	int k;

	if (!tid)
		return NULL;
#pragma unroll
	for (k = 0; k < TSTATE_PROBES; k++) {
		t = ts_slot(h + k);
		if (!t)
			return NULL;
		if (t->tid == tid)
			return t;
	}
	return NULL;
}

/* a freshly claimed slot: forget the previous owner (the in-flight stack and the accumulator
 * are empty with depth = acc_mask = 0) */
static __noinline int ts_reset(struct tstate *t)
{
	t->depth = 0;
	t->seen = 0;
	t->sample_cd = 0;
	t->acc_mask = 0;
	t->acc_n = 0;
	t->acc_epoch = 0;
	t->acc_t0 = 0;
	t->role_gen = ~0u;      /* read the role at the first wait */
	t->role_audio = 0;
	t->stack_top = 0;
	t->unmatched = 0;
	t->first_exit = 0;
	t->abandoned = 0;
	t->overflow = 0;
	t->open_at_exit = 0;
	t->never_returned = 0;
	t->nt_wait_hits = 0;
	t->nt_wake_hits = 0;
	t->off_ts = 0;
	t->on_ts = 0;
	t->wake_ts = 0;
	t->off_seq = 0;
	t->last_wake_ts = 0;
	t->waker_tid = 0;
	t->last_waker = 0;
	t->off_flags = 0;
	t->wakeups = 0;
	t->cycle_ts = 0;
	t->now0 = 0;
	return 0;
}

/* The thread's slot, claimed if it has none.  Only ever called in the thread's own context (its
 * USDT probes and its NTSync calls), so two claims for one tid cannot race; the compare-and-swap
 * settles threads whose tids hash onto the same slot. */
static __always_inline struct tstate *ts_claim(__u32 tid)
{
	__u32 h = (tid * TSTATE_HASH) >> (32 - MAX_TIDS_BITS);
	struct tstate *t;
	int k;

	if (!tid)
		return NULL;
#pragma unroll
	for (k = 0; k < TSTATE_PROBES; k++) {
		t = ts_slot(h + k);
		if (!t)
			return NULL;
		if (t->tid == tid)
			return t;
	}
#pragma unroll
	for (k = 0; k < TSTATE_PROBES; k++) {
		t = ts_slot(h + k);
		if (!t)
			return NULL;
		if (t->tid == 0 && __sync_val_compare_and_swap(&t->tid, 0, tid) == 0) {
			ts_reset(t);
			return t;
		}
	}
	cnt(CT_TSTATE_FULL);
	return NULL;
}

static __always_inline bool pid_traced(__u32 *pid)
{
	return bpf_map_lookup_elem(&pids, pid) != NULL;
}

/* The kernel-side probes fire for every process.  A thread with a slot belongs to a traced
 * process (slots are claimed only from probes of traced pids and released when their thread
 * exits), so the common case costs one array lookup; the pid map is consulted only for a thread
 * without a slot (its first NTSync call, or an untraced process). */
static __always_inline struct tstate *ts_traced(__u64 pt)
{
	__u32 key = (__u32)(pt >> 32);
	struct tstate *t = ts_find((__u32)pt);

	if (t)
		return t;
	if (!pid_traced(&key))
		return NULL;
	return ts_claim((__u32)pt);
}

/* --roles audio: USDT crossings only for audio-role threads (+ the callback tid) */
static __always_inline bool tid_wanted(__u32 *tid)
{
	__u8 *r;

	if (!CFG.roles_audio)
		return true;
	if (*tid == gl.callback_tid)
		return true;
	r = bpf_map_lookup_elem(&tids, tid);
	return r && ROLE_IS_AUDIO(*r);
}

/* Whether the thread has an audio role (the callback thread, or `tids`, which the loader keeps in
 * step with its classifier in every mode).  The entry is looked up again only after the loader
 * bumped role_gen, so a wait costs a compare, not a hash lookup.  The key is the slot's own tid
 * (map value memory, never the stack). */
static __always_inline bool ts_audio(struct tstate *t)
{
	__u32 g = role_gen;
	__u8 *r;

	if (t->tid == gl.callback_tid)
		return true;
	if (t->role_gen != g) {
		r = bpf_map_lookup_elem(&tids, &t->tid);
		t->role_audio = (r && ROLE_IS_AUDIO(*r)) ? 1 : 0;
		t->role_gen = g;
	}
	return t->role_audio != 0;
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

/* Block association rule (design B §3b): the block in progress at entry time, else the
 * 100 ms window bucket (flagged between_blocks for the callback thread). */
static __always_inline void assoc_into(__u64 *seq, __u16 *flags, __u32 tid, __u64 now)
{
	__u64 s = gl.cur_seq;

	if (s) {
		*seq = s;
		*flags = 0;
		return;
	}
	*seq = WINDOW_BIT | (now / WINDOW_NS);
	*flags = tid == gl.callback_tid ? (AGGF_WINDOW | AGGF_BETWEEN_BLOCKS) : AGGF_WINDOW;
}

/* --mode drilldown: one pairing anomaly with a copy of the thread's in-flight stack, so that the
 * entries that never return (or the exits that match nothing) can be identified.  Always runs
 * in the current thread's context; what_kind = what | kind << 8 (five arguments at most). */
static __noinline int emit_anomaly(struct tstate *t, __u32 what_kind, __u32 id, __u64 frame, __u32 aux)
{
	struct rec_anomaly *r;
	__u32 d = t->depth;
	int i;

	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		cnt(CT_ANOMALY_DROP);
		return 0;
	}
	r->h.type = REC_ANOMALY;
	r->h.len = sizeof(*r);
	r->h.tid = (__u32)bpf_get_current_pid_tgid();
	r->h.ts = bpf_ktime_get_ns();
	r->frame = frame;
	r->id = id;
	r->aux = aux;
	r->what = (__u8)what_kind;
	r->kind = (__u8)(what_kind >> 8);
	r->depth = (__u8)(d < INFLIGHT_DEPTH ? d : INFLIGHT_DEPTH);
	r->pad = 0;
	r->pad2 = 0;
#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		r->kinds[i] = t->s[i].kind;
		r->ids[i] = t->s[i].id;
		r->frames[i] = t->s[i].frame;
	}
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

#define anomaly(t, what, kind, id, frame, aux) \
	do { if (CFG.mode == MODE_DRILLDOWN) emit_anomaly((t), (what) | ((__u32)(kind) << 8), (id), (frame), (aux)); } while (0)

/* ------------------------------------------------------------------------
 * scheduler keys: one key/value under construction in a map value (struct aggscratch)
 * ---------------------------------------------------------------------- */
static __noinline int agg_commit(struct aggscratch *s)
{
	struct agg_val *v;
	void *m;
	long err;

	m = bpf_map_lookup_elem(&agg, &s->slot);
	if (!m)
		return 0;
	v = bpf_map_lookup_elem(m, &s->key);
	if (!v) {
		err = bpf_map_update_elem(m, &s->key, &s->val, BPF_NOEXIST);
		if (err == 0)
			return 0;
		if (err != -WT_EEXIST) {
			cnt(CT_AGG_FULL);
			return 0;
		}
		v = bpf_map_lookup_elem(m, &s->key);
		if (!v)
			return 0;
	}
	/* keys are per tid: only the CPU switching that thread updates them */
	v->count += s->val.count;
	v->total_ns += s->val.total_ns;
	if (s->val.max_ns > v->max_ns)
		v->max_ns = s->val.max_ns;
	v->oncpu_ns += s->val.oncpu_ns;
	if (s->val.aux_ns > v->aux_ns)
		v->aux_ns = s->val.aux_ns;
	if (s->val.last_waker)
		v->last_waker = s->val.last_waker;
	return 0;
}

/* fill s for a duration key and commit it */
static __always_inline void agg_add(struct aggscratch *s, __u64 now, __u64 seq, __u32 tid, __u8 kind,
				    __u16 flags, __u32 id, __u64 dur, __u64 oncpu, __u64 aux, __u32 waker)
{
	s->key.seq = seq;
	s->key.tid = tid;
	s->key.kind = kind;
	s->key.pkind = 0;
	s->key.flags = flags;
	s->key.id = id;
	s->key.pid_ = 0;
	s->val.count = 1;
	s->val.total_ns = dur;
	s->val.max_ns = dur;
	s->val.oncpu_ns = oncpu;
	s->val.aux_ns = aux;
	s->val.last_waker = waker;
	s->val.pad = 0;
	s->slot = (__u32)((now / AGG_SLOT_NS) & (AGG_SLOTS - 1));
	agg_commit(s);
}

/* ------------------------------------------------------------------------
 * per-thread crossing accumulator (struct tstate ak[] / av[], ACC_SLOTS slots)
 *
 * A completed crossing (or a count-only point event) is folded into the thread's own table: no
 * hash map, no atomic, no cache line another thread writes.  A key's slot is found by hashing
 * it and probing linearly; acc_mask says which slots are in use.  The table goes to user space
 * as one REC_AGG ring-buffer record (acc_flush)
 *   * before the thread blocks in an NTSync or wineserver wait: always for a thread without an
 *     audio role (ts_audio), and for an audio-role thread once it holds keys of two blocks or
 *     more, or half a table (the AudioCalc workers each reach their waits at their own time,
 *     so their records do not all contend for the ring at the block start, and a worker
 *     flushes about every second block);
 *   * at a commit when its keys are three blocks old (threads that never wait) or
 *     ACC_MAX_AGE_NS old (between blocks, and when Live is not playing);
 *   * when a new key finds the table full;
 *   * when the thread exits (on_sched_process_exit, or on_sched_switch for a dead task whose
 *     slot the exit program did not release);
 * and user space drains what is left from the slots at stop.  An AudioCalc worker makes ~60
 * crossings and 4-6 distinct keys per block (B5b): one record replaces ~60 hash updates.  Keys
 * are complete (seq, tid, kind, id, parent, flags), so user space merges partial aggregates of
 * one key exactly as it merged agg-map keys.  Still late: the keys of a thread that sleeps
 * outside those waits (nanosleep, poll: NtDelayExecution, unix-side calls) travel at its next
 * probe, and user space moves keys of a block it already wrote to the thread's 100 ms window
 * (tracer.json counters.keys_for_flushed_block; _audio counts those of audio-role threads).
 * ---------------------------------------------------------------------- */
static __always_inline __u32 acc_hash(__u64 seq, __u64 idp, __u32 kfl)
{
	return (__u32)(((seq ^ idp ^ ((__u64)kfl << 17)) * 0x9E3779B97F4A7C15ULL) >> (64 - ACC_BITS));
}

static __noinline int acc_flush(struct tstate *t)
{
	struct rec_agg *r;
	__u32 mask = t->acc_mask, n = 0;
	int i;

	t->acc_mask = 0;
	t->acc_n = 0;
	if (!mask)
		return 0;
	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		__u64 lost = 0;

#pragma unroll
		for (i = 0; i < ACC_SLOTS; i++)
			if (mask & (1u << i))
				lost += t->av[i].count;
		cnt_add(CT_RB_DROP_AGG, lost);
		return 0;
	}
	r->h.type = REC_AGG;
	r->h.len = sizeof(*r);
	r->h.tid = t->tid;
	r->h.ts = bpf_ktime_get_ns();
	r->pad = 0;
#pragma unroll
	for (i = 0; i < ACC_SLOTS; i++) {
		if (mask & (1u << i)) {
			struct acc_ent *o = &r->e[n & (ACC_SLOTS - 1)];

			o->seq = t->ak[i].seq;
			o->idp = t->ak[i].idp;
			o->kfl = t->ak[i].kfl;
			o->waker = t->av[i].waker;
			o->count = t->av[i].count;
			o->total_ns = t->av[i].total_ns;
			o->max_ns = t->av[i].max_ns;
			o->oncpu_ns = t->av[i].oncpu_ns;
			n++;
		}
	}
	r->n = n;
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

/* Fold the crossing in t->s[idx] (entered at s[idx].ts, completed at now) into the accumulator.
 * Everything is read from the entry after the possible flush calls, so nothing but t, idx and
 * now lives across them (a tiny frame). */
#define ACC_FULL 0xffu       /* acc_commit's slot search: no hit, no free slot */
#define ACC_NEW  0x80u       /* ... a free slot (| its index) */

static __noinline int acc_commit(struct tstate *t, __u32 idx, __u64 now)
{
	struct inflight_ent *e;
	struct acc_key *k;
	struct acc_val *v;
	__u64 seq, idp, dur;
	__u32 kfl, h, s, slot = ACC_FULL, j;

	if (t->acc_mask && (gl.blocks - t->acc_epoch >= 3 || now - t->acc_t0 >= ACC_MAX_AGE_NS))
		acc_flush(t);
	e = &t->s[idx & (INFLIGHT_DEPTH - 1)];
	seq = e->seq;
	idp = ACC_IDP(e->id, e->pid_);
	kfl = ACC_KFL(e->kind, e->pkind, e->flags);
	h = acc_hash(seq, idp, kfl);
#pragma unroll
	for (j = 0; j < ACC_SLOTS; j++) {
		s = (h + j) & (ACC_SLOTS - 1);
		if (!(t->acc_mask & (1u << s))) {
			slot = s | ACC_NEW;             /* free slot: install */
			break;
		}
		k = &t->ak[s];
		if (k->seq == seq && k->idp == idp && k->kfl == kfl) {
			slot = s;                       /* hit: update */
			break;
		}
	}
	if (slot == ACC_FULL) {                         /* table full */
		acc_flush(t);
		e = &t->s[idx & (INFLIGHT_DEPTH - 1)];
		seq = e->seq;
		idp = ACC_IDP(e->id, e->pid_);
		kfl = ACC_KFL(e->kind, e->pkind, e->flags);
		slot = acc_hash(seq, idp, kfl) | ACC_NEW;
	}
	dur = now - e->ts;
	v = &t->av[slot & (ACC_SLOTS - 1)];
	if (slot & ACC_NEW) {
		if (!t->acc_mask) {
			t->acc_epoch = gl.blocks;
			t->acc_t0 = now;
		}
		t->acc_mask |= 1u << (slot & (ACC_SLOTS - 1));
		t->acc_n++;
		k = &t->ak[slot & (ACC_SLOTS - 1)];
		k->seq = seq;
		k->idp = idp;
		k->kfl = kfl;
		v->count = 1;
		v->total_ns = dur;
		v->max_ns = dur;
		v->oncpu_ns = dur > e->off_ns ? dur - e->off_ns : 0;
		v->waker = t->last_wake_ts >= e->ts ? t->last_waker : 0;
		return 0;
	}
	v->count += 1;
	v->total_ns += dur;
	if (dur > v->max_ns)
		v->max_ns = dur;
	v->oncpu_ns += dur > e->off_ns ? dur - e->off_ns : 0;
	if (t->last_wake_ts >= e->ts && t->last_waker)
		v->waker = t->last_waker;
	return 0;
}

/* The thread is about to block (NTSync wait, wineserver wait).  A thread without an audio role
 * ships its keys now: it may sleep for seconds, and keys that reach user space after their block
 * was written (BLOCK_FLUSH_NS in wine-trace.c) lose the block (they go to the thread's 100 ms
 * window instead).  An audio-role thread waits about a block at most while the audio runs, so it
 * batches: keys of two blocks, half a table or old keys go now, the rest after the wait (the
 * AudioCalc workers reach their waits at different times, so they do not meet at the ring-buffer
 * lock at the block start). */
static __always_inline void acc_before_block(struct tstate *t, __u64 now)
{
	if (t->acc_mask && (gl.blocks - t->acc_epoch >= 2 || t->acc_n >= ACC_SLOTS / 2 ||
			    now - t->acc_t0 >= ACC_MAX_AGE_NS || !ts_audio(t)))
		acc_flush(t);
}

/* A count-only key for the block / window in progress: NtCallbackReturn, --no-exit entries,
 * NTSync wakes.  The key is built in the free in-flight slot s[depth] (never visible: depth
 * does not move) and folded in like a zero-length crossing.  nested = 1: inside the thread's
 * innermost open syscall / unix call, whose kind and id become the key's parent (an NTSync
 * wake inside NtSetEvent gets NtSetEvent's caller).  Returns the scratch slot index for
 * emit_point_event, or -1 (in-flight stack full: the event is counted as an overflow). */
static __noinline int acc_point(struct tstate *t, __u32 kind, __u32 id, __u32 nested)
{
	struct inflight_ent *e;
	__u64 now = bpf_ktime_get_ns();
	__u32 d = t->depth;
	int i;

	if (d >= INFLIGHT_DEPTH) {
		t->overflow++;
		cnt(CT_INFLIGHT_OVERFLOW);
		return -1;
	}
	e = &t->s[d & (INFLIGHT_DEPTH - 1)];
	e->ts = now;
	e->off_ns = 0;
	e->aux = 0;
	e->frame = 0;
	e->id = id;
	e->pid_ = 0;
	e->kind = (__u8)kind;
	e->pkind = 0;
	e->sampled = 0;
	assoc_into(&e->seq, &e->flags, t->tid, now);
	if (nested) {
#pragma unroll
		for (i = 0; i < INFLIGHT_DEPTH; i++) {
			if ((__u32)i < d && (t->s[i].kind == KIND_SYSCALL || t->s[i].kind == KIND_UNIXCALL)) {
				e->pkind = t->s[i].kind;
				e->pid_ = t->s[i].id;
			}
		}
	}
	acc_commit(t, d, now);
	return (int)d;
}

/* ------------------------------------------------------------------------
 * in-flight stack per thread (depth INFLIGHT_DEPTH), entry/exit pairing
 * ---------------------------------------------------------------------- */

/* The next free slot of t's in-flight stack, initialised (association, timestamp, id, pairing
 * key); NULL on overflow.  The entry becomes visible with t->depth++ once the caller filled it. */
static __always_inline struct inflight_ent *push_slot(struct tstate *t, __u32 tid, __u8 kind, __u64 now, __u32 id,
						      __u64 frame)
{
	__u32 d = t->depth;
	struct inflight_ent *e;

	if (d >= INFLIGHT_DEPTH) {
		t->overflow++;
		cnt(CT_INFLIGHT_OVERFLOW);
		anomaly(t, AN_OVERFLOW, kind, id, frame, 0);
		return NULL;
	}
	e = &t->s[d & (INFLIGHT_DEPTH - 1)];
	e->ts = now;
	e->off_ns = 0;
	e->aux = 0;
	e->frame = frame;
	e->id = id;
	e->pid_ = 0;
	e->kind = kind;
	e->pkind = 0;
	e->sampled = 0;
	assoc_into(&e->seq, &e->flags, tid, now);
	return e;
}

/* A new syscall or unix call at `frame`.  The dispatcher keeps one frame per user-callback nesting
 * level (a callback gets a new frame below it), and PE code cannot enter it while an outer call
 * of the same level is in progress, so an in-flight syscall / unix call with the same frame
 * never passed its exit probe (missed, or entered before the exit probe was attached): pop it and
 * everything entered after it as never_returned.  Left there, it would sit below every later
 * entry of the thread, fill its in-flight stack and let a later exit at that frame complete it
 * with a bogus duration.  (The B5b AudioCalc overflows themselves came from NTSync waits of the
 * fentry/fexit attach window: the loader now attaches every exit side first.) */
static __noinline int pop_stale(struct tstate *t, __u32 kind, __u32 id, __u64 frame)
{
	__u32 d = t->depth;
	int i, found = -1;

#pragma unroll
	for (i = INFLIGHT_DEPTH - 1; i >= 0; i--) {
		if ((__u32)i < d && t->s[i].frame == frame &&
		    (t->s[i].kind == KIND_SYSCALL || t->s[i].kind == KIND_UNIXCALL))
			found = i;                     /* the lowest such entry */
	}
	if (found < 0 || d > INFLIGHT_DEPTH)
		return 0;
	anomaly(t, AN_NEVER_RETURNED, kind, id, frame, (__u32)found);
	t->never_returned += d - (__u32)found;
	cnt_add(CT_NEVER_RETURNED, d - (__u32)found);
	t->depth = (__u32)found;
	return 0;
}

/* nested kinds: remember the innermost open syscall / unix call (design B: server_req and
 * ntsync waits inherit the enclosing entry's caller) */
static __always_inline void set_parent(struct tstate *t, struct inflight_ent *e)
{
	__u32 d = t->depth;
	int i;

#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		if ((__u32)i < d && (t->s[i].kind == KIND_SYSCALL || t->s[i].kind == KIND_UNIXCALL)) {
			e->pkind = t->s[i].kind;
			e->pid_ = t->s[i].id;
		}
	}
}

/* index of the newest in-flight entry of `kind` (with `frame` when match_frame), or -1 */
static __always_inline int find_entry(struct tstate *t, __u8 kind, __u64 frame, bool match_frame)
{
	__u32 d = t->depth;
	int found = -1, i;

#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		if ((__u32)i < d && t->s[i].kind == kind && (!match_frame || t->s[i].frame == frame))
			found = i;
	}
	return found;
}

/* drill-down record of the completed entry idx (its flags include the exit's) */
static __noinline int emit_event(struct tstate *t, __u32 idx, __u64 now, __s32 status)
{
	struct inflight_ent *e = &t->s[idx & (INFLIGHT_DEPTH - 1)];
	struct rec_event *r;
	int i;

	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		cnt(CT_RB_DROP_EVENT);
		return 0;
	}
	r->h.type = REC_EVENT;
	r->h.len = sizeof(*r);
	r->h.tid = t->tid;
	r->h.ts = now;
	r->seq = e->seq;
	r->entry_ts = e->ts;
	r->aux = e->aux;
	r->id = e->id;
	r->pid_ = e->pid_;
	r->kind = e->kind;
	r->pkind = e->pkind;
	r->flags = e->flags;
	r->status = status;
	r->waker_tid = t->last_wake_ts >= e->ts ? t->last_waker : 0;
	r->pad = 0;
	/* this entry's sample, or the innermost enclosing sampled entry's (server_req / ntsync
	 * inside a syscall inherit the enclosing stack sample) */
	r->stack_ts = 0;
#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		if ((__u32)i < (idx & (INFLIGHT_DEPTH - 1)) && t->s[i].sampled)
			r->stack_ts = t->s[i].ts;
	}
	if (e->sampled)
		r->stack_ts = e->ts;
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

/* pop entry idx (and everything nested above it), fold it into the accumulator, emit the
 * drill-down record */
static __noinline int complete(struct tstate *t, __u32 idx, __u32 extra, __s32 status)
{
	struct inflight_ent *e;
	__u32 d = t->depth;
	__u64 now;

	idx &= INFLIGHT_DEPTH - 1;
	if (idx >= d || d > INFLIGHT_DEPTH)
		return 0;
	e = &t->s[idx];
	now = bpf_ktime_get_ns();
	if (d - 1 - idx) {
		anomaly(t, AN_ABANDONED, e->kind, e->id, e->frame, idx);
		t->abandoned += d - 1 - idx;
		cnt_add(CT_ABANDONED, d - 1 - idx);
	}
	e->flags |= (__u16)extra;
	acc_commit(t, idx, now);
	if (CFG.mode == MODE_DRILLDOWN)
		emit_event(t, idx, now, status);
	t->depth = idx;
	return 0;
}

/* ------------------------------------------------------------------------
 * stack sampling (rec_stack), reserved and filled in place
 * ---------------------------------------------------------------------- */
static __always_inline bool want_sample(struct tstate *t, struct inflight_ent *e)
{
	if (CFG.mode == MODE_SAMPLE)
		return false;
	if (CFG.sample_n) {
		/* the random sampler counts down per thread: the next sample comes after 1 .. 2N-1 entries
		 * (uniform, mean N), so it costs one prandom per sample instead of one (and a division)
		 * per entry, and the random spacing cannot alias with periodic call patterns */
		if (t->sample_cd > 1) {
			t->sample_cd--;
		} else {
			t->sample_cd = 1 + bpf_get_prandom_u32() % (2 * CFG.sample_n - 1);
			cnt(CT_SAMPLE_RANDOM);
			return true;
		}
	}
	/* the per-block budget is read before the atomic add: once it is spent, entries of the
	 * block's tail do not write the shared line at all */
	if (CFG.slack_thresh_pct && gl.sample_after_ns && e->ts >= gl.sample_after_ns && e->seq == gl.cur_seq &&
	    gl.trig_used < CFG.slack_samples && __sync_fetch_and_add(&gl.trig_used, 1) < CFG.slack_samples) {
		cnt(CT_SAMPLE_SLACK);
		return true;
	}
	if (CFG.trigger_count && bpf_map_lookup_elem(&trigger_ids, &e->id)) {
		cnt(CT_SAMPLE_TRIGGER);
		return true;
	}
	return false;
}

#define SB (CFG.stack_bytes)

/* The register block is Wine's syscall_frame, read through the entry's frame pointer.  Its rsp
 * (regs[17]) and rip (regs[14]) are exactly the probes' user_rsp/user_rip (syscall: NtXxx+0x14)
 * and caller_rip (unix call: the PE caller) operands, so no argument fetch is needed here.
 * The window starts at rsp and stops at t->stack_top, the first page above a sampled rsp that
 * did not read: a thread whose wait sits near the top of its stack (the AudioCalc workers) used
 * to take a page fault on every sample before the halved retry succeeded (B5c perf: ~8% of
 * wine_syscall_entry's cycles); now it takes one per stack. */
static __noinline int sample_stack(struct tstate *t, __u32 idx)
{
	struct inflight_ent *e = &t->s[idx & (INFLIGHT_DEPTH - 1)];
	struct rec_stack *r;
	__u64 rsp, lim, pend;
	__u32 got = 0;

	r = bpf_ringbuf_reserve(&rb, sizeof(struct rec_stack) + SB, 0);
	if (!r) {
		cnt(CT_STACK_DROP);
		return 0;
	}
	r->h.type = REC_STACK;
	r->h.tid = t->tid;
	r->h.ts = e->ts;
	r->seq = e->seq;
	r->frame = e->frame;
	r->id = e->id;
	r->pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
	r->kind = e->kind;
	r->pad8 = 0;
	r->pad32 = 0;
	/* zeroed by the helper on failure */
	bpf_probe_read_user(r->regs, sizeof(r->regs), (const void *)e->frame);
	r->rsp = r->regs[SYSCALL_FRAME_RSP_OFF / 8];
	r->rip = r->regs[SYSCALL_FRAME_RIP_OFF / 8];
	rsp = r->rsp;
	if (rsp) {
		lim = SB;
		if (t->stack_top > rsp && t->stack_top - rsp < lim)
			lim = t->stack_top - rsp;
		if (lim > SB)
			lim = SB;
		if (lim >= 8 && bpf_probe_read_user(r->bytes, lim, (const void *)rsp) == 0) {
			got = (__u32)lim;
		} else {
			/* the window ran into the next page: it is not mapped (the top of this stack) */
			pend = (rsp | 4095) + 1;
			if (pend - rsp < lim) {
				t->stack_top = pend;
				lim = pend - rsp;
				if (lim > SB)
					lim = SB;
				if (lim >= 8 && bpf_probe_read_user(r->bytes, lim, (const void *)rsp) == 0)
					got = (__u32)lim;
			}
		}
	}
	if (!got) {
		bpf_ringbuf_discard(r, BPF_RB_NO_WAKEUP);
		cnt(CT_STACK_READ_FAIL);
		return 0;
	}
	r->nbytes = (__u16)got;
	r->h.len = (__u16)(sizeof(struct rec_stack) + got);
	bpf_ringbuf_submit(r, RB_FLAGS);
	e->sampled = 1;
	cnt(CT_STACKS);
	return 0;
}

/* ------------------------------------------------------------------------
 * USDT: wine:* (ntdll.so, patch 0108).  The probes are attached per traced pid, so no
 * pid filter is needed here.
 * ---------------------------------------------------------------------- */
SEC("usdt")
int wine_syscall_entry(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct inflight_ent *e;
	struct tstate *t;
	__u32 d, id = 0;

	hit(HIT_SYSCALL_ENTRY);
	if (!tid_wanted(&tid)) {
		cnt(CT_FILTERED);
		return 0;
	}
	t = ts_claim(tid);
	if (!t)
		return 0;
	t->seen = 1;
	if (CFG.fast_args) {                             /* -4@176(%rcx) 8@%rcx */
		/* the id goes to the BPF stack: copy_from_user's destination check is cheapest there */
		t->arg[1] = ctx->cx;
		bpf_probe_read_user(&id, 4, (const void *)(ctx->cx + SYSCALL_FRAME_ID_OFF));
	} else {
		bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);    /* id */
		bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);    /* frame */
		id = (__u32)t->arg[0];
	}
	if (CFG.no_exit) {
		acc_point(t, KIND_SYSCALL, id, 0);
		return 0;
	}
	if (id == CFG.callback_return_id) {
		/* NtCallbackReturn resumes the user callback's caller inside the outer syscall and never
		 * exits through its own frame: pushing it would stack one dead entry per callback until
		 * the outer exit (GUI threads overflowed INFLIGHT_DEPTH) */
		acc_point(t, KIND_SYSCALL, id, 0);
		cnt(CT_CALLBACK_RETURN);
		return 0;
	}
	if (t->depth)            /* nothing can be stale on an empty in-flight stack (the common case) */
		pop_stale(t, KIND_SYSCALL, id, t->arg[1]);
	d = t->depth;
	e = push_slot(t, tid, KIND_SYSCALL, bpf_ktime_get_ns(), id, t->arg[1]);
	if (!e)
		return 0;
	t->depth = d + 1;
	if (want_sample(t, e))
		sample_stack(t, d);
	return 0;
}

SEC("usdt")
int wine_syscall_exit(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct tstate *t;
	int i;

	hit(HIT_SYSCALL_EXIT);
#ifdef WT_SELFTEST_BIG_FRAME
	/* `make test-gate` only: a 128-byte frame must put this program on the per-CPU private
	 * stack, and the loader's self-check must refuse to attach (never built otherwise) */
	{
		volatile __u64 big[16];
		int k;

		for (k = 0; k < 16; k++)
			big[k] = bpf_get_prandom_u32();
		if (big[tid & 15] == 42)
			cnt(CT_FILTERED);
	}
#endif
	if (!tid_wanted(&tid))
		return 0;
	t = ts_find(tid);
	if (!t || !t->seen) {
		/* init_syscall_frame's tail jumps to the return label: one exit without entry per
		 * thread start (and per thread that was inside a syscall when tracing began) */
		t = ts_claim(tid);
		if (t) {
			t->seen = 1;
			t->first_exit++;
		}
		cnt(CT_FIRST_EXIT);
		return 0;
	}
	if (CFG.fast_args)                               /* -4@%eax 8@%rcx -4@176(%rcx) -4@180(%rcx) */
		t->arg[1] = ctx->cx;
	else
		bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);    /* frame */
	i = find_entry(t, KIND_SYSCALL, t->arg[1], true);
	t->arg[3] = 0;
	if (i < 0 || CFG.mode == MODE_DRILLDOWN) {      /* restore_flags */
		if (CFG.fast_args)
			bpf_probe_read_user(&t->arg[3], 4, (const void *)(t->arg[1] + SYSCALL_FRAME_RF_OFF));
		else
			bpf_usdt_arg(ctx, 3, (long *)&t->arg[3]);
	}
	if (i < 0) {
		/* The unix-call dispatcher marks every unix-call frame INCOMPLETE_FRAME_CONTEXT and its
		 * slow path returns through this label after unixcall_exit already popped the unix
		 * call: no syscall entry exists for it, so the miss is counted apart. */
		if ((__u32)t->arg[3] & WT_RESTORE_FLAGS_INCOMPLETE_FRAME_CONTEXT) {
			cnt(CT_UNIXCALL_SLOW_EXIT);
		} else {
			t->unmatched++;
			cnt(CT_UNMATCHED_EXIT);
			if (CFG.mode == MODE_DRILLDOWN) {        /* the exit's syscall id: -4@176(%rcx) */
				t->arg[2] = 0;
				if (CFG.fast_args)
					bpf_probe_read_user(&t->arg[2], 4, (const void *)(t->arg[1] + SYSCALL_FRAME_ID_OFF));
				else
					bpf_usdt_arg(ctx, 2, (long *)&t->arg[2]);
				anomaly(t, AN_UNMATCHED_EXIT, KIND_SYSCALL, (__u32)t->arg[2], t->arg[1], (__u32)t->arg[3]);
			}
		}
		return 0;
	}
	if (CFG.fast_args)
		t->arg[0] = (__u32)ctx->ax;                  /* status */
	else
		bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);
	complete(t, (__u32)i,
		 ntstatus_flags((__u32)t->arg[0]) |
		 (((__u32)t->arg[3] & WT_RESTORE_FLAGS_INCOMPLETE_FRAME_CONTEXT) ? AGGF_INCOMPLETE : 0),
		 (__s32)t->arg[0]);
	return 0;
}

/* handle -> small index (REC_UNIXLIB tells user space which handle an index stands for) */
static __noinline __u32 unixlib_index(struct tstate *t, __u32 tid)
{
	struct rec_unixlib *r;
	__u32 *p, idx;

	p = bpf_map_lookup_elem(&unixlibs, &t->ukey);
	if (p)
		return *p;
	idx = __sync_fetch_and_add(&gl.unixlib_next, 1) + 1;
	if (idx > 0xfffe)
		return 0xffff;
	t->arg[5] = idx;
	if (bpf_map_update_elem(&unixlibs, &t->ukey, &t->arg[5], BPF_NOEXIST) == 0) {
		r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
		if (r) {
			r->h.type = REC_UNIXLIB;
			r->h.len = sizeof(*r);
			r->h.tid = tid;
			r->h.ts = bpf_ktime_get_ns();
			r->handle = t->ukey.handle;
			r->pid = t->ukey.pid;
			r->idx = idx;
			bpf_ringbuf_submit(r, RB_FLAGS);
		} else {
			cnt(CT_RB_DROP_OTHER);
		}
		return idx;
	}
	p = bpf_map_lookup_elem(&unixlibs, &t->ukey);
	return p ? *p : 0xffff;
}

SEC("usdt")
int wine_unixcall_entry(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct inflight_ent *e;
	struct tstate *t;
	__u32 d, idx;

	hit(HIT_UNIXCALL_ENTRY);
	if (!tid_wanted(&tid)) {
		cnt(CT_FILTERED);
		return 0;
	}
	t = ts_claim(tid);
	if (!t)
		return 0;
	if (CFG.fast_args) {                             /* 8@%r10 -4@%edx 8@%rsp 8@112(%rsp) */
		t->ukey.handle = ctx->r10;
		t->arg[1] = (__u32)ctx->dx;
		t->arg[2] = ctx->sp;
	} else {
		bpf_usdt_arg(ctx, 0, (long *)&t->ukey.handle);
		bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);    /* code */
		bpf_usdt_arg(ctx, 2, (long *)&t->arg[2]);    /* frame */
	}
	t->ukey.pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
	t->ukey.pad = 0;
	idx = unixlib_index(t, tid);
	if (CFG.no_exit) {
		acc_point(t, KIND_UNIXCALL, (idx << 16) | ((__u32)t->arg[1] & 0xffff), 0);
		return 0;
	}
	/* the unix-call frame is the dispatcher's frame of this level too (8@%rsp == the syscall frame) */
	if (t->depth)
		pop_stale(t, KIND_UNIXCALL, (idx << 16) | ((__u32)t->arg[1] & 0xffff), t->arg[2]);
	d = t->depth;
	e = push_slot(t, tid, KIND_UNIXCALL, bpf_ktime_get_ns(), (idx << 16) | ((__u32)t->arg[1] & 0xffff), t->arg[2]);
	if (!e)
		return 0;
	if (CFG.mode == MODE_DRILLDOWN) {                /* the PE caller: 8@112(%rsp) = frame->rip */
		if (CFG.fast_args)
			bpf_probe_read_user(&e->aux, 8, (const void *)(e->frame + SYSCALL_FRAME_RIP_OFF));
		else
			bpf_usdt_arg(ctx, 3, (long *)&e->aux);
	}
	t->depth = d + 1;
	if (want_sample(t, e))
		sample_stack(t, d);
	return 0;
}

SEC("usdt")
int wine_unixcall_exit(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct tstate *t;
	int i;

	hit(HIT_UNIXCALL_EXIT);
	if (!tid_wanted(&tid))
		return 0;
	t = ts_find(tid);
	if (!t)
		return 0;
	if (CFG.fast_args)                               /* -4@%eax 8@%rcx */
		t->arg[1] = ctx->cx;
	else
		bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);    /* frame */
	i = find_entry(t, KIND_UNIXCALL, t->arg[1], true);
	if (i < 0) {
		t->unmatched++;
		cnt(CT_UNMATCHED_EXIT);
		anomaly(t, AN_UNMATCHED_EXIT, KIND_UNIXCALL, 0, t->arg[1], CFG.fast_args ? (__u32)ctx->ax : 0);
		return 0;
	}
	if (CFG.fast_args)
		t->arg[0] = (__u32)ctx->ax;                  /* status */
	else
		bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);
	complete(t, (__u32)i, ntstatus_flags((__u32)t->arg[0]), (__s32)t->arg[0]);
	return 0;
}

/* server_req_start(req_type) / server_wait_start(flags): nested entries keyed by their id */
static __always_inline int nested_start(struct pt_regs *ctx, __u8 kind)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct inflight_ent *e;
	struct tstate *t;
	__u32 d;

	if (!tid_wanted(&tid)) {
		cnt(CT_FILTERED);
		return 0;
	}
	t = ts_claim(tid);
	if (!t)
		return 0;
	bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);
	if (CFG.no_exit) {
		acc_point(t, kind, (__u32)t->arg[0], 0);
		return 0;
	}
	t->arg[5] = bpf_ktime_get_ns();
	if (kind == KIND_SERVER_WAIT)       /* wait_select_reply: the thread is about to block */
		acc_before_block(t, t->arg[5]);
	d = t->depth;
	e = push_slot(t, tid, kind, t->arg[5], (__u32)t->arg[0], (__u32)t->arg[0]);
	if (!e)
		return 0;
	set_parent(t, e);
	t->depth = d + 1;
	return 0;
}

static __always_inline int nested_end(struct pt_regs *ctx, __u8 kind, bool match_id)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct tstate *t;
	__u32 st;
	int i;

	if (!tid_wanted(&tid))
		return 0;
	t = ts_find(tid);
	if (!t)
		return 0;
	if (match_id) {
		bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);   /* req_type */
		i = find_entry(t, kind, (__u32)t->arg[0], true);
		bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);   /* status */
		st = (__u32)t->arg[1];
	} else {
		i = find_entry(t, kind, 0, false);
		bpf_usdt_arg(ctx, 0, (long *)&t->arg[1]);   /* ret */
		st = (__u32)t->arg[1];
	}
	if (i < 0) {
		t->unmatched++;
		cnt(CT_UNMATCHED_EXIT);
		anomaly(t, AN_UNMATCHED_EXIT, kind, match_id ? (__u32)t->arg[0] : 0, 0, st);
		return 0;
	}
	complete(t, (__u32)i, ntstatus_flags(st), (__s32)st);
	return 0;
}

SEC("usdt")
int wine_server_req_start(struct pt_regs *ctx)
{
	hit(HIT_SERVER_REQ_START);
	return nested_start(ctx, KIND_SERVER_REQ);
}

SEC("usdt")
int wine_server_req_end(struct pt_regs *ctx)
{
	hit(HIT_SERVER_REQ_END);
	return nested_end(ctx, KIND_SERVER_REQ, true);
}

SEC("usdt")
int wine_server_wait_start(struct pt_regs *ctx)
{
	hit(HIT_SERVER_WAIT_START);
	return nested_start(ctx, KIND_SERVER_WAIT);
}

SEC("usdt")
int wine_server_wait_end(struct pt_regs *ctx)
{
	hit(HIT_SERVER_WAIT_END);
	return nested_end(ctx, KIND_SERVER_WAIT, false);
}

/* ------------------------------------------------------------------------
 * USDT: pipeasio:* (pipeasio64.dll.so, patch pipeasio/0017).  Block probes fire on the
 * PipeASIO callback thread, cycle probes on the PipeWire data-loop thread.
 * ---------------------------------------------------------------------- */
static __always_inline struct rec_block *block_rec(__u32 tid, __u32 phase)
{
	struct rec_block *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	int i;

	if (!r) {
		cnt(CT_RB_DROP_BLOCK);
		return NULL;
	}
	r->h.type = REC_BLOCK;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = bpf_ktime_get_ns();
	r->seq = 0;
#pragma unroll
	for (i = 0; i < 9; i++)
		r->a[i] = 0;
	r->phase = phase;
	r->pad = 0;
	return r;
}

/* t->arg[] = seq, nframes, rate, clock_nsec, deadline_ns, flags; t->now0 = probe time.  Only
 * struct global is written: block_end ships the block in one record. */
static __noinline int block_begin(struct tstate *t, __u32 tid)
{
	__u64 margin;

	gl.callback_tid = tid;
	gl.block_start_ts = t->now0;
	gl.deadline_ns = t->arg[4];
	gl.clock_nsec = t->arg[3];
	gl.start_flags = (__u32)t->arg[5];
	gl.before_ts = 0;
	gl.after_ts = 0;
	if ((__u32)t->arg[1] != gl.nframes || (__u32)t->arg[2] != gl.rate || !gl.period_ns) {
		/* the two 64-bit divisions only when the buffer size or rate changes */
		gl.nframes = (__u32)t->arg[1];
		gl.rate = (__u32)t->arg[2];
		gl.period_ns = gl.rate ? ((__u64)gl.nframes * 1000000000ULL + gl.rate / 2) / gl.rate : 0;
		gl.slack_margin_ns = gl.period_ns * CFG.slack_thresh_pct / 100;
	}
	margin = gl.slack_margin_ns;
	gl.sample_after_ns = gl.deadline_ns > margin ? gl.deadline_ns - margin : 0;
	gl.trig_used = 0;
	gl.blocks++;
	gl.cur_seq = t->arg[0];          /* last: entries of other threads now join this block */
	return 0;
}

SEC("usdt")
int pipeasio_block_start(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct tstate *t;

	hit(HIT_BLOCK_START);
	if (gl.stopping)        /* the loader is detaching (block_start goes first): no new block */
		return 0;
	t = ts_claim(tid);
	if (!t)
		return 0;
	t->now0 = bpf_ktime_get_ns();
	bpf_usdt_arg(ctx, 0, (long *)&t->arg[0]);
	bpf_usdt_arg(ctx, 1, (long *)&t->arg[1]);
	bpf_usdt_arg(ctx, 2, (long *)&t->arg[2]);
	bpf_usdt_arg(ctx, 3, (long *)&t->arg[3]);
	bpf_usdt_arg(ctx, 4, (long *)&t->arg[4]);
	bpf_usdt_arg(ctx, 5, (long *)&t->arg[5]);
	return block_begin(t, tid);
}

/* Only blocks whose block_start this tracer saw (gl.cur_seq set) get their other phases: a block
 * in progress at attach, or one that started after gl.stopping, would be an END without a START.
 * before / after only stamp struct global (the callback thread is its only writer); block_end
 * ships the whole block. */
static __always_inline int block_mark(struct pt_regs *ctx, bool after)
{
	long seq = 0;

	if (!gl.cur_seq)
		return 0;
	bpf_usdt_arg(ctx, 0, &seq);
	if ((__u64)seq != gl.cur_seq)
		return 0;
	if (after)
		gl.after_ts = bpf_ktime_get_ns();
	else
		gl.before_ts = bpf_ktime_get_ns();
	return 0;
}

SEC("usdt")
int pipeasio_block_before_live(struct pt_regs *ctx)
{
	hit(HIT_BLOCK_BEFORE_LIVE);
	return block_mark(ctx, false);
}

SEC("usdt")
int pipeasio_block_after_live(struct pt_regs *ctx)
{
	hit(HIT_BLOCK_AFTER_LIVE);
	return block_mark(ctx, true);
}

SEC("usdt")
int pipeasio_block_end(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct rec_block *r;

	hit(HIT_BLOCK_END);
	if (!gl.cur_seq)        /* see block_mark */
		return 0;
	r = block_rec(tid, PHASE_BLOCK_END);
	if (r) {
		bpf_usdt_arg(ctx, 0, (long *)&r->seq);
		bpf_usdt_arg(ctx, 1, (long *)&r->a[7]);   /* flags */
		bpf_usdt_arg(ctx, 2, (long *)&r->a[8]);   /* missed */
		if (r->seq == gl.cur_seq) {               /* gl describes this block: the whole block */
			r->phase = PHASE_BLOCK;
			r->a[0] = (__u64)gl.nframes | ((__u64)gl.rate << 32);
			r->a[1] = gl.clock_nsec;
			r->a[2] = gl.deadline_ns;
			r->a[3] = gl.start_flags;
			r->a[4] = gl.block_start_ts;
			r->a[5] = gl.before_ts;
			r->a[6] = gl.after_ts;
		} else {                                  /* an end whose start we did not see */
			r->a[0] = r->a[7];
			r->a[1] = r->a[8];
			r->a[7] = 0;
			r->a[8] = 0;
		}
		gl.last_seq = r->seq;
		bpf_ringbuf_submit(r, RB_FLAGS);
	} else {
		gl.last_seq = gl.cur_seq;
	}
	gl.cur_seq = 0;
	return 0;
}

/* The cycle start only stamps the thread: cycle_end's record carries that stamp (a[2]), which
 * is all the loader uses (blocks.jsonl cycle.t_start / pre_ns).  The five operands
 * (clock_nsec, next_nsec, duration, position, cycle_flags) and a record of its own made this
 * the most expensive program per run (1.1-1.9 us in B5b/B5c's Live runs). */
SEC("usdt")
int pipeasio_cycle_start(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct tstate *t;

	(void)ctx;
	hit(HIT_CYCLE_START);
	t = ts_claim(tid);
	if (t)
		t->cycle_ts = bpf_ktime_get_ns();
	return 0;
}

SEC("usdt")
int pipeasio_cycle_end(struct pt_regs *ctx)
{
	__u32 tid = (__u32)bpf_get_current_pid_tgid();
	struct rec_block *r;
	struct tstate *t;

	hit(HIT_CYCLE_END);
	t = ts_find(tid);
	r = block_rec(tid, PHASE_CYCLE_END);
	if (!r)
		return 0;
	if (t && t->cycle_ts) {
		r->a[2] = t->cycle_ts;
		/* a block that started inside this cycle owns the cycle */
		if (gl.block_start_ts >= t->cycle_ts)
			r->seq = gl.cur_seq ? gl.cur_seq : gl.last_seq;
	}
	bpf_usdt_arg(ctx, 0, (long *)&r->a[0]);       /* missed */
	bpf_usdt_arg(ctx, 1, (long *)&r->a[1]);       /* delivered */
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

/* ------------------------------------------------------------------------
 * NTSync (kernel side, no Wine patch): waits via ntsync_char_ioctl, wakes via
 * ntsync_obj_ioctl.  Three attachment variants share these helpers.
 * ---------------------------------------------------------------------- */
static __noinline int ntsync_wait_enter(__u32 cmd, __u64 parm)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 key = (__u32)pt;
	struct inflight_ent *e;
	struct nt_wait_args *wa;
	struct tstate *t;
	__u32 d;

	t = ts_traced(pt);
	if (!t)
		return 0;
	if (CFG.roles_audio && !tid_wanted(&key)) {
		cnt(CT_FILTERED);
		return 0;
	}
	t->nt_wait_hits++;
	wa = (struct nt_wait_args *)t->wa;
	if (bpf_probe_read_user(wa, sizeof(*wa), (const void *)parm)) {
		wa->count = 0xff;
		wa->alert = 0;
	}
	if (CFG.no_exit) {
		acc_point(t, KIND_NTSYNC_WAIT, NTSYNC_WAIT_ID(cmd == NTSYNC_IOC_WAIT_ALL, wa->alert, wa->count), 0);
		return 0;
	}
	t->arg[5] = bpf_ktime_get_ns();
	acc_before_block(t, t->arg[5]);                 /* the thread is about to block */
	d = t->depth;
	e = push_slot(t, (__u32)pt, KIND_NTSYNC_WAIT, t->arg[5],
		      NTSYNC_WAIT_ID(cmd == NTSYNC_IOC_WAIT_ALL, wa->alert, wa->count), parm);
	if (!e)
		return 0;
	set_parent(t, e);
	t->depth = d + 1;
	return 0;
}

/* strict: the caller knows this return belongs to a WAIT_ANY/WAIT_ALL (fexit sees cmd), so a
 * miss is counted in CT_NTSYNC_UNMATCHED.  The kretprobe and sys_exit_ioctl variants see every
 * ntsync_char_ioctl / ioctl return and pass strict = false: they complete the wait only when it
 * is the innermost in-flight entry of the thread and return silently otherwise. */
static __noinline int ntsync_wait_exit(long ret, bool strict)
{
	struct inflight_ent *e;
	struct nt_wait_args *wa;
	struct tstate *t;
	__u32 extra = 0;
	int i;

	/* a thread without a slot has no in-flight wait to complete (slots exist only for traced
	 * pids, see ts_traced): one lookup, no pid map */
	t = ts_find((__u32)bpf_get_current_pid_tgid());
	if (!t)
		return 0;
	i = find_entry(t, KIND_NTSYNC_WAIT, 0, false);
	if (i < 0) {
		if (strict) {
			cnt(CT_NTSYNC_UNMATCHED);
			anomaly(t, AN_UNMATCHED_EXIT, KIND_NTSYNC_WAIT, 0, 0, (__u32)ret);
		}
		return 0;
	}
	if (!strict && (__u32)i + 1 != t->depth)
		return 0;
	e = &t->s[i & (INFLIGHT_DEPTH - 1)];
	if (ret == 0) {
		wa = (struct nt_wait_args *)t->wa;
		if ((e->id & 2) && bpf_probe_read_user(wa, sizeof(*wa), (const void *)e->frame) == 0 &&
		    wa->index == ((e->id >> 8) & 0xff))
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
	complete(t, (__u32)i, extra, (__s32)ret);
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

/* drill-down record of a point event (an NTSync wake: no duration) whose key acc_point left in
 * the scratch slot s[idx] */
static __noinline int emit_point_event(struct tstate *t, __u32 idx)
{
	struct inflight_ent *e = &t->s[idx & (INFLIGHT_DEPTH - 1)];
	struct rec_event *r;
	__u32 d = t->depth;
	int i;

	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		cnt(CT_RB_DROP_EVENT);
		return 0;
	}
	r->h.type = REC_EVENT;
	r->h.len = sizeof(*r);
	r->h.tid = t->tid;
	r->h.ts = e->ts;
	r->seq = e->seq;
	r->entry_ts = e->ts;
	r->stack_ts = 0;
	r->aux = 0;
	r->id = e->id;
	r->pid_ = e->pid_;
	r->kind = e->kind;
	r->pkind = e->pkind;
	r->flags = e->flags;
	r->status = 0;
	r->waker_tid = 0;
	r->pad = 0;
#pragma unroll
	for (i = 0; i < INFLIGHT_DEPTH; i++) {
		if ((__u32)i < d && t->s[i].sampled)
			r->stack_ts = t->s[i].ts;
	}
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

static __noinline int ntsync_wake(__u32 cmd)
{
	struct tstate *t;
	__u32 id;
	int idx;

	id = wake_id(cmd);
	if (!id)
		return 0;
	t = ts_traced(bpf_get_current_pid_tgid());
	if (!t)
		return 0;
	t->nt_wake_hits++;
	idx = acc_point(t, KIND_NTSYNC_WAKE, id, 1);
	if (CFG.mode == MODE_DRILLDOWN && idx >= 0)
		emit_point_event(t, (__u32)idx);
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
 * scheduler (tp_btf: non-preemptible, recursion-guarded).  They only use slots the threads
 * claimed themselves (a thread is traced from its first probe hit or NTSync call on).
 * ---------------------------------------------------------------------- */
static __noinline int emit_offcpu(__u32 tid, __u64 now, __u64 off_ts, __u64 run_delay, __u32 waker)
{
	struct rec_offcpu *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		cnt(CT_RB_DROP_OTHER);
		return 0;
	}
	r->h.type = REC_OFFCPU;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = now;
	r->off_ts = off_ts;
	r->on_ts = now;
	r->run_delay_ns = run_delay;
	r->waker_tid = waker;
	r->pad = 0;
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

static __noinline int switch_out(struct tstate *t, __u32 tid, __u64 now, __u32 prev_state)
{
	if (t->on_ts) {
		assoc_into(&t->sg.key.seq, &t->sg.key.flags, tid, now);
		agg_add(&t->sg, now, t->sg.key.seq, tid, KIND_ONCPU, t->sg.key.flags, 0, now - t->on_ts, 0, 0, 0);
	}
	t->on_ts = 0;
	t->off_ts = now;
	assoc_into(&t->off_seq, &t->off_flags, tid, now);
	if (prev_state == 0)
		t->off_flags |= AGGF_PREEMPTED;   /* still runnable */
	t->wake_ts = 0;
	t->waker_tid = 0;
	return 0;
}

static __noinline int switch_in(struct tstate *t, __u32 tid, __u64 now)
{
	__u64 off, rd;
	int i;

	if (t->off_ts) {
		off = now - t->off_ts;
		if (t->off_flags & AGGF_PREEMPTED)
			rd = off;
		else
			rd = t->wake_ts > t->off_ts ? now - t->wake_ts : 0;
		agg_add(&t->sg, now, t->off_seq, tid, KIND_OFFCPU, t->off_flags, t->waker_tid, off, rd, rd,
			t->waker_tid);
#pragma unroll
		for (i = 0; i < INFLIGHT_DEPTH; i++) {
			if ((__u32)i < t->depth)
				t->s[i].off_ns += off;
		}
		/* the per-interval records are opt-in (--sched-records): the loader only counts them, and
		 * off-CPU time already reaches blocks.offcpu / threads.jsonl through the agg keys */
		if (CFG.mode == MODE_DRILLDOWN && CFG.sched_records && off >= CFG.offcpu_min_ns)
			emit_offcpu(tid, now, t->off_ts, rd, t->waker_tid);
		t->off_ts = 0;
	}
	t->on_ts = now;
	return 0;
}

/* A thread past exit_signals() (PF_EXITING) is about to reach, or has passed,
 * on_sched_process_exit, which releases its slot. */
#define WT_TASK_DEAD  0x00000080u

/* Every context switch of the machine runs this.  The small pid map (hot in every cache) comes
 * first: a slot lookup of an untraced task would probe TSTATE_PROBES cold slots before it fails
 * (open addressing with released slots cannot stop at a free one). */
SEC("tp_btf/sched_switch")
int BPF_PROG(on_sched_switch, bool preempt, struct task_struct *prev, struct task_struct *next,
	     unsigned int prev_state)
{
	__u32 key;
	struct tstate *t;
	__u64 now = bpf_ktime_get_ns();

	(void)preempt;
	key = prev->tgid;
	if (pid_traced(&key)) {
		t = ts_find(prev->pid);
		if (t) {
			if ((prev_state & WT_TASK_DEAD) || prev->exit_state) {
				/* past on_sched_process_exit, which normally released the slot (not when
				 * its link was gone first, e.g. in the teardown): ship the accumulator
				 * before the slot goes back to the pool, read_tstates() skips free slots.
				 * Safe: this program is not preemptible, and a dead task runs none of
				 * its own programs. */
				if (t->acc_mask)
					acc_flush(t);
				t->tid = 0;
			} else {
				switch_out(t, prev->pid, now, prev_state);
			}
		}
	}
	key = next->tgid;
	if (pid_traced(&key)) {
		t = ts_find(next->pid);
		if (t)
			switch_in(t, next->pid, now);
	}
	return 0;
}

static __always_inline int sched_waking_common(struct task_struct *p, bool irq)
{
	__u32 key = p->tgid, waker_tid, waker_pid;
	struct rec_wake *r;
	struct tstate *t;
	__u64 now, cur;

	if (!pid_traced(&key))
		return 0;
	key = p->pid;
	t = ts_find(key);
	if (!t)
		return 0;
	now = bpf_ktime_get_ns();
	cur = bpf_get_current_pid_tgid();
	waker_tid = (__u32)cur;
	waker_pid = cur >> 32;
	if (irq || waker_tid == key) {
		/* interrupt context (timers, I/O completion): `current` is only the interrupted task */
		waker_tid = 0;
		waker_pid = 0;
	}
	t->wake_ts = now;
	t->waker_tid = waker_tid;
	t->last_wake_ts = now;
	t->last_waker = waker_tid;
	t->wakeups++;
	if (CFG.mode == MODE_DRILLDOWN && CFG.sched_records) {     /* opt-in, see switch_in */
		r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
		if (!r) {
			cnt(CT_RB_DROP_OTHER);
			return 0;
		}
		r->h.type = REC_WAKE;
		r->h.len = sizeof(*r);
		r->h.tid = (__u32)cur;
		r->h.ts = now;
		r->wakee_tid = key;
		r->waker_pid = waker_pid;
		r->waker_tid = waker_tid;
		if (irq)
			__builtin_memcpy(r->waker_comm, "<irq>\0\0\0\0\0\0\0\0\0\0", 16);
		else
			bpf_get_current_comm(r->waker_comm, sizeof(r->waker_comm));
		bpf_ringbuf_submit(r, RB_FLAGS);
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
static __always_inline struct rec_task *task_rec(__u16 type, __u32 tid, __u32 pid, __u32 ppid, __u32 ptid,
						 __u32 flags)
{
	struct rec_task *r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);

	if (!r) {
		cnt(CT_RB_DROP_OTHER);
		return NULL;
	}
	r->h.type = type;
	r->h.len = sizeof(*r);
	r->h.tid = tid;
	r->h.ts = bpf_ktime_get_ns();
	r->pid = pid;
	r->parent_pid = ppid;
	r->parent_tid = ptid;
	r->flags = flags;
	r->unmatched = 0;
	r->first_exit = 0;
	r->abandoned = 0;
	r->overflow = 0;
	r->open_at_exit = 0;
	r->never_returned = 0;
	r->nt_wait_hits = 0;
	r->nt_wake_hits = 0;
	return r;
}

SEC("tp_btf/sched_process_fork")
int BPF_PROG(on_sched_process_fork, struct task_struct *parent, struct task_struct *child)
{
	__u32 key = parent->tgid;
	struct rec_task *r;
	__u8 *one;

	if (!pid_traced(&key))
		return 0;
	if (child->tgid != parent->tgid) {
		/* new process: trace it kernel-side at once (the value pointer is the parent's own
		 * pids entry, 1); user space attaches its USDT probes */
		one = bpf_map_lookup_elem(&pids, &key);
		key = child->tgid;
		if (one)
			bpf_map_update_elem(&pids, &key, one, BPF_ANY);
		r = task_rec(REC_FORK, child->pid, child->tgid, parent->tgid, parent->pid, 0);
	} else {
		r = task_rec(REC_THREAD, child->pid, child->tgid, parent->tgid, parent->pid, 0);
	}
	if (!r)
		return 0;
	BPF_CORE_READ_STR_INTO(&r->comm, child, comm);
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

/* Runs in the exiting thread's own context: its last accumulated crossings, its counters, and
 * the slot goes back to the pool. */
SEC("tp_btf/sched_process_exit")
int BPF_PROG(on_sched_process_exit, struct task_struct *p, bool group_dead)
{
	__u32 key = p->tgid, tid = p->pid;
	struct rec_task *r;
	struct tstate *t;

	if (!pid_traced(&key))
		return 0;
	t = ts_find(tid);
	if (t && t->acc_mask)
		acc_flush(t);
	r = task_rec(REC_EXIT, tid, p->tgid, 0, 0, group_dead ? 1 : 0);
	if (r)
		__builtin_memset(r->comm, 0, sizeof(r->comm));
	if (t) {
		/* the thread's last calls (NtTerminateThread/Process) never return: open, not abandoned */
		if (t->depth && t->depth <= INFLIGHT_DEPTH) {
			t->open_at_exit += t->depth;
			cnt_add(CT_OPEN_AT_EXIT, t->depth);
		}
		if (r) {
			r->unmatched = t->unmatched;
			r->first_exit = t->first_exit;
			r->abandoned = t->abandoned;
			r->overflow = t->overflow;
			r->open_at_exit = t->open_at_exit;
			r->never_returned = t->never_returned;
			r->nt_wait_hits = t->nt_wait_hits;
			r->nt_wake_hits = t->nt_wake_hits;
		}
		t->tid = 0;
	}
	key = tid;
	bpf_map_delete_elem(&tids, &key);
	if (group_dead) {
		key = p->tgid;
		bpf_map_delete_elem(&pids, &key);
	}
	if (r)
		bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

SEC("tp_btf/task_rename")
int BPF_PROG(on_task_rename, struct task_struct *task, const char *comm)
{
	__u32 key = task->tgid;
	struct rec_name *r;

	if (!pid_traced(&key))
		return 0;
	r = bpf_ringbuf_reserve(&rb, sizeof(*r), 0);
	if (!r) {
		cnt(CT_RB_DROP_OTHER);
		return 0;
	}
	r->h.type = REC_NAME;
	r->h.len = sizeof(*r);
	r->h.tid = task->pid;
	r->h.ts = bpf_ktime_get_ns();
	r->pid = key;
	bpf_probe_read_kernel_str(r->comm, sizeof(r->comm), comm);
	bpf_ringbuf_submit(r, RB_FLAGS);
	return 0;
}

/* ------------------------------------------------------------------------
 * --mode sample: cpu-clock perf sampling (per CPU, pid-filtered here); the record is
 * filled in place from the interrupted registers
 * ---------------------------------------------------------------------- */
SEC("perf_event")
int on_perf_sample(struct bpf_perf_event_data *ctx)
{
	__u64 pt = bpf_get_current_pid_tgid();
	__u32 key = (__u32)(pt >> 32);
	struct rec_stack *r;
	struct pt_regs *u;
	__u64 now;
	__u32 got = 0;
	bool user;

	if (!pid_traced(&key))
		return 0;
	key = (__u32)pt;
	if (!tid_wanted(&key))
		return 0;
	r = bpf_ringbuf_reserve(&rb, sizeof(struct rec_stack) + SB, 0);
	if (!r) {
		cnt(CT_STACK_DROP);
		return 0;
	}
	now = bpf_ktime_get_ns();
	user = (ctx->regs.csx & 3) == 3;
	if (user) {
		r->regs[0] = ctx->regs.ax;   r->regs[1] = ctx->regs.bx;   r->regs[2] = ctx->regs.cx;
		r->regs[3] = ctx->regs.dx;   r->regs[4] = ctx->regs.si;   r->regs[5] = ctx->regs.di;
		r->regs[6] = ctx->regs.r8;   r->regs[7] = ctx->regs.r9;   r->regs[8] = ctx->regs.r10;
		r->regs[9] = ctx->regs.r11;  r->regs[10] = ctx->regs.r12; r->regs[11] = ctx->regs.r13;
		r->regs[12] = ctx->regs.r14; r->regs[13] = ctx->regs.r15; r->regs[14] = ctx->regs.ip;
		r->regs[15] = ctx->regs.csx; r->regs[16] = ctx->regs.flags; r->regs[17] = ctx->regs.sp;
		r->regs[18] = ctx->regs.ssx; r->regs[19] = ctx->regs.bp;
	} else {
		/* kernel-mode sample (thread inside a syscall): the user registers at syscall entry */
		u = (struct pt_regs *)bpf_task_pt_regs(bpf_get_current_task_btf());
		if (!u) {
			bpf_ringbuf_discard(r, BPF_RB_NO_WAKEUP);
			return 0;
		}
		r->regs[0] = BPF_CORE_READ(u, ax);   r->regs[1] = BPF_CORE_READ(u, bx);
		r->regs[2] = BPF_CORE_READ(u, cx);   r->regs[3] = BPF_CORE_READ(u, dx);
		r->regs[4] = BPF_CORE_READ(u, si);   r->regs[5] = BPF_CORE_READ(u, di);
		r->regs[6] = BPF_CORE_READ(u, r8);   r->regs[7] = BPF_CORE_READ(u, r9);
		r->regs[8] = BPF_CORE_READ(u, r10);  r->regs[9] = BPF_CORE_READ(u, r11);
		r->regs[10] = BPF_CORE_READ(u, r12); r->regs[11] = BPF_CORE_READ(u, r13);
		r->regs[12] = BPF_CORE_READ(u, r14); r->regs[13] = BPF_CORE_READ(u, r15);
		r->regs[14] = BPF_CORE_READ(u, ip);  r->regs[15] = BPF_CORE_READ(u, csx);
		r->regs[16] = BPF_CORE_READ(u, flags); r->regs[17] = BPF_CORE_READ(u, sp);
		r->regs[18] = BPF_CORE_READ(u, ssx); r->regs[19] = BPF_CORE_READ(u, bp);
	}
	r->h.type = REC_STACK;
	r->h.tid = key;
	r->h.ts = now;
	r->seq = gl.cur_seq ? gl.cur_seq : (WINDOW_BIT | (now / WINDOW_NS));
	r->frame = r->regs[19];
	r->rsp = r->regs[17];
	r->rip = r->regs[14];
	r->id = user ? 0 : 1;
	r->pid = (__u32)(pt >> 32);
	r->kind = KIND_PERF;
	r->pad8 = 0;
	r->pad32 = 0;
	if (r->rsp) {
		if (bpf_probe_read_user(r->bytes, SB, (const void *)r->rsp) == 0)
			got = SB;
		else if (bpf_probe_read_user(r->bytes, SB / 2, (const void *)r->rsp) == 0)
			got = SB / 2;
		else if (bpf_probe_read_user(r->bytes, SB / 4, (const void *)r->rsp) == 0)
			got = SB / 4;
	}
	if (!got) {
		bpf_ringbuf_discard(r, BPF_RB_NO_WAKEUP);
		cnt(CT_STACK_READ_FAIL);
		return 0;
	}
	r->nbytes = (__u16)got;
	r->h.len = (__u16)(sizeof(struct rec_stack) + got);
	bpf_ringbuf_submit(r, RB_FLAGS);
	cnt(CT_STACKS);
	return 0;
}
