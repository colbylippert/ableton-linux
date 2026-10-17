// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * wine-trace.c — user-space side of the Wine interface profiler (libbpf CO-RE loader).
 *
 * Loads wine-trace.bpf.c through the bpftool skeleton, attaches the USDT probes of
 * patch 0108 (ntdll.so, provider "wine") and pipeasio/0017 (pipeasio64.dll.so, provider
 * "pipeasio") per traced pid, the kernel-side NTSync probes, the scheduler and task
 * lifecycle tracepoints, drains the in-kernel aggregation and the ring buffer, and writes
 * the same files as the bpftrace prototype + reduce.py:
 *
 *   blocks.jsonl   one record per audio block (header record first)
 *   threads.jsonl  one record per 100 ms window x tid
 *   summary.json   the interface rollup (reduce.py's schema, ableton-linux-tracer-summary/v1)
 *   events.jsonl   every completed crossing (--mode drilldown)
 *   stacks.jsonl   kept stack windows in symbolize.py's record shape
 *   tracer.json    merged in place (the wrapper writes the start fields)
 *   maps-<pid>.txt / maps-<pid>-stop.txt  /proc/PID/maps snapshots for symbolize.py
 *
 * Every timestamp is bpf_ktime_get_ns() == CLOCK_MONOTONIC, the suite's time.monotonic_ns()
 * base and PipeWire's clock.nsec base.  Offsets in the output files are seconds from the
 * header's monotonic_start_ns, which is the moment every probe was attached.
 *
 * Design: ../../../plans/design-B-tracer-and-probes.md sections 3b, 3c, 5 and 9.  Build and
 * usage: BUILD.md next to this file.
 */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <glob.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <linux/perf_event.h>
#include <linux/types.h>
#include <bpf/bpf.h>
#include <bpf/btf.h>
#include <bpf/libbpf.h>

#include "wine-trace.h"
#include "wine-trace.skel.h"

#define LOADER_NAME      "wine-trace.c"
#define SUMMARY_SCHEMA   "ableton-linux-tracer-summary/v1"
#define DEFAULT_NEAR_LATE 0.15
#define DEFAULT_TRAP_NS  1000u      /* assumed uprobe trap cost per hit (not measured) */
#define BLOCK_FLUSH_NS   700000000ULL      /* write a block 0.7 s after its end */
#define BLOCK_GIVEUP_NS  5000000000ULL     /* a block without block_end after 5 s is incomplete */
#define WINDOW_FLUSH_W   25                /* write a 100 ms window 2.5 s after it */
#define FOLLOW_TIMEOUT_NS 15000000000ULL   /* a forked child must map ntdll.so within 15 s */
#define POLL_MS          25
#define DRAIN_BATCH      4096
#define MAX_LINKS        4096
#define MAX_ATTACH_DESC  512

enum keep_stacks { KEEP_NONE = 0, KEEP_LATE = 1, KEEP_ALL = 2 };

static const char *const kind_names[KIND__COUNT] = {
	"none", "syscall", "unixcall", "server_req", "server_wait", "ntsync_wait", "ntsync_wake",
	"offcpu", "oncpu", "cycle", "sample",
};
#define IS_CROSSING_KIND(k) ((k) >= KIND_SYSCALL && (k) <= KIND_NTSYNC_WAKE)

static const char *const stat_names[ST__COUNT] = {
	[ST_HIT_SYSCALL_ENTRY] = "syscall_entry", [ST_HIT_SYSCALL_EXIT] = "syscall_exit",
	[ST_HIT_UNIXCALL_ENTRY] = "unixcall_entry", [ST_HIT_UNIXCALL_EXIT] = "unixcall_exit",
	[ST_HIT_SERVER_REQ_START] = "server_req_start", [ST_HIT_SERVER_REQ_END] = "server_req_end",
	[ST_HIT_SERVER_WAIT_START] = "server_wait_start", [ST_HIT_SERVER_WAIT_END] = "server_wait_end",
	[ST_HIT_BLOCK_START] = "block_start", [ST_HIT_BLOCK_BEFORE_LIVE] = "block_before_live",
	[ST_HIT_BLOCK_AFTER_LIVE] = "block_after_live", [ST_HIT_BLOCK_END] = "block_end",
	[ST_HIT_CYCLE_START] = "cycle_start", [ST_HIT_CYCLE_END] = "cycle_end",
	[ST_HIT_NTSYNC_WAIT] = "ntsync_wait", [ST_HIT_NTSYNC_WAKE] = "ntsync_wake",
	[ST_HIT_SCHED_SWITCH] = "sched_switch", [ST_HIT_SCHED_WAKING] = "sched_waking",
	[ST_HIT_PERF_SAMPLE] = "perf_sample",
	[ST_UNMATCHED_EXIT] = "unmatched_exits", [ST_THREAD_START_EXIT] = "unmatched_exits_first_on_tid",
	[ST_ABANDONED_ENTRY] = "abandoned_entries", [ST_INFLIGHT_OVERFLOW] = "inflight_overflow",
	[ST_AGG_FULL] = "agg_full", [ST_RINGBUF_DROP] = "ringbuf_drops",
	[ST_STACK_READ_FAIL] = "stack_read_fail", [ST_STACKS] = "stacks_emitted",
	[ST_FILTERED] = "filtered_by_role", [ST_NTSYNC_UNMATCHED] = "ntsync_wait_exit_without_entry",
	[ST_SAMPLE_CTR] = "sample_counter", [ST_UNIXCALL_SLOW_EXIT] = "unixcall_slow_path_exits",
};
#define ST_FIRST_COUNTER ST_UNMATCHED_EXIT

/* ======================================================================
 * options
 * ==================================================================== */
static struct {
	const char *out;
	int mode;                 /* enum wt_mode */
	__u32 pids[MAX_PIDS];
	int npids;
	char ntsync[16];          /* auto|fentry|kprobe|tracepoint|off */
	int sched;                /* -1 = default (on in drilldown) */
	const char *run_id;
	__u32 sample_n;
	int sample_set;
	__u32 stack_bytes;
	int roles_audio;
	int no_exit;
	__u32 slack_pct;
	__u32 ringbuf_mb;
	double duration;
	__u32 trigger_ids[MAX_TRIGGER_IDS];
	int ntrigger;
	const char *tables;
	const char *ntdll;
	const char *pipeasio;
	int follow;
	double near_late;
	int keep_stacks;          /* -1 = default */
	__u32 trap_ns;
	int perf_hz;
	int verbose;
	int quiet;
	int allow_priv_stack;
} opt = {
	.mode = MODE_SUMMARY, .ntsync = "auto", .sched = -1, .stack_bytes = STACK_BYTES_DEFAULT,
	.slack_pct = SLACK_THRESH_PCT_DEFAULT, .ringbuf_mb = RINGBUF_MB_DEFAULT, .follow = 1,
	.near_late = DEFAULT_NEAR_LATE, .keep_stacks = -1, .trap_ns = DEFAULT_TRAP_NS, .perf_hz = 999,
};

static volatile sig_atomic_t stop_flag;
static __u64 base_ns;            /* monotonic_start_ns: every probe attached */
static __u64 stop_ns;
static char exe_dir[PATH_MAX];

/* ======================================================================
 * small utilities
 * ==================================================================== */
static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
	va_list ap;

	if (opt.quiet)
		return;
	fputs("wine-trace: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
static void die(const char *fmt, ...)
{
	va_list ap;

	fputs("wine-trace: error: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);

	if (!p)
		die("out of memory (%zu bytes)", n);
	return p;
}

static void *xcalloc(size_t n, size_t sz)
{
	void *p = calloc(n ? n : 1, sz ? sz : 1);

	if (!p)
		die("out of memory (%zu x %zu bytes)", n, sz);
	return p;
}

static void *xrealloc(void *p, size_t n)
{
	p = realloc(p, n ? n : 1);
	if (!p)
		die("out of memory (%zu bytes)", n);
	return p;
}

static char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = xmalloc(n);

	memcpy(p, s, n);
	return p;
}

/* grow *arr (element size sz) so that it holds at least need elements */
static void grow(void **arr, size_t *cap, size_t need, size_t sz)
{
	size_t c = *cap ? *cap : 8;

	if (need <= *cap)
		return;
	while (c < need)
		c *= 2;
	*arr = xrealloc(*arr, c * sz);
	*cap = c;
}

/* bounded string copy (truncates, always terminates) */
static void scopy(char *d, size_t n, const char *s)
{
	size_t l = 0;

	for (; l + 1 < n && s[l]; l++)
		d[l] = s[l];
	d[l] = '\0';
}

static __u64 mono_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (__u64)ts.tv_sec * 1000000000ULL + (__u64)ts.tv_nsec;
}

static double off_s(__u64 ns)
{
	return ((double)(__s64)(ns - base_ns)) / 1e9;
}

static char *read_file(const char *path, size_t *len_out)
{
	FILE *f = fopen(path, "rb");
	char *buf = NULL;
	size_t len = 0, cap = 0, n;

	if (!f)
		return NULL;
	for (;;) {
		grow((void **)&buf, &cap, len + 65536 + 1, 1);
		n = fread(buf + len, 1, cap - len - 1, f);
		len += n;
		if (n == 0)
			break;
	}
	fclose(f);
	buf[len] = '\0';
	if (len_out)
		*len_out = len;
	return buf;
}

/* first line of a small /proc file, newline stripped; "" on failure */
static void read_line(const char *path, char *buf, size_t n)
{
	FILE *f = fopen(path, "r");

	buf[0] = '\0';
	if (!f)
		return;
	if (fgets(buf, (int)n, f))
		buf[strcspn(buf, "\n")] = '\0';
	fclose(f);
}

static void str_lower(char *d, const char *s, size_t n)
{
	size_t i;

	for (i = 0; i + 1 < n && s[i]; i++)
		d[i] = (char)tolower((unsigned char)s[i]);
	d[i] = '\0';
}

static bool ends_with(const char *s, const char *suf)
{
	size_t a = strlen(s), b = strlen(suf);

	return a >= b && strcmp(s + a - b, suf) == 0;
}

/* JSON string literal */
static void jstr(FILE *f, const char *s)
{
	const unsigned char *p = (const unsigned char *)(s ? s : "");

	fputc('"', f);
	for (; *p; p++) {
		switch (*p) {
		case '"': fputs("\\\"", f); break;
		case '\\': fputs("\\\\", f); break;
		case '\n': fputs("\\n", f); break;
		case '\r': fputs("\\r", f); break;
		case '\t': fputs("\\t", f); break;
		default:
			if (*p < 0x20)
				fprintf(f, "\\u%04x", *p);
			else
				fputc(*p, f);
		}
	}
	fputc('"', f);
}

static void jnum_or_null(FILE *f, bool have, long long v)
{
	if (have)
		fprintf(f, "%lld", v);
	else
		fputs("null", f);
}

/* comm[16] from the kernel may lack a terminator */
static void comm_copy(char *dst, const char *src)
{
	memcpy(dst, src, 16);
	dst[15] = '\0';
}

/* ======================================================================
 * open-addressing hash: u64 key -> u64 value (linear probing, backward-shift delete)
 * ==================================================================== */
struct hmap {
	__u64 *keys;
	__u64 *vals;
	unsigned char *used;
	size_t cap, n;
};

static __u64 hmix(__u64 x)
{
	x += 0x9e3779b97f4a7c15ULL;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
	return x ^ (x >> 31);
}

static void hmap_put(struct hmap *h, __u64 k, __u64 v);

static void hmap_resize(struct hmap *h, size_t cap)
{
	struct hmap o = *h;
	size_t i;

	h->keys = xcalloc(cap, sizeof(__u64));
	h->vals = xcalloc(cap, sizeof(__u64));
	h->used = xcalloc(cap, 1);
	h->cap = cap;
	h->n = 0;
	for (i = 0; i < o.cap; i++)
		if (o.used[i])
			hmap_put(h, o.keys[i], o.vals[i]);
	free(o.keys);
	free(o.vals);
	free(o.used);
}

static __u64 *hmap_get(const struct hmap *h, __u64 k)
{
	size_t i;

	if (!h->cap)
		return NULL;
	for (i = hmix(k) & (h->cap - 1); h->used[i]; i = (i + 1) & (h->cap - 1))
		if (h->keys[i] == k)
			return &h->vals[i];
	return NULL;
}

static void hmap_put(struct hmap *h, __u64 k, __u64 v)
{
	size_t i;

	if ((h->n + 1) * 4 >= h->cap * 3)
		hmap_resize(h, h->cap ? h->cap * 2 : 64);
	for (i = hmix(k) & (h->cap - 1); h->used[i]; i = (i + 1) & (h->cap - 1)) {
		if (h->keys[i] == k) {
			h->vals[i] = v;
			return;
		}
	}
	h->used[i] = 1;
	h->keys[i] = k;
	h->vals[i] = v;
	h->n++;
}

static void hmap_del(struct hmap *h, __u64 k)
{
	size_t i, j, home;

	if (!h->cap)
		return;
	for (i = hmix(k) & (h->cap - 1); h->used[i]; i = (i + 1) & (h->cap - 1))
		if (h->keys[i] == k)
			break;
	if (!h->used[i])
		return;
	h->used[i] = 0;
	h->n--;
	for (j = (i + 1) & (h->cap - 1); h->used[j]; j = (j + 1) & (h->cap - 1)) {
		home = hmix(h->keys[j]) & (h->cap - 1);
		/* move j back to i when i lies cyclically in [home, j) */
		if ((j > i && (home <= i || home > j)) || (j < i && (home <= i && home > j))) {
			h->keys[i] = h->keys[j];
			h->vals[i] = h->vals[j];
			h->used[i] = 1;
			h->used[j] = 0;
			i = j;
		}
	}
}

static __u64 fnv64(const char *s)
{
	__u64 h = 1469598103934665603ULL;

	for (; *s; s++) {
		h ^= (unsigned char)*s;
		h *= 1099511628211ULL;
	}
	return h;
}

/* ======================================================================
 * minimal JSON tree (tables file, tracer.json merge)
 * ==================================================================== */
enum jtype { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ };

struct jv {
	enum jtype t;
	char *s;              /* J_NUM raw text, J_STR decoded text, J_BOOL "true"/"false" */
	size_t n, cap;
	char **keys;          /* J_OBJ */
	struct jv **items;    /* J_ARR, J_OBJ */
};

struct jparser {
	const char *p;
	const char *err;
};

static struct jv *jv_new(enum jtype t)
{
	struct jv *v = xcalloc(1, sizeof(*v));

	v->t = t;
	return v;
}

static void jv_free(struct jv *v)
{
	size_t i;

	if (!v)
		return;
	for (i = 0; i < v->n; i++) {
		if (v->keys)
			free(v->keys[i]);
		jv_free(v->items[i]);
	}
	free(v->keys);
	free(v->items);
	free(v->s);
	free(v);
}

static void jv_push(struct jv *a, char *key, struct jv *item)
{
	grow((void **)&a->items, &a->cap, a->n + 1, sizeof(*a->items));
	if (a->t == J_OBJ) {
		a->keys = xrealloc(a->keys, a->cap * sizeof(*a->keys));
		a->keys[a->n] = key;
	}
	a->items[a->n++] = item;
}

static struct jv *jv_get(const struct jv *o, const char *key)
{
	size_t i;

	if (!o || o->t != J_OBJ)
		return NULL;
	for (i = 0; i < o->n; i++)
		if (strcmp(o->keys[i], key) == 0)
			return o->items[i];
	return NULL;
}

/* set (replace or append) key in object o; takes ownership of v */
static void jv_set(struct jv *o, const char *key, struct jv *v)
{
	size_t i;

	for (i = 0; i < o->n; i++) {
		if (strcmp(o->keys[i], key) == 0) {
			jv_free(o->items[i]);
			o->items[i] = v;
			return;
		}
	}
	jv_push(o, xstrdup(key), v);
}

static void jp_ws(struct jparser *jp)
{
	while (*jp->p == ' ' || *jp->p == '\t' || *jp->p == '\n' || *jp->p == '\r')
		jp->p++;
}

static void utf8_put(char **buf, size_t *len, size_t *cap, unsigned cp)
{
	grow((void **)buf, cap, *len + 5, 1);
	if (cp < 0x80) {
		(*buf)[(*len)++] = (char)cp;
	} else if (cp < 0x800) {
		(*buf)[(*len)++] = (char)(0xc0 | (cp >> 6));
		(*buf)[(*len)++] = (char)(0x80 | (cp & 0x3f));
	} else if (cp < 0x10000) {
		(*buf)[(*len)++] = (char)(0xe0 | (cp >> 12));
		(*buf)[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3f));
		(*buf)[(*len)++] = (char)(0x80 | (cp & 0x3f));
	} else {
		(*buf)[(*len)++] = (char)(0xf0 | (cp >> 18));
		(*buf)[(*len)++] = (char)(0x80 | ((cp >> 12) & 0x3f));
		(*buf)[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3f));
		(*buf)[(*len)++] = (char)(0x80 | (cp & 0x3f));
	}
}

static int hex4(const char *p, unsigned *out)
{
	unsigned v = 0;
	int i;

	for (i = 0; i < 4; i++) {
		char c = p[i];

		v <<= 4;
		if (c >= '0' && c <= '9')
			v |= (unsigned)(c - '0');
		else if (c >= 'a' && c <= 'f')
			v |= (unsigned)(c - 'a' + 10);
		else if (c >= 'A' && c <= 'F')
			v |= (unsigned)(c - 'A' + 10);
		else
			return -1;
	}
	*out = v;
	return 0;
}

static char *jp_string(struct jparser *jp)
{
	char *buf = NULL;
	size_t len = 0, cap = 0;

	if (*jp->p != '"') {
		jp->err = "string expected";
		return NULL;
	}
	jp->p++;
	grow((void **)&buf, &cap, 16, 1);
	while (*jp->p && *jp->p != '"') {
		char c = *jp->p++;

		if (c == '\\') {
			char e = *jp->p++;
			unsigned cp;

			switch (e) {
			case '"': case '\\': case '/': c = e; break;
			case 'b': c = '\b'; break;
			case 'f': c = '\f'; break;
			case 'n': c = '\n'; break;
			case 'r': c = '\r'; break;
			case 't': c = '\t'; break;
			case 'u':
				if (hex4(jp->p, &cp)) {
					jp->err = "bad \\u escape";
					free(buf);
					return NULL;
				}
				jp->p += 4;
				if (cp >= 0xd800 && cp < 0xdc00 && jp->p[0] == '\\' && jp->p[1] == 'u') {
					unsigned lo;

					if (!hex4(jp->p + 2, &lo) && lo >= 0xdc00 && lo < 0xe000) {
						cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
						jp->p += 6;
					}
				}
				utf8_put(&buf, &len, &cap, cp);
				continue;
			default:
				jp->err = "bad escape";
				free(buf);
				return NULL;
			}
		}
		grow((void **)&buf, &cap, len + 2, 1);
		buf[len++] = c;
	}
	if (*jp->p != '"') {
		jp->err = "unterminated string";
		free(buf);
		return NULL;
	}
	jp->p++;
	grow((void **)&buf, &cap, len + 1, 1);
	buf[len] = '\0';
	return buf;
}

static struct jv *jp_value(struct jparser *jp, int depth)
{
	struct jv *v;

