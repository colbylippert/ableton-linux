# Building the production tracer (`build/wine-trace`)

The libbpf CO-RE tracer of design B section 3b: `wine-trace.bpf.c` (kernel side), `wine-trace.c`
(loader, reduction and output writer), `wine-trace.h` (shared structs and constants). It is built
on the Linux machine that runs it, never shipped: `vmlinux.h` comes from that kernel's BTF.
`profiler/bin/wine-trace` uses `build/wine-trace` only when asked (`--libbpf` or
`WINE_TRACE_BACKEND=libbpf`); the default is the bpftrace prototype while the loader is disabled
(below), so `make` alone never breaks a suite trace.

## BLOCKER: disabled by default (B5 live test, kernel 7.2.9-cachyos)

On the first attach to Live the kernel oopsed inside `wine_syscall_exit`. The failing load read a
pointer through `r9`, which holds a per-CPU address. That means the verifier had given the program
a **per-CPU private stack**. Since 6.13 it does this ("adaptive") for `BPF_PROG_TYPE_KPROBE`
programs, uprobes included, whose stack is at least 64 bytes. Uprobe programs are preemptible,
though, so two runs on one CPU share that stack: a spilled pointer was overwritten by a
`bpf_ktime_get_ns()` value (`0xd32a9f8c8fc`). The oops killed Live's `pipeasio-rt` thread, so audio
blocks stopped after 306. It also left uprobe unregistration stuck in `synchronize_srcu`: the
tracer is in D state and only a reboot clears it.

Every USDT program here uses 184–304 bytes of stack (`llvm-objdump -d build/wine-trace.bpf.o`,
largest `r10 - N` per program). `pipeasio_block_*` and `on_task_rename` are the only ones under 64.
Until every uprobe program, subprograms included, is below 64 bytes, the loader refuses to run.
The fix is to keep temporaries in a per-tid map value instead of on the stack: per-CPU scratch
races for the same reason. `--unsafe-private-stack` overrides this guard, for synthetic workloads
only and never against Live.

The synthetic USDT workload (fake `ntdll.so`/`pipeasio64.dll.so`) traced cleanly with this build.
It ran on the same kernel before the Live test.

## Prerequisites (CachyOS / Arch)

```bash
sudo pacman -S --needed clang bpf libbpf libelf zlib gcc make
```

| Tool | Tested | Why |
|---|---|---|
| clang | 23 | `-target bpf` |
| bpftool (`bpf` package) | 7.8 | `btf dump` (vmlinux.h) and `gen skeleton` |
| libbpf | 1.7 | USDT attach (`bpf_program__attach_usdt`, needs >= 1.0), ring buffer, batch map ops |
| gcc / cc | 16 | the loader (`-Wall -Wextra` clean) |
| kernel | 7.2.9-cachyos | BTF (`/sys/kernel/btf/vmlinux`), `/sys/kernel/btf/ntsync` for the fentry NTSync probes |

The kernel needs `CONFIG_DEBUG_INFO_BTF=y` (and BTF for the `ntsync` module for `--ntsync fentry`;
without it the loader falls back to kprobes, then to the `sys_enter/exit_ioctl` tracepoints).

## Make targets

```bash
make -C profiler/tracer            # build/vmlinux.h, build/wine-trace.bpf.o, build/wine-trace.skel.h, build/wine-trace
make -C profiler/tracer check      # build + list program sections and maps + `wine-trace --version`
make -C profiler/tracer clean      # remove build/
```

Overrides: `CLANG=`, `BPFTOOL=`, `CC=`, `BUILD=` (output directory), `VMLINUX_BTF=`,
`BPF_CPU=v3`. Everything generated lands in `build/` (ignored by git, so `build.sh`'s source
snapshot never sees it). `vmlinux.h` enters the BPF compile through `-isystem`, so the build prints
only warnings of our own code: a clean build prints none.

**Regenerate after a kernel update**: `make -C profiler/tracer clean all`. `vmlinux.h` is a snapshot
of the running kernel's BTF; CO-RE relocates field offsets at load time, but new or renamed
tracepoint arguments (`tp_btf/*`) need the new header.

**ABI**: `WINE_TRACE_ABI` in `wine-trace.h` is bumped whenever a struct shared by the two sides
changes; the loader and the BPF object are always built together, so a stale `build/` is the only
way to mix them (`make clean all`).

## Running

Through the wrapper (the normal way; it discovers the prefix pids, snapshots the maps, writes the
start fields of `tracer.json`, runs `symbolize.py` after stop and chowns the directory):

```bash
sudo -n profiler/bin/wine-trace start --out DIR [--pid P]... [--run-id TOKEN] [--mode summary|drilldown]
sudo -n profiler/bin/wine-trace stop  --out DIR
sudo -n profiler/bin/wine-trace run   --out DIR --duration 30
```

Directly (what the wrapper runs; root needed for uprobe/fentry attach):

```bash
sudo -n profiler/tracer/build/wine-trace --out DIR --pid LIVE_PID --pid WINESERVER_PID \
    [--mode summary|drilldown|sample] [--duration S] [--ntsync auto|fentry|kprobe|tracepoint|off] \
    [--sched on|off] [--run-id T] [--sample 1/N] [--stack-bytes N] [--keep-stacks none|late|all] \
    [--roles audio|all] [--no-exit] [--slack-threshold PCT] [--near-late-fraction F] [--ringbuf-mb N] \
    [--trigger-ids ID,...] [--tables FILE] [--ntdll PATH] [--pipeasio PATH] [--no-follow] [--trap-ns N] -v
```

