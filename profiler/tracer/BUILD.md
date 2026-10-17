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

* keeps its BPF frame below 64 bytes: the stack holds only small scalars, the array-map key and
  the syscall id read from the frame (frames are 8–40 bytes, `make self-check` prints them);
* keeps per-thread scratch in the thread's own `struct tstate`, a slot of the `tstate` array map
  that the thread claims itself (compare-and-swap of `tid`, see "Cost per hit"): the
  accumulator (`ak[]`/`av[]`), the scheduler's key under construction (`sg`), `ukey`, the USDT
  arguments (`arg[]`), the NTSync wait arguments (`wa[]`), the in-flight entry stack. No other
  thread writes a thread's slot (the scheduler programs only use their own fields), and a
  thread cannot run two of its own programs at once;
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
exit 2).  B5c (0.4.0): the same in 16 option sets (summary/drilldown × sched on/off, `--ntsync
kprobe|tracepoint|off`, `--roles audio`, `--no-exit`, `--generic-args`, `--no-follow`, `--mode
sample`, `--sched-records`), largest USDT frame 40 bytes.

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

## Trap calibration (`wine-trace calibrate`)

The BPF run time of every program is measured (`BPF_ENABLE_STATS`), the cost of the probe hit
around it is not: the int3 trap (5-byte nop sites) or the optimised-uprobe entry (10-byte nop
sites on kernel 7.2), the uprobe lookup and handler chain, and the statistics bookkeeping
itself. `profiler/bin/wine-trace calibrate` (`calibrate.py`; run it as the prefix's user with
Live stopped, under the shared lock) measures it: `trapcal.exe` (`trapcal.c`, built with mingw-w64
into `build/`) makes R timed loops of N `NtYieldExecution` calls in the prefix, pinned to one CPU
at a time (`--cpu`, default `auto`: CPU 2, a P-core, and on a hybrid CPU also the first E-core;
or a list such as `2,12`), once untraced and once traced by this loader (`wine-trace start
--libbpf --pid <trapcal>`: the self-check runs before anything is attached); each call is one
`syscall_entry` and one `syscall_exit` hit:

    ns_per_trap = (traced - untraced - bpf(wine_syscall_entry) - bpf(wine_syscall_exit)) / 2

from the medians, with the two BPF run times measured in the same traced run. A third run on the
first CPU with K idle traced trapcal processes (`--extra-consumers`, default 3) gives
`ns_per_extra_consumer`: every traced process is one more consumer of the shared ntdll.so
uprobes, and a hit runs all their handlers. The record (`trap-calibration.json`: kernel,
ntdll.so path/size/mtime/sha256, the four dispatcher probe sites' bytes and kind, all repeats, the
BPF times, method; the top-level `cpu`, `untraced`, `traced` and `ns_per_trap` are the first
CPU's, `by_cpu` holds every CPU's, `ns_per_trap_by_type` the slowest per core type and
`ns_per_trap_max` the slowest CPU) goes to the run directory and to
`~/.local/state/profiler/trap-calibration.json`, which `wine-trace start` passes to the loader
(`--trap-calibration`). The loader uses it only while the kernel release and the traced ntdll.so
(path, size, mtime) match: `overhead.trap_ns_source` = `calibration` and
`overhead.trap_calibration` = the record; a stale file is named in
`overhead.trap_calibration_rejected` and a warning, and the estimate falls back to the B5b value
500 ns with `trap_ns_assumed: true` (`--trap-ns N` overrides both: source `option`). Recalibrate
after every runtime or kernel change.

The estimate is a **lower bound**: `trap_ns_per_hit` is the first CPU's figure (a P-core),
measured in a tight loop with hot caches, while Live's audio threads are not pinned and also run
on the E-cores, and miss caches. When the calibration covered several CPUs, the loader adds
`trap_ns_per_hit_max`, `trap_ns_per_block_max`, `estimate_ns_per_block_max` and
`trap_cpu_pct_estimate_max` from `ns_per_trap_max` (the slowest CPU, an E-core here), so the
overhead is a range.

