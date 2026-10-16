# profiler/tracer — Wine interface tracer (prototype stage)

Traces the Windows→Wine crossings of Ableton Live (NT syscalls, unix calls, wineserver
requests/waits, NTSync waits and wakes) and joins them to PipeASIO audio blocks. Design:
`../../plans/design-B-tracer-and-probes.md` (sections 3a, 3b, 9); the `summary.json` shape
follows `../../plans/design-C-control-suite-agent-loop.md` section B.

This directory currently holds the **bpftrace prototype** (`wine-trace.bt` + `reduce.py`), the
id tables and their generator, and the tests. The libbpf production tracer
(`wine-trace.bpf.c`/`wine-trace.c`, built into `build/wine-trace`) is a later deliverable; the
wrapper already prefers it when the binary exists.

| File | Role |
|---|---|
| `wine-trace.bt` | bpftrace 0.27 template: one text line per event (USDT probes of patch 0108 / pipeasio 0017, kernel-side NTSync `fentry`, optional scheduler and child-follow probes). Never run directly: `profiler/bin/wine-trace` rewrites it. |
| `reduce.py` | Offline join of the event lines into `blocks.jsonl`, `threads.jsonl`, `summary.json` (+ `events.jsonl` in drilldown); updates `tracer.json`. |
| `gen_tables.py` | Generates `tables/wine-<ver>.json` (syscall ids, wineserver request numbers, unix-call codes) from a patched Wine tree. |
| `tables/wine-11.13.json` | Generated from the 11.13 base + the 96-patch series (`series-aceb236`, protocol 957). |
| `tests/test_reduce.py`, `tests/test_gen_tables.py` | `python3 -I -m unittest discover -s profiler/tracer/tests -v` from the repo root. |
| `../bin/wine-trace` | The CLI (`start`/`stop`/`run`/`status`) shared with the suite and the root helper. |

## Running (VM: passwordless `sudo -n`)

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
`--proto` (force bpftrace even when `build/wine-trace` exists), `--no-ntsync` (strip the
kernel-side NTSync probes), `--sched`/`--no-sched`, `--no-follow` (no exec/rename tracking),
`--no-pid-filter` (trace every process mapping ntdll.so), `--wine-root DIR`, `--prefix DIR`,
`--tables FILE`, `--attach-timeout S`.

What `start` does: resolves `ntdll.so` and `pipeasio64.dll.so` from the pids' `/proc/PID/maps`
(fallback `$ABLETON_WINE_ROOT/lib/wine/x86_64-unix/`), snapshots the maps to `maps-<pid>.txt`,
lists the available probes with `bpftrace -l`, writes `DIR/wine-trace.bt` (sections and absent
probes stripped, placeholders substituted), checks it with `bpftrace --dry-run` (if the NTSync
probes are the reason it fails, they are dropped and the script is retried), daemonises
`bpftrace -q -B full` with `setsid` (pidfile `DIR/wine-trace.pid`, stdout `events.txt`, stderr
`bpftrace.stderr`), waits for the `hdr` line (printed by `BEGIN`, i.e. after every probe attached)
and writes `tracer.json`. `stop` snapshots the maps again (`maps-<pid>-stop.txt`), sends SIGINT
(TERM after `--stop-timeout`, then KILL), runs `reduce.py`, builds `maps.json`
(`{"type":"maps","snapshots":[{"t","pid","text"}]}`) and, when `symbolize.py` exists, runs
`symbolize.py --blocks blocks.jsonl --maps maps.json --out blocks.symbolized.jsonl --symcache
symcache.json --imports-out imports.json` (non-fatal; the prototype records no stack windows, so
this validates the pipeline and dumps Live's import table), then chowns `DIR` to
`SUDO_UID:SUDO_GID`.

Exit codes: 0 ok, 1 error, 2 usage, 3 not running (`status`). Fails fast when `ntdll.so` has no
`wine:` USDT notes (runtime built without patch 0108) or bpftrace is missing.

## Event line format (`events.txt`, contract between `wine-trace.bt` and `reduce.py`)

All timestamps are `nsecs` (CLOCK_MONOTONIC, the suite's `time.monotonic_ns()` base); hex fields
have no `0x` prefix; `seq` is the block in progress at the probe (0 = none).

| Line | Meaning |
|---|---|
| `hdr mono_start_ns=N format=1` | `BEGIN`: base for every `offset_seconds` |
| `T ts tid pid comm=NAME` | first sight of a thread (comm may contain spaces) |
| `N ts tid comm=NAME` | `task_rename` (Wine writes `SetThreadDescription` names to comm) |
| `P ts pid parent=PPID comm=NAME` | exec of a child of a traced process (now traced too) |
| `E ts tid syscall ID fr=FRAME seq=S rsp=X rip=X` | `wine:syscall_entry`; `rsp`/`rip` are the user stack pointer / `NtXxx+0x14` |
| `X ts tid syscall ID fr=FRAME st=STATUS rf=RESTORE_FLAGS` | `wine:syscall_exit` |
| `E ts tid unixcall HANDLE:CODE fr=FRAME seq=S rip=X` | `wine:unixcall_entry` (`rip` = PE caller) |
| `X ts tid unixcall fr=FRAME st=STATUS` | `wine:unixcall_exit` |
| `S ts tid req TYPE dur=NS st=STATUS seq=S` | one wineserver request (`server_req_end`; start = ts − dur) |
| `S ts tid wait FLAGS dur=NS st=STATUS seq=S` | one `wait_select_reply` (`server_wait_end`) |
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
| `Lost N events` | bpftrace perf-buffer drops (counted as `lost_events`) |

Lines starting with `@` (bpftrace's map dump at exit) and anything unknown are ignored and counted.

## Reduction rules (`reduce.py`)

* Lines are sorted by timestamp (bpftrace drains per-CPU buffers; the file is not ordered).
* `E`/`X` are paired per tid in LIFO order by frame pointer. An `X` matching an entry below the top
  pops the entries above it as `abandoned_entries` (user-mode callbacks leave through
  `NtCallbackReturn`). An `X` matching nothing is an `unmatched_exit`; the sub-counters
  `unmatched_exits_first_on_tid` (thread start / entered before tracing) and
  `unmatched_exits_with_restore_flags` (NtContinue, unix-call slow path) classify them.
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
  and process comm from the `T`/`N`/`P` lines and the pid images in `tracer.json`): `audio_worker`
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
    --out profiler/tracer/tables/wine-11.13.json --label "wine-src (series-aceb236)"
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

* Every crossing is a `printf` through the perf buffer: expect µs-level overhead per hit and
  `Lost N events` under load (`BPFTRACE_PERF_RB_PAGES`, default 1024 pages per CPU). Timing
  claims come from the production tracer on bare metal, never from this prototype.
* No stack windows: callers are placeholders until the libbpf tracer and `symbolize.py` exist.
* USDT probes are attached by file (every process mapping that `ntdll.so` pays the nop → trap);
  the pid filter only limits the output.
* The bpftrace script was written against the 0.27 syntax (`delete(@map, key)`, `uptr()`,
  `fentry:module:function`, `--dry-run`) but could not be compiled yet: bpftrace is not installed
  on the VM at the time of writing (see the VERIFY list in the stage report).
