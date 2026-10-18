# Design B — trace points, tracer, caller resolution, roles, whole-app mode, validation, overhead, outputs

Companion to `wine-interface-profiler-plan.md`. Verified against the real Wine 11.13 base (`vendor/wine-base-5c23dd1c.tar.zst`), the repo, the PipeASIO tarball, the PipeWire SDK and kernel lists.

## 0. Verified facts the design rests on

- `dlls/ntdll/unix/signal_x86_64.c` (11.13): `__wine_syscall_dispatcher` entry at 2983, `ldmxcsr 0x33c(%r13)` at 3094, `__wine_syscall_dispatcher_return` label at 3128, unix-call `callq *(%r10,%rdx,8)` at 3385.
- PE thunks for ntdll **and** win32u come from `__ASM_SYSCALL_FUNC` (`dlls/ntdll/signal_x86_64.c:45-47`, `dlls/win32u/main.c:2576-2582`): `callq *(0x7ffe1000)` at +0x18, `ret` at +0x1f; the dispatcher's `subq $0xb` makes `frame->rip = NtXxx+0x14`. win32u ids are 0x1000+ (`KeAddSystemServiceTable(..., 1)` at `dlls/win32u/syscall.c:184`).
- `__wine_unix_call` is a `static inline` in `include/wine/unixlib.h:295` calling through the PE global pointer, so the unix-call return address is the PE caller itself.
- `server_call_unlocked` (`dlls/ntdll/unix/server.c:285`) is plain C; `req->u.req.request_header.req` is overwritten by the reply union after `wait_reply`, so the type must be captured before sending.
- NTSync waits go through one site, `linux_wait_objs` (`sync.c:399-450`), `ioctl(device, NTSYNC_IOC_WAIT_ANY/ALL)`.
- Wine 11.13 writes thread names to `/proc/PID/task/TID/comm` (`thread.c:2034-2069`), so `AudioCalc` and every other `SetThreadDescription` name appear in comm (15 chars).
- `RtlQueryPerformanceCounter` (`dlls/ntdll/time.c:382`) always calls `NtQueryPerformanceCounter`: QPC is a deterministic syscall for the validation probe. `ws2_32` has no unixlib in 11.13 (socket() is AFD syscalls), so unix-call validation must use a module that has one (dwrite, winscard, mmdevapi/winealsa/winepulse, opengl32, winegstreamer, winebus, mountmgr, ...).
- MSVC images with 0x200 file alignment are `pread()` into anonymous memory (`virtual.c:2383-2418`); only the header page stays file-backed (`map_pe_header`, 2730-2760) — the symbolizer must use `[base, base+SizeOfImage)` from the header mapping, not per-page backing.
- PipeASIO unix half is `lib/wine/x86_64-unix/pipeasio64.dll.so` (`pipeasio.dll.so` is a relative symlink), compiled by host gcc (`cmake/WineDLL.cmake`), so C `STAP_PROBEn` works; `spa_io_clock.next_nsec` ("logical start time of the next cycle") exists in the vendored 1.6.2 SDK.
- libbpf's USDT argument parser accepts only decimal displacement offsets (`sscanf("%d @ %ld ( %%reg )")`), so asm templates must use decimal offsets.
- Kernel: NOP5 emulation merged April 2025 and the "optimize usdt probes on x86_64" series (July 2025) replaces int3 with a `call` to a trampoline + `uprobe` syscall for 5-byte nop sites (~2x faster); the kernel selftest sdt.h defines the x86_64 nop as `0f 1f 44 00 00`.
- systemtap `sys/sdt.h` is CC0; `sdt-config.h` is two `#define`s.

---

## 1. Wine USDT patch: `patches/0108-ntdll-add-static-trace-points.patch`

**One patch, four files.** Keep `dlls/ntdll/unix/sync.c` untouched so `performance/0001` (which patches `linux_wait_objs`) keeps applying with `--3way`; NTSync observation is done kernel-side (section 3).