Laptop, B5c (kernel 7.2.9-2-cachyos, the installed nop5 runtime, 7 x 200000 calls): CPU 2
(P-core) untraced 477.9 ns per NtYieldExecution, traced 1487.2 ns, BPF 61.6 + 45.1 ns per hit
pair, so **451.3 ns per probe hit** outside the BPF program; +5.6 ns per further traced process;
the repeats agreed within 0.5 %. `--cpu auto` (calibrate.py/2, run
`~/.local/share/profiler/runs/b5c-fixer-trapcal`): CPU 2 (P-core) 478.8 / 1480.3 ns, BPF
61.6 + 44.3 ns, so **447.8 ns**; CPU 12 (E-core) untraced 1191.4 ns, traced 2569.0 ns, BPF
103.3 + 69.2 ns, so **602.5 ns** per hit, a third more; +4.7 ns per further traced process.

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
| kernel | 7.2.9-cachyos | BTF (`/sys/kernel/btf/vmlinux`), `/sys/kernel/btf/ntsync` for the fentry NTSync probes; Linux 7.2 or later for a runtime with the 10-byte nop USDT sites (patch 0108 / pipeasio 0017: an older kernel refuses those uprobes with ENOTSUPP, error 524, and the loader says so) |

The kernel needs `CONFIG_DEBUG_INFO_BTF=y` (and BTF for the `ntsync` module for `--ntsync fentry`;
without it the loader falls back to kprobes, then to the `sys_enter/exit_ioctl` tracepoints).
Root (or CAP_SYS_ADMIN) is needed to load the programs and to read their JIT images.

## Make targets

```bash
make -C profiler/tracer            # build/vmlinux.h, build/wine-trace.bpf.o, build/wine-trace.skel.h, build/wine-trace
make -C profiler/tracer check      # build + list program sections and maps + `wine-trace --version`
make -C profiler/tracer test       # JIT prologue classifier unit test
make -C profiler/tracer test-python # the Python tests (unittest discover ... -t . from the repo root)
make -C profiler/tracer trapcal    # build/trapcal.exe (mingw-w64), the trap calibration workload
make -C profiler/tracer self-check # sudo -n: load + stack check, never attaches
make -C profiler/tracer test-gate  # sudo -n: the broken build must be refused
make -C profiler/tracer clean      # remove build/ (the test-gate build lives in build/gate/)
```

Overrides: `CLANG=`, `BPFTOOL=`, `CC=`, `BUILD=` (output directory), `VMLINUX_BTF=`,
`BPF_CPU=v3`, `BPF_EXTRA=` (extra clang flags), `SUDO=`, `MINGW=`, `PYTHON=`. Everything generated lands in `build/`
(ignored by git, so `build.sh`'s source snapshot never sees it). `vmlinux.h` enters the BPF compile
through `-isystem`, so the build prints only warnings of our own code: a clean build prints none.

**Regenerate after a kernel update**: `make -C profiler/tracer clean all self-check`. `vmlinux.h`
is a snapshot of the running kernel's BTF; CO-RE relocates field offsets at load time, but new or
renamed tracepoint arguments (`tp_btf/*`) need the new header, and a new kernel can change the
verifier's stack accounting or the JIT prologue (the self-check catches both).

**ABI**: `WINE_TRACE_ABI` in `wine-trace.h` (5 since B5c) is bumped whenever a struct shared by the two
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
    [--trap-calibration FILE] [--trap-ns N] [--sched-records] [--generic-args] [--unsafe-private-stack] -v
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
5. Main loop (25 ms): consumes the ring buffer (block phases, the threads' accumulated crossings
   in `REC_AGG` records, stack samples, drill-down events, thread names, forks, unix-library
   handles) and drains the scheduler keys. A `REC_AGG` entry is a complete key (block `seq` or
   window id, tid, kind, id, parent, flags) with its count, total, max, on-CPU time and last
   waker: user space merges partial aggregates of one key exactly as it merged agg-map keys
   (see "Cost per hit"). The scheduler programs (`--sched on`) still write `agg[(now / 100 ms) &
   3]`; slot window `W` is drained with `bpf_map_lookup_and_delete_batch` once the clock is in
   `W + 2`, so the BPF side never updates a value that user space is deleting. At stop the slots
   of the threads still alive are read for what their accumulators still hold
   (`counters.acc_entries_at_stop`) and for their per-thread counters.
6. A block is written 3 s after its `block_end`, with its crossings merged by (tid, kind, id
   name, parent), the off-CPU time of audio-role threads, and references to its stack samples; a
   100 ms thread window is written 4 s after it ends (after the blocks that started in it, whose
   crossings it includes). Keys that arrive after their block was written go to the thread's
   window of the block's end instead (`counters.keys_for_flushed_block`; `_audio` counts those of
   audio-role threads and raises a warning, since they also miss the lost-slack attribution). At
   stop everything left is flushed and the distinct stacks are written to `stacks.jsonl`.