	if (depth > 64) {
		jp->err = "nesting too deep";
		return NULL;
	}
	jp_ws(jp);
	switch (*jp->p) {
	case '{':
		v = jv_new(J_OBJ);
		jp->p++;
		jp_ws(jp);
		if (*jp->p == '}') {
			jp->p++;
			return v;
		}
		for (;;) {
			char *key;
			struct jv *item;

			jp_ws(jp);
			key = jp_string(jp);
			if (!key)
				goto fail;
			jp_ws(jp);
			if (*jp->p != ':') {
				free(key);
				jp->err = "':' expected";
				goto fail;
			}
			jp->p++;
			item = jp_value(jp, depth + 1);
			if (!item) {
				free(key);
				goto fail;
			}
			jv_push(v, key, item);
			jp_ws(jp);
			if (*jp->p == ',') {
				jp->p++;
				continue;
			}
			if (*jp->p == '}') {
				jp->p++;
				return v;
			}
			jp->err = "',' or '}' expected";
			goto fail;
		}
	case '[':
		v = jv_new(J_ARR);
		jp->p++;
		jp_ws(jp);
		if (*jp->p == ']') {
			jp->p++;
			return v;
		}
		for (;;) {
			struct jv *item = jp_value(jp, depth + 1);

			if (!item)
				goto fail;
			jv_push(v, NULL, item);
			jp_ws(jp);
			if (*jp->p == ',') {
				jp->p++;
				continue;
			}
			if (*jp->p == ']') {
				jp->p++;
				return v;
			}
			jp->err = "',' or ']' expected";
			goto fail;
		}
	case '"':
		v = jv_new(J_STR);
		v->s = jp_string(jp);
		if (!v->s)
			goto fail;
		return v;
	case 't':
		if (strncmp(jp->p, "true", 4) == 0) {
			jp->p += 4;
			v = jv_new(J_BOOL);
			v->s = xstrdup("true");
			return v;
		}
		break;
	case 'f':
		if (strncmp(jp->p, "false", 5) == 0) {
			jp->p += 5;
			v = jv_new(J_BOOL);
			v->s = xstrdup("false");
			return v;
		}
		break;
	case 'n':
		if (strncmp(jp->p, "null", 4) == 0) {
			jp->p += 4;
			return jv_new(J_NULL);
		}
		break;
	default:
		if (*jp->p == '-' || isdigit((unsigned char)*jp->p)) {
			const char *s = jp->p;
			size_t n;

			while (*jp->p && strchr("+-0123456789.eE", *jp->p))
				jp->p++;
			n = (size_t)(jp->p - s);
			v = jv_new(J_NUM);
			v->s = xmalloc(n + 1);
			memcpy(v->s, s, n);
			v->s[n] = '\0';
			return v;
		}
	}
	jp->err = "unexpected character";
	return NULL;
fail:
	jv_free(v);
	return NULL;
}

static struct jv *json_parse(const char *text, const char **err)
{
	struct jparser jp = { .p = text, .err = NULL };
	struct jv *v = jp_value(&jp, 0);

	if (v) {
		jp_ws(&jp);
		if (*jp.p) {
			jv_free(v);
			v = NULL;
			jp.err = "trailing data";
		}
	}
	if (err)
		*err = jp.err;
	return v;
}

/* Python json.dump(indent=1) layout */
static void json_write(FILE *f, const struct jv *v, int indent)
{
	size_t i;

	switch (v->t) {
	case J_NULL: fputs("null", f); break;
	case J_BOOL: case J_NUM: fputs(v->s, f); break;
	case J_STR: jstr(f, v->s); break;
	case J_ARR:
	case J_OBJ:
		if (!v->n) {
			fputs(v->t == J_ARR ? "[]" : "{}", f);
			break;
		}
		fputc(v->t == J_ARR ? '[' : '{', f);
		for (i = 0; i < v->n; i++) {
			fprintf(f, "%s\n%*s", i ? "," : "", indent + 1, "");
			if (v->t == J_OBJ) {
				jstr(f, v->keys[i]);
				fputs(": ", f);
			}
			json_write(f, v->items[i], indent + 1);
		}
		fprintf(f, "\n%*s%c", indent, "", v->t == J_ARR ? ']' : '}');
		break;
	}
}

static long long jv_int(const struct jv *v, long long dflt)
{
	if (!v || v->t != J_NUM)
		return dflt;
	return strtoll(v->s, NULL, 10);
}

/* ======================================================================
 * id tables (tables/wine-<ver>.json from gen_tables.py)
 * ==================================================================== */
static struct {
	char path[PATH_MAX];
	char wine_version[32];
	long long protocol;
	struct hmap syscalls;     /* id -> char* */
	struct hmap requests;     /* number -> char* */
	struct jv *unixcalls;     /* {"winscard": {"0": "name"}} */
	struct jv *root;
} tables;

static char wine_root[PATH_MAX];
static char wine_version[32];
static char *warnings[64];
static int nwarnings;

static void warn_add(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void warn_add(const char *fmt, ...)
{
	char buf[512];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	logmsg("warning: %s", buf);
	if (nwarnings < (int)(sizeof(warnings) / sizeof(warnings[0])))
		warnings[nwarnings++] = xstrdup(buf);
}

static void detect_wine_version(void)
{
	char path[PATH_MAX + 64], *text, *p;

	wine_version[0] = '\0';
	if (!wine_root[0])
		return;
	snprintf(path, sizeof(path), "%s/ABLETON-WINE-BUILD-INFO.txt", wine_root);
	text = read_file(path, NULL);
	if (text) {
		for (p = text; p && *p; p = strchr(p, '\n') ? strchr(p, '\n') + 1 : NULL) {
			if (strncmp(p, "wine:", 5) == 0) {
				char *w = strstr(p, "wine-");
				size_t n = 0;

				if (w) {
					w += 5;
					while ((isdigit((unsigned char)w[n]) || w[n] == '.') && n + 1 < sizeof(wine_version))
						n++;
					while (n && w[n - 1] == '.')
						n--;
					memcpy(wine_version, w, n);
					wine_version[n] = '\0';
				}
				break;
			}
		}
		free(text);
	}
	if (!wine_version[0]) {
		/* last N.N in the runtime path, like the wrapper */
		const char *s = wine_root, *best = NULL;
		size_t bestn = 0;

		while (*s) {
			if (isdigit((unsigned char)*s)) {
				const char *q = s;
				size_t n = 0;

				while (isdigit((unsigned char)q[n]))
					n++;
				if (q[n] == '.' && isdigit((unsigned char)q[n + 1])) {
					n++;
					while (isdigit((unsigned char)q[n]))
						n++;
					best = q;
					bestn = n;
				}
				s = q + n;
			} else {
				s++;
			}
		}
		if (best && bestn < sizeof(wine_version)) {
			memcpy(wine_version, best, bestn);
			wine_version[bestn] = '\0';
		}
	}
}

static void load_tables(void)
{
	char path[PATH_MAX + 64];
	const char *err = NULL;
	char *text;
	struct jv *root, *o;
	size_t i;

	path[0] = '\0';
	if (opt.tables) {
		scopy(path, sizeof(path), opt.tables);
	} else {
		if (wine_version[0]) {
			snprintf(path, sizeof(path), "%s/../tables/wine-%s.json", exe_dir, wine_version);
			if (access(path, R_OK) != 0)
				path[0] = '\0';
		}
		if (!path[0]) {
			glob_t g;
			char pat[PATH_MAX + 64];

			snprintf(pat, sizeof(pat), "%s/../tables/wine-*.json", exe_dir);
			if (glob(pat, 0, NULL, &g) == 0 && g.gl_pathc) {
				scopy(path, sizeof(path), g.gl_pathv[0]);
				globfree(&g);
			}
		}
	}
	if (!path[0]) {
		warn_add("no id table found next to %s; ids stay numeric", exe_dir);
		return;
	}
	text = read_file(path, NULL);
	if (!text) {
		warn_add("cannot read id table %s: %s", path, strerror(errno));
		return;
	}
	root = json_parse(text, &err);
	free(text);
	if (!root || root->t != J_OBJ) {
		warn_add("id table %s: %s", path, err ? err : "not an object");
		jv_free(root);
		return;
	}
	if (!realpath(path, tables.path))
		scopy(tables.path, sizeof(tables.path), path);
	tables.root = root;
	o = jv_get(root, "wine_version");
	if (o && o->t == J_STR)
		scopy(tables.wine_version, sizeof(tables.wine_version), o->s);
	tables.protocol = jv_int(jv_get(root, "server_protocol_version"), -1);
	o = jv_get(root, "syscalls");
	for (i = 0; o && o->t == J_OBJ && i < o->n; i++)
		if (o->items[i]->t == J_STR)
			hmap_put(&tables.syscalls, strtoull(o->keys[i], NULL, 16), (__u64)(uintptr_t)o->items[i]->s);
	o = jv_get(root, "requests");
	for (i = 0; o && o->t == J_OBJ && i < o->n; i++)
		if (o->items[i]->t == J_STR)
			hmap_put(&tables.requests, strtoull(o->keys[i], NULL, 10), (__u64)(uintptr_t)o->items[i]->s);
	tables.unixcalls = jv_get(root, "unixcalls");
	if (wine_version[0] && tables.wine_version[0] && strcmp(wine_version, tables.wine_version) != 0)
		warn_add("tables %s are for Wine %s but the runtime is %s", tables.path, tables.wine_version,
			 wine_version);
}

static const char *tables_basename(void)
{
	const char *s = strrchr(tables.path, '/');

	return tables.path[0] ? (s ? s + 1 : tables.path) : NULL;
}

/* ======================================================================
 * processes, threads, roles
 * ==================================================================== */
struct maprange { __u64 lo, hi; char *name; };

struct proc {
	__u32 pid;
	char comm[16];
	char image[256];
	char exe[PATH_MAX];
	char ntdll[PATH_MAX];
	char pipeasio[PATH_MAX];
	bool attached;          /* USDT probes attached */
	bool initial;           /* from --pid */
	bool gone;
	bool snapshot_written;
	__u64 pending_since;    /* fork follow: waiting for ntdll.so (0 = not pending) */
	struct maprange *ranges;
	size_t nranges;
	bool ranges_loaded;
};

struct thr {
	__u32 tid, pid;
	char comm[16];
	char role[64];
	bool role_valid;
	bool callback;
	__u8 bpf_role;          /* role written to the tids map (--roles audio) */
};

static struct hmap procs;     /* pid -> struct proc* */
static struct hmap thrs;      /* tid -> struct thr* */
static __u32 callback_tid;
static struct wine_trace *skel;

static struct proc *proc_get(__u32 pid, bool create)
{
	__u64 *v = hmap_get(&procs, pid);
	struct proc *p;

	if (v)
		return (struct proc *)(uintptr_t)*v;
	if (!create)
		return NULL;
	p = xcalloc(1, sizeof(*p));
	p->pid = pid;
	hmap_put(&procs, pid, (__u64)(uintptr_t)p);
	return p;
}

/* comm, image (Windows exe basename from argv[0]) and exe of a live process */
static void proc_identify(struct proc *p)
{
	char path[64], buf[4096];
	ssize_t n;
	int fd;

	snprintf(path, sizeof(path), "/proc/%u/comm", p->pid);
	read_line(path, buf, sizeof(buf));
	if (buf[0])
		scopy(p->comm, sizeof(p->comm), buf);
	snprintf(path, sizeof(path), "/proc/%u/cmdline", p->pid);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		n = read(fd, buf, sizeof(buf) - 1);
		close(fd);
		if (n > 0) {
			const char *b = buf, *s;

			buf[n] = '\0';
			for (s = buf; *s; s++)
				if (*s == '/' || *s == '\\')
					b = s + 1;
			if (*b)
				scopy(p->image, sizeof(p->image), b);
		}
	}
	if (!p->image[0])
		scopy(p->image, sizeof(p->image), p->comm);
	snprintf(path, sizeof(path), "/proc/%u/exe", p->pid);
	n = readlink(path, p->exe, sizeof(p->exe) - 1);
	p->exe[n > 0 ? n : 0] = '\0';
}

static void proc_free_ranges(struct proc *p)
{
	size_t i;

	for (i = 0; i < p->nranges; i++)
		free(p->ranges[i].name);
	free(p->ranges);
	p->ranges = NULL;
	p->nranges = 0;
}

/* parse /proc/PID/maps: .so ranges (unix-call handles) and the two probe libraries */
static bool proc_scan_maps(struct proc *p, bool keep_text)
{
	char path[64], *text, *line, *save = NULL;
	size_t cap = 0;
	FILE *snap = NULL;

	snprintf(path, sizeof(path), "/proc/%u/maps", p->pid);
	text = read_file(path, NULL);
	if (!text)
		return false;
	if (keep_text && opt.out) {
		char spath[PATH_MAX];

		snprintf(spath, sizeof(spath), "%s/maps-%u.txt", opt.out, p->pid);
		if (access(spath, F_OK) != 0) {
			snap = fopen(spath, "w");
			if (snap) {
				fputs(text, snap);
				fclose(snap);
				p->snapshot_written = true;
			}
		}
	}
	proc_free_ranges(p);
	for (line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
		unsigned long long lo, hi;
		int off = 0;
		const char *file;

		if (sscanf(line, "%llx-%llx %*s %*s %*s %*s %n", &lo, &hi, &off) < 2 || !off)
			continue;
		file = line + off;
		while (*file == ' ')
			file++;
		if (*file != '/')
			continue;
		if (!p->ntdll[0] && strstr(file, "/x86_64-unix/ntdll.so") && ends_with(file, "ntdll.so"))
			scopy(p->ntdll, sizeof(p->ntdll), file);
		if (!p->pipeasio[0] && strstr(file, "/x86_64-unix/pipeasio") && ends_with(file, ".dll.so"))
			scopy(p->pipeasio, sizeof(p->pipeasio), file);
		if (ends_with(file, ".so") || strstr(file, ".so.")) {
			const char *b = strrchr(file, '/');

			grow((void **)&p->ranges, &cap, p->nranges + 1, sizeof(*p->ranges));
			p->ranges[p->nranges].lo = lo;
			p->ranges[p->nranges].hi = hi;
			p->ranges[p->nranges].name = xstrdup(b ? b + 1 : file);
			p->nranges++;
		}
	}
	free(text);
	p->ranges_loaded = true;
	return true;
}

static const char *proc_module_at(struct proc *p, __u64 addr)
{
	size_t i;
	int pass;

	for (pass = 0; pass < 2; pass++) {
		if (!p->ranges_loaded || pass == 1)
			if (!proc_scan_maps(p, false))
				return NULL;
		for (i = 0; i < p->nranges; i++)
			if (addr >= p->ranges[i].lo && addr < p->ranges[i].hi)
				return p->ranges[i].name;
	}
	return NULL;
}

static struct thr *thr_get(__u32 tid, __u32 pid_hint)
{
	__u64 *v = hmap_get(&thrs, tid);
	struct thr *t;
	char path[64], buf[256];

	if (v)
		return (struct thr *)(uintptr_t)*v;
	t = xcalloc(1, sizeof(*t));
	t->tid = tid;
	t->pid = pid_hint;
	/* first sight of a tid we were not told about: ask /proc (works for any tid) */
	snprintf(path, sizeof(path), "/proc/%u/comm", tid);
	read_line(path, buf, sizeof(buf));
	scopy(t->comm, sizeof(t->comm), buf);
	if (!t->pid) {
		FILE *f;

		snprintf(path, sizeof(path), "/proc/%u/status", tid);
		f = fopen(path, "r");
		if (f) {
			while (fgets(buf, sizeof(buf), f)) {
				if (strncmp(buf, "Tgid:", 5) == 0) {
					t->pid = (__u32)strtoul(buf + 5, NULL, 10);
					break;
				}
			}
			fclose(f);
		}
	}
	hmap_put(&thrs, tid, (__u64)(uintptr_t)t);
	return t;
}

static __u8 role_enum(const char *role)
{
	if (strcmp(role, "pipeasio_callback") == 0) return ROLE_PIPEASIO_CALLBACK;
	if (strcmp(role, "audio_worker") == 0) return ROLE_AUDIO_WORKER;
	if (strcmp(role, "pipeasio_rt") == 0) return ROLE_PIPEASIO_RT;
	if (strcmp(role, "pipeasio_worker") == 0) return ROLE_PIPEASIO_WORKER;
	if (strcmp(role, "main") == 0) return ROLE_MAIN;
	if (strcmp(role, "wineserver") == 0) return ROLE_WINESERVER;
	if (strcmp(role, "webview") == 0) return ROLE_WEBVIEW;
	if (strcmp(role, "max") == 0) return ROLE_MAX;
	if (strcmp(role, "push2") == 0) return ROLE_PUSH2;
	if (strncmp(role, "live:", 5) == 0) return ROLE_LIVE;
	if (strncmp(role, "plugin:", 7) == 0) return ROLE_PLUGIN;
	return ROLE_UNKNOWN;
}

static bool role_is_audio(const char *role)
{
	return ROLE_IS_AUDIO(role_enum(role)) || strncmp(role, "plugin:", 7) == 0;
}

/* Built-in copy of the roles.toml rules (design B section 5), as reduce.py's builtin_role */
static const char *role_of(__u32 tid)
{
	struct thr *t = thr_get(tid, 0);
	struct proc *p;
	char image[256];
	const char *pcomm;

	if (t->role_valid)
		return t->role;
	p = t->pid ? proc_get(t->pid, false) : NULL;
	if (p && !p->comm[0] && !p->gone)
		proc_identify(p);
	str_lower(image, p ? p->image : "", sizeof(image));
	pcomm = p && p->comm[0] ? p->comm : NULL;
	if (t->callback)
		snprintf(t->role, sizeof(t->role), "pipeasio_callback");
	else if (strcmp(t->comm, "AudioCalc") == 0)
		snprintf(t->role, sizeof(t->role), "audio_worker");
	else if (strcmp(t->comm, "pipeasio-rt") == 0)
		snprintf(t->role, sizeof(t->role), "pipeasio_rt");
	else if (strcmp(t->comm, "pipeasio-worker") == 0)
		snprintf(t->role, sizeof(t->role), "pipeasio_worker");
	else if (strcmp(image, "wineserver") == 0 || strcmp(t->comm, "wineserver") == 0 ||
		 (pcomm && strcmp(pcomm, "wineserver") == 0))
		snprintf(t->role, sizeof(t->role), "wineserver");
	else if (strcmp(image, "msedgewebview2.exe") == 0)
		snprintf(t->role, sizeof(t->role), "webview");
	else if (strcmp(image, "max.exe") == 0)
		snprintf(t->role, sizeof(t->role), "max");
	else if (strcmp(image, "push2displayprocess.exe") == 0)
		snprintf(t->role, sizeof(t->role), "push2");
	else if (t->pid && tid == t->pid && ends_with(image, ".exe"))
		snprintf(t->role, sizeof(t->role), "main");
	else if (strncmp(image, "ableton live", 12) == 0 && t->comm[0] && pcomm && strcmp(t->comm, pcomm) != 0)
		snprintf(t->role, sizeof(t->role), "live:%s", t->comm);
	else if (t->comm[0])
		snprintf(t->role, sizeof(t->role), "unknown:%s", t->comm);
	else
		snprintf(t->role, sizeof(t->role), "unknown:%u", tid);
	t->role_valid = true;
	return t->role;
}

/* --roles audio: keep the kernel's tid filter in step with the classifier */
static void thr_sync_bpf_role(struct thr *t)
{
	__u8 r;
	int fd;

	if (!opt.roles_audio || !skel)
		return;
	r = role_enum(role_of(t->tid));
	if (r == t->bpf_role)
		return;
	fd = bpf_map__fd(skel->maps.tids);
	if (ROLE_IS_AUDIO(r))
		bpf_map_update_elem(fd, &t->tid, &r, BPF_ANY);
	else
		bpf_map_delete_elem(fd, &t->tid);
	t->bpf_role = r;
}