Without `--duration` it runs until SIGINT/SIGTERM, then detaches, drains and writes. It prints
`attached monotonic_start_ns=N probes=P links=L` on stdout once every probe is attached.

## What it does

1. Reads `/proc/PID/maps` of every `--pid` for `.../x86_64-unix/ntdll.so` and
   `pipeasio64.dll.so` (`--ntdll`/`--pipeasio` override), the Wine version
   (`ABLETON-WINE-BUILD-INFO.txt` of the runtime, else the path) and the id table
   (`--tables`, else `../tables/wine-<version>.json` next to the binary).
2. Opens the skeleton, sizes the ring buffer, enables only the programs it will attach (NTSync
   variant, scheduler programs for `--sched on`, the irq-aware `sched_waking` variant when
   `__preempt_count` is in vmlinux BTF, the perf program for `--mode sample`) and loads it. A load
   failure with `--ntsync auto` retries with the next NTSync variant; the verifier log is printed by
   libbpf.
3. Fills `cfg`, `pids` (and `tids` for `--roles audio`), attaches the kernel programs, then the 8
   `wine:` probes and, where the driver is mapped, the 6 `pipeasio:` probes per pid
   (`bpf_program__attach_usdt(prog, pid, path, provider, name)`, so the breakpoints exist only in
   the traced processes). Children forked by a traced process are added to `pids` in the kernel at
   once and get their USDT probes as soon as their maps show `ntdll.so` (15 s limit).
4. Main loop (25 ms): consumes the ring buffer (block phases, stack samples, drill-down events,
   thread names, forks, unix-library handles) and drains the aggregation. Every aggregated key is
   written at completion time into `agg[(now / 100 ms) & 3]`; slot window `W` is drained with
   `bpf_map_lookup_and_delete_batch` once the clock is in `W + 2`, so the BPF side never updates a
   value that user space is deleting. Keys are merged by their own `seq` (block) or window id.
5. A block is written 0.7 s after its `block_end`, with its crossings merged by (tid, kind, id
   name), the off-CPU time of audio-role threads, and its stack samples; a 100 ms thread window is
   written 2.5 s after it ends. At stop everything left is flushed.

## Output (same contract as the prototype + `reduce.py`, see README.md)

| File | Notes |
|---|---|
| `blocks.jsonl` | header record + one record per block: timing fields, `late`/`near_late` (each block's own period), `crossings[{tid, role, kind, id, n, total_ns, max_ns, timeouts?, woken_by?}]` without `caller` (callers come from `stacks`, which `bench-report.py interface` apportions per (tid, kind, id)), `offcpu[]` (audio roles, `--sched on`), `stacks[]`, `cycle?` |
| `threads.jsonl` | header + per 100 ms window x tid; includes the crossings inside blocks (window of the block start) as well as the between-block buckets; `oncpu_ns/offcpu_ns/run_delay_ns` are `null` without `--sched on` |
| `summary.json` | reduce.py's schema; `call_sites` and `hotspots_non_audio` are per (kind, id) with `caller: "*"`; `tracer.overhead` and `tracer.programs` carry the measured BPF cost |
| `events.jsonl` | drill-down: one record per completed crossing (`stack_ref` = the sample of this or the enclosing entry) |
| `stacks.jsonl` | `symbolize.py`'s record shape (`type: stack, ref, t, tid, pid, seq, kind, id, frame, rip, rsp, regs[20], stack_hex`). `--keep-stacks late` (summary default) keeps only the samples of late and near-late blocks, which are also inlined into those blocks' `stacks[]` so the wrapper's `symbolize.py --blocks` run resolves them; `all` (drill-down default) keeps every sample and puts `{ref, t, tid, kind, id}` references into the other blocks |
| `tracer.json` | merged in place: `started_monotonic_ns` becomes the moment every probe was attached (the wrapper's pre-launch value moves to `launch_monotonic_ns`), plus `attached_monotonic_ns`, `stopped_monotonic_ns`, `lost_events` (ring-buffer drops + aggregation-map full + in-flight overflow), `probe_hits`, `counters`, `blocks`, `overhead_estimate_ns_per_block`, `overhead`, `programs` (verifier instruction counts and run time per program), `attach`, `followed_pids` |
| `maps-<pid>.txt`, `maps-<pid>-stop.txt` | written when the wrapper has not already (followed children, stop snapshots) |

All times are `bpf_ktime_get_ns()` = `CLOCK_MONOTONIC`, the suite's `time.monotonic_ns()` and
PipeWire's `clock.nsec`; offsets are seconds from the header's `monotonic_start_ns`.

**Overhead**: the loader enables `BPF_STATS_RUN_TIME` while it runs, so `tracer.json.programs[]`
and `overhead.bpf_*` are measured BPF execution times; the uprobe trap itself is not measured
(`overhead.estimate_ns_per_block` adds `--trap-ns`, default 1000 ns, per hit). The loader's own
CPU time is `overhead.loader_cpu_pct` (getrusage over the traced wall time).
