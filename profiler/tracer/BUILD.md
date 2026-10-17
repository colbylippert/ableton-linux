# Building the production tracer (`build/wine-trace`)

The libbpf CO-RE tracer of design B section 3b: `wine-trace.bpf.c` (kernel side), `wine-trace.c`
(loader, reduction and output writer), `wine-trace.h` (shared structs, constants and the JIT
prologue classifier). It is built on the Linux machine that runs it, never shipped: `vmlinux.h`
comes from that kernel's BTF. `profiler/bin/wine-trace` uses `build/wine-trace` by default when it
is built and its stack self-check passes, else the bpftrace prototype (the reason is printed and
kept in `tracer.json` `backend_reason`); `--libbpf` / `--proto` force a backend.

## The stack rule (why the BPF code looks the way it does)

Kernel 7.2.9-cachyos (PREEMPT full, and every kernel since 6.14) gives `BPF_PROG_TYPE_KPROBE`
programs, uprobes and USDT included, whose BPF stack is 64 bytes or more (rounded up to 16) a
**per-CPU private stack**: the JIT prologue is `movabs …,%r9; add %gs:this_cpu_off,%r9` instead of
`sub $N,%rsp`. USDT programs run preemptible (`migrate_disable()` only) and without a recursion
guard, so a second thread entering the same program on the same CPU overwrites the preempted run's
frame. That crashed bpftrace (`std::bad_alloc`) and oopsed the first libbpf loader inside
`wine_syscall_exit` (a timestamp loaded as a pointer through `r9`), which killed Live's
`pipeasio-rt` thread and left uprobe unregistration stuck in `synchronize_srcu` until a reboot
(`../../../plans/findings/b5-tproto-rootcause.md`, `b5-kernel-oops-24441.txt`). Per-CPU maps used
as in-flight scratch have the same hazard. So every uprobe program and every subprogram it calls:

* keeps its BPF frame below 64 bytes: the only stack variable is the tid used as a map key
  (frames are 8–40 bytes, `make self-check` prints them);
* keeps per-thread scratch in the thread's own `struct tstate` (hash map value keyed by tid):
  map keys and values under construction (`ag`, `sg`, `ukey`), the USDT arguments (`arg[]`), the
  NTSync wait arguments (`wa[]`), the in-flight entry stack. No other thread touches a tid's
  value, and a thread cannot run two of its own programs at once;
* builds ring-buffer records in place in `bpf_ringbuf_reserve()`d memory (`bpf_probe_read_user`
  and `bpf_usdt_arg` write straight into them);
* counts with atomic adds on global data (`.bss` `counters[]`), and uses no per-CPU map at all;
* takes its configuration from frozen `.rodata` (`CFG`): the verifier drops dead branches and the
  stack-sample reservation size is a constant.

fentry/fexit/tp_btf programs have the kernel's per-program recursion guard and the scheduler
tracepoints run non-preemptible; they follow the same rules anyway.

## The stack self-check (mandatory before every attach)

