# User-mode QueryPerformanceCounter (patch 0109)

Patch `0109` lets `QueryPerformanceCounter` read the counter in user mode, without a
syscall, when `WINE_QPC_TSC=1` is set. Without the switch nothing changes.

## Switch

Set `WINE_QPC_TSC` in the environment of the process that starts wineserver. The
launcher passes it through like any other Wine switch; the bench suite records it.

| Value | Effect |
|---|---|
| `1` | Enabled when the TSC is invariant and the kernel keeps time on it (clocksource `tsc`). |
| `force` | Skips the clocksource check, for testing in virtual machines. |
| `debug` | As `1`, and wineserver logs its tracking every 5 s on stderr. |
| unset | QPC takes its regular route (the `NtQueryPerformanceCounter` syscall). |

wineserver writes one line to stderr when it enables the mapping, with the TSC
frequency it measured, or when it declines and why.

## Why

Live calls `QueryPerformanceCounter` about 65 times per 1.33 ms audio block (diagnostic
D0001). Wine's `RtlQueryPerformanceCounter` always made the `NtQueryPerformanceCounter`
syscall: 76 ns per call on the test laptop, most of it the syscall dispatcher's register
and extended-state save and restore. Windows reads the counter in user mode
(`QpcBypassEnabled` in `KUSER_SHARED_DATA`).

## Design

- **QPC keeps 100 ns units and 10 MHz.** Windows' layout (`QpcBypassEnabled`,
  `QpcShift` and a TSC-derived `QpcFrequency`) cannot be used. Wine's own code treats
  `NtQueryPerformanceCounter` values as 100 ns ticks without asking for the frequency:
  - the threadpool timers;
  - the wait timeouts in `unix/sync.c` and `unix/server.c`;
  - win32u input, nsiproxy, and the OSS and CoreAudio drivers.
- **Where the mapping lives:** wineserver publishes `struct wine_qpc_tsc` at offset
  `0xf00` of the shared user data page. The struct is defined in `include/ddk/wdm.h`,
  for Wine's sources only (`__WINESRC__`).
  - The section is rounded up to a whole page, and `KUSER_SHARED_DATA` ends at `0x738`,
    so the tail of the page is free.
  - `counter = base_qpc + ((tsc - base_tsc) * mult + base_frac) / 2^32`, with `mult`
    in 32.32 fixed point.
- **No reader ever waits for wineserver.** Two copies of the mapping form a latch:
  wineserver writes the inactive copy, then advances the index. A seqlock would have
  realtime audio threads spinning behind a SCHED_OTHER wineserver that was preempted in
  the middle of an update.
- **When it is on:** only with an invariant TSC (CPUID `0x80000007` EDX bit 8) and the
  kernel clocksource `tsc`.
  - wineserver calibrates the rate during its first second. Until then QPC takes its
    regular route.
  - The first mapping is anchored at `CLOCK_BOOTTIME`, so the switch-over is continuous.
- **Tracking:** wineserver refreshes the shared page on every wakeup, at least every
  16 ms.
  - Each refresh reads the TSC around its `monotonic_counter()` call. A sample wider
    than 10,000 cycles (preempted) is dropped.
  - Every second it measures `CLOCK_BOOTTIME`'s rate against the TSC again.
  - It slews the remaining phase error over about a second, by at most 1 %, never
    stepping back. A lag over 10 ms, after a suspend, steps forward.
  - QPC must follow the kernel clock's rate. NTP and timesyncd slew it, by percents
    after a suspend, and PipeASIO stamps the ASIO system time with `CLOCK_MONOTONIC`.
- **Both routes agree:** `NtQueryPerformanceCounter` reads the same mapping.
- **x86_64 only:** only x86_64 code reads the mapping in user mode; i386 code keeps the
  syscall.

## Results

On the profiling laptop (i7-13620H, clocksource `tsc`, TSC measured at 2,918,377 kHz):

| | Regular route | `WINE_QPC_TSC=1` |
|---|---|---|
| `QueryPerformanceCounter` per call (qpcprobe) | 76 ns | 14 ns |
| `syncbench` qpc, median | 76.5 ns | 15.0 ns |
| Monotonic over 2,000,000 alternating values | yes | yes |
| Gap, `NtQueryPerformanceCounter` read right after `QueryPerformanceCounter` | 0.74 ticks | 0.49 ticks |

With `WINE_QPC_TSC=debug`, QPC was 955 ns from `CLOCK_BOOTTIME` right after
calibration. It then settled to 62–106 ns from it, with the rate within 1 ppm of the
calibration.

A virtual machine is no place to judge the tracking. WSL's timesyncd slews its clock by
±5 %, so the reference itself moves.

## Probe

```
tools/build_qpcprobe.sh
tools/run_in_prefix.sh qpcprobe.exe     # exit status = number of failed checks
```

The probe checks:
- the frequency;
- monotonicity over 2,000,000 alternating values from both routes;
- agreement between the routes;
- the rate against the system time over 3 s;
- the cost per call of each route, and which route `QueryPerformanceCounter` takes.

The user-mode route needs `WINE_QPC_TSC=1` in wineserver's environment, so restart
wineserver after changing the switch.