| File | Change |
|---|---|
| `dlls/ntdll/unix/sdt.h` (new) | Vendored `sys/sdt.h` (CC0), two edits below. Private to ntdll's unix side. |
| `dlls/ntdll/unix/sdt-config.h` (new) | `#define _SDT_ASM_SECTION_AUTOGROUP_SUPPORT 1` / `#define _SDT_ASM_SECTION_RETAIN_SUPPORT 1` (binutils 2.38 in the jammy container supports the `?` and `R` section flags; if gas rejects `"aGR"`, set RETAIN to 0 — Wine's unix link does not use `--gc-sections`). |
| `dlls/ntdll/unix/signal_x86_64.c` | `#include "sdt.h"`; 4 asm probes. |
| `dlls/ntdll/unix/server.c` | `#include "sdt.h"`; 2 C probes in `server_call_unlocked`, 2 around `wait_select_reply` in `server_select`; one fingerprint literal. |

**Edits to the vendored header** (comment block at the top):
1. x86_64 probe site is a 5-byte nop so the kernel's optimized-uprobe path applies. `_SDT_ASM_1(990: _SDT_NOP)` cannot take a comma-containing `.byte` list (the `_SDT_S(x)` re-invocation would split on commas), so use the 5-argument helper exactly as the kernel selftest copy does:
   ```c
   #if defined(__x86_64__)
   # define _SDT_DEF_NOP _SDT_ASM_5(990: .byte 0x0f, 0x1f, 0x44, 0x00, 0x00)
   #else
   # define _SDT_DEF_NOP _SDT_ASM_1(990: _SDT_NOP)
   #endif
   /* in _SDT_ASM_BODY: replace  _SDT_ASM_1(990: _SDT_NOP)  with  _SDT_DEF_NOP */
   ```
   On kernels without NOP5 support the site is simply single-stepped (still correct, classic cost).
2. Nothing else. `_SDT_HAS_SEMAPHORES` stays undefined (no semaphores: no runtime-state cost; bpftrace needs no `-p`).

**How the include works inside `__ASM_GLOBAL_FUNC`.** `__ASM_DEFINE_FUNC` is a file-scope *basic* `asm("...")` whose `code` argument is a sequence of adjacent string literals (`include/wine/asm.h:93-109`). `STAP_PROBE_ASM(provider, name, template)` expands (C99 variadic form, `sdt.h:471-474`) to adjacent string literals: `"990: .byte 0x0f,..."` `".pushsection .note.stapsdt,\"?\",\"note\"\n"` … `".ascii \"<template>\"\n"` … `".popsection\n"` + the `_.stapsdt.base` block. The template is passed *unquoted* (stringified by `_SDT_ASM_SUBSTR`); it must contain **no commas** (comma-containing templates select the 2-argument `_SDT_ASM_BODY_2` path meant for `STAP_PROBE_ASM_TEMPLATE(n)`), and because this is basic asm, `%rcx` is written with a single `%`. The sdt labels (`990`–`994`) do not collide with the dispatcher's `1`–`4`. `.altmacro` is left on by the header; nothing after the probe in the dispatcher uses `<...>` or `%expr` macro arguments. VERIFY: the build assembles; `objdump -d ntdll.so | grep -c 'nopl 0x0(%rax,%rax,1)'` shows the 4 sites.

**Argument strings must use decimal displacements**: `0xb0(%rcx)` fails to parse in libbpf. Use `176(%rcx)` etc.

### 1a. `wine:syscall_entry(id, frame, user_rsp, user_rip)`

Placement: after the kernel-stack switch and FS setup, before the table lookup — between 11.13 lines 3094 and 3095:

```c
                   "ldmxcsr 0x33c(%r13)\n\t"       /* amd64_thread_data()->mxcsr */
                   STAP_PROBE_ASM(wine, syscall_entry, -4@176(%rcx) 8@%rcx 8@136(%rcx) 8@112(%rcx))
                   "movl 0xb0(%rcx),%eax\n\t"      /* frame->syscall_id */
```

Register liveness at that point (all three Linux sub-paths converge at `2:`): `%rcx` = `frame` (restored by `leaq -0x98(%rbp),%rcx` on the `arch_prctl` path, untouched on the `wrfsbase` and no-`pthread_teb` paths), `%rbp` = `frame+0x98`, `%r13` = TEB, `%rsp` = `frame` (top of the kernel stack; the frame lies *above* rsp, free space below), `%r10/%r8/%r9` = syscall args 1/3/4, `%r15` = `user_rsp+0x28`, `%rax/%rdx/%rbx/%rsi/%rdi` dead. The probe writes no register. Args: `frame->syscall_id` (full id: bits 12-13 = table, so 0x1000+ = win32u), the frame address (drill-down reads the 0xa0-byte register block from it), `frame->rsp` (user stack pointer: `*(u64*)user_rsp` is the return address into the NtXxx *caller*) and `frame->rip` (= `NtXxx+0x14`; identifies the stub/module only).

Why not at `prolog_end`: there the thread is still on the user stack; the optimized-uprobe trampoline is entered by a `call`, which pushes below `rsp`; the chosen site has free kernel-stack space below `rsp` (red-zone safe). Every site in this patch satisfies that property.

### 1b. `wine:syscall_exit(status, frame, id, restore_flags)`

At the common return label (11.13 line 3128), after the CFI directives and before the stack move:

```c
                   __ASM_LOCAL_LABEL("__wine_syscall_dispatcher_return") ":\n\t"
                   __ASM_CFI(".cfi_remember_state\n\t")
                   __ASM_CFI_CFA_IS_AT2(rcx, 0xa8, 0x01) /* frame->syscall_cfa */
                   STAP_PROBE_ASM(wine, syscall_exit, -4@%eax 8@%rcx -4@176(%rcx) -4@180(%rcx))
                   "leaq 0x70(%rcx),%rsp\n\t"      /* %rsp > frame means no longer inside syscall */
```

Every path into the label sets `%rcx = frame` first (3127, 3279, 3285, 3289, 3386+3398 for the unix-call slow path, and the `__wine_syscall_dispatcher_return` function at 3289 used by NtContinue/exception/callback returns). `restore_flags` (0x20000 = `RESTORE_FLAGS_INCOMPLETE_FRAME_CONTEXT`) tells the tracer that an exit belongs to a unix call whose frame was modified (APC/exception). Thread start (`init_syscall_frame`'s tail jumps here) yields one unmatched exit per thread; the tracer counts and ignores it.

### 1c. `wine:unixcall_entry(handle, code, frame, caller_rip)` / `wine:unixcall_exit(status, frame)`

```c
                   "movq %r8,%rdi\n\t"             /* args */
                   STAP_PROBE_ASM(wine, unixcall_entry, 8@%r10 -4@%edx 8@%rsp 8@112(%rsp))
                   "callq *(%r10,%rdx,8)\n\t"
                   "movq %rsp,%rcx\n\t"
                   STAP_PROBE_ASM(wine, unixcall_exit, -4@%eax 8@%rcx)
                   "ldmxcsr 0xd8(%rcx)\n\t"        /* frame->xsave.MxCsr */
```

State before the call: `%r10` = unixlib handle (address of the module's `__wine_unix_call_funcs` table inside its `.so`), `%rdx` = code, `%rdi/%r8` = args, `%rsp` = frame (`%rcx` may be clobbered by the `arch_prctl` path, hence `%rsp`), `%rbp` is still the *user* rbp. `frame->rip` is the return address inside the PE caller function. After the call only `%rax` (NTSTATUS) and `%rcx`=frame are meaningful; pairing is by tid + frame pointer.

### 1d. C probes in `dlls/ntdll/unix/server.c`

```c
unsigned int server_call_unlocked( void *req_ptr )
{
    struct thread_data *data = get_thread_data();
    struct __server_request_info * const req = req_ptr;
    const int req_type = req->u.req.request_header.req;   /* union: overwritten by the reply */
    unsigned int ret;

    STAP_PROBE1( wine, server_req_start, req_type );
    if (!(ret = send_request( data->request_fd, req )))
        ret = wait_reply( data->reply_fd, req );
    STAP_PROBE2( wine, server_req_end, req_type, ret );
    return ret;
}
```
and in `server_select` (line 777): `STAP_PROBE1( wine, server_wait_start, flags ); ret = wait_select_reply( data->wait_fd, &cookie ); STAP_PROBE1( wine, server_wait_end, ret );` — where non-NTSync and APC-alertable waits actually block.

Fingerprint literal: `static const char wine_usdt_marker[] __attribute__((used)) = "WINE_USDT_V1";`.

**Audit wiring**: `REQUIRED_WINE_TAIL='0108-ntdll-add-static-trace-points.patch'` (`scripts/build-audit.sh:13`); FINGERPRINTS line `0108|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_USDT_V1`; add to the `[4/4]` structural invariants a `must_usdt lib/wine/x86_64-unix/ntdll.so wine 8` helper (`readelf -n "$tree/$1" | grep -c "Provider: $2"` must equal the expected probe count) — proves `.note.stapsdt` survived `strip --strip-unneeded` (`container-build.sh:609`). GNU strip keeps non-debug note sections and the allocated 1-byte `.stapsdt.base` (VERIFY on the first build). Then `scripts/build-audit.sh --freeze`, BASE.txt provenance bullet, CHANGELOG.

**Scope notes**: zero cost unattached (one 5-byte nop per site, notes are non-alloc); unix side is gcc + GNU ld (lld is PE-only); no i386 unix side under `--enable-archs=i386,x86_64` — 32-bit plugin threads reach the same x86_64 dispatcher through `wow64.dll!Wow64SystemServiceEx`, counted with caller frames stopping at `wow64.dll`.

## 2. PipeASIO block marker patch: `patches/pipeasio/0017-usdt-block-markers.patch`

Git-format patch like 0014/0015 (applied with `patch -p1`, `container-build.sh:258-260`). Files: `include/sdt.h` + `include/sdt-config.h` (same vendored header), new `include/pipeasio_block_clock.h` (pure helpers, unit-testable), `include/pipeasio_probe.h`, `include/audio.h`, `src/audio.c`, `src/asio.c`, `include/pipeasio_telemetry.h`, `tests/unit/test_block_clock.c`, `tests/unit/CMakeLists.txt`, `README.md`.

```c
/* include/pipeasio_probe.h: ELF-only; the mingw WoW64 PE half must not see .note.stapsdt */
#if defined(__linux__) && !defined(PIPEASIO_WOW64_PE)
# include "sdt.h"
# define PIPEASIO_PROBE(name, ...) STAP_PROBEV(pipeasio, name, ##__VA_ARGS__)  /* SDT_USE_VARIADIC */
#else
# define PIPEASIO_PROBE(name, ...) ((void)0)
#endif
```

```c
/* include/pipeasio_block_clock.h */
static inline uint64_t pipeasio_block_period_ns(uint32_t nframes, uint32_t rate)
{ return rate ? ((uint64_t)nframes * 1000000000ull + rate / 2) / rate : 0; }
/* PipeWire: clock.nsec = start of the current cycle; clock.next_nsec = logical start of the
 * next cycle (the data loop's next wakeup). The host callback must return before it. */
static inline uint64_t pipeasio_block_deadline_ns(uint64_t nsec, uint64_t next_nsec,
                                                  uint32_t duration, uint32_t rate)
{ return next_nsec > nsec ? next_nsec : nsec + pipeasio_block_period_ns(duration, rate); }
static inline int64_t pipeasio_block_slack_ns(uint64_t deadline_ns, uint64_t end_ns)
{ return (int64_t)(deadline_ns - end_ns); }
```

Probes (provider `pipeasio`), all emitted unconditionally (nop when unattached), next to the existing telemetry hooks:

| Probe | Site | Args |
|---|---|---|
| `cycle_start(clock_nsec, next_nsec, duration, position, cycle_flags)` | `audio_on_process` entry (`audio.c:1546`), after the `last_clock_nsec` store | brackets the full PipeWire cycle incl. dequeue/queue |
| `cycle_end(missed, delivered)` | end of `audio_on_process` (after the queue loop) | `missed` = the position-gap count computed at 1619-1631 |
| `block_start(seq, nframes, rate, clock_nsec, deadline_ns, flags)` | `process_callback` right after `pipeasio_host_call_begin` (`asio.c:2554`) | `flags`: bit0 admitted |
| `block_before_live(seq)` / `block_after_live(seq)` | `pipeasio_host_call_process`, both branches, where `telemetry_cycle_before_live/after_live` sit (0014) | |
| `block_end(seq, flags, missed)` | after the output publish loop, before `pipeasio_host_call_end` | `flags` += bit1 time_info, bit2 muted |

Sequence counter: `uint64_t block_seq` in `IPipeASIOImpl`, incremented at `process_callback` entry on the callback thread only (starts at 1; 0 means "no block"); `audio_client_t` gains `last_next_nsec`, `last_duration`, `last_rate` stores in `audio_on_process` and a getter `audio_get_cycle_deadline_nsec(c)`. The deadline is also handed to telemetry: `pipeasio_telemetry_sample` gains `uint64_t seq; int64_t slack_ns;`, `telemetry_cycle_finish` fills them, and the per-second `cycles=` line (0015's `telemetry_log`) gains `block_range=%llu-%llu late=%llu`.

"Late" for PipeASIO: the callback runs on the data-loop thread; if it has not returned by `next_nsec` the driver starts the next cycle without this node's output — PipeWire sets `SPA_IO_CLOCK_FLAG_XRUN_RECOVER` for the node on the following cycle; PipeASIO counts the missed cycles from `clock.position` gaps (1611-1632). The tracer reports `slack_ns = deadline_ns - t_end`, `late = slack < 0`, `near_late = slack < 15% of period` (configurable), cross-checked against `missed` from `block_end`.

Optional in the same patch (recommended): `SetThreadDescription(GetCurrentThread(), L"pipeasio-rt")` in `audio_rt_trampoline` (`audio.c:104`) and `L"pipeasio-worker"` in `lifecycle_worker`.

Fingerprint: `pipeasio/0017|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|block_range=`; `REQUIRED_PIPEASIO_TAIL='pipeasio/0017-usdt-block-markers.patch'`; structural `must_usdt lib/wine/x86_64-unix/pipeasio64.dll.so pipeasio 7`.

Unit test `tests/unit/test_block_clock.c` (`pipeasio_add_unit_test(test_block_clock test_block_clock.c)` + `TIMEOUT 10`, harness `test_helpers.h`): period 64@48000 = 1,333,333 ns, 128@44100 = 2,902,494 ns, rate 0 → 0; deadline prefers `next_nsec` when `> nsec`, else `nsec + period`; slack sign; a sample with `seq`/`slack_ns` round-trips through the SPSC ring.

## 3. Tracer: prototype → production

### 3a. Prototype `profiler/tracer/wine-trace.bt` (bpftrace 0.27)

Per-event lines only — validates probe arguments and the join; `profiler/tracer/reduce.py` joins by `seq` and `tid` offline. The wrapper substitutes `$ABLETON_WINE_ROOT` (resolve `pipeasio.dll.so` to the real `pipeasio64.dll.so`):

```
BEGIN { @seq = (uint64)0; printf("hdr mono_start_ns=%llu\n", nsecs); }
usdt:@NTDLL@:wine:syscall_entry   { @sc[tid] = nsecs; @scid[tid] = (uint32)arg0;
                                    printf("E %llu %d syscall %x seq=%llu rsp=%llx rip=%llx\n", nsecs, tid, (uint32)arg0, @seq, arg2, arg3); }
usdt:@NTDLL@:wine:syscall_exit    { if (@sc[tid]) { printf("X %llu %d syscall %x dur=%llu st=%x rf=%x\n", nsecs, tid, @scid[tid], nsecs-@sc[tid], (uint32)arg0, (uint32)arg3); delete(@sc[tid]); } }
usdt:@NTDLL@:wine:unixcall_entry  { @uc[tid] = nsecs; printf("E %llu %d unixcall %llx:%d seq=%llu rip=%llx\n", nsecs, tid, arg0, (uint32)arg1, @seq, arg3); }
usdt:@NTDLL@:wine:unixcall_exit   { if (@uc[tid]) { printf("X %llu %d unixcall dur=%llu st=%x\n", nsecs, tid, nsecs-@uc[tid], (uint32)arg0); delete(@uc[tid]); } }
usdt:@NTDLL@:wine:server_req_start{ @sr[tid] = nsecs; }
usdt:@NTDLL@:wine:server_req_end  { printf("S %llu %d req %d dur=%llu st=%x seq=%llu\n", nsecs, tid, (int32)arg0, nsecs-@sr[tid], (uint32)arg1, @seq); }
usdt:@PIPEASIO@:pipeasio:block_start { @seq = (uint64)arg0; @cb = tid;
                                    printf("B %llu %d start seq=%llu n=%d rate=%d clk=%llu dl=%llu\n", nsecs, tid, arg0, (uint32)arg1, (uint32)arg2, arg3, arg4); }
usdt:@PIPEASIO@:pipeasio:block_before_live { printf("B %llu %d before seq=%llu\n", nsecs, tid, arg0); }
usdt:@PIPEASIO@:pipeasio:block_after_live  { printf("B %llu %d after seq=%llu\n", nsecs, tid, arg0); }
usdt:@PIPEASIO@:pipeasio:block_end  { printf("B %llu %d end seq=%llu fl=%x missed=%d\n", nsecs, tid, arg0, (uint32)arg1, (uint32)arg2); }
```
`-4@` args arrive sign-extended; cast to `(uint32)`. Run as `bpftrace -B none wine-trace.bt > events.txt` (attach by file; no `-p`). VERIFY: `bpftrace -l 'usdt:/…/ntdll.so:*'` lists the 8 probes.

### 3b. Production: libbpf CO-RE in C

`profiler/tracer/wine-trace.bpf.c` + `profiler/tracer/wine-trace.c` (skeleton via `bpftool gen skeleton`; `Makefile`: `clang -O2 -g -target bpf -D__TARGET_ARCH_x86`, `cc … -lbpf -lelf -lz`). Built on the CachyOS host (jammy's libbpf 0.5 predates USDT support). Python/ctypes rejected: the user-space side must drain a ring buffer and batch-read maps at 10-20 Hz with no GC pauses.

**Attachment**: `bpf_program__attach_usdt(prog, pid, "<root>/lib/wine/x86_64-unix/ntdll.so", "wine", "syscall_entry", NULL)` once per traced pid (explicit pids make the kernel install the breakpoint only in those mms). PIDs: `profiler/bin/wine-trace` (bash) sources `scripts/lib/config.sh` + `scripts/lib/lifecycle.sh` and uses `ableton_prefix_pids "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX"` (includes `wineserver`), optionally narrowed by `--run-id TOKEN` (`ABLETON_BENCH_RUN_ID=`), and `--pid` extras; children followed with `tp_btf/sched_process_fork` (re-attaching the USDT programs for the new pid from user space on the fork event).

**NTSync (kernel side, no Wine patch)**: `fentry/fexit` on `ntsync_char_ioctl` (`cmd ∈ {NTSYNC_IOC_WAIT_ANY, NTSYNC_IOC_WAIT_ALL}`; `bpf_probe_read_user` of `struct ntsync_wait_args` at `parm` gives `count/alert/owner` on entry and `index` on exit; return 0 / -ETIMEDOUT / -EINTR / -EOWNERDEAD) and `fentry/ntsync_obj_ioctl` for wakes (`EVENT_SET`, `EVENT_PULSE`, `SEM_RELEASE`, `MUTEX_UNLOCK`; the current task is the waker). Needs module BTF (`/sys/kernel/btf/ntsync`). Fallback chain `--ntsync fentry|kprobe|tracepoint`: `kprobe/kretprobe` by kallsyms name, then `tracepoint:syscalls:sys_enter/exit_ioctl` filtered by `cmd`. VERIFY with `grep ntsync_ /sys/kernel/tracing/available_filter_functions`.

**Scheduler**: `tp_btf/sched_switch` (prev/next in the tid set → on/off-CPU intervals, run-queue delay = switch-in − wakeup), `tp_btf/sched_waking` (waker = current, wakee in set → `woken_by`), `tracepoint/task/task_rename` (live thread names), `sched_process_exit`.

**Maps**:
```c
struct agg_key { __u64 seq;      /* block seq, or (1ULL<<63)|window_id (100 ms) for non-block buckets */
                 __u32 tid; __u16 kind; __u16 flags; __u32 id; __u32 pad; };
struct agg_val { __u64 count, total_ns, max_ns, oncpu_ns; };
struct inflight_ent { __u64 ts, seq, frame; __u32 id; __u16 kind; __u16 sampled; };
struct inflight { struct inflight_ent s[4]; __u8 depth; __u32 drops; };
struct global { __u64 cur_seq, block_start_ts, deadline_ns, epoch; __u32 callback_tid, nframes, rate; };

BPF_MAP(agg, HASH, agg_key, agg_val, 65536) agg[4];   /* ring of 4 epochs (64 blocks each) */
BPF_MAP(inflight, HASH, u32 tid, struct inflight, 4096);
BPF_MAP(sched, HASH, u32 tid, {__u64 off_ts, wake_ts; __u32 waker_tid;}, 4096);
BPF_MAP(pids, HASH, u32, u8, 64);  BPF_MAP(tids, HASH, u32, u8 role, 4096);
BPF_MAP(cfg, ARRAY, u32, struct {u32 mode, sample_n, stack_bytes, roles, slack_thresh_pct;}, 1);
BPF_MAP(gl, ARRAY, u32, struct global, 1);
BPF_MAP(rb, RINGBUF, 16 MiB);  BPF_MAP(scratch, PERCPU_ARRAY, u32, u8[4096+256], 1);
```
`agg[(epoch) & 3]` is written at the *event's completion time* using the key's `seq` from its entry; user space drains `agg[(epoch-2) & 3]` with `bpf_map_lookup_and_delete_batch` (two epochs ≈ 170 ms of slack at 750 blocks/s). No per-event work in user space in summary mode.

**Handlers (sketch)**:
```c
SEC("usdt") int BPF_USDT(syscall_entry, __u32 id, __u64 frame, __u64 rsp, __u64 rip) {
    if (!traced_pid()) return 0;
    __u32 tid = bpf_get_current_pid_tgid();
    struct global *g = cur_global();
    struct inflight *f = inflight_get_or_init(tid);
    __u64 seq = (tid == g->callback_tid || g->cur_seq) ? g->cur_seq : 0;
    push(f, KIND_SYSCALL, id, frame, bpf_ktime_get_ns(), seq);
    if (want_stack(f, g)) emit_stack_sample(KIND_SYSCALL, id, frame, rsp, rip, seq);
    return 0;
}
SEC("usdt") int BPF_USDT(syscall_exit, __s32 status, __u64 frame, __u32 id, __u32 rflags) {
    struct inflight *f = inflight_lookup(tid);
    if (!f || !(e = pop_matching(f, frame))) { count_unmatched(rflags); return 0; }
    agg_add(e->seq, tid, KIND_SYSCALL, e->id, now - e->ts);
    return 0;
}
SEC("usdt") int BPF_USDT(block_start, __u64 seq, __u32 n, __u32 rate, __u64 clk, __u64 dl, __u32 fl) {
    g->cur_seq = seq; g->callback_tid = tid; g->block_start_ts = now; g->deadline_ns = dl; g->epoch = seq >> 6;
    rb_emit(BLOCK_START, seq, now, clk, dl, n, rate, fl);  return 0; }
SEC("usdt") int BPF_USDT(block_end, __u64 seq, __u32 fl, __u32 missed) {
    rb_emit(BLOCK_END, seq, now, fl, missed, g->deadline_ns);  g->cur_seq = 0;  return 0; }
SEC("fexit/ntsync_char_ioctl") int BPF_PROG(ntsync_wait_exit, struct file *f, unsigned cmd, unsigned long parm, long ret) { … }
```
`server_req_start/end` and ntsync waits are nested inside the enclosing syscall/unixcall entry; aggregated as their own kinds (`server_req`, `ntsync_wait`) and *inherit the enclosing entry's stack sample id*.

**Block association rule**: the callback thread's events between `block_start` and `block_end` belong to that `seq`; its events between blocks go to the window bucket with flag `between_blocks`. Every other thread's event belongs to the block in progress at its *entry* time (`g->cur_seq`, 0 → window bucket). Non-audio threads are additionally aggregated per 100 ms window (`threads.jsonl`), including wineserver (role `wineserver`, kinds `oncpu/offcpu/ntsync_wake` only).

### 3c. Stack capture and ring-buffer records

Only for `syscall_entry`/`unixcall_entry`, and only when `mode == drilldown`, or every N-th event (`--sample 1/N`), or the current block is already past the slack threshold, or `--trigger-ids` matches:

```c
struct rec_hdr { __u16 type; __u16 len; __u32 tid; __u64 ts; };            /* 16 B */
struct rec_stack { struct rec_hdr h; __u64 seq, frame, rsp, rip; __u32 id; __u16 kind; __u16 nbytes;
                   __u64 regs[20];          /* syscall_frame bytes 0x00..0x9f: rax..rbp (read via frame ptr) */
                   __u8 bytes[];            /* --stack-bytes (512..4096, default 1536) from user rsp */ };
struct rec_block { struct rec_hdr h; __u64 seq, clock_nsec, deadline_ns; __u32 nframes, rate, flags, missed; __u8 phase; };
struct rec_wake  { struct rec_hdr h; __u32 wakee_tid, waker_pid, waker_tid; char waker_comm[16]; };     /* drill-down */
struct rec_offcpu{ struct rec_hdr h; __u64 off_ts, on_ts, run_delay_ns; __u32 waker_tid; };          /* ≥ 50 µs, drill-down */
struct rec_name  { struct rec_hdr h; __u32 pid; char comm[16]; };
```
Budget: 16 MiB ring; drill-down at 1/4 sampling of ~40k crossings/s = 10k × ~1.7 KB = 17 MB/s → drain at ≥ 20 Hz; summary mode writes only BLOCK records. Ring drops are counted and reported.

**Controls**: `--mode summary|drilldown|sample`, `--sample 1/N` (default 1/64 summary, 1/4 drilldown), `--stack-bytes N`, `--roles audio|all`, `--no-exit`, `--slack-threshold 15`, `--ntsync fentry|kprobe|tracepoint|off`, `--sched on|off`, `--ringbuf-mb`, `--duration`, `--out DIR`, `--calibrate`.

**CLI contract (shared with the root helper and the suite)**: `profiler/bin/wine-trace start --out DIR --pid… [--run-id TOKEN] --mode M` (daemonises via setsid, pidfile in DIR, writes `tracer.json` with `started_monotonic_ns`, version, mode, sample, attach list), `stop --out DIR` (SIGINT, flush, reduce + symbolize, writes `stopped_monotonic_ns`, `lost_events`, probe hit counts, `overhead_estimate_ns_per_block`), `run --duration S`. Output files readable by the invoking user (chown to `SUDO_UID`).

## 4. Caller resolution: `profiler/tracer/symbolize.py` (stdlib only)

**Module map.** Snapshot `/proc/PID/maps` at start, on `sched_process_exec`, every 5 s, and whenever an address misses. A PE image is a mapping with file offset 0 whose file starts with `MZ`; the path is the on-disk `.exe/.dll/.vst3` for Live/plugins and `lib/wine/x86_64-windows/*.dll` for Wine's PE DLLs. Image extent is `[base, base + SizeOfImage)` from the file's optional header. ELF mappings (`*.so`) are recorded to label unix-side addresses (`unix:ntdll.so+0x…`) and stop unwinding there. Module identity = (path, size, mtime, base).

**PE parser** (minimal, ~250 lines): DOS/NT headers (PE32+; PE32 → name only), sections, directories: EXPORT (name → RVA; `nearest preceding export` for Wine DLLs), EXCEPTION (`RUNTIME_FUNCTION[]` sorted by `BeginAddress` → `bisect`), IMPORT (Live's import table dumped once per run to `imports.json` as the permitted static map). `UNWIND_INFO`: version, flags, `SizeOfProlog`, `CountOfCodes`, `FrameRegister/FrameOffset`, codes, chained entry.

**Unwinder** (x64, offline, deterministic, ~300 lines):
```python
def unwind(ctx, mem, start_mode):            # mem = captured stack window [rsp0, rsp0+n)
    if start_mode == "syscall":  rip, rsp = mem.u64(ctx.rsp), ctx.rsp + 8   # caller of NtXxx
    else:                        rip, rsp = ctx.rip, ctx.rsp                # unixcall: PE caller itself
    regs = ctx.regs                                                          # rbx,rbp,rsi,rdi,r12..r15 from the frame copy
    for depth in range(max_frames):
        mod = modules.find(rip);  frames.append(fmt(mod, rip))
        if mod is None or mod.kind != "pe64": break                         # unix .so / JIT / wow64 32-bit side
        rf = mod.runtime_function(rip - mod.base)
        if rf is None: rip, rsp = mem.u64(rsp), rsp + 8; continue           # leaf
        ui = mod.unwind_info(rf); off = rip - mod.base - rf.begin
        while True:
            for code in ui.codes_to_apply(off):                              # skip codes past the current prolog offset
                op = code.op
                if op == UWOP_PUSH_NONVOL: regs[code.reg] = mem.u64(rsp); rsp += 8
                elif op == UWOP_ALLOC_SMALL: rsp += (code.info + 1) * 8
                elif op == UWOP_ALLOC_LARGE: rsp += code.large_size
                elif op == UWOP_SET_FPREG: rsp = regs[ui.frame_reg] - ui.frame_off * 16
                elif op in (UWOP_SAVE_NONVOL, UWOP_SAVE_NONVOL_FAR): regs[code.reg] = mem.u64(rsp + code.disp)
                elif op in (UWOP_SAVE_XMM128, UWOP_SAVE_XMM128_FAR, UWOP_EPILOG): pass
                elif op == UWOP_PUSH_MACHFRAME: return frames, "machframe"
            if not ui.chained: break
            rf, ui, off = ui.chained_rf, mod.unwind_info(ui.chained_rf), 10**9
        rip, rsp = mem.u64(rsp), rsp + 8
    return frames, reason
```
Reads outside the window stop with `stack_window_exhausted` (reported per site so `--stack-bytes` can be tuned). Frames: `ntdll.dll!NtXxx+0x14`, then `kernelbase.dll!WaitForSingleObjectEx+0xe3`, then `Ableton Live 12 Trial.exe+0x1a2b3c4` (module+offset only), plugin `Serum.vst3+0x…`, `wow64.dll!…` (stop). Max 12 frames.

**Caches**: per (module_id, rva) → decoded `RUNTIME_FUNCTION`/codes; per (module_id, rva) → symbol string; per hash of the first 6 return addresses → frame list; persisted to `<out>/symcache.json` with the module identity.

## 5. Thread roles

Wine 11.13 already writes Windows thread names into comm, so no `wine:thread_name` probe is needed. Classification (user space; `profiler/tracer/roles.toml`; result stored in `tids` map for `--roles audio`):

| Role | Rule |
|---|---|
| `pipeasio_callback` | the tid that fires `pipeasio:block_start` (re-learned on every block) |
| `audio_worker` | comm `AudioCalc` |
| `main` | tid == pid of a `*.exe` process |
| `wineserver` | process comm `wineserver` in the prefix set |
| `pipeasio_worker` / `pipeasio_rt` | comm `pipeasio-worker` / `pipeasio-rt` once 0017 names them |
| `live:<comm>` | any other named Live thread |
| `plugin:<module>` | threads whose start routine lies in a plugin module: read `NtCreateThreadEx`'s 5th argument (`*(user_rsp+0x28)` in the entry's stack window) on `syscall_entry(id==NtCreateThreadEx)` and symbolize; the new tid arrives via `sched_process_fork` |
| `webview`, `max`, `push2` | by process exe name (msedgewebview2.exe, Max.exe, Push2DisplayProcess.exe) |
| `unknown:<comm>` | fallback |

## 6. Whole-app profiling mode: `profiler/bin/profile-app`

- `--backend bpf` (default): the tracer with `--mode sample`: a `perf_event` BPF program (software `cpu-clock`, 999 Hz, per traced pid) emits a `rec_stack` with `rip/rsp/rbp` from `bpf_perf_event_data` and the stack window; the PE chain is recovered by the offline unwinder, the unix-side leaf (`ntdll.so`, `win32u.so`, `winex11.so`, libc, PipeWire) symbolized from `.symtab` of the **unstripped dev-loop tree** when `--symbols-root` points at it (fallback `module.so+offset`). Exact per-thread CPU and off-CPU come from `sched_switch` accounting. Output: `samples.jsonl`, folded stacks (`stacks.folded`: `role;comm;frame;frame… count`), `profile.json` (per-role CPU share, top PE modules/sites, top unix leaves, off-CPU reasons for audio threads), and an SVG from `profiler/tracer/flamegraph.py` (own ~150-line renderer).
- `--backend perf` (dev loop, unstripped runtime): `perf record -e cpu-clock -F 999 --call-graph dwarf,8192 -p <pids>` (Wine's unix side has no frame pointers; `.eh_frame` survives stripping, symbols do not), then `perf script -F comm,tid,time,ip,sym,dso` piped into `symbolize.py --perf` which replaces `[unknown]` PE addresses with `module+offset`. PE frames end the perf callchain; this backend is for "what unix-side code is hot".

## 7. Validation

**`tools/traceprobe.c`** (built by `tools/build_traceprobe.sh`, same toolchain lines as `tools/build_apcprobe.sh`; run with `tools/run_in_prefix.sh traceprobe.exe` while `wine-trace --pid <probe pid>` records). PASS/FAIL/SKIP lines, exit = FAIL count; prints machine-readable `EXPECT <kind> <id> <op> <n>` lines that `profiler/tracer/validate.py` compares with the tracer's counts for the probe's tid:

| Phase | Calls | Expected tracer observation |
|---|---|---|
| 1 | `NtYieldExecution` ×100 | 100 × `syscall 0x0046`, each `status ∈ {0, STATUS_NO_YIELD_PERFORMED}` |
| 2 | `QueryPerformanceCounter` ×200 | 200 × `syscall 0x0031` (11.13 always syscalls; flagged "QPC may become user-mode in a later Wine") |
| 3 | `CreateEventW`+`CloseHandle` ×50 | 50 × `NtCreateEvent` each enclosing exactly 1 `server_req create_event`; 50 × `NtClose` with `close_handle` |
| 4 | `WaitForSingleObject(ev, 10 ms)` ×20, unsignaled | 20 × `NtWaitForSingleObject` enclosing 20 `ntsync_wait WAIT_ANY` returning -ETIMEDOUT (10 ms ± 1 ms); ≥ 1 `get_inproc_sync`-type request on first use (VERIFY name in 11.13 `server/protocol.def`) |
| 5 | helper thread `SetEvent` ×20 while main waits infinite | 20 `ntsync_wake EVENT_SET` from the helper tid; 20 waits ending 0 with `woken_by == helper tid` |
| 6 | `SCardEstablishContext` ×10 | 10 × `unixcall` with handle → `winscard.so` (VERIFY the PE side calls `WINE_UNIX_CALL` unconditionally); plus `DWriteCreateFactory` + `GetGlyphIndices` ×20 → `unixcall` handle → `dwrite.so` |
| 7 | `SleepEx(1, TRUE)` ×10 | 10 × `NtDelayExecution`, each enclosing either a `server_wait` (default) or an `ntsync_wait count=0` (`WINE_APC_FASTPATH=1`) |

Ordering/pairing checks: zero `unmatched_exit` for the probe tid other than the thread-start one; `abandoned_entries == 0`; every `server_req` has an enclosing syscall or unixcall.

**Block join**: run Live idle with `PIPEASIO_TELEMETRY=on` plus the tracer for 60 s; `validate.py --telemetry live.log --blocks blocks.jsonl` checks per second `cycles=` == `block_start` count (±1 at interval edges), `block_range=A-B` equals the tracer's seq range, telemetry `live_callback` p50/p95/p99 agree with `t_after_live - t_before_live` within 2 µs, `late=` equals the tracer's late count.

**Unit tests**: `profiler/tracer/tests/test_symbolize.py` (synthetic PE32+ image built in-memory with `.pdata` `UNWIND_INFO` {PUSH_NONVOL rbp, ALLOC_SMALL 0x20, SET_FPREG}, a chained entry, an export table, plus a synthetic stack window → asserts recovered return addresses and `module!export+off` strings); `test_reduce.py` for the block association rule and epoch drain; the PipeASIO `test_block_clock`.

## 8. Overhead plan

- **Probe cost model** (bare metal, to be measured): classic int3 uprobe ≈ 1–2.5 µs per hit; the x86_64 optimized uprobe roughly doubles throughput (3.2 M/s → 6.75 M/s) — plan with ≈ 0.5 µs optimized / ≈ 2 µs classic per hit incl. a BPF handler with 2–3 map ops. `fentry` ≈ 0.1 µs, tracepoints ≈ 0.1 µs. VERIFY the VM kernel has the optimization with `--calibrate` (runs `traceprobe.exe` phase 1 traced/untraced and reports ns/hit).
- **Budget**: 64 frames @ 48 kHz = 1,333 µs per block. 50 crossings per block at 2 µs = 200 µs (15%) — unacceptable; at 0.5 µs = 50 µs (3.75%). Hence: dispatcher-level probes only, in-kernel aggregation, `--no-exit` when only counts are needed, `--roles audio`, stack copies only sampled/triggered, explicit-pid attachment. First measurement in the VM is the raw rate (`bpftrace -e 'usdt:…:syscall_entry { @[comm] = count(); }'`).
- **Red zone / trampoline safety**: all probe sites are on Wine's kernel stack or in non-leaf C functions.
- **Matched traced/untraced proof** (bare metal only): three suite runs (untraced; summary; drilldown) compared with `make bench-compare`: Live process CPU%, voluntary context switches, PipeWire xruns/ERR, telemetry p99 (`PIPEASIO_TELEMETRY=on` in all three), tracer counters. Acceptance for summary mode: < 1% process CPU and < 2% on the callback p99.

## 9. Output formats

All times are `offset_seconds` from the run's `monotonic_start_ns` (`bpf_ktime_get_ns()` = CLOCK_MONOTONIC = the suite's `time.monotonic_ns()` base = PipeWire's `clock.nsec` base); first line of every file is a `{"type":"header"}` record with `monotonic_start_ns`, runtime VERSION, pid set, mode, sample settings, table versions.

`blocks.jsonl`:
```json
{"seq":123456,"t_start":12.345678,"t_before_live":12.345690,"t_after_live":12.346170,"t_end":12.346179,
 "clock_nsec":...,"deadline_ns":...,"period_ns":1333333,"nframes":64,"rate":48000,"callback_tid":4242,
 "wake_latency_ns":41000,"pre_ns":12000,"live_ns":480000,"post_ns":9000,"slack_ns":812000,
 "late":false,"near_late":false,"missed_cycles":0,"flags":["admitted","time_info"],
 "crossings":[
  {"tid":4242,"role":"pipeasio_callback","kind":"ntsync_wait","id":"WAIT_ANY","n":1,"total_ns":310000,"max_ns":310000,"woken_by":{"tid":4301,"role":"audio_worker"}},
  {"tid":4301,"role":"audio_worker","kind":"syscall","id":"NtReleaseSemaphore","n":3,"total_ns":2100,"max_ns":900},
  {"tid":4301,"role":"audio_worker","kind":"server_req","id":"select","n":1,"total_ns":45000,"max_ns":45000}],
 "offcpu":[{"tid":4242,"ns":300000,"intervals":1,"max_run_delay_ns":12000}],
 "stacks":[{"tid":4301,"kind":"syscall","id":"NtWaitForMultipleObjects","frames":["ntdll.dll!NtWaitForMultipleObjects+0x14","kernelbase.dll!WaitForMultipleObjectsEx+0xe3","Ableton Live 12 Trial.exe+0x1a2b3c4"],"stop":"max_frames"}]}
```
`kind ∈ syscall|unixcall|server_req|server_wait|ntsync_wait|ntsync_wake|offcpu`; `id` = syscall name (table `profiler/tracer/tables/wine-<ver>.json`, generated by `profiler/tracer/gen_tables.py --wine-src <patched tree>` from `dlls/ntdll/ntsyscalls.h` `ALL_SYSCALLS` (0x0000–0x0fff), `dlls/win32u/win32syscalls.h` (0x1000+), `include/wine/server_protocol.h` `enum request` (patched tree; 0078 bumps `SERVER_PROTOCOL_VERSION`), and the first enum of each `dlls/*/unixlib.h` for unix-call codes; keyed by runtime VERSION with a mismatch warning), `module.so#code` when unknown; unix-call ids are `winscard.so:scard_establish_context`, resolved by mapping the `handle` address through the maps snapshot.

`summary.json` → the `interface` section in the measurement schema (see Design C §B for the authoritative field names: `blocks`, `lost_slack`, `call_sites[{rank,key,kind,name,caller,late_blocks,near_late_blocks,n_in_late_blocks,per_late_block,total_ns_in_late_blocks,max_ns,share_of_lost_slack,n_all_blocks,total_ns_all_blocks,woken_by}]`, `kinds`, `roles`, `hotspots_non_audio`, plus tracer counters `unmatched_exits`, `abandoned_entries`, `ringbuf_drops`, `probe_hits`, `overhead_estimate_ns_per_block`). Ranking: `total_ns_in_late_blocks` = Σ over late/near-late blocks of the site's `total_ns` (sites = symbolized chain truncated to depth 3 + kind + id; unsampled events are apportioned to the sampled sites of the same (tid, kind, id) within the block); ties by count.

`threads.jsonl` (per 100 ms window × tid):
```json
{"t":12.3,"window_ms":100,"pid":4200,"tid":4310,"comm":"MIDI","role":"live:MIDI","oncpu_ns":1200000,"offcpu_ns":98800000,"wakeups":12,"run_delay_ns":30000,
 "crossings":{"syscall":{"n":40,"total_ns":950000},"server_req":{"n":2,"total_ns":80000}},"top_ids":[["NtUserMsgWaitForMultipleObjectsEx",10,95000000]]}
```
`events.jsonl` (drill-down only): raw `{t, tid, kind, id, dur_ns, status, seq, stack_ref, woken_by}`; `samples.jsonl`/`stacks.folded`/`profile.json` for profile-app.

Critical files: `patches/0108-ntdll-add-static-trace-points.patch` (targets `dlls/ntdll/unix/signal_x86_64.c` lines 3094/3128/3385-3386 and `dlls/ntdll/unix/server.c:285-293,777` of the 11.13 base), `patches/pipeasio/0017-usdt-block-markers.patch`, `scripts/build-audit.sh`, `profiler/tracer/wine-trace.bpf.c` + `wine-trace.c` + `wine-trace.bt`, `profiler/tracer/symbolize.py`, `tools/traceprobe.c`.