static void thr_set_comm(__u32 tid, __u32 pid, const char *comm)
{
	struct thr *t = thr_get(tid, pid);

	if (pid)
		t->pid = pid;
	comm_copy(t->comm, comm);
	t->role_valid = false;
	if (pid && pid == tid) {
		struct proc *p = proc_get(pid, false);

		/* the main thread's comm is the process comm (task_rename of a Wine child) */
		if (p && p->initial == false)
			comm_copy(p->comm, comm);
	}
	thr_sync_bpf_role(t);
}

static void scan_threads(__u32 pid)
{
	char path[64], cpath[96], buf[64];
	struct dirent *de;
	DIR *d;

	snprintf(path, sizeof(path), "/proc/%u/task", pid);
	d = opendir(path);
	if (!d)
		return;
	while ((de = readdir(d))) {
		__u32 tid = (__u32)strtoul(de->d_name, NULL, 10);

		if (!tid)
			continue;
		snprintf(cpath, sizeof(cpath), "/proc/%u/task/%u/comm", pid, tid);
		read_line(cpath, buf, sizeof(buf));
		{
			char c16[16] = { 0 };

			scopy(c16, sizeof(c16), buf);
			thr_set_comm(tid, pid, c16);
		}
	}
	closedir(d);
}

/* ======================================================================
 * id naming
 * ==================================================================== */
struct unixlib { __u32 pid; __u64 handle; char module[64]; bool resolved; };
static struct unixlib *unixlibs;
static size_t nunixlibs_cap;
static struct hmap unixcall_names;   /* id -> char* */

static void unixlib_record(__u32 idx, __u32 pid, __u64 handle)
{
	if (idx >= 0x10000)
		return;
	grow((void **)&unixlibs, &nunixlibs_cap, idx + 1, sizeof(*unixlibs));
	memset(&unixlibs[idx], 0, sizeof(unixlibs[idx]));
	unixlibs[idx].pid = pid;
	unixlibs[idx].handle = handle;
}

static const char *unixcall_name(__u32 id)
{
	__u64 *v = hmap_get(&unixcall_names, id);
	__u32 idx = id >> 16, code = id & 0xffff;
	char buf[256];
	struct unixlib *u;

	if (v)
		return (const char *)(uintptr_t)*v;
	snprintf(buf, sizeof(buf), "unixcall#%u", code);
	if (idx < nunixlibs_cap && unixlibs[idx].pid) {
		u = &unixlibs[idx];
		if (!u->resolved) {
			struct proc *p = proc_get(u->pid, true);
			const char *m = proc_module_at(p, u->handle);

			if (m)
				scopy(u->module, sizeof(u->module), m);
			u->resolved = true;
		}
		if (u->module[0]) {
			char mod[64], key[16];
			struct jv *codes, *name;

			scopy(mod, sizeof(mod), u->module);
			if (ends_with(mod, ".so"))
				mod[strlen(mod) - 3] = '\0';
			snprintf(key, sizeof(key), "%u", code);
			codes = jv_get(tables.unixcalls, mod);
			name = jv_get(codes, key);
			if (name && name->t == J_STR)
				snprintf(buf, sizeof(buf), "%s:%s", u->module, name->s);
			else
				snprintf(buf, sizeof(buf), "%s#%u", u->module, code);
		}
	}
	{
		char *s = xstrdup(buf);

		/* cache only resolved names: an index may be recorded after its first use */
		if (idx < nunixlibs_cap && unixlibs[idx].pid)
			hmap_put(&unixcall_names, id, (__u64)(uintptr_t)s);
		else {
			static char tmp[256];

			scopy(tmp, sizeof(tmp), s);
			free(s);
			return tmp;
		}
		return s;
	}
}

/* name of (kind, id); returns a pointer valid until the next call with a buffer of the caller */
static const char *id_name(int kind, __u32 id, char *buf, size_t n)
{
	__u64 *v;

	switch (kind) {
	case KIND_SYSCALL:
		v = hmap_get(&tables.syscalls, id);
		if (v)
			return (const char *)(uintptr_t)*v;
		snprintf(buf, n, "syscall_0x%04x", id);
		return buf;
	case KIND_UNIXCALL:
		snprintf(buf, n, "%s", unixcall_name(id));
		return buf;
	case KIND_SERVER_REQ:
		v = hmap_get(&tables.requests, id);
		if (v)
			return (const char *)(uintptr_t)*v;
		snprintf(buf, n, "request_%d", (int)id);
		return buf;
	case KIND_SERVER_WAIT:
		/* include/wine/server_protocol.h: SELECT_ALERTABLE 1, SELECT_INTERRUPTIBLE 2 */
		if ((id & 3) == 3)
			snprintf(buf, n, "alertable|interruptible");
		else if (id & 1)
			snprintf(buf, n, "alertable");
		else if (id & 2)
			snprintf(buf, n, "interruptible");
		else
			snprintf(buf, n, "0");
		return buf;
	case KIND_NTSYNC_WAIT:
		return (id & 1) ? "WAIT_ALL" : "WAIT_ANY";
	case KIND_NTSYNC_WAKE:
		switch (id) {
		case WAKE_EVENT_SET: return "EVENT_SET";
		case WAKE_EVENT_PULSE: return "EVENT_PULSE";
		case WAKE_SEM_RELEASE: return "SEM_RELEASE";
		case WAKE_MUTEX_UNLOCK: return "MUTEX_UNLOCK";
		default: snprintf(buf, n, "wake_%u", id); return buf;
		}
	case KIND_OFFCPU:
		snprintf(buf, n, "waker_%u", id);
		return buf;
	default:
		snprintf(buf, n, "%u", id);
		return buf;
	}
}

static void write_flag_names(FILE *f, __u16 fl)
{
	static const struct { __u16 bit; const char *name; } names[] = {
		{ AGGF_BETWEEN_BLOCKS, "between_blocks" }, { AGGF_TIMEOUT, "timeout" }, { AGGF_ALERTED, "alerted" },
		{ AGGF_ERROR, "error" }, { AGGF_OWNERDEAD, "ownerdead" }, { AGGF_INCOMPLETE, "incomplete_frame" },
		{ AGGF_PREEMPTED, "preempted" }, { AGGF_INTR, "interrupted" },
	};
	size_t i;
	bool first = true;

	fputc('[', f);
	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (fl & names[i].bit) {
			fprintf(f, "%s\"%s\"", first ? "" : ",", names[i].name);
			first = false;
		}
	}
	fputc(']', f);
}

/* ======================================================================
 * output files
 * ==================================================================== */
static FILE *f_blocks, *f_threads, *f_events, *f_stacks;
static char p_blocks[PATH_MAX], p_threads[PATH_MAX], p_events[PATH_MAX], p_stacks[PATH_MAX];

static const char *mode_name(void)
{
	return opt.mode == MODE_DRILLDOWN ? "drilldown" : opt.mode == MODE_SAMPLE ? "sample" : "summary";
}

static const char *keep_name(void)
{
	return opt.keep_stacks == KEEP_ALL ? "all" : opt.keep_stacks == KEEP_LATE ? "late" : "none";
}

static FILE *open_out(const char *name, char *final_path)
{
	char tmp[PATH_MAX + 16];
	FILE *f;

	snprintf(final_path, PATH_MAX, "%s/%s", opt.out, name);
	snprintf(tmp, sizeof(tmp), "%s.partial", final_path);
	f = fopen(tmp, "w");
	if (!f)
		die("cannot create %s: %s", tmp, strerror(errno));
	setvbuf(f, NULL, _IOFBF, 1 << 20);
	return f;
}

static void close_out(FILE **f, const char *final_path)
{
	char tmp[PATH_MAX + 16];

	if (!*f)
		return;
	snprintf(tmp, sizeof(tmp), "%s.partial", final_path);
	if (fclose(*f) != 0)
		warn_add("write error on %s: %s", tmp, strerror(errno));
	else if (rename(tmp, final_path) != 0)
		warn_add("cannot rename %s: %s", tmp, strerror(errno));
	*f = NULL;
}

static void write_header(FILE *f, const char *file)
{
	struct proc *p;
	size_t i;
	bool first = true;

	fprintf(f, "{\"type\":\"header\",\"file\":\"%s\",\"roles\":\"builtin\",\"monotonic_start_ns\":%llu,"
		   "\"monotonic_end_ns\":null,\"version\":\"wine-trace/" WINE_TRACE_VERSION "\",\"backend\":\"libbpf\","
		   "\"reducer\":\"" LOADER_NAME "/" WINE_TRACE_VERSION "\",\"wine_version\":",
		file, (unsigned long long)base_ns);
	if (wine_version[0] || tables.wine_version[0])
		jstr(f, wine_version[0] ? wine_version : tables.wine_version);
	else
		fputs("null", f);
	fputs(",\"tables\":", f);
	if (tables_basename())
		jstr(f, tables_basename());
	else
		fputs("null", f);
	fputs(",\"server_protocol_version\":", f);
	jnum_or_null(f, tables.protocol >= 0, tables.protocol);
	fputs(",\"pids\":[", f);
	for (i = 0; i < procs.cap; i++) {
		if (!procs.used[i])
			continue;
		p = (struct proc *)(uintptr_t)procs.vals[i];
		if (!p->initial)
			continue;
		fprintf(f, "%s%u", first ? "" : ",", p->pid);
		first = false;
	}
	fprintf(f, "],\"mode\":\"%s\",\"sample\":{\"rate\":1,\"stack_sample_n\":%u,\"stack_bytes\":%u,"
		   "\"slack_threshold_pct\":%u,\"keep_stacks\":\"%s\",\"roles\":\"%s\",\"no_exit\":%s},"
		   "\"near_late_fraction\":%g,\"window_ms\":%llu,\"clock\":\"CLOCK_MONOTONIC\"}\n",
		mode_name(), opt.sample_n, opt.stack_bytes, opt.slack_pct, keep_name(),
		opt.roles_audio ? "audio" : "all", opt.no_exit ? "true" : "false", opt.near_late,
		(unsigned long long)(WINDOW_NS / 1000000ULL));
}

/* ======================================================================
 * whole-trace aggregates for summary.json
 * ==================================================================== */
struct site {               /* call site (kind, id name), caller-less */
	char *key;
	int kind;
	char *name;
	__u64 late_blocks, near_late_blocks, n_in_late, total_in_late, blocks_with_site;
	double attributed;
	__u64 n_all, total_all, max_ns;
	__u32 wakers[5];
	__u64 waker_n[5];
	struct site *next;
};
static struct hmap sites;            /* fnv64(key) -> struct site* chain */

struct hotspot { char *key; char *role; int kind; char *name; __u64 n, total; struct hotspot *next; };
static struct hmap hotspots;

struct rolebins { char *role; __u64 *n, *total; size_t nb, cap; struct rolebins *next; };
static struct hmap rolebins;

static __u64 kinds_n[KIND__COUNT], kinds_total[KIND__COUNT];

static struct {
	__u64 count, late, near_late, missed, incomplete;
	__s64 *slack;
	__u64 *elapsed;
	size_t nslack, capslack, nel, capel;
	__u64 period_min, period_max;
	__u64 first_t0, last_t1;
	__u64 lost_total;
	double attributed_total;
	struct hmap periods;   /* period -> count */
} bstat;

static struct {
	__u64 rb_records[16];
	__u64 keys_drained, drains, keys_for_flushed_block, keys_for_unknown_block;
	__u64 stacks_kept, stacks_dropped, events_written, blocks_written, windows_written;
	__u64 forks, follow_attached, follow_failed, offcpu_records, wake_records;
	__u64 open_entries_at_end, invalid_blocks, rb_short;
} cnt;

static struct site *site_get(int kind, const char *name)
{
	char key[512];
	__u64 h, *v;
	struct site *s;

	snprintf(key, sizeof(key), "%s|%s", kind_names[kind], name);
	h = fnv64(key);
	v = hmap_get(&sites, h);
	for (s = v ? (struct site *)(uintptr_t)*v : NULL; s; s = s->next)
		if (strcmp(s->key, key) == 0)
			return s;
	s = xcalloc(1, sizeof(*s));
	s->key = xstrdup(key);
	s->kind = kind;
	s->name = xstrdup(name);
	s->next = v ? (struct site *)(uintptr_t)*v : NULL;
	hmap_put(&sites, h, (__u64)(uintptr_t)s);
	return s;
}

static void site_waker(struct site *s, __u32 waker, __u64 n)
{
	int i, min = 0;

	for (i = 0; i < 5; i++) {
		if (s->wakers[i] == waker) {
			s->waker_n[i] += n;
			return;
		}
		if (s->waker_n[i] < s->waker_n[min])
			min = i;
	}
	if (s->waker_n[min] < n) {     /* keep the 5 most frequent (approximately) */
		s->wakers[min] = waker;
		s->waker_n[min] = n;
	}
}

static void hotspot_add(const char *role, int kind, const char *name, __u64 n, __u64 total)
{
	char key[512];
	__u64 h, *v;
	struct hotspot *s;

	snprintf(key, sizeof(key), "%s|%s|%s", role, kind_names[kind], name);
	h = fnv64(key);
	v = hmap_get(&hotspots, h);
	for (s = v ? (struct hotspot *)(uintptr_t)*v : NULL; s; s = s->next)
		if (strcmp(s->key, key) == 0)
			break;
	if (!s) {
		s = xcalloc(1, sizeof(*s));
		s->key = xstrdup(key);
		s->role = xstrdup(role);
		s->kind = kind;
		s->name = xstrdup(name);
		s->next = v ? (struct hotspot *)(uintptr_t)*v : NULL;
		hmap_put(&hotspots, h, (__u64)(uintptr_t)s);
	}
	s->n += n;
	s->total += total;
}

static struct rolebins *rolebins_get(const char *role)
{
	__u64 h = fnv64(role), *v = hmap_get(&rolebins, h);
	struct rolebins *r;

	for (r = v ? (struct rolebins *)(uintptr_t)*v : NULL; r; r = r->next)
		if (strcmp(r->role, role) == 0)
			return r;
	r = xcalloc(1, sizeof(*r));
	r->role = xstrdup(role);
	r->next = v ? (struct rolebins *)(uintptr_t)*v : NULL;
	hmap_put(&rolebins, h, (__u64)(uintptr_t)r);
	return r;
}

/* ======================================================================
 * blocks
 * ==================================================================== */
struct xent {
	__u32 tid;
	__u16 kind, flags;
	__u32 id, waker;
	__u64 count, total, max, oncpu, aux;
};

struct stackrec {
	__u64 ref, ts, seq, frame, rsp, rip;
	__u32 tid, id;
	__u16 kind, nbytes;
	__u64 regs[20];
	unsigned char *bytes;
	bool written;
};

struct block {
	__u64 seq;
	__u64 t0, before, after, t1, clock_nsec, deadline;
	__u32 tid, nframes, rate, start_flags, end_flags, missed;
	bool have_start, have_end, have_before, have_after;
	struct xent *x;
	size_t nx, capx;
	struct stackrec *st;
	size_t nst, capst;
	bool have_cycle, cycle_end;
	__u64 c_start, c_end;
	__u32 c_missed, c_delivered;
	__u64 created;          /* mono_ns() when the record was created */
};

static struct hmap blocks;          /* seq -> struct block* (pending) */
static struct hmap flushed_seqs;    /* recently written seqs -> t1 (late keys) */
static struct hmap cycle_starts;    /* tid -> cycle_start ts */
static __u64 stack_ref_next = 1;

static struct block *block_get(__u64 seq, bool create)
{
	__u64 *v = hmap_get(&blocks, seq);
	struct block *b;

	if (v)
		return (struct block *)(uintptr_t)*v;
	if (!create)
		return NULL;
	b = xcalloc(1, sizeof(*b));
	b->seq = seq;
	b->created = mono_ns();
	hmap_put(&blocks, seq, (__u64)(uintptr_t)b);
	return b;
}

static void block_free(struct block *b)
{
	size_t i;

	for (i = 0; i < b->nst; i++)
		free(b->st[i].bytes);
	free(b->st);
	free(b->x);
	free(b);
}

static void stack_write(FILE *f, const struct stackrec *s, bool record)
{
	struct thr *t = thr_get(s->tid, 0);
	char nb[256];
	const char *name = s->kind == KIND_PERF ? (s->id ? "kernel" : "user") : id_name(s->kind, s->id, nb, sizeof(nb));
	size_t i;

	if (record)
		fprintf(f, "{\"type\":\"stack\",\"ref\":%llu,", (unsigned long long)s->ref);
	else
		fprintf(f, "{\"ref\":%llu,", (unsigned long long)s->ref);
	fprintf(f, "\"t\":%.6f,\"tid\":%u,\"pid\":%u,\"seq\":%llu,\"kind\":\"%s\",\"id\":", off_s(s->ts), s->tid,
		t->pid, (unsigned long long)((s->seq & WINDOW_BIT) ? 0 : s->seq),
		s->kind == KIND_PERF ? "sample" : kind_names[s->kind]);
	jstr(f, name);
	fprintf(f, ",\"id_num\":%u,\"role\":", s->id);
	jstr(f, role_of(s->tid));
	fprintf(f, ",\"frame\":\"0x%llx\",\"rip\":\"0x%llx\",\"rsp\":\"0x%llx\",\"regs\":[",
		(unsigned long long)s->frame, (unsigned long long)s->rip, (unsigned long long)s->rsp);
	for (i = 0; i < 20; i++)
		fprintf(f, "%s%llu", i ? "," : "", (unsigned long long)s->regs[i]);
	fputs("],\"stack_hex\":\"", f);
	for (i = 0; i < s->nbytes; i++)
		fprintf(f, "%02x", s->bytes[i]);
	fputs("\"}", f);
	if (record)
		fputc('\n', f);
}

static void stack_ref_only(FILE *f, const struct stackrec *s)
{
	char nb[256];

	fprintf(f, "{\"ref\":%llu,\"t\":%.6f,\"tid\":%u,\"kind\":\"%s\",\"id\":", (unsigned long long)s->ref,
		off_s(s->ts), s->tid, kind_names[s->kind]);
	jstr(f, id_name(s->kind, s->id, nb, sizeof(nb)));
	fputc('}', f);
}

/* ---- threads windows ---- */
struct idagg { __u16 kind; __u32 id; __u64 n, total; };

struct twin {
	__u64 w;
	__u32 tid;
	__u64 kn[KIND__COUNT], kt[KIND__COUNT];
	struct idagg *ids;
	size_t nids, capids;
	__u64 oncpu, offcpu, run_delay, wakeups;
	bool sched;
	__u64 btw_n, btw_t;
};

static struct hmap windows;     /* (w << 32 | tid) -> struct twin* */
static __u64 min_window = UINT64_MAX;

static struct twin *twin_get(__u64 w, __u32 tid)
{
	__u64 key = (w << 32) | tid, *v = hmap_get(&windows, key);
	struct twin *t;

	if (v)
		return (struct twin *)(uintptr_t)*v;
	t = xcalloc(1, sizeof(*t));
	t->w = w;
	t->tid = tid;
	hmap_put(&windows, key, (__u64)(uintptr_t)t);
	if (w < min_window)
		min_window = w;
	return t;
}

static void twin_add(__u64 w, const struct xent *x, bool between)
{
	struct twin *t = twin_get(w, x->tid);
	size_t i;

	if (x->kind == KIND_ONCPU) {
		t->oncpu += x->total;
		t->sched = true;
		return;
	}
	if (x->kind == KIND_OFFCPU) {
		t->offcpu += x->total;
		t->run_delay += x->oncpu;
		if (!(x->flags & AGGF_PREEMPTED))
			t->wakeups += x->count;
		t->sched = true;
		return;
	}
	if (!IS_CROSSING_KIND(x->kind))
		return;
	t->kn[x->kind] += x->count;
	t->kt[x->kind] += x->total;
	if (between) {
		t->btw_n += x->count;
		t->btw_t += x->total;
	}
	for (i = 0; i < t->nids; i++) {
		if (t->ids[i].kind == x->kind && t->ids[i].id == x->id) {
			t->ids[i].n += x->count;
			t->ids[i].total += x->total;
			return;
		}
	}
	grow((void **)&t->ids, &t->capids, t->nids + 1, sizeof(*t->ids));
	t->ids[t->nids].kind = x->kind;
	t->ids[t->nids].id = x->id;
	t->ids[t->nids].n = x->count;
	t->ids[t->nids].total = x->total;
	t->nids++;
}