7. Stop: sets `gl.stopping` (no block starts after that; the one in progress completes), then
   destroys the links in reverse attach order, drains and writes. Only blocks whose `block_start` the
   tracer saw get their other phases, so `blocks.incomplete` counts real gaps, not the block in
   progress at attach or the ~0.1 s link teardown. Since 0.4 a block travels as one record that
   `block_end` writes (`PHASE_BLOCK`: the start, before-Live and after-Live stamps wait in struct
   global, whose only writer is the callback thread), so the callback thread pays one ring-buffer
   reservation per block instead of four, and the `cycle_start` probe only stamps its thread
   (`cycle_end`'s record carries the stamp). A dropped block record loses the whole block
   (`ringbuf_drops_block`); `"rebuilt": true` (0.3: start fields from `BLOCK_END`) no longer occurs.

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
their place in `call_sites` (ranked by time in late blocks) with no share. Since B5c the bpftrace
prototype's `reduce.py` (its crossings carry `parent` too, header `nesting: parent`) and
`bench-report.py interface` apply the same rule, so `report.md` never counts one wait twice
(B5b's report gave NtWaitForSingleObject 37.7 % and `ntsync_wait WAIT_ANY` 37.4 % for the same
waits); `report.md` lists the nested crossings in a table of their own.
In the B5b run 95.4 % of the sampled stacks reached a Live/plugin frame (mostly one frame after the
kernelbase wrapper); `stack_window_exhausted` stops happen deeper than that.

## Output (same contract as the prototype + `reduce.py`, see README.md)

| File | Notes |
|---|---|
| `blocks.jsonl` | header record + one record per block: timing fields, `late`/`near_late` (each block's own period), `rebuilt?` (0.3 only: start fields from `BLOCK_END`), `crossings[{tid, role, kind, id, parent?, n, total_ns, max_ns, timeouts?, woken_by?}]` without `caller`, `offcpu[]` (audio roles, `--sched on`), `stacks[]` (sample references), `cycle?` |
| `blocks.symbolized.jsonl` | written by `symbolize.py` (wrapper): every crossing with `caller`, `caller_basis` (and `caller_share` when split); `stacks[]` entries with `site`, `stop` and the first frames |
| `threads.jsonl` | header + per 100 ms window x tid; includes the crossings inside blocks (window of the block start) as well as the between-block buckets; `oncpu_ns/offcpu_ns/run_delay_ns` are `null` without `--sched on` |
| `summary.json` | reduce.py's schema + `nested_call_sites` (nested kinds per parent, no `share_of_lost_slack`; see "Lost slack"); after `symbolize.py`, `call_sites`, `nested_call_sites` and `hotspots_non_audio` are per (kind, id, caller) |
| `events.jsonl` | drill-down: one record per completed crossing and NTSync wake, `caller` placeholder (`ntdll.dll!<Name>+0x14`, `pe!0x<rip>`, nested kinds their enclosing call's), `parent`, `stack_ref` = the representative of this or the enclosing entry's sample |
| `anomalies.jsonl` | drill-down: header + one record per pairing anomaly: `{t, tid, role, what: inflight_overflow\|unmatched_exit\|never_returned\|abandoned, kind, id (null when the exit does not carry it), id_num, frame, restore_flags\|status\|first_popped\|completed_index, depth, inflight[{kind, id, frame}]}` (the in-flight stack before any pop) |
| `stacks.jsonl` | `symbolize.py`'s record shape (`type: stack, ref, t, tid, pid, seq, kind, id, frame, rip, rsp, regs[20], stack_hex`) + `samples`, `in_blocks`, `tids[[tid, n]]`: one record per distinct stack |
| `tracer.json` | merged in place: `started_monotonic_ns` = the moment every probe was attached (the wrapper's pre-launch value moves to `launch_monotonic_ns`), `attached_monotonic_ns`, `stopped_monotonic_ns`, `tracer_exit: clean`, `clean_exit`, `lost_events` + `loss` (with `ringbuf_drops`, `fraction_of_hits`), `probe_hits`, `counters` (+ `acc_entries`, `acc_entries_at_stop`, `ringbuf_records.agg`; `keys_before_block_record`: keys that arrived before their block's record, normal since 0.4 writes it at `block_end`; `keys_for_unknown_block`: keys of blocks that never got a record, counted when written or given up; `keys_for_flushed_block`, `_audio`: keys that arrived after their block was written), `anomalies` (drill-down), `per_tid` (validate.py; + `never_returned`), `blocks`, `overhead_estimate_ns_per_block`, `overhead` (see "Overhead"), `programs` (run time, `recursion_misses` and stack class per program), `stack_check`, `private_stack_programs`, `private_stack_risky`, `attach`, `followed_pids`, `sample` (+ `sched_records`, `acc_slots`) |
| `maps-<pid>.txt`, `maps-<pid>-stop.txt` | written when the wrapper has not already (followed children, stop snapshots) |

`lost_events` counts crossings or blocks missing from the output: ring-buffer drops of block,
event and task/name/unixlib records, the crossings of dropped `REC_AGG` records
(`ringbuf_drops_agg_crossings`), aggregation-map overflow (scheduler keys), in-flight stack
overflow, threads without a slot, and the kernel-side programs' recursion misses: runs of the fentry/fexit, tp_btf,
kprobe/kretprobe, tracepoint and perf_event programs that the kernel skipped because the program
was already running on that CPU (`bpf_prog_info.recursion_misses`; the NTSync fentry programs are
preemptible, so a thread preempted inside one makes the next NTSync call on that CPU go unseen: a
lost wait, wait exit or wake). They are `loss.by_kind.recursion_misses` and `loss.recursion_misses`
(per program: `programs[].recursion_misses`; uprobe programs have no guard and never miss); B5b
review: 1,784 in 25 s of Benchmark_Inbuilts, where `lost_events` had said 56. Dropped stack
samples are not lost events (their crossings are counted): `loss.stack_samples_dropped`.
`loss.fraction_of_hits` relates it to the probe hits, `loss.ringbuf_drops` counts the ring
buffer's own drops. `bench-report.py interface` raises `interface-lost-events` only when the ring
buffer dropped records or the loss exceeds 0.1 % of the probe hits (the recursion misses alone are
~1e-4 of the hits on every Live run); the counts are reported either way.

All times are `bpf_ktime_get_ns()` = `CLOCK_MONOTONIC`, the suite's `time.monotonic_ns()` and
PipeWire's `clock.nsec`; offsets are seconds from the header's `monotonic_start_ns`.

**Overhead**: `tracer.json.programs[]` and `overhead.bpf_*` are measured BPF execution times
(`BPF_ENABLE_STATS`); probe hits are the USDT programs' `run_cnt` (traced NTSync waits and wakes are
per-thread counts). `overhead.bpf_ns_per_block` is every program's run time per block (USDT and
kernel-side); `overhead.trap_ns_per_hit` is the calibrated (or assumed, see "Trap calibration")
cost of one USDT hit outside its program, plus `ns_per_extra_consumer` for each further traced
process (`usdt_processes`); `trap_ns_per_block` = `usdt_hits_per_block` x `trap_ns_per_hit`, and
`estimate_ns_per_block` (= `overhead_estimate_ns_per_block`) is their sum: the NTSync fentry
programs have no trap (B5b multiplied every hit, NTSync included, by the USDT mean plus 500 ns).
The trap part is a lower bound (hot-cache P-core calibration, see "Trap calibration"); with a
calibration of several CPUs, `trap_ns_per_hit_max`, `trap_ns_per_block_max`,
`estimate_ns_per_block_max` and `trap_cpu_pct_estimate_max` use its slowest CPU.
`trap_cpu_pct_estimate` = `usdt_hits` x `trap_ns_per_hit` over the wall time;
`assumed_trap_ns_per_hit` repeats `trap_ns_per_hit` for older readers. The loader's own CPU time is
`overhead.loader_cpu_pct` (getrusage over the traced wall time). All `*_cpu_pct` are percent of one
CPU.

## Cost per hit (B5c)

Live playing Benchmark_Inbuilts at 64 frames / 48 kHz (one block per 1.333 ms) makes ~745 USDT
hits per block (Benchmark_VSTs ~800): ~263k syscall entries and as many exits per second, nearly
all from the AudioCalc workers (NtSetEvent, NtResetEvent, NtWaitForSingleObject,
NtQueryPerformanceCounter), ~12k unix calls, 3k server requests and the six PipeASIO probes per
block; the NTSync programs (fentry, no trap) add ~137k wakes and ~54k waits per second. A USDT hit
costs its trap (451 ns, "Trap calibration") plus its program. `perf record` of a traced Live run
put 0.3's BPF time into the user reads of `bpf_probe_read_user`, `bpf_ktime_get_ns`, the tid
hash-map lookup (jhash and a `bcmp` call), the agg-map update of every crossing, and ring-buffer
lock contention when all AudioCalc workers submitted at the block start. 0.4.0 (ABI 5):

* **Thread state in an array map** (`tstate`, 8192 slots): a thread's slot is the Fibonacci hash of
  its tid plus up to 3 linear probes, claimed by the thread itself with a compare-and-swap of `tid`
  and released at `sched_process_exit` (or when `sched_switch` sees the dead task); the verifier
  inlines array lookups. A thread that finds no free slot is counted (`counters.thread_state_full`)
  and not traced.
* **Per-thread accumulator**: a completed crossing is folded into the thread's own 16-slot table
  (key: block `seq` or window, kind, id, parent, flags; value: count, total, max, on-CPU time, last
  waker) instead of an agg-map update. The table travels as one `REC_AGG` record: before the thread
  blocks in an NTSync or wineserver wait (a thread without an audio role every time; an audio-role
  thread once it holds keys of two blocks or half a table), at a commit when its keys are 3 blocks
  or 50 ms old, when a new key finds it full, and at thread exit; the loader drains what is left at
  stop (`counters.acc_entries_at_stop`). An AudioCalc worker flushes about every second block,
  each at its own wait, so the workers no longer meet at the ring-buffer lock. The audio roles
  come from the loader's classifier through the `tids` map (in every mode; `--roles audio` also
  filters by it), which a thread looks up again only when the loader bumps `role_gen`. Keys of a
  thread that sleeps outside those waits (`NtDelayExecution`, unix-side `poll`) still travel at its
  next probe, which is why a block is written 3 s after its end ("What it does").
