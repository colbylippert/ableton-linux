# profiler/tracer — Wine interface tracer

Traces the Windows→Wine crossings of Ableton Live (NT syscalls, unix calls, wineserver
requests/waits, NTSync waits and wakes) and joins them to PipeASIO audio blocks. Design:
`../../plans/design-B-tracer-and-probes.md` (sections 3a, 3b, 9); the `summary.json` shape
follows `../../plans/design-C-control-suite-agent-loop.md` section B.

Two backends write the same files. The **libbpf production tracer** (`wine-trace.bpf.c` +
`wine-trace.c`, built into `build/wine-trace` by `make -C profiler/tracer`; `BUILD.md`) aggregates
in the kernel, samples stack windows and gives every crossing a real caller through
`symbolize.py`. `profiler/bin/wine-trace` uses it by default when it is built **and** its stack
self-check passes (every uprobe/USDT program must run on the kernel stack, never on the kernel's
per-CPU private stack, which preemptible uprobe programs corrupt); otherwise it falls back to the
**bpftrace prototype** (`wine-trace.bt` + `reduce.py`) and prints why (`tracer.json`
`backend_reason`). `--libbpf` / `--proto` (or `WINE_TRACE_BACKEND=libbpf|bpftrace`) force a
backend; a forced libbpf start still fails when the loader's own pre-attach self-check refuses.

| File | Role |
|---|---|
| `wine-trace.bpf.c`, `wine-trace.c`, `wine-trace.h`, `Makefile` | libbpf tracer: kernel side, loader/reducer, shared structs and the JIT prologue classifier (`BUILD.md`) |
| `wine-trace.bt` | bpftrace 0.27 template: one text line per event (USDT probes of patch 0108 / pipeasio 0017, kernel-side NTSync `fentry`, optional scheduler and child-follow probes). Never run directly: `profiler/bin/wine-trace` rewrites it. |
| `reduce.py` | Offline join of the prototype's event lines into `blocks.jsonl`, `threads.jsonl`, `summary.json` (+ `events.jsonl` in drilldown); updates `tracer.json`. |
| `symbolize.py` | Module maps, PE `.pdata` unwinder, caller apportionment (`blocks.symbolized.jsonl`, `summary.json` call sites per caller), roles table (design B sections 4-5). |
| `gen_tables.py` | Generates `tables/wine-<ver>.json` (syscall ids, wineserver request numbers, unix-call codes) from a patched Wine tree. |
| `tables/wine-11.13.json` | Generated from the 11.13 base + the 96-patch series (`series-aceb236`) + 0108 (table inputs unchanged by 0108), protocol 957. |
| `validate.py` | Compares a traced `tools/traceprobe.exe` run (its `EXPECT` lines) and PipeASIO telemetry with the tracer's output (design B section 7). |
| `tests/test_reduce.py`, `tests/test_bt_template.py`, `tests/test_gen_tables.py`, `tests/test_validate.py`, `tests/test_symbolize.py`, `tests/test_jit_classifier.py` (+ `.c`) | `python3 -I -m unittest discover -s profiler/tracer/tests -v` from the repo root; the C classifier test also runs as `make -C profiler/tracer test`. |
| `../bin/wine-trace` | The CLI (`start`/`stop`/`run`/`status`) shared with the suite and the root helper. |

## Callers (libbpf backend)