struct named { const char *name; __u64 n, total; };

static int cmp_named(const void *a, const void *b)
{
	const struct named *x = a, *y = b;

	if (x->total != y->total)
		return x->total > y->total ? -1 : 1;
	return strcmp(x->name, y->name);
}

struct rolewin { const char *role; __u64 n, total; };

static int cmp_twin(const void *a, const void *b)
{
	const struct twin *x = *(const struct twin *const *)a, *y = *(const struct twin *const *)b;

	if (x->w != y->w)
		return x->w < y->w ? -1 : 1;
	return x->tid < y->tid ? -1 : x->tid > y->tid;
}

static bool sched_enabled;

static void twin_write(struct twin *t, struct rolewin **rw, size_t *nrw, size_t *caprw)
{
	struct thr *th = thr_get(t->tid, 0);
	const char *role = role_of(t->tid);
	char names[64][128];
	struct named top[64];
	size_t ntop = 0, i, j;
	__u64 n_all = 0, t_all = 0;
	int k;
	bool first;

	/* merge ids by name (ntsync ids differ by count/alert) */
	for (i = 0; i < t->nids && ntop < 64; i++) {
		char nb[256];
		const char *nm = id_name(t->ids[i].kind, t->ids[i].id, nb, sizeof(nb));

		for (j = 0; j < ntop; j++)
			if (strcmp(top[j].name, nm) == 0)
				break;
		if (j == ntop) {
			scopy(names[ntop], sizeof(names[ntop]), nm);
			top[ntop].name = names[ntop];
			top[ntop].n = 0;
			top[ntop].total = 0;
			ntop++;
		}
		top[j].n += t->ids[i].n;
		top[j].total += t->ids[i].total;
	}
	qsort(top, ntop, sizeof(top[0]), cmp_named);
	fprintf(f_threads, "{\"t\":%.3f,\"window_ms\":%llu,\"pid\":%u,\"tid\":%u,\"comm\":",
		((double)(__s64)(t->w * WINDOW_NS - base_ns)) / 1e9, (unsigned long long)(WINDOW_NS / 1000000ULL),
		th->pid, t->tid);
	jstr(f_threads, th->comm);
	fputs(",\"role\":", f_threads);
	jstr(f_threads, role);
	fputs(",\"oncpu_ns\":", f_threads);
	jnum_or_null(f_threads, sched_enabled, (long long)t->oncpu);
	fputs(",\"offcpu_ns\":", f_threads);
	jnum_or_null(f_threads, sched_enabled, (long long)t->offcpu);
	fprintf(f_threads, ",\"wakeups\":%llu,\"run_delay_ns\":", (unsigned long long)t->wakeups);
	jnum_or_null(f_threads, sched_enabled, (long long)t->run_delay);
	fputs(",\"crossings\":{", f_threads);
	first = true;
	for (k = KIND_SYSCALL; k <= KIND_NTSYNC_WAKE; k++) {
		if (!t->kn[k])
			continue;
		fprintf(f_threads, "%s\"%s\":{\"n\":%llu,\"total_ns\":%llu}", first ? "" : ",", kind_names[k],
			(unsigned long long)t->kn[k], (unsigned long long)t->kt[k]);
		first = false;
		n_all += t->kn[k];
		t_all += t->kt[k];
	}
	fputs("},\"top_ids\":[", f_threads);
	for (i = 0; i < ntop && i < 5; i++) {
		fputs(i ? ",[" : "[", f_threads);
		jstr(f_threads, top[i].name);
		fprintf(f_threads, ",%llu,%llu]", (unsigned long long)top[i].n, (unsigned long long)top[i].total);
	}
	fputc(']', f_threads);
	if (t->btw_n)
		fprintf(f_threads, ",\"between_blocks\":{\"n\":%llu,\"total_ns\":%llu}", (unsigned long long)t->btw_n,
			(unsigned long long)t->btw_t);
	fputs("}\n", f_threads);
	cnt.windows_written++;
	/* per-role crossing load of this window (summary.json roles) */
	for (i = 0; i < *nrw; i++)
		if (strcmp((*rw)[i].role, role) == 0)
			break;
	if (i == *nrw) {
		grow((void **)rw, caprw, *nrw + 1, sizeof(**rw));
		(*rw)[i].role = rolebins_get(role)->role;
		(*rw)[i].n = 0;
		(*rw)[i].total = 0;
		(*nrw)++;
	}
	(*rw)[i].n += n_all;
	(*rw)[i].total += t_all;
}

/* write every window w < limit (all windows when limit == UINT64_MAX) */
static void flush_windows(__u64 limit)
{
	struct twin **list = NULL;
	struct rolewin *rw = NULL;
	size_t n = 0, cap = 0, i, nrw = 0, caprw = 0;
	__u64 cur_w = UINT64_MAX;

	if (min_window >= limit)
		return;
	for (i = 0; i < windows.cap; i++) {
		struct twin *t;

		if (!windows.used[i])
			continue;
		t = (struct twin *)(uintptr_t)windows.vals[i];
		if (t->w < limit) {
			grow((void **)&list, &cap, n + 1, sizeof(*list));
			list[n++] = t;
		}
	}
	qsort(list, n, sizeof(*list), cmp_twin);
	for (i = 0; i <= n; i++) {
		if (i == n || list[i]->w != cur_w) {
			size_t r;

			for (r = 0; r < nrw; r++) {
				struct rolebins *rb = rolebins_get(rw[r].role);

				grow((void **)&rb->n, &rb->cap, rb->nb + 1, sizeof(*rb->n));
				rb->total = xrealloc(rb->total, rb->cap * sizeof(*rb->total));
				rb->n[rb->nb] = rw[r].n;
				rb->total[rb->nb] = rw[r].total;
				rb->nb++;
			}
			nrw = 0;
			if (i == n)
				break;
			cur_w = list[i]->w;
		}
		if (f_threads)
			twin_write(list[i], &rw, &nrw, &caprw);
		hmap_del(&windows, (list[i]->w << 32) | list[i]->tid);
		free(list[i]->ids);
		free(list[i]);
	}
	free(list);
	free(rw);
	min_window = UINT64_MAX;
	for (i = 0; i < windows.cap; i++)
		if (windows.used[i] && ((struct twin *)(uintptr_t)windows.vals[i])->w < min_window)
			min_window = ((struct twin *)(uintptr_t)windows.vals[i])->w;
}

/* ---- block output ---- */
struct xc {                 /* merged crossing of one block */
	__u32 tid;
	int kind;
	char name[160];
	__u64 n, total, max;
	__u32 waker;
	__u64 waker_n;
	__u64 timeouts;
};

static int cmp_xc(const void *a, const void *b)
{
	const struct xc *x = a, *y = b;

	if (x->total != y->total)
		return x->total > y->total ? -1 : 1;
	if (x->tid != y->tid)
		return x->tid < y->tid ? -1 : 1;
	if (x->kind != y->kind)
		return x->kind < y->kind ? -1 : 1;
	return strcmp(x->name, y->name);
}

static int cmp_s64(const void *a, const void *b)
{
	__s64 x = *(const __s64 *)a, y = *(const __s64 *)b;

	return x < y ? -1 : x > y;
}

static int cmp_u64(const void *a, const void *b)
{
	__u64 x = *(const __u64 *)a, y = *(const __u64 *)b;

	return x < y ? -1 : x > y;
}

static void block_flush(struct block *b)
{
	struct xc *xc = NULL;
	size_t nxc = 0, capxc = 0, i, j;
	__u64 period, near_ns, w0;
	__s64 slack = 0;
	bool have_slack, late = false, near = false;
	__u64 crossing_total = 0;
	FILE *f = f_blocks;

	if (!b->have_start || !b->have_end || b->t1 < b->t0) {
		if (!b->have_start || !b->have_end)
			bstat.incomplete++;
		else
			cnt.invalid_blocks++;
		/* its crossings still count for the thread windows */
		for (i = 0; i < b->nx; i++)
			twin_add((b->have_start ? b->t0 : b->t1) / WINDOW_NS, &b->x[i], false);
		return;
	}
	period = b->rate ? ((__u64)b->nframes * 1000000000ULL + b->rate / 2) / b->rate : 0;
	near_ns = (__u64)llround(opt.near_late * (double)period);
	have_slack = b->deadline != 0;
	if (have_slack) {
		slack = (__s64)(b->deadline - b->t1);
		late = slack < 0;
		near = !late && slack < (__s64)near_ns;
	}
	w0 = b->t0 / WINDOW_NS;

	/* merge the drained keys by (tid, kind, name) */
	for (i = 0; i < b->nx; i++) {
		const struct xent *x = &b->x[i];
		char nb[256];
		const char *nm;

		twin_add(w0, x, false);
		if (!IS_CROSSING_KIND(x->kind))
			continue;
		nm = id_name(x->kind, x->id, nb, sizeof(nb));
		for (j = 0; j < nxc; j++)
			if (xc[j].tid == x->tid && xc[j].kind == x->kind && strcmp(xc[j].name, nm) == 0)
				break;
		if (j == nxc) {
			grow((void **)&xc, &capxc, nxc + 1, sizeof(*xc));
			memset(&xc[j], 0, sizeof(xc[j]));
			xc[j].tid = x->tid;
			xc[j].kind = x->kind;
			scopy(xc[j].name, sizeof(xc[j].name), nm);
			nxc++;
		}
		xc[j].n += x->count;
		xc[j].total += x->total;
		if (x->max > xc[j].max)
			xc[j].max = x->max;
		if (x->flags & AGGF_TIMEOUT)
			xc[j].timeouts += x->count;
		if (x->waker) {
			if (!xc[j].waker || xc[j].waker == x->waker) {
				xc[j].waker = x->waker;
				xc[j].waker_n += x->count;
			} else if (x->count > xc[j].waker_n) {
				xc[j].waker = x->waker;
				xc[j].waker_n = x->count;
			}
		}
	}
	qsort(xc, nxc, sizeof(*xc), cmp_xc);
	for (i = 0; i < nxc; i++)
		crossing_total += xc[i].total;

	/* summary statistics */
	bstat.count++;
	if (late)
		bstat.late++;
	if (near)
		bstat.near_late++;
	bstat.missed += b->missed;
	if (have_slack) {
		grow((void **)&bstat.slack, &bstat.capslack, bstat.nslack + 1, sizeof(*bstat.slack));
		bstat.slack[bstat.nslack++] = slack;
	}
	grow((void **)&bstat.elapsed, &bstat.capel, bstat.nel + 1, sizeof(*bstat.elapsed));
	bstat.elapsed[bstat.nel++] = b->t1 - b->t0;
	if (period) {
		__u64 *pc = hmap_get(&bstat.periods, period);

		hmap_put(&bstat.periods, period, pc ? *pc + 1 : 1);
		if (!bstat.period_min || period < bstat.period_min)
			bstat.period_min = period;
		if (period > bstat.period_max)
			bstat.period_max = period;
	}
	if (!bstat.first_t0 || b->t0 < bstat.first_t0)
		bstat.first_t0 = b->t0;
	if (b->t1 > bstat.last_t1)
		bstat.last_t1 = b->t1;
	if (late || near) {
		__u64 lost = (__u64)((__s64)near_ns - slack);
		__u64 attributed = lost < crossing_total ? lost : crossing_total;

		bstat.lost_total += lost;
		bstat.attributed_total += (double)attributed;
		for (i = 0; i < nxc; i++) {
			struct site *s = site_get(xc[i].kind, xc[i].name);

			s->blocks_with_site++;
			if (late)
				s->late_blocks++;
			else
				s->near_late_blocks++;
			s->n_in_late += xc[i].n;
			s->total_in_late += xc[i].total;
			if (crossing_total)
				s->attributed += (double)attributed * (double)xc[i].total / (double)crossing_total;
		}
	}

	/* blocks.jsonl record */
	if (f) {
		fprintf(f, "{\"seq\":%llu,\"t_start\":%.6f,\"t_before_live\":", (unsigned long long)b->seq, off_s(b->t0));
		if (b->have_before)
			fprintf(f, "%.6f", off_s(b->before));
		else
			fputs("null", f);
		fputs(",\"t_after_live\":", f);
		if (b->have_after)
			fprintf(f, "%.6f", off_s(b->after));
		else
			fputs("null", f);
		fprintf(f, ",\"t_end\":%.6f,\"clock_nsec\":%llu,\"deadline_ns\":%llu,\"period_ns\":%llu,\"nframes\":%u,"
			   "\"rate\":%u,\"callback_tid\":%u,\"wake_latency_ns\":",
			off_s(b->t1), (unsigned long long)b->clock_nsec, (unsigned long long)b->deadline,
			(unsigned long long)period, b->nframes, b->rate, b->tid);
		jnum_or_null(f, b->clock_nsec != 0, (long long)(b->t0 - b->clock_nsec));
		fputs(",\"pre_ns\":", f);
		jnum_or_null(f, b->have_before, (long long)(b->before - b->t0));
		fputs(",\"live_ns\":", f);
		jnum_or_null(f, b->have_before && b->have_after, (long long)(b->after - b->before));
		fputs(",\"post_ns\":", f);
		jnum_or_null(f, b->have_after, (long long)(b->t1 - b->after));
		fprintf(f, ",\"elapsed_ns\":%llu,\"slack_ns\":", (unsigned long long)(b->t1 - b->t0));
		jnum_or_null(f, have_slack, slack);
		fprintf(f, ",\"late\":%s,\"near_late\":%s,\"missed_cycles\":%u,\"flags\":[", late ? "true" : "false",
			near ? "true" : "false", b->missed);
		{
			bool first = true;

			if (b->end_flags & 1) { fputs("\"admitted\"", f); first = false; }
			if (b->end_flags & 2) { fputs(first ? "\"time_info\"" : ",\"time_info\"", f); first = false; }
			if (b->end_flags & 4) { fputs(first ? "\"muted\"" : ",\"muted\"", f); }
		}
		fputs("],\"crossings\":[", f);
		for (i = 0; i < nxc; i++) {
			fprintf(f, "%s{\"tid\":%u,\"role\":", i ? "," : "", xc[i].tid);
			jstr(f, role_of(xc[i].tid));
			fprintf(f, ",\"kind\":\"%s\",\"id\":", kind_names[xc[i].kind]);
			jstr(f, xc[i].name);
			fprintf(f, ",\"n\":%llu,\"total_ns\":%llu,\"max_ns\":%llu", (unsigned long long)xc[i].n,
				(unsigned long long)xc[i].total, (unsigned long long)xc[i].max);
			if (xc[i].timeouts)
				fprintf(f, ",\"timeouts\":%llu", (unsigned long long)xc[i].timeouts);
			if (xc[i].waker) {
				fprintf(f, ",\"woken_by\":{\"tid\":%u,\"role\":", xc[i].waker);
				jstr(f, role_of(xc[i].waker));
				fprintf(f, ",\"count\":%llu}", (unsigned long long)xc[i].waker_n);
			}
			fputc('}', f);
		}
		fputs("],\"offcpu\":[", f);
		{
			bool first = true;

			for (i = 0; i < b->nx; i++) {
				const struct xent *x = &b->x[i];
				__u64 ns = 0, intervals = 0, maxd = 0;

				if (x->kind != KIND_OFFCPU || !role_is_audio(role_of(x->tid)))
					continue;
				/* merge all offcpu keys of this tid (different wakers / flags) */
				for (j = 0; j < i; j++)
					if (b->x[j].kind == KIND_OFFCPU && b->x[j].tid == x->tid)
						break;
				if (j < i)
					continue;
				for (j = i; j < b->nx; j++) {
					if (b->x[j].kind != KIND_OFFCPU || b->x[j].tid != x->tid)
						continue;
					ns += b->x[j].total;
					intervals += b->x[j].count;
					if (b->x[j].aux > maxd)
						maxd = b->x[j].aux;
				}
				fprintf(f, "%s{\"tid\":%u,\"role\":", first ? "" : ",", x->tid);
				jstr(f, role_of(x->tid));
				fprintf(f, ",\"ns\":%llu,\"intervals\":%llu,\"max_run_delay_ns\":%llu}", (unsigned long long)ns,
					(unsigned long long)intervals, (unsigned long long)maxd);
				first = false;
			}
		}
		fputs("],\"stacks\":[", f);
		{
			bool first = true;
			bool inline_data = (late || near) && opt.keep_stacks != KEEP_NONE;

			for (i = 0; i < b->nst; i++) {
				struct stackrec *s = &b->st[i];

				if (!inline_data && opt.keep_stacks != KEEP_ALL)
					continue;
				fputs(first ? "" : ",", f);
				first = false;
				if (inline_data)
					stack_write(f, s, false);
				else
					stack_ref_only(f, s);
				if (inline_data && !s->written && f_stacks) {
					stack_write(f_stacks, s, true);
					s->written = true;
				}
			}
		}
		fputc(']', f);
		if (b->have_cycle) {
			fprintf(f, ",\"cycle\":{\"t_start\":%.6f,\"pre_ns\":%lld", off_s(b->c_start),
				(long long)(b->t0 - b->c_start));
			if (b->cycle_end)
				fprintf(f, ",\"t_end\":%.6f,\"post_ns\":%lld,\"missed\":%u,\"delivered\":%u", off_s(b->c_end),
					(long long)(b->c_end - b->t1), b->c_missed, b->c_delivered);
			fputc('}', f);
		}
		fputs("}\n", f);
		cnt.blocks_written++;
	}
	for (i = 0; i < b->nst; i++) {
		if (b->st[i].written)
			cnt.stacks_kept++;
		else
			cnt.stacks_dropped++;
	}
	free(xc);
}

/* write blocks that ended before `limit` (and give up on blocks without end) */
static void flush_blocks(__u64 now, bool all)
{
	__u64 *seqs = NULL;
	size_t n = 0, cap = 0, i;

	for (i = 0; i < blocks.cap; i++) {
		struct block *b;

		if (!blocks.used[i])
			continue;
		b = (struct block *)(uintptr_t)blocks.vals[i];
		if (all || (b->have_end && b->t1 + BLOCK_FLUSH_NS < now) ||
		    (!b->have_end && b->created + BLOCK_GIVEUP_NS < now)) {
			grow((void **)&seqs, &cap, n + 1, sizeof(*seqs));
			seqs[n++] = b->seq;
		}
	}
	qsort(seqs, n, sizeof(*seqs), cmp_u64);
	for (i = 0; i < n; i++) {
		struct block *b = block_get(seqs[i], false);

		block_flush(b);
		hmap_del(&blocks, seqs[i]);
		hmap_put(&flushed_seqs, seqs[i], b->have_end ? b->t1 : b->t0);
		block_free(b);
	}
	/* forget flushed seqs after 10 s */
	if (flushed_seqs.n > 20000) {
		n = 0;
		for (i = 0; i < flushed_seqs.cap; i++) {
			if (flushed_seqs.used[i] && flushed_seqs.vals[i] + 10000000000ULL < now) {
				grow((void **)&seqs, &cap, n + 1, sizeof(*seqs));
				seqs[n++] = flushed_seqs.keys[i];
			}
		}
		for (i = 0; i < n; i++)
			hmap_del(&flushed_seqs, seqs[i]);
	}
	free(seqs);
}

/* ======================================================================
 * aggregation drain
 * ==================================================================== */