After `wine_trace__load()` and before anything is attached, the loader reads every loaded program's
JIT image and xlated code (`bpf_prog_get_info_by_fd`: `jited_prog_insns`, `jited_func_lens`,
`xlated_prog_insns`, `func_info`) and classifies each function (main program and subprograms) by
decoding its prologue (`jit_prologue_class` in `wine-trace.h`): `sub rsp,imm32` = **kernel-stack**,
`movabs r9,…` (+ `add r9,gs:…`) = **private-stack**, no frame set-up = kernel-stack only when the
xlated code never touches `r10` (else **unknown**). A preemptible program (`usdt`/`uprobe`
section) that is not provably on the kernel stack makes the loader refuse to attach (exit 2, the
offending programs marked `RISKY` on stderr). `tracer.json` gets `stack_check` (per program and
function: class, JIT frame bytes, xlated stack depth), `private_stack_programs` and
`private_stack_risky` (bench-report's `interface-tracer-private-stack` confounder).

```bash
sudo -n build/wine-trace --self-check [--mode M --sched on|off --ntsync X --ntdll PATH]   # JSON on stdout, exit 0 / 2
make -C profiler/tracer self-check   # the same with the defaults, report in build/stack-check.json
make -C profiler/tracer test-gate    # a deliberately broken build (one USDT program with a 128-byte
                                     # frame, -DWT_SELFTEST_BIG_FRAME) must be refused with exit 2
make -C profiler/tracer test         # classifier unit test against prologue bytes captured from this
                                     # kernel's JIT (tests/test_jit_classifier.c; no root)
sudo -n build/wine-trace --self-check --dump-jit DIR   # first 96 JIT bytes of every function, for new
                                                        # fixtures when a kernel changes the prologue
```

`--unsafe-private-stack` attaches anyway (recorded in `tracer.json` and as a warning): for
experiments on synthetic workloads only, never against Live. `profiler/bin/wine-trace` runs the
self-check with the run's own options to choose the backend, and the loader checks again before it
attaches.

Verified on the laptop (B5b): all 14 USDT programs and every subprogram on the kernel stack in
summary, drilldown (sched on), `--ntsync kprobe|tracepoint`, `--roles audio`, `--no-exit` and
`--mode sample` builds; `make test-gate` refused (`wine_syscall_exit … private-stack … RISKY`,
exit 2).

## Probe operands (fast path)

`bpf_usdt_arg()` costs two or three helper calls per argument. The four dispatcher probes of patch
0108 have fixed operands, so when ntdll.so's `.note.stapsdt` carries exactly
`FAST_ARGS_SYSCALL_ENTRY`/`…_EXIT`/`FAST_ARGS_UNIXCALL_ENTRY`/`…_EXIT` (checked with libelf before
load, every traced ntdll.so) the programs read `%rcx`/`%eax`/`%r10`/`%edx`/`%rsp` straight from the
trapped registers and the syscall id / restore flags with one `bpf_probe_read_user`. Otherwise (or
with `--generic-args`) everything goes through `bpf_usdt_arg`. `tracer.json`
`stack_check.usdt_operands` says which. The server and PipeASIO probes (compiler-chosen operands)
always use `bpf_usdt_arg`. The choice is a load-time constant, so a followed child whose ntdll.so is
not one of the verified files (`st_dev`/`st_ino`) has its operands checked before it is attached;
on a mismatch it is not traced (a warning, `counters.follow_skipped_unverified_ntdll`).

## Prerequisites (CachyOS / Arch)

```bash
sudo pacman -S --needed clang bpf libbpf libelf zlib gcc make
```

| Tool | Tested | Why |
|---|---|---|
| clang | 23 | `-target bpf` |
| bpftool (`bpf` package) | 7.8 | `btf dump` (vmlinux.h) and `gen skeleton` |
| libbpf | 1.7 | USDT attach (`bpf_program__attach_usdt`, needs >= 1.0), ring buffer, batch map ops |
| libelf | elfutils | `.note.stapsdt` operand check |
| gcc / cc | 16 | the loader (`-Wall -Wextra` clean) |
| kernel | 7.2.9-cachyos | BTF (`/sys/kernel/btf/vmlinux`), `/sys/kernel/btf/ntsync` for the fentry NTSync probes |

The kernel needs `CONFIG_DEBUG_INFO_BTF=y` (and BTF for the `ntsync` module for `--ntsync fentry`;
without it the loader falls back to kprobes, then to the `sys_enter/exit_ioctl` tracepoints).
Root (or CAP_SYS_ADMIN) is needed to load the programs and to read their JIT images.

## Make targets

```bash
make -C profiler/tracer            # build/vmlinux.h, build/wine-trace.bpf.o, build/wine-trace.skel.h, build/wine-trace
make -C profiler/tracer check      # build + list program sections and maps + `wine-trace --version`
make -C profiler/tracer test       # JIT prologue classifier unit test
make -C profiler/tracer self-check # sudo -n: load + stack check, never attaches
make -C profiler/tracer test-gate  # sudo -n: the broken build must be refused
make -C profiler/tracer clean      # remove build/ (the test-gate build lives in build/gate/)
```

Overrides: `CLANG=`, `BPFTOOL=`, `CC=`, `BUILD=` (output directory), `VMLINUX_BTF=`,
`BPF_CPU=v3`, `BPF_EXTRA=` (extra clang flags), `SUDO=`. Everything generated lands in `build/`
(ignored by git, so `build.sh`'s source snapshot never sees it). `vmlinux.h` enters the BPF compile
through `-isystem`, so the build prints only warnings of our own code: a clean build prints none.

**Regenerate after a kernel update**: `make -C profiler/tracer clean all self-check`. `vmlinux.h`
is a snapshot of the running kernel's BTF; CO-RE relocates field offsets at load time, but new or
renamed tracepoint arguments (`tp_btf/*`) need the new header, and a new kernel can change the
verifier's stack accounting or the JIT prologue (the self-check catches both).

**ABI**: `WINE_TRACE_ABI` in `wine-trace.h` (4) is bumped whenever a struct shared by the two
sides changes; the loader and the BPF object are always built together, so a stale `build/` is the
only way to mix them (`make clean all`).

## Running

Through the wrapper (the normal way; it discovers the prefix pids, snapshots the maps, writes the
start fields of `tracer.json`, runs `symbolize.py` after stop and chowns the directory):

```bash
sudo -n profiler/bin/wine-trace start --out DIR [--pid P]... [--run-id TOKEN] [--mode summary|drilldown]
sudo -n profiler/bin/wine-trace stop  --out DIR
sudo -n profiler/bin/wine-trace run   --out DIR --duration 30
```

Directly (what the wrapper runs):

```bash
sudo -n profiler/tracer/build/wine-trace --out DIR --pid LIVE_PID --pid WINESERVER_PID \
    [--mode summary|drilldown|sample] [--duration S] [--ntsync auto|fentry|kprobe|tracepoint|off] \
    [--sched on|off] [--run-id T] [--sample 1/N] [--stack-bytes N] [--keep-stacks none|late|all] \
    [--roles audio|all] [--no-exit] [--slack-threshold PCT] [--slack-samples N] [--near-late-fraction F] \
    [--ringbuf-mb N] [--trigger-ids ID,...] [--tables FILE] [--ntdll PATH] [--pipeasio PATH] [--no-follow] \
    [--trap-ns N] [--generic-args] [--unsafe-private-stack] -v
```

Without `--duration` it runs until SIGINT/SIGTERM, then detaches, drains and writes. It prints
`attached monotonic_start_ns=N probes=P links=L` on stdout once its self-check passed and every
probe is attached (the wrapper waits for this line; exit 2 = the self-check refused), and
`stopped monotonic_stop_ns=N blocks=B lost=L` after the outputs are written.

## What it does

1. Reads `/proc/PID/maps` of every `--pid` for `.../x86_64-unix/ntdll.so` and
   `pipeasio64.dll.so` (`--ntdll`/`--pipeasio` override), the Wine version
   (`ABLETON-WINE-BUILD-INFO.txt` of the runtime, else the path) and the id table
   (`--tables`, else `../tables/wine-<version>.json` next to the binary).
2. Enables BPF run-time statistics (`BPF_ENABLE_STATS`), verifies the probe operands (above),
   opens the skeleton, writes `.rodata` (mode, sampling, stack bytes, NtCallbackReturn's syscall id
   from the table, ...), sizes the ring buffer, enables only the programs it will attach and loads.
   A load failure with `--ntsync auto` retries with the next NTSync variant.
3. **Stack self-check** (above): refuses to attach on a risky program.
4. Fills `pids` (and `tids` for `--roles audio`), attaches the kernel programs, then the 8 `wine:`
   probes and, where the driver is mapped, the 6 `pipeasio:` probes per pid, each exit side before
   its entry side (Pairing details)
   (`bpf_program__attach_usdt(prog, pid, path, provider, name)`, so the breakpoints exist only in the
   traced processes). Children forked by a traced process are added to `pids` in the kernel at once
   and get their USDT probes as soon as their maps show `ntdll.so` (15 s limit).
5. Main loop (25 ms): consumes the ring buffer (block phases, stack samples, drill-down events,
   thread names, forks, unix-library handles) and drains the aggregation. Every aggregated key is
   written at completion time into `agg[(now / 100 ms) & 3]`; slot window `W` is drained with
   `bpf_map_lookup_and_delete_batch` once the clock is in `W + 2`, so the BPF side never updates a
   value that user space is deleting. Keys are merged by their own `seq` (block) or window id.
6. A block is written 0.7 s after its `block_end`, with its crossings merged by (tid, kind, id
   name, parent), the off-CPU time of audio-role threads, and references to its stack samples; a
   100 ms thread window is written 2.5 s after it ends. At stop everything left is flushed and the
   distinct stacks are written to `stacks.jsonl`.
7. Stop: sets `gl.stopping` (no block starts after that; the one in progress completes), then
   destroys the links in reverse attach order, drains and writes. Only blocks whose `block_start` the
   tracer saw get their other phases, so `blocks.incomplete` counts real gaps, not the block in
   progress at attach or the ~0.1 s link teardown. A block whose `BLOCK_START` record was dropped
   is rebuilt from `BLOCK_END`'s copy of the block state (`"rebuilt": true`, no `clock_nsec`).

Pairing details: entries are paired with exits per tid by frame pointer (syscalls, unix calls) or
id (server requests), innermost first; an exit that matches an entry below the top pops the
entries above it as `abandoned_entries`. `NtCallbackReturn` (it resumes the user callback's caller
and never exits through its own frame) is counted as a zero-duration crossing and never pushed:
pushing it stacked one dead entry per GUI callback until the outer call returned and overflowed
the in-flight stack of Live's main thread. Entries still open when their thread exits
(`NtTerminateThread/Process`) are `open_at_thread_exit`, not abandoned. Syscalls and unix calls of
one user-callback nesting level share the dispatcher's frame, so a new syscall / unix call at a
frame that an in-flight one still holds pops that stale entry and everything above it as
`never_returned`. The exit side of every pair (fexit, kretprobe, `sys_exit_ioctl`, the `_exit` /
`_end` USDT probes, `block_end`) is attached before its entry side and detached after it: in B5b
the fentry/fexit attach window left each busy AudioCalc thread with 8 NTSync waits that had no
exit program yet and no enclosing syscall; they filled its in-flight stack (the `inflight_overflow`
of every Live run), and each later wait exit completed one of them with a duration of seconds,
abandoning the live `NtWaitForSingleObject` (whose exit then matched nothing). Nested kinds
(server requests and waits, NTSync waits and wakes) record their enclosing syscall / unix call
(`parent`), which gives them its callers. In drill-down every in-flight overflow, unmatched exit,
`never_returned` pop and abandoned pop is also written to `anomalies.jsonl` with the thread's
in-flight stack at that moment (`tracer.json` `anomalies.top` counts them by kind and id).

## Stack samples and callers

A `syscall_entry`/`unixcall_entry` is sampled with probability 1/N (`--sample 1/N`: 1/64 in
summary, 1/4 in drilldown), when its block is already within `--slack-threshold` (15 %) of its
period of the deadline (at most `--slack-samples` (16) per block), or for `--trigger-ids`. A sample
is the 0xa0-byte syscall frame (registers; its rsp/rip are the probe's user_rsp/user_rip or
caller_rip) and `--stack-bytes` (1536) of user stack, reserved and filled in the ring buffer.

The loader deduplicates samples by a fingerprint (pid, kind, id, rip, rsp & 15 and the first 16
stack words that point into executable mappings, with their offsets: the same assumption as
`symbolize.py`'s unwind cache, `STACK_CACHE_WORDS`; with 6, ~3 % of the samples merged with a
stack whose caller-deciding return address was code word 7-10). The first sample of a
fingerprint is kept with its window
(`stacks.jsonl`, with per-tid sample counts); every sample becomes a `{ref, t, tid, kind, id}`
reference in its block. Live B5b run (60 s summary): 393,602 samples, 762 distinct stacks,
2.6 MB `stacks.jsonl`.

`symbolize.py` unwinds the representatives (PE `.pdata`), and gives every crossing a caller:
the frames after the syscall stub up to and including the first application frame (Live or a
plugin, `module+offset` only) within 4 frames, e.g.
`kernelbase.dll!WaitForSingleObject+0x49 <- Ableton Live 12 Trial.exe+0x4f8c119`. Native runtime
DLLs of the prefix (`msvcp*`, `vcruntime*`, `ucrtbase`, `concrt*`, `api-ms-win-*`, any PE under
`drive_c/windows/system32|syswow64`) are walked past, one extra frame each (a
`std::condition_variable` wait: `... <- msvcp140.dll+0x122e8 <- MaxPlug.dll+0x64b9e9`). A crossing is
split over the callers sampled for its (tid, kind, id) in the same block (`caller_basis: block`),
else over the run's samples of that (tid, kind, id) (`run`); nested kinds use their enclosing
call's samples (`parent-block`, `parent-run`); `unsampled` otherwise. `summary.json` `call_sites`,
`nested_call_sites` and `hotspots_non_audio` are rewritten per caller (`callers` has the basis
statistics).

Lost slack (libbpf `summary.json`, the loader's and `symbolize.py`'s alike): each late or near-late
block's `near_late_slack_ns - slack_ns` is shared among its top-level crossings of audio-role
threads (callback, AudioCalc, PipeASIO rt/worker, plugin threads) in proportion to their time,
capped at that time. Nested crossings are already part of their enclosing call's time (counting
both gave one physical wait two shares of about 0.4 each): they are ranked in `nested_call_sites`
(keyed by their parent as well) without `share_of_lost_slack`. Crossings of other threads keep
their place in `call_sites` (ranked by time in late blocks) with no share. `reduce.py`'s summary and
`bench-report.py interface` still share the lost slack among all crossings.
In the B5b run 95.4 % of the sampled stacks reached a Live/plugin frame (mostly one frame after the
kernelbase wrapper); `stack_window_exhausted` stops happen deeper than that.

## Output (same contract as the prototype + `reduce.py`, see README.md)

| File | Notes |
|---|---|
| `blocks.jsonl` | header record + one record per block: timing fields, `late`/`near_late` (each block's own period), `rebuilt?` (start fields from `BLOCK_END`), `crossings[{tid, role, kind, id, parent?, n, total_ns, max_ns, timeouts?, woken_by?}]` without `caller`, `offcpu[]` (audio roles, `--sched on`), `stacks[]` (sample references), `cycle?` |
| `blocks.symbolized.jsonl` | written by `symbolize.py` (wrapper): every crossing with `caller`, `caller_basis` (and `caller_share` when split); `stacks[]` entries with `site`, `stop` and the first frames |
| `threads.jsonl` | header + per 100 ms window x tid; includes the crossings inside blocks (window of the block start) as well as the between-block buckets; `oncpu_ns/offcpu_ns/run_delay_ns` are `null` without `--sched on` |
| `summary.json` | reduce.py's schema + `nested_call_sites` (nested kinds per parent, no `share_of_lost_slack`; see "Lost slack"); after `symbolize.py`, `call_sites`, `nested_call_sites` and `hotspots_non_audio` are per (kind, id, caller) |
| `events.jsonl` | drill-down: one record per completed crossing and NTSync wake, `caller` placeholder (`ntdll.dll!<Name>+0x14`, `pe!0x<rip>`, nested kinds their enclosing call's), `parent`, `stack_ref` = the representative of this or the enclosing entry's sample |
| `anomalies.jsonl` | drill-down: header + one record per pairing anomaly: `{t, tid, role, what: inflight_overflow\|unmatched_exit\|never_returned\|abandoned, kind, id (null when the exit does not carry it), id_num, frame, restore_flags\|status\|first_popped\|completed_index, depth, inflight[{kind, id, frame}]}` (the in-flight stack before any pop) |
| `stacks.jsonl` | `symbolize.py`'s record shape (`type: stack, ref, t, tid, pid, seq, kind, id, frame, rip, rsp, regs[20], stack_hex`) + `samples`, `in_blocks`, `tids[[tid, n]]`: one record per distinct stack |
| `tracer.json` | merged in place: `started_monotonic_ns` = the moment every probe was attached (the wrapper's pre-launch value moves to `launch_monotonic_ns`), `attached_monotonic_ns`, `stopped_monotonic_ns`, `tracer_exit: clean`, `clean_exit`, `lost_events` + `loss`, `probe_hits`, `counters`, `anomalies` (drill-down), `per_tid` (validate.py; + `never_returned`), `blocks`, `overhead_estimate_ns_per_block`, `overhead`, `programs` (run time, `recursion_misses` and stack class per program), `stack_check`, `private_stack_programs`, `private_stack_risky`, `attach`, `followed_pids` |
| `maps-<pid>.txt`, `maps-<pid>-stop.txt` | written when the wrapper has not already (followed children, stop snapshots) |

`lost_events` counts crossings or blocks missing from the output: ring-buffer drops of block,
event and task/name/unixlib records, aggregation-map overflow, in-flight stack overflow, threads
without state, and the kernel-side programs' recursion misses: runs of the fentry/fexit, tp_btf,
kprobe/kretprobe, tracepoint and perf_event programs that the kernel skipped because the program
was already running on that CPU (`bpf_prog_info.recursion_misses`; the NTSync fentry programs are
preemptible, so a thread preempted inside one makes the next NTSync call on that CPU go unseen: a
lost wait, wait exit or wake). They are `loss.by_kind.recursion_misses` and `loss.recursion_misses`
(per program: `programs[].recursion_misses`; uprobe programs have no guard and never miss); B5b
review: 1,784 in 25 s of Benchmark_Inbuilts, where `lost_events` had said 56. Dropped stack
samples are not lost events (their crossings are counted): `loss.stack_samples_dropped`.
`loss.fraction_of_hits` relates it to the probe hits.

All times are `bpf_ktime_get_ns()` = `CLOCK_MONOTONIC`, the suite's `time.monotonic_ns()` and
PipeWire's `clock.nsec`; offsets are seconds from the header's `monotonic_start_ns`.

**Overhead**: `tracer.json.programs[]` and `overhead.bpf_*` are measured BPF execution times
(`BPF_ENABLE_STATS`); probe hits are the USDT programs' `run_cnt` (traced NTSync waits and wakes are
counted in BPF). The uprobe trap is not measured per run: `overhead.trap_cpu_pct_estimate` uses
`--trap-ns` (default 500 ns, measured on the laptop: traceprobe NtYieldExecution x5000 took 662 ns
per call untraced and 1795 ns traced; the entry/exit programs ran 93 + 70 ns, leaving ~485 ns per
trap). The loader's own CPU time is `overhead.loader_cpu_pct` (getrusage over the traced wall
time). All `*_cpu_pct` are percent of one CPU.

Measured with Live playing Benchmark_Inbuilts at 64 frames / 48 kHz (B5b): ~650k probe hits/s,
of which Live's AudioCalc workers make ~290 syscalls per block (NtSetEvent, NtResetEvent,
NtWaitForSingleObject, NtQueryPerformanceCounter); summary mode: BPF 470 ns per USDT run, BPF
33.9 % + traps ~26 % (estimated) + loader 18.9 % of one CPU; drill-down: BPF 942 ns per run, loader
68 %. Timing claims need an interleaved traced/untraced A/B (design B section 8): the tracer adds
~1.1 µs per syscall to the traced threads.