A crossing's `caller` in `blocks.symbolized.jsonl` and in `summary.json` `call_sites` /
`hotspots_non_audio` is a real chain from the sampled stack windows: the frames after the syscall
stub up to and including the first application frame (Live or a plugin, `module+offset`, never
disassembled), e.g. `kernelbase.dll!WaitForSingleObject+0x49 <- Ableton Live 12 Trial.exe+0x4f8c119`;
native runtime DLLs of the prefix (`msvcp140.dll`, `vcruntime*`, `ucrtbase`, anything under
`drive_c/windows/system32`) are walked past to the code that called them.
Stacks are sampled at syscall / unix-call entries (1/64 in summary, 1/4 in drilldown, plus up to 16
per block once the block is within 15 % of its period of the deadline). Unsampled crossings are
apportioned to the callers sampled for the same (tid, kind, id) in the same block
(`caller_basis: block`), else in the whole run (`run`); server requests and NTSync waits/wakes use
their enclosing call's samples (`parent-block`, `parent-run`); `unsampled` when that thread never
sampled the id. `scripts/bench-report.py interface` ranks call sites by these callers (it prefers
each crossing's recorded caller). The libbpf `summary.json` ranks the nested kinds apart
(`nested_call_sites`) and shares each late block's lost slack among the top-level crossings of
audio-role threads only (BUILD.md, "Lost slack"); the reducer's summary and `bench-report.py`
still share it among all crossings.

## Running (passwordless `sudo -n`)

```bash
sudo -n profiler/bin/wine-trace start --out "$RUN/raw/interface" --mode summary      # pids discovered
sudo -n profiler/bin/wine-trace start --out DIR --pid 4200 --pid 4100 --run-id TOKEN  # suite style
sudo -n profiler/bin/wine-trace status --out DIR                                      # exit 0 running, 3 not
sudo -n profiler/bin/wine-trace stop  --out DIR                                       # SIGINT, reduce, chown
sudo -n profiler/bin/wine-trace run   --out DIR --duration 30 --mode drilldown        # start+sleep+stop
```

`start` options: `--pid P` (repeatable; without it the prefix pids come from
`scripts/lib/lifecycle.sh` `ableton_prefix_pids`, evaluated with the invoking user's `HOME`, and
`--run-id TOKEN` keeps only processes carrying `ABLETON_BENCH_RUN_ID=TOKEN`), `--mode
summary|drilldown` (drilldown also writes `events.jsonl` and enables the scheduler probes),
`--libbpf` / `--proto` (force a backend; default: libbpf when built and its `--self-check` passes,
see above), `--allow-private-stack` (prototype only: trace although a multi-thread USDT program
landed on a per-CPU private stack, see "Stack budget" below), `--no-ntsync` (strip the
kernel-side NTSync probes), `--sched`/`--no-sched`, `--no-follow` (no exec/rename tracking),
`--no-pid-filter` (trace every process mapping ntdll.so), `--wine-root DIR`, `--prefix DIR`,
`--tables FILE`, `--attach-timeout S`.

What `start` does with the libbpf backend: resolves the libraries and snapshots maps and threads
as below, runs `build/wine-trace --self-check` with the run's options (report in
`stack-check.json`; a failure falls back to bpftrace), daemonises `build/wine-trace` with `setsid`
(pidfile `DIR/wine-trace.pid`, `wine-trace.stdout`, `wine-trace.stderr`) and waits for its
`attached monotonic_start_ns=N` line (the loader checks every program's stack again before it
attaches; exit 2 = refused). `stop` sends SIGINT, records `tracer_exit` (`clean` when the loader
merged its final fields into `tracer.json`; `killed`, `crashed`, `no-end` otherwise) and runs
`symbolize.py --blocks --stacks --summary` (`blocks.symbolized.jsonl`; `WINE_TRACE_SYMBOLIZE_EVENTS=1`
also writes `events.symbolized.jsonl`). The libbpf tracer's files are described in `BUILD.md`.