static void consume_key(const struct agg_key *k, const struct agg_val *v)
{
	struct xent x = {
		.tid = k->tid, .kind = k->kind, .flags = k->flags, .id = k->id, .waker = v->last_waker,
		.count = v->count, .total = v->total_ns, .max = v->max_ns, .oncpu = v->oncpu_ns, .aux = v->aux_ns,
	};

	cnt.keys_drained++;
	if (k->kind < KIND__COUNT && IS_CROSSING_KIND(k->kind)) {
		char nb[256];
		const char *nm = id_name(k->kind, k->id, nb, sizeof(nb));
		struct site *s = site_get(k->kind, nm);
		const char *role = role_of(k->tid);

		kinds_n[k->kind] += v->count;
		kinds_total[k->kind] += v->total_ns;
		s->n_all += v->count;
		s->total_all += v->total_ns;
		if (v->max_ns > s->max_ns)
			s->max_ns = v->max_ns;
		if (v->last_waker)
			site_waker(s, v->last_waker, v->count);
		if (!role_is_audio(role))
			hotspot_add(role, k->kind, nm, v->count, v->total_ns);
	}
	if (k->seq & WINDOW_BIT) {
		twin_add(k->seq & ~WINDOW_BIT, &x, (k->flags & AGGF_BETWEEN_BLOCKS) != 0);
		return;
	}
	{
		struct block *b = block_get(k->seq, false);

		if (!b) {
			__u64 *t = hmap_get(&flushed_seqs, k->seq);

			if (t) {
				cnt.keys_for_flushed_block++;
				twin_add(*t / WINDOW_NS, &x, false);
				return;
			}
			/* a block whose block_start we have not seen yet (or never will) */
			cnt.keys_for_unknown_block++;
			b = block_get(k->seq, true);
		}
		grow((void **)&b->x, &b->capx, b->nx + 1, sizeof(*b->x));
		b->x[b->nx++] = x;
	}
}

static struct agg_key *drain_keys;
static struct agg_val *drain_vals;

static void drain_slot(int slot)
{
	struct bpf_map *maps[AGG_SLOTS] = { skel->maps.agg0, skel->maps.agg1, skel->maps.agg2, skel->maps.agg3 };
	int fd = bpf_map__fd(maps[slot & (AGG_SLOTS - 1)]);
	__u64 in = 0, out = 0;
	bool first = true;
	LIBBPF_OPTS(bpf_map_batch_opts, bo);

	cnt.drains++;
	for (;;) {
		__u32 count = DRAIN_BATCH, i;
		int err = bpf_map_lookup_and_delete_batch(fd, first ? NULL : &in, &out, drain_keys, drain_vals, &count,
							  &bo);
		int e = errno;

		for (i = 0; i < count && (err == 0 || e == ENOENT); i++)
			consume_key(&drain_keys[i], &drain_vals[i]);
		if (err) {
			if (e != ENOENT)
				warn_add("draining agg%d: %s", slot, strerror(e));
			break;
		}
		in = out;
		first = false;
	}
}

static __u64 next_drain_w;   /* the next slot window to drain */

/* Slot window w (keys completed while now / AGG_SLOT_NS == w) is quiet once the clock is in
 * window w + 2: the BPF side then writes slot (w + 2) & 3 only after another 100 ms.  When
 * the loop lags, a window that maps onto the current or previous slot is skipped (its keys
 * are drained with that slot's own window later), never drained while it receives writes. */
static void drain_due(__u64 now)
{
	__u64 cur = now / AGG_SLOT_NS;
	bool done[AGG_SLOTS] = { false };

	if (!next_drain_w)
		next_drain_w = cur;
	for (; next_drain_w + 2 <= cur; next_drain_w++) {
		int s = (int)(next_drain_w & (AGG_SLOTS - 1));

		if (done[s] || s == (int)(cur & (AGG_SLOTS - 1)) || s == (int)((cur - 1) & (AGG_SLOTS - 1)))
			continue;
		drain_slot(s);
		done[s] = true;
	}
}

/* ======================================================================
 * ring buffer
 * ==================================================================== */
struct tidring { __u64 ts[8], ref[8]; unsigned pos; };
static struct hmap stack_refs;      /* tid -> struct tidring* (drill-down stack_ref lookup) */

static void stack_ref_remember(__u32 tid, __u64 ts, __u64 ref)
{
	__u64 *v = hmap_get(&stack_refs, tid);
	struct tidring *r;

	if (v) {
		r = (struct tidring *)(uintptr_t)*v;
	} else {
		r = xcalloc(1, sizeof(*r));
		hmap_put(&stack_refs, tid, (__u64)(uintptr_t)r);
	}
	r->ts[r->pos & 7] = ts;
	r->ref[r->pos & 7] = ref;
	r->pos++;
}

static __u64 stack_ref_find(__u32 tid, __u64 ts)
{
	__u64 *v = hmap_get(&stack_refs, tid);
	struct tidring *r;
	int i;

	if (!v || !ts)
		return 0;
	r = (struct tidring *)(uintptr_t)*v;
	for (i = 0; i < 8; i++)
		if (r->ts[i] == ts)
			return r->ref[i];
	return 0;
}

static void follow_child(__u32 pid, __u64 now);

static void handle_block_rec(const struct rec_block *r)
{
	struct block *b;

	switch (r->phase) {
	case PHASE_BLOCK_START: {
		struct thr *t = thr_get(r->h.tid, 0);

		if (!t->callback) {
			t->callback = true;
			t->role_valid = false;
			thr_sync_bpf_role(t);
		}
		callback_tid = r->h.tid;
		b = block_get(r->seq, true);
		b->have_start = true;
		b->t0 = r->h.ts;
		b->tid = r->h.tid;
		b->nframes = r->nframes;
		b->rate = r->rate;
		b->clock_nsec = r->clock_nsec;
		b->deadline = r->deadline_ns;
		b->start_flags = r->flags;
		break;
	}
	case PHASE_BEFORE_LIVE:
		b = block_get(r->seq, true);
		b->before = r->h.ts;
		b->have_before = true;
		break;
	case PHASE_AFTER_LIVE:
		b = block_get(r->seq, true);
		b->after = r->h.ts;
		b->have_after = true;
		break;
	case PHASE_BLOCK_END:
		b = block_get(r->seq, true);
		b->t1 = r->h.ts;
		b->end_flags = r->flags;
		b->missed = r->missed;
		b->have_end = true;
		if (!b->have_start && r->clock_nsec && r->clock_nsec <= r->h.ts) {
			/* the block_start record was lost: the BPF side repeats its timestamp here */
			b->t0 = r->clock_nsec;
			b->deadline = r->deadline_ns;
			b->nframes = r->nframes;
			b->rate = r->rate;
			b->tid = r->h.tid;
		}
		break;
	case PHASE_CYCLE_START:
		hmap_put(&cycle_starts, r->h.tid, r->h.ts);
		break;
	case PHASE_CYCLE_END: {
		__u64 *cs = hmap_get(&cycle_starts, r->h.tid);

		if (r->seq && cs) {
			b = block_get(r->seq, false);
			if (b) {
				b->have_cycle = true;
				b->c_start = *cs;
				b->c_end = r->h.ts;
				b->cycle_end = true;
				b->c_missed = r->missed;
				b->c_delivered = r->flags;
			}
		}
		if (cs)
			hmap_del(&cycle_starts, r->h.tid);
		break;
	}
	default:
		break;
	}
}

static void handle_stack_rec(const struct rec_stack *r, size_t size)
{
	struct stackrec s = { 0 };
	size_t n = r->nbytes;

	if (sizeof(*r) + n > size) {
		cnt.rb_short++;
		return;
	}
	s.ref = stack_ref_next++;
	s.ts = r->h.ts;
	s.seq = r->seq;
	s.frame = r->frame;
	s.rsp = r->rsp;
	s.rip = r->rip;
	s.tid = r->h.tid;
	s.id = r->id;
	s.kind = r->kind;
	s.nbytes = (__u16)n;
	memcpy(s.regs, r->regs, sizeof(s.regs));
	s.bytes = xmalloc(n);
	memcpy(s.bytes, r->bytes, n);
	if (opt.mode == MODE_DRILLDOWN)
		stack_ref_remember(s.tid, s.ts, s.ref);
	if (opt.keep_stacks == KEEP_ALL && f_stacks) {
		stack_write(f_stacks, &s, true);
		s.written = true;
	}
	if (!(s.seq & WINDOW_BIT) && s.seq && s.kind != KIND_PERF) {
		struct block *b = block_get(s.seq, true);

		grow((void **)&b->st, &b->capst, b->nst + 1, sizeof(*b->st));
		b->st[b->nst++] = s;
		return;
	}
	if (s.written)
		cnt.stacks_kept++;
	else
		cnt.stacks_dropped++;
	free(s.bytes);
}

static void handle_event_rec(const struct rec_event *r)
{
	FILE *f = f_events;
	char nb[256];
	__u64 ref;

	if (!f)
		return;
	/* events.jsonl carries the crossing kinds (validate.py's KINDS); PipeWire cycles are in
	 * blocks.jsonl's `cycle` */
	if (r->kind >= KIND__COUNT || !IS_CROSSING_KIND(r->kind))
		return;
	fprintf(f, "{\"t\":%.6f,\"tid\":%u,\"role\":", off_s(r->entry_ts), r->h.tid);
	jstr(f, role_of(r->h.tid));
	fprintf(f, ",\"kind\":\"%s\",\"id\":", kind_names[r->kind]);
	jstr(f, id_name(r->kind, r->id, nb, sizeof(nb)));
	fprintf(f, ",\"id_num\":%u,\"dur_ns\":%llu,\"status\":", r->id, (unsigned long long)(r->h.ts - r->entry_ts));
	if (r->kind == KIND_NTSYNC_WAIT || r->kind == KIND_NTSYNC_WAKE)
		fprintf(f, "%d", r->status);
	else
		fprintf(f, "\"0x%x\"", (unsigned)r->status);
	fprintf(f, ",\"seq\":%llu,\"flags\":", (unsigned long long)((r->seq & WINDOW_BIT) ? 0 : r->seq));
	write_flag_names(f, r->flags);
	if (r->kind == KIND_NTSYNC_WAIT)
		fprintf(f, ",\"count\":%u,\"alert\":%u", (r->id >> 8) & 0xff, (r->id >> 1) & 1);
	ref = stack_ref_find(r->h.tid, r->stack_ts);
	if (ref)
		fprintf(f, ",\"stack_ref\":%llu", (unsigned long long)ref);
	if (r->waker_tid) {
		fprintf(f, ",\"woken_by\":{\"tid\":%u,\"role\":", r->waker_tid);
		jstr(f, role_of(r->waker_tid));
		fputc('}', f);
	}
	fputs("}\n", f);
	cnt.events_written++;
}

static int handle_rec(void *ctx, void *data, size_t size)
{
	const struct rec_hdr *h = data;

	(void)ctx;
	if (size < sizeof(*h)) {
		cnt.rb_short++;
		return 0;
	}
	if (h->type < 16)
		cnt.rb_records[h->type]++;
	switch (h->type) {
	case REC_BLOCK:
		if (size >= sizeof(struct rec_block))
			handle_block_rec(data);
		break;
	case REC_STACK:
		if (size >= sizeof(struct rec_stack))
			handle_stack_rec(data, size);
		break;
	case REC_EVENT:
		if (size >= sizeof(struct rec_event))
			handle_event_rec(data);
		break;
	case REC_UNIXLIB:
		if (size >= sizeof(struct rec_unixlib)) {
			const struct rec_unixlib *r = data;

			unixlib_record(r->idx, r->pid, r->handle);
			/* resolve the module now, while the process (and its maps) is certainly alive */
			if (r->idx < nunixlibs_cap) {
				struct proc *p = proc_get(r->pid, true);
				const char *m = proc_module_at(p, r->handle);

				if (m)
					scopy(unixlibs[r->idx].module, sizeof(unixlibs[r->idx].module), m);
				unixlibs[r->idx].resolved = true;
			}
		}
		break;
	case REC_NAME:
		if (size >= sizeof(struct rec_name)) {
			const struct rec_name *r = data;

			thr_set_comm(h->tid, r->pid, r->comm);
		}
		break;
	case REC_FORK:
		if (size >= sizeof(struct rec_task)) {
			const struct rec_task *r = data;
			struct proc *p = proc_get(r->pid, true);

			cnt.forks++;
			comm_copy(p->comm, r->comm);
			thr_set_comm(h->tid, r->pid, r->comm);
			if (opt.follow && !p->attached && !p->pending_since)
				p->pending_since = h->ts ? h->ts : mono_ns();
		}
		break;
	case REC_THREAD:
		if (size >= sizeof(struct rec_task)) {
			const struct rec_task *r = data;

			thr_set_comm(h->tid, r->pid, r->comm);
		}
		break;
	case REC_EXIT:
		if (size >= sizeof(struct rec_task)) {
			const struct rec_task *r = data;

			if (r->flags & 1) {
				struct proc *p = proc_get(r->pid, false);

				if (p) {
					p->gone = true;
					p->pending_since = 0;
				}
			}
		}
		break;
	case REC_OFFCPU:
		cnt.offcpu_records++;
		break;
	case REC_WAKE:
		cnt.wake_records++;
		break;
	default:
		break;
	}
	return 0;
}

/* ======================================================================
 * BPF setup and attachment
 * ==================================================================== */
static struct bpf_link *links[MAX_LINKS];
static int nlinks;
static char *attach_desc[MAX_ATTACH_DESC];
static int nattach_desc;
static char ntsync_used[16] = "off";
static bool waking_irq;
static int stats_fd = -1;
static int nperf;

static void add_link(struct bpf_link *l)
{
	if (nlinks < MAX_LINKS)
		links[nlinks++] = l;
	else
		bpf_link__destroy(l);
}