* NTSync hit counts are per-thread fields (the loader sums the slots and the exited threads'
  `REC_TASK`); the random stack sampler counts down per thread (one `bpf_get_prandom_u32` per
  sample); a stack window stops at the thread's first unreadable page (one fault per stack, not
  per sample); the slack trigger reads its per-block budget before its atomic add, which has a
  cache line of its own; the NTSync programs find a thread by its slot and look at the pid map
  only for threads without one; no record forces a consumer wakeup (`BPF_RB_NO_WAKEUP`, the loader
  polls every 25 ms).
* **PipeASIO**: a block is one record (`PHASE_BLOCK`) that `block_end` writes; `block_start`,
  `before_live` and `after_live` stamp struct global, `cycle_start` stamps its thread (its five
  operands and its own record made it the most expensive program per run).
* **Scheduler programs** (drill-down, `--sched on`): the pid map first (a slot lookup of an untraced
  task would probe four cold slots), and the per-interval `REC_WAKE` / `REC_OFFCPU` records only
  with `--sched-records` (the loader only counted them; off-CPU time reaches `blocks.offcpu` and
  `threads.jsonl` through the agg keys).

Measured on the laptop (kernel 7.2.9-2-cachyos, installed nop5 runtime, `profiler/bin/bench
--trace interface|drilldown`, 30 s per set; before = 0.3.1 / ABI 4 as installed, after = 0.4.0;
runs `~/.local/share/profiler/runs/20261017T171827Z-b5c-a2-before`, `…T182019Z-b5c-a2-after4`,
`…T181419Z-b5c-a2-before-drill`, `…T182333Z-b5c-a2-after4-drill`). ns per run (runs per second
within 2 % before and after, the unix calls within 10 %):

