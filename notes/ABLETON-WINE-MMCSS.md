# MMCSS "Pro Audio" threads as Linux realtime threads (patch 0113)

Patch `0113` gives Wine's avrt functions the job MMCSS does on Windows. With `WINE_MMCSS=1`, a thread that registers for
the "Pro Audio" task runs `SCHED_FIFO`. Without the switch nothing changes.

## Switch

Set `WINE_MMCSS` in Live's environment. The launcher passes it through like any other Wine switch, and the bench suite
records it.

| Variable | Effect |
|---|---|
| `WINE_MMCSS=1` (or `true`, `yes`, `on`) | A thread registering for "Pro Audio" becomes `SCHED_FIFO` at the base priority. |
| `WINE_MMCSS_RTPRIO=N` | The base priority, 1–98 (default 10). |
| unset, or anything else | Wine's stubs, as upstream: nothing changes. |

Wine writes one line on the `winediag` channel when the switch takes effect, and one if the priority cannot be set.

The switch is meant to go with `ABLETON_RT=off`. That stops the launcher's blanket `chrt -r 10`, so only Live's
registered threads run realtime.

## Why

On Windows, MMCSS (the Multimedia Class Scheduler Service) raises a thread that calls
`AvSetMmThreadCharacteristics("Pro Audio")` into the realtime priority range (23–26 for that task). The application
needs no special rights, and its other threads keep normal priority.

Wine's avrt functions are stubs that report success and do nothing. The ableton-linux launcher makes up for it by
running the whole of Live with `chrt -r 10`. All 76 of Live's threads (UI, file loading, plugin windows) then share the
audio workers' realtime priority, and a busy one can hold up a worker.

A diagnostic launch with `WINEDEBUG=+avrt,warn+threadname` shows what Live registers:

| Thread | Calls |
|---|---|
| AudioCalc (each audio worker) | `AvSetMmThreadCharacteristicsW("Pro Audio")`, then `AvSetMmThreadPriority(…, AVRT_PRIORITY_CRITICAL)` |
| timer (two threads) | `AvSetMmThreadCharacteristicsW("Pro Audio")` |

Nothing else in Live registers. PipeASIO's callback thread (`pipeasio-rt`) sets its own scheduling
(`PIPEASIO_REALTIME=1`, `SCHED_FIFO` 15).

## Design

- **Where:** `dlls/avrt/main.c`, with a new unix side in `dlls/avrt/unixlib.c` (Wine's unixlib interface;
  `UNIXLIB = avrt.so`).
- **Register:** `AvSetMmThreadCharacteristicsW("Pro Audio")` sets the calling thread to
  `SCHED_FIFO | SCHED_RESET_ON_FORK` at the base priority. Threads it starts are not realtime. Other task names keep the
  stub.
- **Priority:** `AvSetMmThreadPriority` sets base + its −2..+2 (`VERYLOW`..`CRITICAL`), clamped to 1–98. Live's workers
  ask for `CRITICAL`, so they run at 12 by default, below `pipeasio-rt` at 15.
- **Revert:** `AvRevertMmThreadCharacteristics` restores the earlier policy and priority. It keeps
  `SCHED_RESET_ON_FORK`, because an unprivileged thread may not clear that flag again.
- **Handle:** the returned handle carries the unix tid and the earlier scheduling (tag `0xa7…5a`). Nothing is allocated,
  and a stub handle (`0x12345678`) is never dereferenced.
- **Fallbacks:** without the unix side (the 32-bit DLL) or without `RLIMIT_RTPRIO` (or `CAP_SYS_NICE`), the stub
  behaviour remains.
- **Fingerprint:** the literal `WINE_MMCSS` in `avrt.so`.

## Probe

`tools/mmcssprobe.c`: a thread names itself, registers for "Games" and then "Pro Audio", sets `CRITICAL` and then
`LOW`, starts a child thread, and reverts. After each step the probe reads that thread's policy and rt priority from
`/proc/<pid>/task/<tid>/stat` through Wine's Z: drive.

Wine opens files in the wineserver, so `Z:\proc\self` is the wineserver's; the probe finds its own process by its unix
name.

On the profiling laptop (dev runtime), every mode passes:

| Mode | Register | `CRITICAL` | `LOW` | Child | Revert |
|---|---|---|---|---|---|
| stub | normal | normal | normal | normal | normal |
| `WINE_MMCSS=1` | FIFO 10 | FIFO 12 | FIFO 9 | normal | normal |
| `WINE_MMCSS=1` under `chrt -r 10` | FIFO 10 | FIFO 12 | FIFO 9 | normal | RR 10 |

    tools/build_mmcssprobe.sh
    WINE_MMCSS=1 tools/run_in_prefix.sh mmcssprobe.exe

## Effect in Live

A functional run on the dev runtime (`WINE_MMCSS=1 ABLETON_RT=off`, Inbuilts, 60 s, unpinned) showed the scheduling
during playback:

| Threads | Scheduling |
|---|---|
| AudioCalc (all five) | `SCHED_FIFO` 12 |
| `pipeasio-rt` | `SCHED_FIFO` 15 |
| MainThread (the UI and others), browser, file and network threads | normal |

The DSP average was 7.0 %, with no peaks over 100 %. The pre-registered trial is T0032 (`profiler/plans/kernel-plan.md`).