static void add_desc(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void add_desc(const char *fmt, ...)
{
	char buf[PATH_MAX + 128];
	va_list ap;
	int i;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	for (i = 0; i < nattach_desc; i++)
		if (strcmp(attach_desc[i], buf) == 0)
			return;
	if (nattach_desc < MAX_ATTACH_DESC)
		attach_desc[nattach_desc++] = xstrdup(buf);
}

static int libbpf_print(enum libbpf_print_level level, const char *fmt, va_list ap)
{
	if (level == LIBBPF_DEBUG && opt.verbose < 2)
		return 0;
	if (level == LIBBPF_INFO && !opt.verbose)
		return 0;
	return vfprintf(stderr, fmt, ap);
}

static bool file_exists(const char *p)
{
	return access(p, F_OK) == 0;
}

static bool kallsyms_has(const char *sym)
{
	FILE *f = fopen("/proc/kallsyms", "r");
	char line[512];
	bool found = false;
	size_t n = strlen(sym);

	if (!f)
		return false;
	while (!found && fgets(line, sizeof(line), f)) {
		char *s = strchr(line, ' ');

		if (!s || !(s = strchr(s + 1, ' ')))
			continue;
		s++;
		if (strncmp(s, sym, n) == 0 && (s[n] == '\n' || s[n] == '\t' || s[n] == ' ' || s[n] == '\0'))
			found = true;
	}
	fclose(f);
	return found;
}

static bool btf_has_preempt_count(void)
{
	struct btf *btf = btf__load_vmlinux_btf();
	bool found;

	if (!btf)
		return false;
	found = btf__find_by_name_kind(btf, "__preempt_count", BTF_KIND_VAR) >= 0;
	btf__free(btf);
	return found;
}

static void set_autoload(void)
{
	bool fentry = strcmp(ntsync_used, "fentry") == 0, kprobe = strcmp(ntsync_used, "kprobe") == 0,
	     tp = strcmp(ntsync_used, "tracepoint") == 0;
	bool sched = opt.sched == 1;

	bpf_program__set_autoload(skel->progs.fe_ntsync_char_ioctl, fentry);
	bpf_program__set_autoload(skel->progs.fx_ntsync_char_ioctl, fentry);
	bpf_program__set_autoload(skel->progs.fe_ntsync_obj_ioctl, fentry);
	bpf_program__set_autoload(skel->progs.kp_ntsync_char_ioctl, kprobe);
	bpf_program__set_autoload(skel->progs.kr_ntsync_char_ioctl, kprobe);
	bpf_program__set_autoload(skel->progs.kp_ntsync_obj_ioctl, kprobe);
	bpf_program__set_autoload(skel->progs.tp_sys_enter_ioctl, tp);
	bpf_program__set_autoload(skel->progs.tp_sys_exit_ioctl, tp);
	bpf_program__set_autoload(skel->progs.on_sched_switch, sched);
	bpf_program__set_autoload(skel->progs.on_sched_waking, sched && !waking_irq);
	bpf_program__set_autoload(skel->progs.on_sched_waking_irq, sched && waking_irq);
	bpf_program__set_autoload(skel->progs.on_sched_process_fork, opt.follow != 0);
	bpf_program__set_autoload(skel->progs.on_perf_sample, opt.mode == MODE_SAMPLE);
}

static __u32 roundup_pow2(__u32 v)
{
	__u32 p = 1;

	while (p < v && p < (1u << 30))
		p <<= 1;
	return p;
}

/* open + load with the NTSync fallback chain; returns 0 or exits */
static void open_and_load(void)
{
	const char *chain[4];
	int nchain = 0, i, err = 0;

	if (strcmp(opt.ntsync, "auto") == 0) {
		if (file_exists("/sys/kernel/btf/ntsync"))
			chain[nchain++] = "fentry";
		if (kallsyms_has("ntsync_char_ioctl"))
			chain[nchain++] = "kprobe";
		chain[nchain++] = "tracepoint";
		chain[nchain++] = "off";
	} else {
		chain[nchain++] = opt.ntsync;
		if (strcmp(opt.ntsync, "off") != 0)
			chain[nchain++] = "off";
	}
	waking_irq = btf_has_preempt_count();
	for (i = 0; i < nchain; i++) {
		scopy(ntsync_used, sizeof(ntsync_used), chain[i]);
		skel = wine_trace__open();
		if (!skel)
			die("cannot open the BPF skeleton: %s", strerror(errno));
		err = bpf_map__set_max_entries(skel->maps.rb, roundup_pow2(opt.ringbuf_mb) << 20);
		if (err)
			die("cannot size the ring buffer: %s", strerror(-err));
		set_autoload();
		err = wine_trace__load(skel);
		if (!err)
			break;
		warn_add("loading the BPF object with --ntsync %s failed: %s", chain[i], strerror(-err));
		wine_trace__destroy(skel);
		skel = NULL;
	}
	if (!skel)
		die("the BPF object did not load (see the verifier log above)");
	if (strcmp(ntsync_used, opt.ntsync) != 0 && strcmp(opt.ntsync, "auto") != 0)
		warn_add("--ntsync %s fell back to %s", opt.ntsync, ntsync_used);
}

static int attach_usdt_one(struct bpf_program *prog, __u32 pid, const char *path, const char *provider,
			   const char *name)
{
	struct bpf_link *l = bpf_program__attach_usdt(prog, (pid_t)pid, path, provider, name, NULL);

	if (!l) {
		int e = errno;

		if (opt.verbose)
			logmsg("attach %s:%s to pid %u (%s) failed: %s", provider, name, pid, path, strerror(e));
		return -e;
	}
	add_link(l);
	add_desc("usdt:%s:%s:%s", path, provider, name);
	return 0;
}

/* attach the USDT programs to one process; returns the number of probes attached */
static int attach_proc(struct proc *p)
{
	struct { struct bpf_program *prog; const char *name; bool exit; } wine[] = {
		{ skel->progs.wine_syscall_entry, "syscall_entry", false },
		{ skel->progs.wine_syscall_exit, "syscall_exit", true },
		{ skel->progs.wine_unixcall_entry, "unixcall_entry", false },
		{ skel->progs.wine_unixcall_exit, "unixcall_exit", true },
		{ skel->progs.wine_server_req_start, "server_req_start", false },
		{ skel->progs.wine_server_req_end, "server_req_end", true },
		{ skel->progs.wine_server_wait_start, "server_wait_start", false },
		{ skel->progs.wine_server_wait_end, "server_wait_end", true },
	}, pa[] = {
		{ skel->progs.pipeasio_block_start, "block_start", false },
		{ skel->progs.pipeasio_block_before_live, "block_before_live", false },
		{ skel->progs.pipeasio_block_after_live, "block_after_live", false },
		{ skel->progs.pipeasio_block_end, "block_end", false },
		{ skel->progs.pipeasio_cycle_start, "cycle_start", false },
		{ skel->progs.pipeasio_cycle_end, "cycle_end", false },
	};
	const char *ntdll = opt.ntdll && opt.ntdll[0] ? opt.ntdll : p->ntdll;
	const char *pipeasio = opt.pipeasio && opt.pipeasio[0] ? opt.pipeasio : p->pipeasio;
	size_t i;
	int n = 0;

	if (!ntdll[0])
		return 0;
	for (i = 0; i < sizeof(wine) / sizeof(wine[0]); i++) {
		if (opt.no_exit && wine[i].exit)
			continue;
		if (attach_usdt_one(wine[i].prog, p->pid, ntdll, "wine", wine[i].name) == 0)
			n++;
	}
	/* only processes that map the driver can fire its probes */
	if (pipeasio[0] && p->pipeasio[0]) {
		for (i = 0; i < sizeof(pa) / sizeof(pa[0]); i++)
			if (attach_usdt_one(pa[i].prog, p->pid, pipeasio, "pipeasio", pa[i].name) == 0)
				n++;
	}
	if (n)
		p->attached = true;
	return n;
}

static void attach_kernel(void)
{
	struct bpf_program *prog;

	bpf_object__for_each_program(prog, skel->obj) {
		enum bpf_prog_type t = bpf_program__type(prog);
		struct bpf_link *l;
		const char *sec = bpf_program__section_name(prog);

		if (!bpf_program__autoload(prog) || t == BPF_PROG_TYPE_PERF_EVENT)
			continue;
		if (strcmp(sec, "usdt") == 0)
			continue;
		l = bpf_program__attach(prog);
		if (!l) {
			int e = errno;

			if (strncmp(bpf_program__name(prog), "on_sched_process_fork", 21) == 0 ||
			    strncmp(bpf_program__name(prog), "on_task_rename", 14) == 0 ||
			    strncmp(bpf_program__name(prog), "on_sched_process_exit", 21) == 0)
				warn_add("attaching %s (%s) failed: %s", bpf_program__name(prog), sec, strerror(e));
			else
				die("attaching %s (%s) failed: %s", bpf_program__name(prog), sec, strerror(e));
			continue;
		}
		add_link(l);
		add_desc("%s", sec);
	}
}

static void attach_perf(void)
{
	int ncpu = libbpf_num_possible_cpus(), cpu;

	for (cpu = 0; cpu < ncpu; cpu++) {
		struct perf_event_attr attr = {
			.type = PERF_TYPE_SOFTWARE, .config = PERF_COUNT_SW_CPU_CLOCK, .size = sizeof(attr),
			.sample_freq = (__u64)opt.perf_hz, .freq = 1,
		};
		int fd = (int)syscall(__NR_perf_event_open, &attr, -1, cpu, -1, PERF_FLAG_FD_CLOEXEC);
		struct bpf_link *l;

		if (fd < 0)
			continue;   /* offline CPU */
		l = bpf_program__attach_perf_event(skel->progs.on_perf_sample, fd);
		if (!l) {
			close(fd);
			continue;
		}
		add_link(l);
		nperf++;
	}
	if (!nperf)
		die("--mode sample: no cpu-clock perf event could be attached");
	add_desc("perf_event:cpu-clock:%dHz", opt.perf_hz);
}

static void follow_child(__u32 pid, __u64 now)
{
	struct proc *p = proc_get(pid, false);
	int n;

	if (!p || p->attached || !p->pending_since)
		return;
	if (opt.mode == MODE_SAMPLE) {     /* kernel-side pid filter only; no USDT in sample mode */
		p->pending_since = 0;
		return;
	}
	if (p->gone || !proc_scan_maps(p, false)) {
		p->pending_since = 0;
		return;
	}
	if (!p->ntdll[0]) {
		if (now > p->pending_since + FOLLOW_TIMEOUT_NS) {
			p->pending_since = 0;      /* not a Wine process (or never got that far) */
			cnt.follow_failed++;
		}
		return;
	}
	proc_identify(p);
	n = attach_proc(p);
	p->pending_since = 0;
	if (n) {
		cnt.follow_attached++;
		proc_scan_maps(p, true);
		scan_threads(pid);
		logmsg("followed child pid %u (%s): %d probes", pid, p->image, n);
	} else {
		cnt.follow_failed++;
	}
}

static void follow_pending(__u64 now)
{
	size_t i;

	for (i = 0; i < procs.cap; i++) {
		struct proc *p;

		if (!procs.used[i])
			continue;
		p = (struct proc *)(uintptr_t)procs.vals[i];
		if (p->pending_since)
			follow_child(p->pid, now);
	}
}

static void read_stats(__u64 *out)
{
	int ncpu = libbpf_num_possible_cpus(), fd = bpf_map__fd(skel->maps.stats), c;
	__u64 *vals = xcalloc((size_t)ncpu, sizeof(__u64));
	__u32 k;

	for (k = 0; k < ST__COUNT; k++) {
		out[k] = 0;
		if (bpf_map_lookup_elem(fd, &k, vals) == 0)
			for (c = 0; c < ncpu; c++)
				out[k] += vals[c];
	}
	free(vals);
}

/* ======================================================================
 * summary.json, tracer.json
 * ==================================================================== */
static __u64 pct_u64(const __u64 *v, size_t n, double pct)
{
	long rank;

	rank = (long)ceil(pct / 100.0 * (double)n) - 1;
	if (rank < 0)
		rank = 0;
	if (rank > (long)n - 1)
		rank = (long)n - 1;
	return v[rank];
}

static __s64 pct_s64(const __s64 *v, size_t n, double pct)
{
	long rank;

	rank = (long)ceil(pct / 100.0 * (double)n) - 1;
	if (rank < 0)
		rank = 0;
	if (rank > (long)n - 1)
		rank = (long)n - 1;
	return v[rank];
}

static int cmp_site(const void *a, const void *b)
{
	const struct site *x = *(const struct site *const *)a, *y = *(const struct site *const *)b;

	if (x->total_in_late != y->total_in_late)
		return x->total_in_late > y->total_in_late ? -1 : 1;
	if (x->n_in_late != y->n_in_late)
		return x->n_in_late > y->n_in_late ? -1 : 1;
	if (x->total_all != y->total_all)
		return x->total_all > y->total_all ? -1 : 1;
	return strcmp(x->key, y->key);
}

static int cmp_hot(const void *a, const void *b)
{
	const struct hotspot *x = *(const struct hotspot *const *)a, *y = *(const struct hotspot *const *)b;

	if (x->total != y->total)
		return x->total > y->total ? -1 : 1;
	return strcmp(x->key, y->key);
}

struct overhead {
	__u64 bpf_run_ns, bpf_run_cnt, usdt_hits;
	double bpf_ns_per_hit, hits_per_block;
	__u64 estimate_ns_per_block;
	double loader_user_s, loader_sys_s, loader_cpu_pct, wall_s;
	long maxrss_kb;
	bool stats_ok;
};

static __u64 stats[ST__COUNT];
static struct overhead ov;

static void collect_overhead(void)
{
	struct bpf_program *prog;
	struct rusage ru;
	int k;

	ov.stats_ok = stats_fd >= 0;
	bpf_object__for_each_program(prog, skel->obj) {
		struct bpf_prog_info info = { 0 };
		__u32 len = sizeof(info);
		int fd = bpf_program__fd(prog);

		if (fd < 0 || bpf_prog_get_info_by_fd(fd, &info, &len))
			continue;
		ov.bpf_run_ns += info.run_time_ns;
		ov.bpf_run_cnt += info.run_cnt;
	}
	for (k = ST_HIT_SYSCALL_ENTRY; k <= ST_HIT_CYCLE_END; k++)
		ov.usdt_hits += stats[k];
	ov.bpf_ns_per_hit = ov.bpf_run_cnt ? (double)ov.bpf_run_ns / (double)ov.bpf_run_cnt : 0.0;
	ov.hits_per_block = bstat.count ? (double)(ov.usdt_hits + stats[ST_HIT_NTSYNC_WAIT] + stats[ST_HIT_NTSYNC_WAKE]) /
						  (double)bstat.count : 0.0;
	ov.estimate_ns_per_block = (__u64)llround(ov.hits_per_block * (ov.bpf_ns_per_hit + (double)opt.trap_ns));
	getrusage(RUSAGE_SELF, &ru);
	ov.loader_user_s = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6;
	ov.loader_sys_s = (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6;
	ov.wall_s = (double)(stop_ns - base_ns) / 1e9;
	ov.loader_cpu_pct = ov.wall_s > 0 ? 100.0 * (ov.loader_user_s + ov.loader_sys_s) / ov.wall_s : 0.0;
	ov.maxrss_kb = ru.ru_maxrss;
}

static __u64 lost_events(void)
{
	return stats[ST_RINGBUF_DROP] + stats[ST_AGG_FULL] + stats[ST_INFLIGHT_OVERFLOW];
}

static void write_programs(FILE *f)
{
	struct bpf_program *prog;
	bool first = true;

	fputc('[', f);
	bpf_object__for_each_program(prog, skel->obj) {
		struct bpf_prog_info info = { 0 };
		__u32 len = sizeof(info);
		int fd = bpf_program__fd(prog);

		if (!bpf_program__autoload(prog) || fd < 0 || bpf_prog_get_info_by_fd(fd, &info, &len))
			continue;
		fprintf(f, "%s{\"name\":\"%s\",\"section\":", first ? "" : ",", bpf_program__name(prog));
		jstr(f, bpf_program__section_name(prog));
		fprintf(f, ",\"verified_insns\":%u,\"xlated_bytes\":%u,\"jited_bytes\":%u,\"run_cnt\":%llu,"
			   "\"run_time_ns\":%llu,\"ns_per_run\":%.1f}",
			info.verified_insns, info.xlated_prog_len, info.jited_prog_len, (unsigned long long)info.run_cnt,
			(unsigned long long)info.run_time_ns,
			info.run_cnt ? (double)info.run_time_ns / (double)info.run_cnt : 0.0);
		first = false;
	}
	fputc(']', f);
}

static void write_probe_hits(FILE *f)
{
	int k;

	fputc('{', f);
	for (k = ST_HIT_SYSCALL_ENTRY; k <= ST_HIT_PERF_SAMPLE; k++)
		fprintf(f, "%s\"%s\":%llu", k ? "," : "", stat_names[k], (unsigned long long)stats[k]);
	fputc('}', f);
}

static void write_counters_all(FILE *f)
{
	int k;
	size_t i;

	fputc('{', f);
	for (k = ST_FIRST_COUNTER; k < ST__COUNT; k++)
		fprintf(f, "%s\"%s\":%llu", k == ST_FIRST_COUNTER ? "" : ",", stat_names[k], (unsigned long long)stats[k]);
	fprintf(f, ",\"keys_drained\":%llu,\"drains\":%llu,\"keys_for_flushed_block\":%llu,"
		   "\"keys_for_unknown_block\":%llu,\"stacks_kept\":%llu,\"stacks_dropped\":%llu,\"events\":%llu,"
		   "\"blocks_written\":%llu,\"windows_written\":%llu,\"incomplete_blocks\":%llu,\"invalid_blocks\":%llu,"
		   "\"forks\":%llu,\"follow_attached\":%llu,\"follow_failed\":%llu,\"offcpu_records\":%llu,"
		   "\"wake_records\":%llu,\"open_entries_at_end\":%llu,\"short_records\":%llu,\"ringbuf_records\":{",
		(unsigned long long)cnt.keys_drained, (unsigned long long)cnt.drains,
		(unsigned long long)cnt.keys_for_flushed_block, (unsigned long long)cnt.keys_for_unknown_block,
		(unsigned long long)cnt.stacks_kept, (unsigned long long)cnt.stacks_dropped,
		(unsigned long long)cnt.events_written, (unsigned long long)cnt.blocks_written,
		(unsigned long long)cnt.windows_written, (unsigned long long)bstat.incomplete,
		(unsigned long long)cnt.invalid_blocks, (unsigned long long)cnt.forks,
		(unsigned long long)cnt.follow_attached, (unsigned long long)cnt.follow_failed,
		(unsigned long long)cnt.offcpu_records, (unsigned long long)cnt.wake_records,
		(unsigned long long)cnt.open_entries_at_end, (unsigned long long)cnt.rb_short);
	{
		static const char *const rn[] = { "", "stack", "block", "wake", "offcpu", "name", "event", "unixlib",
						  "fork", "thread", "exit" };
		bool first = true;

		for (i = 1; i < sizeof(rn) / sizeof(rn[0]); i++) {
			fprintf(f, "%s\"%s\":%llu", first ? "" : ",", rn[i], (unsigned long long)cnt.rb_records[i]);
			first = false;
		}
	}
	fputs("}}", f);
}

static void write_attach(FILE *f)
{
	int i;

	fputc('[', f);
	for (i = 0; i < nattach_desc; i++) {
		if (i)
			fputc(',', f);
		jstr(f, attach_desc[i]);
	}
	fputc(']', f);
}

static void write_overhead(FILE *f)
{
	fprintf(f, "{\"usdt_hits\":%llu,\"bpf_stats_enabled\":%s,\"bpf_run_cnt\":%llu,\"bpf_run_time_ns\":%llu,"
		   "\"bpf_ns_per_run\":%.1f,\"hits_per_block\":%.2f,\"assumed_trap_ns_per_hit\":%u,"
		   "\"estimate_ns_per_block\":%llu,\"loader_user_s\":%.3f,\"loader_sys_s\":%.3f,\"loader_wall_s\":%.3f,"
		   "\"loader_cpu_pct\":%.3f,\"loader_maxrss_kb\":%ld,\"note\":\"bpf_* are measured "
		   "(kernel.bpf_stats_enabled via BPF_ENABLE_STATS while tracing); the uprobe trap itself is not "
		   "measured: estimate_ns_per_block = hits_per_block x (bpf_ns_per_run + assumed_trap_ns_per_hit)\"}",
		(unsigned long long)ov.usdt_hits, ov.stats_ok ? "true" : "false", (unsigned long long)ov.bpf_run_cnt,
		(unsigned long long)ov.bpf_run_ns, ov.bpf_ns_per_hit, ov.hits_per_block, opt.trap_ns,
		(unsigned long long)ov.estimate_ns_per_block, ov.loader_user_s, ov.loader_sys_s, ov.wall_s,
		ov.loader_cpu_pct, ov.maxrss_kb);
}

static void write_summary(void)
{
	char path[PATH_MAX + 32], tmp[PATH_MAX + 48];
	struct site **sl = NULL;
	struct hotspot **hl = NULL;
	size_t nsl = 0, capsl = 0, nhl = 0, caphl = 0, i;
	__u64 mode_period = 0, mode_count = 0, span = bstat.last_t1 > bstat.first_t0 ? bstat.last_t1 - bstat.first_t0 : 0;
	double minutes = (double)span / 60e9;
	FILE *f;
	int k;
	bool first;

	snprintf(path, sizeof(path), "%s/summary.json", opt.out);
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	f = fopen(tmp, "w");
	if (!f) {
		warn_add("cannot write %s: %s", tmp, strerror(errno));
		return;
	}
	for (i = 0; i < bstat.periods.cap; i++)
		if (bstat.periods.used[i] && bstat.periods.vals[i] > mode_count) {
			mode_count = bstat.periods.vals[i];
			mode_period = bstat.periods.keys[i];
		}
	for (i = 0; i < sites.cap; i++) {
		struct site *s;

		if (!sites.used[i])
			continue;
		for (s = (struct site *)(uintptr_t)sites.vals[i]; s; s = s->next) {
			grow((void **)&sl, &capsl, nsl + 1, sizeof(*sl));
			sl[nsl++] = s;
		}
	}
	qsort(sl, nsl, sizeof(*sl), cmp_site);
	for (i = 0; i < hotspots.cap; i++) {
		struct hotspot *s;

		if (!hotspots.used[i])
			continue;
		for (s = (struct hotspot *)(uintptr_t)hotspots.vals[i]; s; s = s->next) {
			grow((void **)&hl, &caphl, nhl + 1, sizeof(*hl));
			hl[nhl++] = s;
		}
	}
	qsort(hl, nhl, sizeof(*hl), cmp_hot);
	if (bstat.nslack)
		qsort(bstat.slack, bstat.nslack, sizeof(*bstat.slack), cmp_s64);
	if (bstat.nel)
		qsort(bstat.elapsed, bstat.nel, sizeof(*bstat.elapsed), cmp_u64);

	fprintf(f, "{\n \"schema\": \"%s\",\n \"tracer\": {\"version\": \"wine-trace/" WINE_TRACE_VERSION "\", "
		   "\"backend\": \"libbpf\", \"mode\": \"%s\", \"sample_rate\": 1, \"attach\": ",
		SUMMARY_SCHEMA, mode_name());
	write_attach(f);
	fprintf(f, ", \"lost_events\": %llu, \"started_monotonic_ns\": %llu, \"stopped_monotonic_ns\": %llu, "
		   "\"overhead_estimate_ns_per_block\": %llu, \"overhead\": ",
		(unsigned long long)lost_events(), (unsigned long long)base_ns, (unsigned long long)stop_ns,
		(unsigned long long)ov.estimate_ns_per_block);
	write_overhead(f);
	fputs(", \"programs\": ", f);
	write_programs(f);
	fprintf(f, "},\n \"thresholds\": {\"near_late_fraction\": %g, \"deadline_ns_mode\": %llu, "
		   "\"near_late_slack_ns\": %lld, \"near_late_basis\": \"each block's own period_ns\"},\n",
		opt.near_late, (unsigned long long)mode_period, (long long)llround(opt.near_late * (double)mode_period));
	fprintf(f, " \"blocks\": {\"count\": %llu, \"late\": %llu, \"near_late\": %llu, \"late_per_minute\": %.3f, "
		   "\"blocks_per_minute\": %.1f, \"slack_ns\": {\"min\": ",
		(unsigned long long)bstat.count, (unsigned long long)bstat.late, (unsigned long long)bstat.near_late,
		minutes > 0 ? (double)bstat.late / minutes : 0.0, minutes > 0 ? (double)bstat.count / minutes : 0.0);
	jnum_or_null(f, bstat.nslack, bstat.nslack ? bstat.slack[0] : 0);
	fputs(", \"p01\": ", f);
	jnum_or_null(f, bstat.nslack, bstat.nslack ? pct_s64(bstat.slack, bstat.nslack, 1) : 0);
	fputs(", \"p50\": ", f);
	jnum_or_null(f, bstat.nslack, bstat.nslack ? pct_s64(bstat.slack, bstat.nslack, 50) : 0);
	fputs(", \"p99\": ", f);
	jnum_or_null(f, bstat.nslack, bstat.nslack ? pct_s64(bstat.slack, bstat.nslack, 99) : 0);
	fputs("}, \"elapsed_ns\": {\"p50\": ", f);
	jnum_or_null(f, bstat.nel, bstat.nel ? (long long)pct_u64(bstat.elapsed, bstat.nel, 50) : 0);
	fputs(", \"p99\": ", f);
	jnum_or_null(f, bstat.nel, bstat.nel ? (long long)pct_u64(bstat.elapsed, bstat.nel, 99) : 0);
	fputs(", \"max\": ", f);
	jnum_or_null(f, bstat.nel, bstat.nel ? (long long)bstat.elapsed[bstat.nel - 1] : 0);
	fputs("}, \"deadline_ns\": {\"min\": ", f);
	jnum_or_null(f, bstat.period_min != 0, (long long)bstat.period_min);
	fputs(", \"max\": ", f);
	jnum_or_null(f, bstat.period_max != 0, (long long)bstat.period_max);
	fprintf(f, "}, \"missed_cycles\": %llu, \"incomplete\": %llu},\n", (unsigned long long)bstat.missed,
		(unsigned long long)bstat.incomplete);
	{
		__u64 attributed = (__u64)llround(bstat.attributed_total);

		fprintf(f, " \"lost_slack\": {\"definition\": \"sum over late and near-late blocks of (near_late_slack_ns "
			   "- slack_ns)\", \"total_ns\": %llu, \"attributed_ns\": %llu, \"unattributed_ns\": %lld},\n",
			(unsigned long long)bstat.lost_total, (unsigned long long)attributed,
			(long long)bstat.lost_total - (long long)attributed);
	}
	fputs(" \"call_sites\": [", f);
	for (i = 0; i < nsl; i++) {
		struct site *s = sl[i];
		__u64 stressed = s->late_blocks + s->near_late_blocks;
		int w;
		bool wf = true;

		fprintf(f, "%s\n  {\"rank\": %zu, \"key\": ", i ? "," : "", i + 1);
		jstr(f, s->key);
		fprintf(f, ", \"kind\": \"%s\", \"name\": ", kind_names[s->kind]);
		jstr(f, s->name);
		fprintf(f, ", \"caller\": \"*\", \"late_blocks\": %llu, \"near_late_blocks\": %llu, \"n_in_late_blocks\": %llu, "
			   "\"per_late_block\": %.3f, \"total_ns_in_late_blocks\": %llu, \"max_ns\": %llu, "
			   "\"share_of_lost_slack\": %.4f, \"n_all_blocks\": %llu, \"total_ns_all_blocks\": %llu, \"woken_by\": [",
			(unsigned long long)s->late_blocks, (unsigned long long)s->near_late_blocks,
			(unsigned long long)s->n_in_late, stressed ? (double)s->n_in_late / (double)stressed : 0.0,
			(unsigned long long)s->total_in_late, (unsigned long long)s->max_ns,
			bstat.lost_total ? s->attributed / (double)bstat.lost_total : 0.0, (unsigned long long)s->n_all,
			(unsigned long long)s->total_all);
		for (w = 0; w < 5; w++) {
			if (!s->wakers[w])
				continue;
			fprintf(f, "%s{\"tid\": %u, \"role\": ", wf ? "" : ", ", s->wakers[w]);
			jstr(f, role_of(s->wakers[w]));
			fprintf(f, ", \"count\": %llu}", (unsigned long long)s->waker_n[w]);
			wf = false;
		}
		fputs("]}", f);
	}
	fputs("\n ],\n \"kinds\": {", f);
	first = true;
	for (k = KIND_SYSCALL; k <= KIND_NTSYNC_WAKE; k++) {
		if (!kinds_n[k])
			continue;
		fprintf(f, "%s\"%s\": {\"n\": %llu, \"total_ns\": %llu}", first ? "" : ", ", kind_names[k],
			(unsigned long long)kinds_n[k], (unsigned long long)kinds_total[k]);
		first = false;
	}
	fputs("},\n \"roles\": {", f);
	{
		struct rolebins **rl = NULL;
		size_t nrl = 0, caprl = 0, a, b2;

		for (i = 0; i < rolebins.cap; i++) {
			struct rolebins *r;

			if (!rolebins.used[i])
				continue;
			for (r = (struct rolebins *)(uintptr_t)rolebins.vals[i]; r; r = r->next) {
				if (!r->nb)
					continue;
				grow((void **)&rl, &caprl, nrl + 1, sizeof(*rl));
				rl[nrl++] = r;
			}
		}
		for (a = 0; a < nrl; a++)            /* sort by role name */
			for (b2 = a + 1; b2 < nrl; b2++)
				if (strcmp(rl[b2]->role, rl[a]->role) < 0) {
					struct rolebins *t = rl[a];

					rl[a] = rl[b2];
					rl[b2] = t;
				}
		for (a = 0; a < nrl; a++) {
			struct rolebins *r = rl[a];

			qsort(r->n, r->nb, sizeof(*r->n), cmp_u64);
			qsort(r->total, r->nb, sizeof(*r->total), cmp_u64);
			fprintf(f, "%s\n  ", a ? "," : "");
			jstr(f, r->role);
			fprintf(f, ": {\"bins\": %zu, \"crossings_per_100ms\": {\"p50\": %llu, \"p99\": %llu}, "
				   "\"total_ns_per_100ms\": {\"p50\": %llu, \"p99\": %llu}}",
				r->nb, (unsigned long long)pct_u64(r->n, r->nb, 50), (unsigned long long)pct_u64(r->n, r->nb, 99),
				(unsigned long long)pct_u64(r->total, r->nb, 50),
				(unsigned long long)pct_u64(r->total, r->nb, 99));
		}
		free(rl);
	}
	fputs("\n },\n \"hotspots_non_audio\": [", f);
	for (i = 0; i < nhl && i < 20; i++) {
		fprintf(f, "%s\n  {\"role\": ", i ? "," : "");
		jstr(f, hl[i]->role);
		fprintf(f, ", \"kind\": \"%s\", \"name\": ", kind_names[hl[i]->kind]);
		jstr(f, hl[i]->name);
		fprintf(f, ", \"caller\": \"*\", \"n\": %llu, \"total_ns\": %llu}", (unsigned long long)hl[i]->n,
			(unsigned long long)hl[i]->total);
	}
	fprintf(f, "\n ],\n \"counters\": {\"unmatched_exits\": %llu, \"unmatched_exits_first_on_tid\": %llu, "
		   "\"abandoned_entries\": %llu, \"ringbuf_drops\": %llu, \"lost_events\": %llu, \"probe_hits\": ",
		(unsigned long long)stats[ST_UNMATCHED_EXIT], (unsigned long long)stats[ST_THREAD_START_EXIT],
		(unsigned long long)stats[ST_ABANDONED_ENTRY], (unsigned long long)stats[ST_RINGBUF_DROP],
		(unsigned long long)lost_events());
	write_probe_hits(f);
	fprintf(f, ", \"events\": %llu, \"all\": ", (unsigned long long)cnt.events_written);
	write_counters_all(f);
	fputs("},\n \"notes\": [\"call_sites and hotspots_non_audio are per (kind, id) with caller '*': the "
	      "production tracer aggregates in the kernel; per-caller sites come from the stack samples in "
	      "blocks.jsonl (symbolized into blocks.symbolized.jsonl, ranked by bench-report.py interface)\", "
	      "\"blocks.offcpu counts the off-CPU intervals that began inside the block (not clipped to t_end)\", "
	      "\"threads.jsonl includes the crossings inside blocks (window of the block start) as well as the "
	      "between-block buckets\"],\n \"warnings\": [", f);
	for (k = 0; k < nwarnings; k++) {
		fputs(k ? ", " : "", f);
		jstr(f, warnings[k]);
	}
	fputs("]\n}\n", f);
	free(sl);
	free(hl);
	if (fclose(f) != 0 || rename(tmp, path) != 0)
		warn_add("cannot write %s: %s", path, strerror(errno));
}

/* merge our fields into tracer.json (the wrapper owns the start fields) */
static void write_tracer_json(void)
{
	char path[PATH_MAX + 32], tmp[PATH_MAX + 48];
	char *mine_text = NULL, *old_text;
	size_t mine_len = 0, i;
	struct jv *root = NULL, *mine;
	const char *err = NULL;
	FILE *m, *f;
	struct jv *old_start;

	snprintf(path, sizeof(path), "%s/tracer.json", opt.out);
	old_text = read_file(path, NULL);
	if (old_text) {
		root = json_parse(old_text, &err);
		free(old_text);
		if (!root || root->t != J_OBJ) {
			warn_add("tracer.json was not a JSON object (%s); rewriting it", err ? err : "?");
			jv_free(root);
			root = NULL;
		}
	}
	if (!root)
		root = jv_new(J_OBJ);

	m = open_memstream(&mine_text, &mine_len);
	if (!m)
		die("open_memstream: %s", strerror(errno));
	fprintf(m, "{\"backend\":\"libbpf\",\"loader\":{\"name\":\"" LOADER_NAME "\",\"version\":\"" WINE_TRACE_VERSION
		   "\",\"abi\":%d,\"libbpf\":\"%u.%u\"},\"attach\":",
		WINE_TRACE_ABI, libbpf_major_version(), libbpf_minor_version());
	write_attach(m);
	fprintf(m, ",\"attached_monotonic_ns\":%llu,\"stopped_monotonic_ns\":%llu,\"lost_events\":%llu,"
		   "\"probe_hits\":",
		(unsigned long long)base_ns, (unsigned long long)stop_ns, (unsigned long long)lost_events());
	write_probe_hits(m);
	fputs(",\"counters\":", m);
	write_counters_all(m);
	fprintf(m, ",\"blocks\":{\"count\":%llu,\"late\":%llu,\"near_late\":%llu},"
		   "\"overhead_estimate_ns_per_block\":%llu,\"overhead\":",
		(unsigned long long)bstat.count, (unsigned long long)bstat.late, (unsigned long long)bstat.near_late,
		(unsigned long long)ov.estimate_ns_per_block);
	write_overhead(m);
	fputs(",\"programs\":", m);
	write_programs(m);
	fprintf(m, ",\"ntsync\":\"%s\",\"sched\":%s,\"follow\":%s,\"sched_waking_irq\":%s,"
		   "\"sample\":{\"stack_sample_n\":%u,\"stack_bytes\":%u,\"slack_threshold_pct\":%u,\"keep_stacks\":\"%s\","
		   "\"roles\":\"%s\",\"no_exit\":%s,\"ringbuf_mb\":%u,\"trigger_ids\":%d},"
		   "\"reduce\":{\"version\":\"" LOADER_NAME "/" WINE_TRACE_VERSION "\",\"tables\":",
		ntsync_used, sched_enabled ? "true" : "false", opt.follow ? "true" : "false",
		waking_irq ? "true" : "false", opt.sample_n, opt.stack_bytes, opt.slack_pct, keep_name(),
		opt.roles_audio ? "audio" : "all", opt.no_exit ? "true" : "false", roundup_pow2(opt.ringbuf_mb),
		opt.ntrigger);
	if (tables_basename())
		jstr(m, tables_basename());
	else
		fputs("null", m);
	fputs(",\"warnings\":[", m);
	for (i = 0; i < (size_t)nwarnings; i++) {
		fputs(i ? "," : "", m);
		jstr(m, warnings[i]);
	}
	fputs("]},\"followed_pids\":[", m);
	{
		bool first = true;

		for (i = 0; i < procs.cap; i++) {
			struct proc *p;

			if (!procs.used[i])
				continue;
			p = (struct proc *)(uintptr_t)procs.vals[i];
			if (p->initial || !p->attached)
				continue;
			fprintf(m, "%s{\"pid\":%u,\"comm\":", first ? "" : ",", p->pid);
			jstr(m, p->comm);
			fputs(",\"image\":", m);
			jstr(m, p->image);
			fputs(",\"exe\":", m);
			jstr(m, p->exe);
			fputc('}', m);
			first = false;
		}
	}
	fputs("]}", m);
	fclose(m);
	mine = json_parse(mine_text, &err);
	if (!mine)
		die("internal error: tracer.json fragment does not parse (%s): %.200s", err ? err : "?", mine_text);
	free(mine_text);

	/* started_monotonic_ns becomes the true coverage start (all probes attached); the wrapper's
	 * pre-launch value is kept as launch_monotonic_ns */
	old_start = jv_get(root, "started_monotonic_ns");
	if (old_start && old_start->t == J_NUM && (__u64)jv_int(old_start, 0) != base_ns) {
		struct jv *c = jv_new(J_NUM);

		c->s = xstrdup(old_start->s);
		jv_set(root, "launch_monotonic_ns", c);
	}
	{
		struct jv *s = jv_new(J_NUM);
		char buf[32];

		snprintf(buf, sizeof(buf), "%llu", (unsigned long long)base_ns);
		s->s = xstrdup(buf);
		jv_set(root, "started_monotonic_ns", s);
	}
	if (!jv_get(root, "mode") || jv_get(root, "mode")->t != J_STR) {
		struct jv *s = jv_new(J_STR);

		s->s = xstrdup(mode_name());
		jv_set(root, "mode", s);
	}
	if (!jv_get(root, "version")) {
		struct jv *s = jv_new(J_STR);

		s->s = xstrdup("wine-trace/1");
		jv_set(root, "version", s);
	}
	if (!jv_get(root, "sample_rate")) {
		struct jv *s = jv_new(J_NUM);

		s->s = xstrdup("1");
		jv_set(root, "sample_rate", s);
	}
	{
		struct jv *pids = jv_get(root, "pids");

		if (!pids || pids->t != J_ARR) {
			char *t = NULL;
			size_t tl = 0;
			FILE *pm = open_memstream(&t, &tl);
			bool first = true;

			fputc('[', pm);
			for (i = 0; i < procs.cap; i++) {
				struct proc *p;

				if (!procs.used[i])
					continue;
				p = (struct proc *)(uintptr_t)procs.vals[i];
				if (!p->initial)
					continue;
				fprintf(pm, "%s{\"pid\":%u,\"comm\":", first ? "" : ",", p->pid);
				jstr(pm, p->comm);
				fputs(",\"image\":", pm);
				jstr(pm, p->image);
				fputs(",\"exe\":", pm);
				jstr(pm, p->exe);
				fputc('}', pm);
				first = false;
			}
			fputc(']', pm);
			fclose(pm);
			jv_set(root, "pids", json_parse(t, NULL));
			free(t);
		}
	}
	if (!jv_get(root, "wine_version") || jv_get(root, "wine_version")->t == J_NULL) {
		struct jv *s = jv_new(wine_version[0] ? J_STR : J_NULL);

		if (wine_version[0])
			s->s = xstrdup(wine_version);
		jv_set(root, "wine_version", s);
	}
	if (opt.run_id && !jv_get(root, "run_id")) {
		struct jv *s = jv_new(J_STR);

		s->s = xstrdup(opt.run_id);
		jv_set(root, "run_id", s);
	}
	for (i = 0; i < mine->n; i++) {
		jv_set(root, mine->keys[i], mine->items[i]);
		mine->items[i] = NULL;
	}
	for (i = 0; i < mine->n; i++)
		free(mine->keys[i]);
	free(mine->keys);
	free(mine->items);
	mine->n = 0;
	mine->keys = NULL;
	mine->items = NULL;
	jv_free(mine);

	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	f = fopen(tmp, "w");
	if (!f) {
		warn_add("cannot write %s: %s", tmp, strerror(errno));
		jv_free(root);
		return;
	}
	json_write(f, root, 0);
	fputc('\n', f);
	if (fclose(f) != 0 || rename(tmp, path) != 0)
		warn_add("cannot write %s: %s", path, strerror(errno));
	jv_free(root);
}

static void snapshot_stop_maps(void)
{
	size_t i;

	for (i = 0; i < procs.cap; i++) {
		struct proc *p;
		char src[64], dst[PATH_MAX], *text;
		FILE *f;

		if (!procs.used[i])
			continue;
		p = (struct proc *)(uintptr_t)procs.vals[i];
		if (!p->attached && !p->initial)
			continue;
		snprintf(src, sizeof(src), "/proc/%u/maps", p->pid);
		text = read_file(src, NULL);
		if (!text)
			continue;
		snprintf(dst, sizeof(dst), "%s/maps-%u-stop.txt", opt.out, p->pid);
		f = fopen(dst, "w");
		if (f) {
			fputs(text, f);
			fclose(f);
		}
		free(text);
	}
}

static void chown_outputs(void)
{
	const char *u = getenv("SUDO_UID"), *g = getenv("SUDO_GID");
	uid_t uid;
	gid_t gid;
	DIR *d;
	struct dirent *de;

	if (!u || !*u)
		return;
	uid = (uid_t)strtoul(u, NULL, 10);
	gid = (gid_t)strtoul(g && *g ? g : u, NULL, 10);
	if (chown(opt.out, uid, gid) != 0)
		return;
	d = opendir(opt.out);
	if (!d)
		return;
	while ((de = readdir(d))) {
		char p[PATH_MAX];

		if (de->d_name[0] == '.' && (de->d_name[1] == '\0' || (de->d_name[1] == '.' && de->d_name[2] == '\0')))
			continue;
		snprintf(p, sizeof(p), "%s/%s", opt.out, de->d_name);
		if (lchown(p, uid, gid) != 0 && opt.verbose)
			logmsg("chown %s: %s", p, strerror(errno));
	}
	closedir(d);
}

/* ======================================================================
 * main
 * ==================================================================== */
static void on_signal(int sig)
{
	(void)sig;
	stop_flag = 1;
}

static void usage(int code)
{
	fprintf(code ? stderr : stdout,
		"usage: wine-trace --out DIR --pid PID [--pid PID]... [options]\n"
		"\n"
		"  --mode summary|drilldown|sample   (default summary)\n"
		"  --ntsync auto|fentry|kprobe|tracepoint|off   (default auto: fentry, then kprobe, tracepoint)\n"
		"  --sched on|off           scheduler probes (default: on in drilldown, off otherwise)\n"
		"  --run-id TOKEN           recorded in tracer.json\n"
		"  --sample 1/N             stack sample every N-th syscall/unix-call entry (default 1/64, drilldown 1/4;\n"
		"                           1/0 disables)\n"
		"  --stack-bytes N          stack window per sample, %d..%d (default %d)\n"
		"  --keep-stacks none|late|all   which samples reach the output (default late; drilldown all)\n"
		"  --roles audio|all        audio: USDT crossings of audio-role threads only (default all)\n"
		"  --no-exit                count at entry; exit probes not attached (no durations)\n"
		"  --slack-threshold PCT    also sample when the block is within PCT%% of its deadline (default %d)\n"
		"  --near-late-fraction F   near-late threshold as a fraction of the period (default %.2f)\n"
		"  --ringbuf-mb N           ring buffer size (default %d, rounded up to a power of two)\n"
		"  --duration S             stop after S seconds (default: until SIGINT/SIGTERM)\n"
		"  --trigger-ids ID,...     always sample these syscall ids (hex or decimal)\n"
		"  --tables FILE            id table (default ../tables/wine-<ver>.json next to the binary)\n"
		"  --ntdll PATH, --pipeasio PATH   library paths (default: from /proc/PID/maps)\n"
		"  --no-follow              do not attach to children forked by traced processes\n"
		"  --trap-ns N              assumed uprobe trap cost for the overhead estimate (default %u)\n"
		"  --perf-hz N              --mode sample frequency (default 999)\n"
		"  --unsafe-private-stack   attach although the USDT programs exceed 64 bytes of BPF stack (BUILD.md)\n"
		"  -v, --verbose (twice: libbpf debug)   -q, --quiet   --version   -h, --help\n",
		STACK_BYTES_MIN, STACK_BYTES_MAX, STACK_BYTES_DEFAULT, SLACK_THRESH_PCT_DEFAULT, DEFAULT_NEAR_LATE,
		RINGBUF_MB_DEFAULT, DEFAULT_TRAP_NS);
	exit(code);
}

static unsigned long parse_ulong(const char *s, const char *what, unsigned long max)
{
	char *end;
	unsigned long v;

	errno = 0;
	v = strtoul(s, &end, 0);
	if (errno || end == s || *end || v > max) {
		fprintf(stderr, "wine-trace: bad %s '%s'\n", what, s);
		exit(2);
	}
	return v;
}

static void parse_args(int argc, char **argv)
{
	enum { OPT_MODE = 256, OPT_NTSYNC, OPT_SCHED, OPT_RUNID, OPT_SAMPLE, OPT_STACKB, OPT_ROLES, OPT_NOEXIT, OPT_SLACK, OPT_RBMB,
	       OPT_DUR, OPT_TRIG, OPT_TABLES, OPT_NTDLL, OPT_PIPE, OPT_NOFOLLOW, OPT_NEAR, OPT_KEEP, OPT_TRAP, OPT_PERFHZ, OPT_VERSION, OPT_PRIVSTACK };
	static const struct option lo[] = {
		{ "out", required_argument, NULL, 'o' }, { "pid", required_argument, NULL, 'p' },
		{ "mode", required_argument, NULL, OPT_MODE }, { "ntsync", required_argument, NULL, OPT_NTSYNC },
		{ "sched", required_argument, NULL, OPT_SCHED }, { "run-id", required_argument, NULL, OPT_RUNID },
		{ "sample", required_argument, NULL, OPT_SAMPLE }, { "stack-bytes", required_argument, NULL, OPT_STACKB },
		{ "roles", required_argument, NULL, OPT_ROLES }, { "no-exit", no_argument, NULL, OPT_NOEXIT },
		{ "slack-threshold", required_argument, NULL, OPT_SLACK }, { "ringbuf-mb", required_argument, NULL, OPT_RBMB },
		{ "duration", required_argument, NULL, OPT_DUR }, { "trigger-ids", required_argument, NULL, OPT_TRIG },
		{ "tables", required_argument, NULL, OPT_TABLES }, { "ntdll", required_argument, NULL, OPT_NTDLL },
		{ "pipeasio", required_argument, NULL, OPT_PIPE }, { "no-follow", no_argument, NULL, OPT_NOFOLLOW },
		{ "near-late-fraction", required_argument, NULL, OPT_NEAR }, { "keep-stacks", required_argument, NULL, OPT_KEEP },
		{ "trap-ns", required_argument, NULL, OPT_TRAP }, { "perf-hz", required_argument, NULL, OPT_PERFHZ },
		{ "verbose", no_argument, NULL, 'v' }, { "quiet", no_argument, NULL, 'q' },
		{ "unsafe-private-stack", no_argument, NULL, OPT_PRIVSTACK },
		{ "version", no_argument, NULL, OPT_VERSION }, { "help", no_argument, NULL, 'h' }, { NULL, 0, NULL, 0 },
	};
	int c;

	while ((c = getopt_long(argc, argv, "o:p:vqh", lo, NULL)) != -1) {
		switch (c) {
		case 'o': opt.out = optarg; break;
		case 'p':
			if (opt.npids >= MAX_PIDS) {
				fprintf(stderr, "wine-trace: at most %d --pid\n", MAX_PIDS);
				exit(2);
			}
			opt.pids[opt.npids++] = (__u32)parse_ulong(optarg, "--pid", 0x7fffffff);
			break;
		case OPT_MODE:
			if (strcmp(optarg, "summary") == 0) opt.mode = MODE_SUMMARY;
			else if (strcmp(optarg, "drilldown") == 0) opt.mode = MODE_DRILLDOWN;
			else if (strcmp(optarg, "sample") == 0) opt.mode = MODE_SAMPLE;
			else { fprintf(stderr, "wine-trace: --mode summary|drilldown|sample\n"); exit(2); }
			break;
		case OPT_NTSYNC:
			if (strcmp(optarg, "auto") && strcmp(optarg, "fentry") && strcmp(optarg, "kprobe") &&
			    strcmp(optarg, "tracepoint") && strcmp(optarg, "off")) {
				fprintf(stderr, "wine-trace: --ntsync auto|fentry|kprobe|tracepoint|off\n");
				exit(2);
			}
			scopy(opt.ntsync, sizeof(opt.ntsync), optarg);
			break;
		case OPT_SCHED:
			if (strcmp(optarg, "on") == 0) opt.sched = 1;
			else if (strcmp(optarg, "off") == 0) opt.sched = 0;
			else { fprintf(stderr, "wine-trace: --sched on|off\n"); exit(2); }
			break;
		case OPT_RUNID: opt.run_id = optarg; break;
		case OPT_SAMPLE: {
			const char *s = strncmp(optarg, "1/", 2) == 0 ? optarg + 2 : optarg;

			opt.sample_n = (__u32)parse_ulong(s, "--sample", 1u << 30);
			opt.sample_set = 1;
			break;
		}
		case OPT_STACKB:
			opt.stack_bytes = (__u32)parse_ulong(optarg, "--stack-bytes", STACK_BYTES_MAX);
			if (opt.stack_bytes < STACK_BYTES_MIN) {
				fprintf(stderr, "wine-trace: --stack-bytes %d..%d\n", STACK_BYTES_MIN, STACK_BYTES_MAX);
				exit(2);
			}
			break;
		case OPT_ROLES:
			if (strcmp(optarg, "audio") == 0) opt.roles_audio = 1;
			else if (strcmp(optarg, "all") == 0) opt.roles_audio = 0;
			else { fprintf(stderr, "wine-trace: --roles audio|all\n"); exit(2); }
			break;
		case OPT_NOEXIT: opt.no_exit = 1; break;
		case OPT_SLACK: opt.slack_pct = (__u32)parse_ulong(optarg, "--slack-threshold", 100); break;
		case OPT_RBMB: opt.ringbuf_mb = (__u32)parse_ulong(optarg, "--ringbuf-mb", 1024); if (!opt.ringbuf_mb) opt.ringbuf_mb = 1; break;
		case OPT_DUR: {
			char *end;

			opt.duration = strtod(optarg, &end);
			if (end == optarg || *end || opt.duration < 0) {
				fprintf(stderr, "wine-trace: bad --duration '%s'\n", optarg);
				exit(2);
			}
			break;
		}
		case OPT_TRIG: {
			char *copy = xstrdup(optarg), *tok, *save = NULL;

			for (tok = strtok_r(copy, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
				if (opt.ntrigger >= MAX_TRIGGER_IDS) {
					fprintf(stderr, "wine-trace: at most %d --trigger-ids\n", MAX_TRIGGER_IDS);
					exit(2);
				}
				opt.trigger_ids[opt.ntrigger++] = (__u32)parse_ulong(tok, "--trigger-ids", 0xffffffffu);
			}
			free(copy);
			break;
		}
		case OPT_TABLES: opt.tables = optarg; break;
		case OPT_NTDLL: opt.ntdll = optarg; break;
		case OPT_PIPE: opt.pipeasio = optarg; break;
		case OPT_NOFOLLOW: opt.follow = 0; break;
		case OPT_NEAR: {
			char *end;

			opt.near_late = strtod(optarg, &end);
			if (end == optarg || *end || opt.near_late < 0 || opt.near_late > 1) {
				fprintf(stderr, "wine-trace: --near-late-fraction 0..1\n");
				exit(2);
			}
			break;
		}
		case OPT_KEEP:
			if (strcmp(optarg, "none") == 0) opt.keep_stacks = KEEP_NONE;
			else if (strcmp(optarg, "late") == 0) opt.keep_stacks = KEEP_LATE;
			else if (strcmp(optarg, "all") == 0) opt.keep_stacks = KEEP_ALL;
			else { fprintf(stderr, "wine-trace: --keep-stacks none|late|all\n"); exit(2); }
			break;
		case OPT_TRAP: opt.trap_ns = (__u32)parse_ulong(optarg, "--trap-ns", 1000000); break;
		case OPT_PERFHZ: opt.perf_hz = (int)parse_ulong(optarg, "--perf-hz", 100000); if (!opt.perf_hz) opt.perf_hz = 1; break;
		case OPT_PRIVSTACK: opt.allow_priv_stack = 1; break;
		case 'v': opt.verbose++; break;
		case 'q': opt.quiet = 1; break;
		case OPT_VERSION:
			printf("wine-trace %s (" LOADER_NAME ", libbpf %u.%u, abi %d)\n", WINE_TRACE_VERSION,
			       libbpf_major_version(), libbpf_minor_version(), WINE_TRACE_ABI);
			exit(0);
		case 'h': usage(0); break;
		default: usage(2);
		}
	}
	if (optind < argc) {
		fprintf(stderr, "wine-trace: unexpected argument '%s'\n", argv[optind]);
		usage(2);
	}
	if (!opt.out) {
		fprintf(stderr, "wine-trace: --out DIR is required\n");
		usage(2);
	}
	if (!opt.npids) {
		fprintf(stderr, "wine-trace: at least one --pid is required (profiler/bin/wine-trace discovers them)\n");
		usage(2);
	}
	if (opt.sched < 0)
		opt.sched = opt.mode == MODE_DRILLDOWN ? 1 : 0;
	if (!opt.sample_set)
		opt.sample_n = opt.mode == MODE_DRILLDOWN ? SAMPLE_N_DRILLDOWN : SAMPLE_N_SUMMARY;
	if (opt.keep_stacks < 0)
		opt.keep_stacks = opt.mode == MODE_SUMMARY ? KEEP_LATE : KEEP_ALL;
}

static void setup_exe_dir(const char *argv0)
{
	char self[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
	char *s;

	if (n <= 0) {
		scopy(self, sizeof(self), argv0);
	} else {
		self[n] = '\0';
	}
	s = strrchr(self, '/');
	if (s)
		*s = '\0';
	else
		snprintf(self, sizeof(self), ".");
	scopy(exe_dir, sizeof(exe_dir), self);
}

int main(int argc, char **argv)
{
	struct cfg c = { 0 };
	__u32 zero = 0;
	struct ring_buffer *rb;
	struct sigaction sa;
	__u64 now, deadline = 0, last_progress, last_flush = 0;
	int i, total = 0, err;
	struct stat st;

	parse_args(argc, argv);
	setup_exe_dir(argv[0]);
	if (geteuid() != 0)
		die("needs root (uprobe/fentry attach): run through sudo -n or profiler/bin/wine-trace");
	/* B5 live test (kernel 7.2.9-cachyos): the verifier gives BPF_PROG_TYPE_KPROBE programs whose
	 * stack is >= 64 bytes a per-CPU private stack, but uprobe programs are preemptible, so two
	 * runs on one CPU share that stack.  It oopsed inside wine_syscall_exit (a timestamp loaded
	 * as a pointer through r9 = the private stack), killed Live's pipeasio-rt thread and left
	 * uprobe unregistration stuck in synchronize_srcu.  Every USDT program here uses 184-304
	 * bytes of stack, so refuse to attach until they are below 64 bytes. */
	if (!opt.allow_priv_stack)
		die("disabled: the USDT programs use >= 64 bytes of BPF stack, which this kernel runs on a "
		    "per-CPU private stack that preemptible uprobe programs corrupt (oops in the B5 live test; "
		    "see profiler/tracer/BUILD.md).  --unsafe-private-stack overrides, never against Live");
	if (mkdir(opt.out, 0755) != 0 && errno != EEXIST)
		die("cannot create %s: %s", opt.out, strerror(errno));
	if (stat(opt.out, &st) != 0 || !S_ISDIR(st.st_mode))
		die("%s is not a directory", opt.out);
	libbpf_set_print(libbpf_print);

	/* processes and libraries */
	for (i = 0; i < opt.npids; i++) {
		struct proc *p = proc_get(opt.pids[i], true);

		p->initial = true;
		if (!proc_scan_maps(p, true)) {
			warn_add("pid %u is gone; skipped", p->pid);
			p->gone = true;
			continue;
		}
		proc_identify(p);
		if (!wine_root[0] && p->ntdll[0]) {
			const char *suffix = "/lib/wine/x86_64-unix/ntdll.so";
			char real[PATH_MAX];

			if (realpath(p->ntdll, real) && ends_with(real, suffix)) {
				real[strlen(real) - strlen(suffix)] = '\0';
				scopy(wine_root, sizeof(wine_root), real);
			}
		}
	}
	detect_wine_version();
	load_tables();

	/* BPF */
	open_and_load();
	sched_enabled = opt.sched == 1;
	stats_fd = bpf_enable_stats(BPF_STATS_RUN_TIME);
	if (stats_fd < 0)
		warn_add("BPF_ENABLE_STATS failed (%s): no measured BPF run time", strerror(errno));
	c.mode = (__u32)opt.mode;
	c.sample_n = opt.sample_n;
	c.stack_bytes = opt.stack_bytes;
	c.roles = opt.roles_audio ? ROLES_AUDIO : ROLES_ALL;
	c.slack_thresh_pct = opt.slack_pct;
	c.no_exit = (__u32)opt.no_exit;
	c.trigger_count = (__u32)opt.ntrigger;
	c.offcpu_min_ns = (__u32)OFFCPU_MIN_NS_DEFAULT;
	if (opt.mode == MODE_SAMPLE)
		c.sample_n = 0;
	err = bpf_map_update_elem(bpf_map__fd(skel->maps.cfg), &zero, &c, BPF_ANY);
	if (err)
		die("cannot write cfg: %s", strerror(errno));
	for (i = 0; i < opt.ntrigger; i++) {
		__u8 one = 1;

		bpf_map_update_elem(bpf_map__fd(skel->maps.trigger_ids), &opt.trigger_ids[i], &one, BPF_ANY);
	}
	for (i = 0; i < opt.npids; i++) {
		__u8 one = 1;
		struct proc *p = proc_get(opt.pids[i], false);

		if (p->gone)
			continue;
		bpf_map_update_elem(bpf_map__fd(skel->maps.pids), &p->pid, &one, BPF_ANY);
		scan_threads(p->pid);
	}

	/* output files are open before the first record can arrive */
	drain_keys = xcalloc(DRAIN_BATCH, sizeof(*drain_keys));
	drain_vals = xcalloc(DRAIN_BATCH, sizeof(*drain_vals));
	rb = ring_buffer__new(bpf_map__fd(skel->maps.rb), handle_rec, NULL, NULL);
	if (!rb)
		die("cannot create the ring buffer consumer: %s", strerror(errno));

	/* attach: kernel programs first (fork follow must see children of the attach window) */
	attach_kernel();
	if (opt.mode == MODE_SAMPLE)
		attach_perf();
	for (i = 0; i < opt.npids && opt.mode != MODE_SAMPLE; i++) {
		struct proc *p = proc_get(opt.pids[i], false);
		int n;

		if (p->gone)
			continue;
		n = attach_proc(p);
		total += n;
		if (opt.verbose || n)
			logmsg("pid %u (%s): %d USDT probes%s", p->pid, p->image, n,
			       p->pipeasio[0] ? " (with pipeasio)" : "");
	}
	if (!total && opt.mode != MODE_SAMPLE)
		die("no USDT probe could be attached (runtime without patch 0108, or no Wine process among the pids)");
	base_ns = mono_ns();
	if (opt.mode != MODE_SAMPLE) {
		f_blocks = open_out("blocks.jsonl", p_blocks);
		f_threads = open_out("threads.jsonl", p_threads);
		write_header(f_blocks, "blocks");
		write_header(f_threads, "threads");
		if (opt.mode == MODE_DRILLDOWN) {
			f_events = open_out("events.jsonl", p_events);
			write_header(f_events, "events");
		}
	}
	if (opt.keep_stacks != KEEP_NONE || opt.mode == MODE_SAMPLE) {
		f_stacks = open_out("stacks.jsonl", p_stacks);
		write_header(f_stacks, "stacks");
	}
	logmsg("attached %d USDT probes + %d kernel links (ntsync=%s sched=%s mode=%s) monotonic_start_ns=%llu",
	       total, nlinks - total, ntsync_used, sched_enabled ? "on" : "off", mode_name(),
	       (unsigned long long)base_ns);
	printf("attached monotonic_start_ns=%llu probes=%d links=%d\n", (unsigned long long)base_ns, total, nlinks);
	fflush(stdout);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);
	if (opt.duration > 0)
		deadline = base_ns + (__u64)(opt.duration * 1e9);
	last_progress = base_ns;

	while (!stop_flag) {
		/* records are submitted without wakeup (unless the ring is a quarter full): the poll
		 * mostly times out, and the consume collects what arrived in the meantime */
		err = ring_buffer__poll(rb, POLL_MS);
		if (err >= 0)
			err = ring_buffer__consume(rb);
		if (err < 0 && err != -EINTR) {
			warn_add("ring buffer poll failed: %s", strerror(-err));
			break;
		}
		now = mono_ns();
		drain_due(now);
		if (now - last_flush >= 100000000ULL) {
			flush_blocks(now, false);
			flush_windows(now / WINDOW_NS > WINDOW_FLUSH_W ? now / WINDOW_NS - WINDOW_FLUSH_W : 0);
			if (opt.follow)
				follow_pending(now);
			last_flush = now;
		}
		if (opt.verbose && now - last_progress >= 5000000000ULL) {
			read_stats(stats);
			logmsg("t=%.0fs blocks=%llu written=%llu keys=%llu rb_drops=%llu agg_full=%llu stacks=%llu",
			       off_s(now), (unsigned long long)stats[ST_HIT_BLOCK_START], (unsigned long long)cnt.blocks_written,
			       (unsigned long long)cnt.keys_drained, (unsigned long long)stats[ST_RINGBUF_DROP],
			       (unsigned long long)stats[ST_AGG_FULL], (unsigned long long)stats[ST_STACKS]);
			last_progress = now;
		}
		if (deadline && now >= deadline)
			break;
	}

	/* stop: detach everything, then empty the ring buffer and every agg slot */
	stop_ns = mono_ns();
	for (i = 0; i < nlinks; i++)
		bpf_link__destroy(links[i]);
	nlinks = 0;
	ring_buffer__consume(rb);
	for (i = 0; i < AGG_SLOTS; i++)
		drain_slot(i);
	{
		int fd = bpf_map__fd(skel->maps.inflight);
		__u32 key, next, *prev = NULL;
		struct inflight f;

		while (bpf_map_get_next_key(fd, prev, &next) == 0) {
			if (bpf_map_lookup_elem(fd, &next, &f) == 0)
				cnt.open_entries_at_end += f.depth;
			key = next;
			prev = &key;
		}
	}
	read_stats(stats);
	flush_blocks(UINT64_MAX, true);
	flush_windows(UINT64_MAX);
	collect_overhead();
	close_out(&f_blocks, p_blocks);
	close_out(&f_threads, p_threads);
	close_out(&f_events, p_events);
	close_out(&f_stacks, p_stacks);
	if (opt.mode != MODE_SAMPLE)
		write_summary();
	snapshot_stop_maps();
	write_tracer_json();
	chown_outputs();
	logmsg("stopped: %llu blocks (%llu late, %llu near-late), lost=%llu, unmatched=%llu, abandoned=%llu, "
	       "bpf %.0f ns/run over %llu runs, loader cpu %.2f%%",
	       (unsigned long long)bstat.count, (unsigned long long)bstat.late, (unsigned long long)bstat.near_late,
	       (unsigned long long)lost_events(), (unsigned long long)stats[ST_UNMATCHED_EXIT],
	       (unsigned long long)stats[ST_ABANDONED_ENTRY], ov.bpf_ns_per_hit, (unsigned long long)ov.bpf_run_cnt,
	       ov.loader_cpu_pct);
	ring_buffer__free(rb);
	if (stats_fd >= 0)
		close(stats_fd);
	wine_trace__destroy(skel);
	return 0;
}