| Program (runs/s, Inbuilts) | summary Inbuilts | summary VSTs | drill-down Inbuilts |
|---|---:|---:|---:|
| `wine_syscall_entry` (263k) | 138 → **100** | 140 → **100** | 447 → 263 |
| `wine_syscall_exit` (263k) | 170 → **95** | 173 → **96** | 637 → 582 |
| `fe_ntsync_obj_ioctl` (137k, wakes) | 78 → **43** | 79 → **40** | 348 → 283 |
| `fe_ntsync_char_ioctl` (54k, wait entry) | 124 → 142 | 125 → 137 | 115 → 157 |
| `fx_ntsync_char_ioctl` (54k, wait exit) | 278 → **132** | 287 → **131** | 733 → 649 |
| `wine_unixcall_entry` / `_exit` (12k) | 86 / 99 → **69** / **58** | 80 / 96 → **65** / **55** | 190 / 215 → 171 / 140 |
| `wine_server_req_start` / `_end` (3k) | 141 / 299 → 134 / 187 | 151 / 296 → 149 / 193 | 137 / 477 → 144 / 321 |
| `pipeasio_block_start` (751) | 901 → 724 | 1297 → 1117 | 1019 → 1060 |
| `pipeasio_block_before_live` / `_after_live` | 229 / 299 → 219 / 181 | 262 / 287 → 262 / 186 | 292 / 260 → 238 / 206 |
| `pipeasio_block_end` | 284 → 310 | 254 → 310 | 303 → 292 |
| `pipeasio_cycle_start` / `_end` (750) | 1060 / 212 → 446 / 202 | 1414 / 201 → 654 / 192 | 950 / 227 → 526 / 231 |
| `on_sched_switch` (135k) / `on_sched_waking_irq` (68k) | | | 381 / 360 → 266 / 98 |
| **USDT mean** | 155 → **99** | 158 → **100** | 524 → 410 |