What `start` does with the bpftrace backend: resolves `ntdll.so` and `pipeasio64.dll.so` from the pids' `/proc/PID/maps`
(fallback `$ABLETON_WINE_ROOT/lib/wine/x86_64-unix/`), snapshots the maps to `maps-<pid>.txt`,
lists the available probes with `bpftrace -l`, writes `DIR/wine-trace.bt` (sections and absent
probes stripped, placeholders substituted), checks it with `bpftrace --dry-run` (if the NTSync
probes are the reason it fails, they are dropped and the script is retried; the dry run's warnings
stay in `dry-run.log`), writes the threads alive at start as `T` lines to `tasks-start.txt` (and
seeds `@tids` with them), daemonises `bpftrace -q -B full --no-warnings` with `setsid` (pidfile
`DIR/wine-trace.pid`, stdout `events.txt`, stderr `bpftrace.stderr`; `--no-warnings` is part of
the stack budget below and also keeps 0.27's warnings, echoed with the script source on stdout,
out of `events.txt`), waits for the `hdr` line (printed by `BEGIN`, i.e. after every probe
attached), checks the clock domain (the `hdr` timestamp must lie between python's
`time.monotonic_ns()` read before the launch and after the `hdr` appeared; a CLOCK_BOOTTIME stamp
fails and `start` exits 1), checks the JIT prologue of every loaded program with `bpftool` (a
multi-thread USDT program on a per-CPU private stack stops the tracer and `start` exits 1 unless
`--allow-private-stack`) and writes `tracer.json` (`clock: "monotonic"`, `clock_check` with both
readings and CLOCK_BOOTTIME for reference, `private_stack_programs`, `private_stack_risky`,
`private_stack_allowed`). `stop` snapshots the maps and threads again (`maps-<pid>-stop.txt`,
`tasks-stop.txt`), reads the programs' `recursion_misses` (bpftool), sends SIGINT (TERM after
`--stop-timeout`, then KILL), records `tracer_exit` in `tracer.json` (`clean` when the `end` line is
in `events.txt`; `crashed` when `bpftrace.stderr` shows an abort; `killed`, `no-end`,
`exited-before-stop`), runs `reduce.py --recursion-misses N`, builds `maps.json`
(`{"type":"maps","snapshots":[{"t","pid","text"}]}`) and, when `symbolize.py` exists, runs
`symbolize.py --blocks blocks.jsonl --maps maps.json --out blocks.symbolized.jsonl --symcache
symcache.json --imports-out imports.json` (non-fatal; the prototype records no stack windows, so
this validates the pipeline and dumps Live's import table), then chowns `DIR` to
`SUDO_UID:SUDO_GID`.

Exit codes: 0 ok, 1 error, 2 usage, 3 not running (`status`). Fails fast when `ntdll.so` has no
`wine:` USDT notes (runtime built without patch 0108) or bpftrace is missing.

## Event line format (`events.txt`, contract between `wine-trace.bt` and `reduce.py`)

All timestamps are `nsecs(monotonic)` (CLOCK_MONOTONIC, the suite's `time.monotonic_ns()` and
PipeWire's `clock.nsec` base; plain `nsecs` is CLOCK_BOOTTIME in bpftrace 0.27 and differs by the
suspended time on a laptop that has slept); hex fields
have no `0x` prefix; `seq` is the block in progress at the probe (0 = none). Format 3 (B5) is
shaped by the stack budget (below): a 32-bit field printed right after the tid shares its 8-byte
slot, so several lines moved fields; `reduce.py` still reads formats 1 and 2.

| Line | Meaning |
|---|---|
| `hdr mono_start_ns=N format=3 clock=monotonic` | `BEGIN`: base for every `offset_seconds` (format 1 = the pre-B5 script: no `@emitted`, boot-clock `nsecs`; format 2 = the first B5 script) |
| `T ts tid pid comm=NAME` | a thread: `task:task_newtask` for threads created while tracing (`pid` = the new task's process); `tasks-start.txt` / `tasks-stop.txt` (written by the wrapper, `ts` = its own monotonic stamp) for every thread alive at start/stop. Comm may contain spaces. Format 1/2 printed first-sight `T` lines from the USDT probes. |
| `N ts tid comm=NAME` | `task_rename` (Wine writes `SetThreadDescription` names to comm) |
| `P ts pid parent=PPID comm=NAME` | exec of a child of a traced process (now traced too) |
| `E ts tid syscall ID fr=FRAME seq=S` | `wine:syscall_entry` (format 1/2 added `rsp=`/`rip=`, the user stack pointer / `NtXxx+0x14`) |
| `X ts tid syscall st=STATUS fr=FRAME` | `wine:syscall_exit`; paired by frame (format 1/2: `X ts tid syscall ID fr= st= rf=RESTORE_FLAGS`) |
| `E ts tid unixcall c=CODE h=HANDLE seq=S` | `wine:unixcall_entry`, first program (format 1/2: `E ts tid unixcall HANDLE:CODE fr= seq= rip=`) |
| `R ts tid fr=FRAME rip=X` | `wine:unixcall_entry`, second program: frame and PE caller of the unix call that the same thread entered just before (joined within 1 ms) |
| `X ts tid unixcall st=STATUS fr=FRAME` | `wine:unixcall_exit` |
| `S ts tid req TYPE dur=NS seq=S` | one wineserver request (`server_req_end`; start = ts − dur; 64-bit dur, 32-bit seq, no status) |
| `S ts tid wait FLAGS dur=NS st=STATUS seq=S` | one `wait_select_reply` (`server_wait_end`; 64-bit dur: INFINITE waits of idle threads last any time) |
| `B ts tid start seq=S n=FRAMES rate=HZ clk=NS dl=NS` | `pipeasio:block_start` (clock_nsec, deadline_ns absolute) |
| `B ts tid before seq=S` / `after seq=S` | `block_before_live` / `block_after_live` |
| `B ts tid end seq=S fl=FLAGS missed=N` | `block_end`; flags bit0 admitted, bit1 time_info, bit2 muted |
| `C ts tid start clk= next= dur= pos= fl=` / `C ts tid end missed= delivered=` | `pipeasio:cycle_start/end` (when built) |
| `W ts tid cmd=IOCTL count= alert= owner= seq=S` | NTSync `WAIT_ANY` (0xc0284e82) / `WAIT_ALL` (0xc0284e83) entry |
| `w ts tid ret=R idx=I` | the wait's exit (`ret` 0 / −ETIMEDOUT / −EINTR / −EOWNERDEAD) |
| `K ts tid pid cmd=IOCTL seq=S` | NTSync wake: `EVENT_SET` 0x80044e88, `EVENT_PULSE` 0x80044e8a, `SEM_RELEASE` 0xc0044e81, `MUTEX_UNLOCK` 0xc0084e85 |
| `U ts waker_tid waker_pid wakee=TID` | `sched_waking` of a traced thread (`--sched`) |
| `O ts_on tid off=TS_OFF wake=TS_WAKE st=PREV_STATE` | one off-CPU interval of a traced thread (`--sched`) |
| `end mono_end_ns=N` | `END` |
| `@emitted[CODE]: N` | after `end`: printfs issued per line kind (`CODE` = ASCII code of the line letter, 69 = `E`; 101 = `e`: format 3's unix-call `E` line, which also stands for its uncounted `R` line) |
| `Lost N events` | bpftrace's own drop report (counted; hidden by `--no-warnings`, and 0.27 prints none for ring-buffer drops anyway) |

Lost events: bpftrace 0.27 drops ring-buffer records silently (verified: an overload test lost
~28k of 3.7M records without any message), so every printf also bumps `@emitted[CODE]`. `END`
clears `@pids` first (no new event passes the pid filter), then prints `end` and `@emitted`.

    lost_events = max(reported, shortfall) + recursion_misses

* `reported` = `Lost N events` lines + `--lost-events-extra` (the wrapper's count from
  `bpftrace.stderr`); they count the same dropped records as the shortfall, so the two are never
  added;
* `shortfall` = Σ per kind max(0, emitted − received lines) (`T` lines from `tasks-*.txt` are not
  received lines);
* `recursion_misses` = `--recursion-misses`: the fentry/fexit runs the kernel skipped because the
  program was already active on that CPU (bpftool `recursion_misses`, read by `wine-trace stop`
  before SIGINT); their `W`/`w`/`K` lines were never emitted (B5 review run: 2612 in 20 s).

Lines received beyond `@emitted` (printed while the counters were read) are
`received_after_counters`; they can hide a shortfall of the same size, so `loss.lower_bound` is
then true. A format ≥ 2 trace without `@emitted` (bpftrace crashed or was killed: no `END`) gets
`lost_events: null` and a warning, never a silent 0, and its `stopped_monotonic_ns` is its last
event, not the wrapper's stop time. `summary.json` `tracer.loss` and `tracer.json` `loss` carry the
evidence (`source`, `lower_bound`, `reported_by_bpftrace`, `recursion_misses`, `by_kind`,
`emitted`, `received`, `received_after_counters`). `bench-report.py interface` turns a null
`lost_events`, `clean_exit: false` or a `tracer_exit` other than `clean` into the
`interface-tracer-unclean` confounder, a non-zero count into `interface-lost-events` and a
non-empty `private_stack_risky` into `interface-tracer-private-stack`.

## Stack budget (format 3)

USDT programs run preemptible with no recursion guard. Since 6.14 the verifier gives a
`BPF_PROG_TYPE_KPROBE` program with a frame of 64 bytes or more a per-CPU private stack, so two
threads entering the same program on one CPU share its frame and their events mix (B4/B5: the
`std::bad_alloc` aborts with two printfs per program, the libbpf loader's kernel oops). The
multi-thread ntdll programs therefore stay below 64 bytes. Measured with `bpftool prog dump jited`
on the generated script (kernel 7.2.9, bpftrace 0.27):

| Change | Effect |
|---|---|
| `--no-warnings` | smaller frames (presumably no runtime helper-error checks are compiled in); without it 6 of the 10 ntdll programs (and most pipeasio, fentry and tracepoint programs) land on the private stack |
| printf record ≤ 40 bytes (8-byte id + 4 slots) | 40–48 byte frames with the `@emitted` count and the pid filter; a 40-byte record with warnings on, or a 48-byte record, crosses 64 |
| a u32 printed right after the tid | shares the tid's slot (`X` prints `st` before `fr`: 32 bytes instead of 40) |
| unix-call entry split into `E` + `R` | `R` (40-byte record) has no `count()`; `E` counts under 101 for both |

`wine-trace start` checks every program's JIT prologue (`movabs …,%r9; add %gs:…,%r9` = private
stack) and refuses to trace when a multi-thread USDT program is among them; the pipeasio programs
(one callback thread) and fentry/fexit/tracepoint programs (recursion-guarded or non-preemptible)
may use it. `tests/test_bt_template.py` pins the record sizes statically.

Other lines starting with `@` and anything unknown are ignored (the unknown ones counted).

## Reduction rules (`reduce.py`)

* Lines are sorted by (timestamp, file order) (bpftrace drains per-CPU buffers; the file is not
  ordered). Inputs above `--sort-chunk-lines` (default 2,000,000) are sorted in runs under a
  temporary `.reduce-sort-*` directory in the output directory (`--sort-dir`) and merged; the
  directory is removed afterwards. Crossings are aggregated as they complete (per block, per
  100 ms window, per call site), so memory follows blocks × call sites, not events; only
  `--mode drilldown` keeps the event list (for `events.jsonl`). A block's crossings are buffered
  until its `end` line decides whether it gets a record; crossings of blocks that never end go
  to the window buckets (`events_for_unknown_block`).
* `E`/`X` are paired per tid in LIFO order by frame pointer. An `X` matching an entry below the top
  pops the entries above it as `abandoned_entries` (user-mode callbacks leave through
  `NtCallbackReturn`). An `X` matching nothing is an `unmatched_exit` (NtContinue, the unix-call
  slow path); the sub-counter `unmatched_exits_first_on_tid` counts thread starts and calls entered
  before tracing (format 3 prints no restore_flags, so the former
  `unmatched_exits_with_restore_flags` split is gone).
* A format-3 unix-call `E` line gets its frame and PE caller from the `R` line of the same tid
  within 1 ms (`unixcall_entries_without_r`, `unixcall_r_lines_unmatched`,
  `unixcall_r_lines_too_late` count the misses).
* `S`, `W`/`w` and `K` nest inside the innermost open entry of their tid and inherit its caller.
* Block association (design B section 3b): the `seq` printed at entry decides. `seq > 0` →
  that block's `crossings`; `seq == 0` → the 100 ms window bucket of the thread (`threads.jsonl`),
  flagged `between_blocks` for the callback thread. An exit never moves an event.
* `late` = `slack_ns < 0`; `near_late` = `0 ≤ slack_ns < near_late_fraction × period` (the mode
  of `period_ns`; exclusive of `late`). `lost_slack.total_ns` = Σ over late and near-late blocks of
  `near_late_slack_ns − slack_ns`; each block's lost slack is attributed to its crossings in
  proportion to their `total_ns`, capped at the crossing time (`attributed_ns`), the rest is
  `unattributed_ns`. `call_sites` are ranked by `total_ns_in_late_blocks`, then count.
* Caller placeholders until `symbolize.py` runs: syscalls `ntdll.dll!<Name>+0x14` /
  `win32u.dll!<Name>+0x14` (the stub return address is always +0x14), unix calls `pe!0x<rip>`,
  nested kinds inherit. Unix-call ids are `<module>.so:<code name>` when the handle falls inside
  a `.so` mapping of the snapshots and the table knows the code, else `<module>.so#<code>`.
* Roles (design B section 5): `pipeasio_callback` is the tid firing `block_start`; every other
  thread goes through the shared classifier `symbolize.load_roles()` + `roles.toml` (comm, exe
  and process comm from the `T`/`N`/`P` lines -- `tasks-start.txt` and `tasks-stop.txt` included --
  and the pid images in `tracer.json`): `audio_worker`
  (`AudioCalc`), `pipeasio_rt`/`pipeasio_worker`, `wineserver`, `webview`/`max`/`push2` (exe),
  `main` (tid == pid of a `.exe`), `live:<comm>` (named Live threads), `unknown:<comm>`.
  `--roles FILE` picks another table, `--no-roles` (or a missing/broken `symbolize.py`) uses the
  reducer's built-in copy of the same rules; the header records which one ran.
  `plugin:<module>` needs stack windows (production tracer).

Outputs (first line of each `.jsonl` is a `{"type":"header"}` record with `monotonic_start_ns`,
tracer version, pids, mode, tables): `blocks.jsonl` (per block: `seq, t_start, t_before_live,
t_after_live, t_end, clock_nsec, deadline_ns, period_ns, nframes, rate, callback_tid,
wake_latency_ns, pre_ns, live_ns, post_ns, elapsed_ns, slack_ns, late, near_late, missed_cycles,
flags, crossings[{tid, role, kind, id, caller, n, total_ns, max_ns, woken_by?}], offcpu[], stacks[],
cycle?`), `threads.jsonl` (per 100 ms window × tid: `t, window_ms, pid, tid, comm, role, oncpu_ns,
offcpu_ns, wakeups, run_delay_ns, crossings{kind:{n,total_ns}}, top_ids[[id,n,total_ns]],
between_blocks?`; sched fields are `null` without `--sched`), `summary.json` (`tracer, thresholds,
blocks, lost_slack, call_sites, kinds, roles, hotspots_non_audio, counters, warnings`),
`events.jsonl` (drilldown: `t, tid, role, kind, id, caller, dur_ns, status, seq, woken_by?`).
`tracer.json` gains `stopped_monotonic_ns`, `lost_events`, `probe_hits`, `counters`, `blocks`,
`overhead_estimate_ns_per_block` (probe hits per block × `--ns-per-hit`, an assumption, not a
measurement).

```bash
python3 -I profiler/tracer/reduce.py --in DIR [--mode drilldown] [--near-late-fraction 0.15] \
    [--window-ms 100] [--tables profiler/tracer/tables/wine-11.13.json]
```

## Tables

```bash
python3 -I profiler/tracer/gen_tables.py --wine-src ~/wine-dev/work/wine-src \
    --out profiler/tracer/tables/wine-11.13.json --label "wine-src (vendor/wine-base-5c23dd1c + patches through 0108, tag series-aceb236)"
```

Sources: `dlls/ntdll/ntsyscalls.h` and `dlls/win32u/win32syscalls.h` (the `#ifdef _WIN64`
`ALL_SYSCALLS` tables; keys `0x0046`, `0x14bb`), `include/wine/server_protocol.h` (`enum request`,
`SERVER_PROTOCOL_VERSION`), `dlls/*/unixlib.h` (the enum named `*func`/`*funcs`, else the one with
`unix_*` enumerators, else the enum of a directly included `../<module>/unixlib.h`; keyed by the
unix library name, e.g. `winealsa`, `mountmgr`, `libusb-1.0`; the `unix_` prefix is stripped).
Regenerate whenever a patch touches these headers (0078 bumped the protocol to 957); `reduce.py`
picks `tables/wine-<runtime version>.json` and warns on a mismatch.

## Tests

```bash
python3 -I -m unittest discover -s profiler/tracer/tests -v
```

`test_reduce.py` builds a synthetic trace (three blocks: on time, late, near-late; nested and
abandoned syscalls; an unmatched thread-start exit; wineserver request/wait nesting; an NTSync wait
with its waker; a unix call resolved through a maps snapshot; off-CPU intervals) and checks block
fields, the association rule, counters, `summary.json` ranking/lost slack, `tracer.json` updates,
drilldown events and that shuffled input reduces identically. `test_gen_tables.py` parses a
synthetic Wine tree (64-bit table selection, enum initialisers, include fallback, warnings) and
checks the committed 11.13 table (`NtYieldExecution` 0x0046, `NtQueryPerformanceCounter` 0x0031,
`NtCreateEvent` 0x0048, `select` 29, `create_event` 30, `winscard` code 0).

## Known limits of the prototype

* bpftrace formats about 775k lines/s on the laptop: Benchmark_VSTs at 64 frames emits ~1M/s and
  lost 22 % (B5b), with the stock 16 MiB ring and with 256 MiB alike (`perf_rb_pages` is pinned
  in the template's config block; the comment there has the numbers). Use the libbpf backend for
  such loads.
* Every crossing is a `printf` through the ring buffer: expect µs-level overhead per hit and
  silent drops under load (counted through `@emitted`). Timing claims come from the production
  tracer on bare metal, never from this prototype.
* No stack windows: its callers stay placeholders (`ntdll.dll!<Name>+0x14`, `pe!0x<rip>` resolved
  to `module+offset`); real caller chains come from the libbpf backend (above).
* USDT probes are attached by file (every process mapping that `ntdll.so` pays the nop → trap);
  the pid filter only limits the output.
* The stack budget depends on bpftrace's code generation and the kernel's private-stack rule:
  a new bpftrace or kernel can push a program over 64 bytes, which `wine-trace start` then
  refuses (re-measure, then trim the record).
* The server-request line carries no status, and the 32-bit `seq` of the `S` lines wraps after
  2^32 blocks (about 66 days at 64 frames / 48 kHz).