| Per block | summary Inbuilts | summary VSTs | drill-down Inbuilts |
|---|---:|---:|---:|
| BPF, all programs (`bpf_ns_per_block`) | 159.2 → **101.1 µs** | 173.5 → **108.9 µs** | 617.3 → 473.1 µs |
| BPF, % of one CPU | 11.9 → **7.6** | 13.0 → **8.2** | 46.3 → 35.5 |
| traps: USDT hits x 451 ns | 337.8 → 335.5 µs | 359.4 → 361.6 µs | 337.2 → 336.7 µs |
| BPF + traps, % of one CPU | 37.3 → 32.7 | 40.0 → 35.3 | 71.6 → 60.7 |
| loader, % of one CPU | 5.9 → 5.7 | 6.0 → 5.9 | 41.9 → 42.1 |
| lost events (fraction of hits; ring-buffer drops) | 1943 → 1225 (5.0e-5; 0) | 2426 → 1464 (5.5e-5; 0) | 4740 → 5523 (2.2e-4; 0) |

The lost events are all NTSync fentry recursion misses (preempted programs, see "Output"). Every
program that runs more than 10,000 times a second is at 150 ns or less in summary mode (the
syscall pair at 95-100 ns); `wine_server_req_end` (3k/s) is at ~190 ns. `pipeasio_block_start` (six
`bpf_usdt_arg` calls) and `cycle_start` (a slot lookup and a timestamp, nothing else) stay at
0.45-1.1 µs per run, probably cache misses (they are the first programs their threads run after a
wakeup; not measured); the six PipeASIO programs cost 2.1-2.7 µs per block. The trap is now
three quarters of the cost (~336 µs of ~437 µs per block in summary mode, ~1.1 µs per traced
syscall on the AudioCalc workers): the next step is the 10-byte nop sites (optimised uprobes), after
which `wine-trace calibrate` has to be rerun. (B5b's notes gave ~650k hits/s, BPF 470 ns per USDT
run, BPF 33.9 % + traps ~26 % + loader 18.9 % of one CPU and, in drill-down, BPF 942 ns per run and
loader 68 % for the same set; the "before" column is the B5b commit's 0.3.1 build measured on the
same day as the "after" column.) Timing claims still need an interleaved traced/untraced A/B
(design B section 8).

Late keys (the review's fix: audio roles in `tids`, threads without one flush before every wait,
blocks written after 3 s; runs `~/.local/share/profiler/runs/b5c-fixer-summary` and
`…/b5c-fixer-drill` against `after4` above, same sets): `counters.keys_for_flushed_block` 470 → 2
(Inbuilts), 609 → 24 (VSTs), 619 → 32 (drill-down), none of them of audio-role threads
(`keys_for_flushed_block_audio` 0); `REC_AGG` records +0.5 to +2.8 %; USDT mean 89.6 / 98.3 ns per
run (Inbuilts / VSTs) and `fe_ntsync_char_ioctl` 127 / 132 ns, i.e. within run-to-run noise of
`after4`; `wine_server_wait_start` (3 runs/s) went from ~0.45 to ~0.65 µs per run (its ring-buffer
reservation).
