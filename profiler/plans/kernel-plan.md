# Kernel-level performance plan for Ableton Live (dedicated CachyOS laptop)

Living document, approved 2026-10-19: the status table is updated as each item lands, and each item's section records its result.

## Status (updated as items land)
**Halted 2026-10-19 16:08 (user: "halt trials and report and save progress then shrink the partition") for a Windows 11 dual boot.**
- **Plan:** a native Windows baseline on the same laptop, the same Sets and the same buffer.
- **Kept configuration at the halt:** `posix_spawn` (0112), `physcore` with 5 workers, the new display.
- **No kernel-level change has improved Live:**
  - T0024 core clearing: revert.
  - T0026 SMT siblings offline: mechanism-confirmed, no gain.
  - T0025 in-kernel spin: revert. It worked (context switches −64 %), but the DSP average did not move and the audio CPU doubled.
  - T0030 EPP: withdrawn; the bench already runs with EPP `performance`.
- **What the traced runs show:** about 77 % of the audio threads' cycles are Live's own native code; ntsync calls are about 16 %.
- **T0027 halted after A1, B1, A2** (B2 interrupted); the runs are set aside in `t0027-halted` and it reruns from A1 later.
- **Display moved back to the built-in panel (2026-10-19, user):** the BIOS is back at defaults, so the Intel/NVIDIA mux is hybrid and the panel hangs off the Intel GPU.
  - `video=eDP-1:d` is gone from `/etc/default/grub` (backup `grub.profiler-<timestamp>`) and from every profiler variant.
  - `90-profiler-kwin-gpu.conf` (`KWIN_DRM_DEVICES=/dev/dri/nvidia-dgpu`) is moved to `~/.config/environment.d.off/`.
  - KWin now composites on the Intel GPU. eDP-1 runs at 1920×1080 @ 60.32 Hz (like the old external monitor's 59.94 Hz, not the panel's 144 Hz). The external HDMI output on the NVIDIA GPU is disabled.
  - **This shifts the display baseline:** trials before it ran with the NVIDIA-only external display. Interleaved A/B trials stay valid, but absolute display-CPU figures (T0023) do not carry over.
  - To check at the next Live run: which GPU wined3d's Vulkan renderer picks (Intel or NVIDIA). The iGPU shares the package power budget with the P-cores.
- **Next:**
  1. ~~Shrink the laptop's btrfs root to half~~ — **done 16:2x (2026-10-19):** btrfs and partition 2 are 476.5 GiB (same start, UUIDs and name); 477 GiB is unallocated at the end of the disk. A reboot was verified clean. The partition table from before is saved as `~/partition-table-before-windows.sfdisk` on the laptop, with a copy on the workstation.
  2. The user installs Windows 11.
  3. Fix the boot order (GRUB first, os-prober for Windows).
  4. A Windows measurement harness and an interleaved Linux-vs-Windows trial.
  5. Rerun T0027.
  6. A TLB-walk diagnostic (`perf stat`), then a transparent-huge-pages trial for Live's own code.

| Item | State | Trial | Result |
|---|---|---|---|
| T0022 physcore, 5 workers | recorded 2026-10-19: rule H PASS (9/9, −26.0 %) | T0022 | **keep**: the kept layout |
| T0023 display | recorded 2026-10-19: non-inferiority PASS, display CPU −1 point in Live and −2.9 in the compositor | T0023 | **keep**: GPU renderer, Vulkan, present skip 6 |
| T0024 core clearing | recorded 2026-10-19 (second attempt; the first was aborted, its restore left IRQs on 12–15): rule H FAIL, audio CPU +14.5 %; IRQ time on audio threads up; workers clocked 3.23 vs 3.51 GHz | T0024 | **revert** |
| K10 P-core frequency policy (new, from T0024) | **withdrawn unrun**: the bench's power hold already sets EPP performance for every run; the clocks look power/thermal-limited | T0030 | — |
| I0 infrastructure | done (reboot-per-run trials proven by T0027's first runs): campaign tooling in `profiler/trials/`, rule D, root-helper knobs (cpu-online, cpuidle, cpuidle-governor), ledger kinds `kernel`/`kernel-module` (validator fixed), GRUB variants (`profiler/kernel/grub/`, grub.d `45_`, not `09_`, so the normal entries never shift) and the `boot-kernel` variant table. To do on the laptop after T0023: install the helper and the GRUB variants, test rule D and the knobs | — | — |
| K0 census | **done** (D0004): ~83 sync calls per block; K5 syscall-free share ~40 %; spin budget 20–40 µs; K4 gate fires but C2 wakes look cheap; CPU 4 spends 5 % in xhci IRQs | D0004 | see K0 |
| K1 SMT offline | recorded 2026-10-19 (second attempt): audio CPU +2.9 %, Live CPU 34.8 → 39.7 %; siblings offline in every B run | T0026 | **mechanism-confirmed** (not kept) |
| K2 mitigations=off | halted 16:08 after A1, B1, A2 (B2 interrupted) for the Windows install; the mechanism worked (B: 0 vulnerabilities mitigated, A: 5); reruns from A1 later | T0027 | halted |
| K3 ntsync-live spin | recorded 2026-10-19: in Live the DSP average did not move (5 of 9 pairs, −0.4 %) while audio CPU doubled (+22.9 points); the spin worked (context switches −64 %), wake-ups are not the bottleneck | T0025 | **revert** |
| K4 C-state limit, C1E | D0007: a clock floor does not raise the workers' clock; D0008: C2/C3 off alone no consistent gain; D0009: with C1E off too, workers 2.9–3.3 → 4.5 GHz. **T0031: DSP −29.4 % (9/9 pairs), audio CPU −39.6 %, Live CPU 38.1 → 27.3 %, +5 W** | T0031 | **keep**: C1E off, C2/C3 off on the P-cores |
| MMCSS (patch 0113, Wine) | T0032: only Live's audio threads realtime (AudioCalc FIFO 12, the rest normal) against all of Live at RR 10: DSP −0.3 % (8/9 pairs), guards held | T0032 | mechanism-confirmed (opt-in) |
| Load ramp (headroom) | machinery done (every track duplicated per pass, buses trimmed); headroom 4–5× on every Set, failing on spikes at a DSP average of only 11–15 %. D0011: MMCSS does not move it (2 higher, 2 lower of 6 pairs; DSP −1 to −2 %). 77–82 % of the misses fall on 4 of the loop's 24 bars (beats 60, 76, 92, 96: where "7-Vocal 05" plays) | D0011 | no difference |
| K5 LiveSync | not started; deprioritised by T0025: ntsync is 16 % of audio cycles, so at most a CPU gain, not block time (D0004: ~40 % of calls could be syscall-free) | — | — |
| K6 isolation | registered as T0029 (driver ready); T0024 predicts no gain from moving IRQs off the audio cores, so it waits behind K10 | T0029 | — |
| K7–K9 | not started (K7 pre-wake and K8 direct entry also deprioritised: C2 wakes are cheap, and T0025 showed the sync path is not the block-time limit) | — | — |
| Dev commit cd5ca47 (dropped Wine-side spin) | to revert | — | — |

## Windows 11 baseline (same laptop, dual boot; first look 2026-10-19 19:00–19:15)
- **Setup:**
  - Windows 11 Home build 26300 on the same laptop, Live 12 Trial 12.4.6 and the same Sets.
  - Focusrite USB ASIO at 48 kHz with 64 samples.
  - High performance power plan; the trial dialog answered as on Linux.
  - Harness `profiler/windows/bench-win.py`: the bench handler's DSP reports, per-thread CPU via psutil and GetThreadDescription, the Linux bench's launch→ready→settle→play→window sequence.
  - `-MaxAudioThreads` in `Options.txt` sets the worker count.
- **First look:** single 120 s runs per Set, not interleaved; the Linux column is the kept configuration's A arms (T0023–T0026), on the old external display.

  | Set | DSP avg Win, 5 workers | DSP avg Linux (kept) | DSP avg Win, Live's default (22) | audio threads Win 5w (AudioCalc + ASIO callback) | audio threads Linux (AudioCalc + pipeasio-rt) | Live CPU Win 5w |
  |---|---|---|---|---|---|---|
  | Inbuilts | 8.50 | ~9.0 | 9.49 | 18.1 + 13.9 = 32.0 | ~24.5 | 37.8 |
  | Max4Live | 9.33 | ~9.3 | 10.07 | 18.3 + 13.6 = 31.9 | ~27.5 | 35.8 |
  | VSTs | 7.48 | ~8.5 | 8.79 | 12.1 + 11.7 = 23.8 | ~22.2 | 27.1 |

- **Readings:**
  - Windows is 0–1 point lower on DSP average.
  - The workers cost about the same on both systems, but the Focusrite ASIO driver's callback thread (named `0xdd100001`) costs about twice PipeASIO's `pipeasio-rt` (~7 %).
  - Live's total CPU is about equal.
  - Five workers beat Live's own default on Windows too: 22 workers gave +1.0–1.3 DSP points, +5–7 CPU points, and the only missed deadline.
  - No missed deadlines with 5 workers.
  - Correction (from D0005): these Windows figures came from the harness that counted reports queued before the window, so the DSP averages read low (by ~8 % in D0005), and the missed deadline may predate playback. D0005 supersedes the first look.
- **D0005, the interleaved comparison (pre-registered 2026-10-19 ~19:25, before any of its runs):**
  - **Design:** order A1 B1 A2 B2 A3 B3, every run from a fresh boot into its system, the boots alternating; each run plays Inbuilts, Max4Live and VSTs for 120 s.
    - **A:** Linux in the kept configuration, through `profiler/windows/linux-run.sh`, settled as T0015/T0027 were.
    - **B:** Windows 11, through `bench-win.py` with 5 workers, after `settle.ps1` (desktop session, 120 s, then total CPU below 10 %).
    - Driver `profiler/windows/cross-os-trial.sh` on the workstation.
  - **Primary: Live's DSP average per Set-run (9 pairs).**
    - Windows lower in at least 8 of 9 pairs (sign test p = 0.02) means Windows is faster.
    - Linux lower in at least 8 of 9 means Linux is faster.
    - Otherwise no significant difference.
    - The median paired change is reported either way.
  - **Secondary:**
    - audio-thread CPU (AudioCalc plus the callback thread: `pipeasio-rt` against the ASIO driver's);
    - Live's CPU;
    - the peak median;
    - peaks over 100 % (the dropout measure both systems share);
    - Linux's PipeWire errors.
  - It is a comparison of two platforms, so it gets no ledger verdict. The result goes here.
  - **First attempt stopped at B1 (19:26–19:39):** Windows was finishing an OS upgrade (build 26300 → 26300.9711, a restart "Operating System: Upgrade (Planned)" at 19:24:59). D0005's reboot into Linux for A1 interrupted it; on B1's boot it resumed, restarted Windows, and GRUB's default turned that into Linux.
    - Windows Update is now paused for 7 days, with no restart pending.
    - The driver waits through a reboot in progress and stops on a run without results.
    - D0005 restarts from A1 (`d0005b`), so all six runs share one Windows build. The first attempt's A1 is kept for reference only.
  - **D0005 — RESULT (d0005b, 2026-10-19 19:42–20:46; all six runs clean, 18 Set results, 48 kHz, 5 workers on both; corrected the same evening): no significant difference in Live's DSP average. Linux has the lower peak median in all 9 pairs and no missed deadlines.**
    - **Correction:** the first scoring (e5b496a: Windows lower in 7 of 9 pairs, median −9.1 %, 5 missed deadlines) was wrong.
      - `bench-win.py` counted the reports queued on its socket since the handler's pong as window readings: 30–41 per Set-run (17–23 s), mostly from before playback reached the heavy section (average ~3 %). That pulled Windows' DSP average down by ~8 % and its peak median down too.
      - Three of the five readings over 100 % were among them, about 2 s after the handler came up, before playback started.
      - Rescored from the per-reading logs (`profiler/plans/findings/d0005-dsp-readings.tsv`, `profiler/windows/rescore-d0005.py`) with the Windows window only. The script reproduces the first scoring's figures from the same data.
      - The harness now discards queued reports before the window (tested on Windows), and `cross-os-trial.sh` copies the harness from the checkout before each Windows run.
      - The thread CPU figures come from thread times at the window's ends and stand.
    - **Primary (window only):** Windows lower in 5 of 9 pairs (one-sided p = 0.5), median −0.9 %.
      - By Set: Inbuilts +4 / −3 / −1 % (a tie); Max4Live +14 / +6 / +13 % (Linux lower in all three); VSTs −4 / −8 / −7 % (Windows lower in all three).
      - Medians: Linux 9.54 / 8.94 / 8.61, Windows 9.37 / 10.01 / 8.17.
      - Song position: each Linux window began 3.5–4 s before the heavy section (7 intro readings at ~4–5 %), each Windows window as it began. Aligned on the heavy section (100 s from each window's first reading of at least 6 %): Windows lower in 5 of 9, median −1.7 %, the same pattern by Set.
    - **Secondary:**
      - Peak median: Linux lower in 9 of 9 pairs (p = 0.002); Windows +6.4 % (aligned +6.1 %), Max4Live +12–18 %.
      - Missed deadlines in the window: Linux 0 of 9 Set-runs; Windows 2, both Inbuilts and barely over (101.1 % at 10 s in B1, 102.0 % at 114 s in B3). Linux's PipeWire errors: 5 in total, in 3 Set-runs.
      - Live's total CPU is lower on Windows in 9 of 9 pairs (p = 0.002, median −17.8 %): Linux 38.3 / 38.9 / 32.6, Windows 33.0 / 33.2 / 23.8.
      - The audio threads cost the same overall (Windows lower in 3 of 9, median +1.1 %), but split differently. The AudioCalc workers are cheaper on Windows (15.4 / 16.3 / 8.3 against 19.1 / 18.8 / 15.5); the callback thread is cheaper on Linux (PipeASIO's `pipeasio-rt` 7.9 / 7.2 / 6.8 against the Focusrite ASIO thread's 12.8 / 12.9 / 11.3).
      - Caveat: Windows charges thread CPU time at clock ticks (sampled), Linux exactly. A Windows Performance Recorder trace (precise CPU from context switches) would confirm the Windows thread figures.
    - **Readings:**
      - Live's processing under Linux plus Wine is level with native Windows overall: Max4Live 6–14 % cheaper on Linux, VSTs 4–8 % cheaper on Windows, Inbuilts a tie. Blocks are steadier on Linux (peak median in 9 of 9 pairs, no missed deadlines).
      - VSTs: the workers take about twice the CPU under Wine (15.5 against 8.3 %), but the DSP average only 4–8 % more, so most of the extra worker CPU is off the critical path (or Windows' sampled accounting undercounts). Profiling the VSTs Set's AudioCalc threads (perf, against a WPR trace) is still the place to look for a Wine-side cost: denormal handling, the plugins' API calls.
      - Max4Live costs more on Windows; not yet explained.
      - Live's non-audio work (UI, display, Wine's threads) costs more under Linux.
      - PipeASIO's callback is cheaper than the Focusrite ASIO driver's.

## Linux upstream-only baseline (D0006, pre-registered 2026-10-19 ~21:45, before any of its runs)
- **Why:** a new Linux baseline with only upstream's fixes (user: "turn those off and get a new baseline with just upstream fixes"; Linux only, not interleaved). Against D0005's Linux runs (the kept configuration, same procedure, same evening) it shows what our fixes add together. Descriptive only: no verdict.
- **Configuration** (`profiler/windows/linux-run.sh TAG upstream`):
  - Off (ours):
    - posix_spawn (`WINE_POSIX_SPAWN`, 0112, T0020);
    - PipeASIO realtime (`PIPEASIO_REALTIME`, T0003; upstream ships it off);
    - the physcore pinning with 5 workers (T0022);
    - the new display (T0023: Vulkan, Live's GPU renderer, present skip 6);
    - realtime throttling off.
  - Upstream's defaults instead:
    - the launcher's automatic worker count: 15 on this laptop (10 physical cores, raised to half of Live's own 30);
    - no pinning;
    - wined3d on OpenGL with every frame shown, and Live's GPU renderer off (the golden before T0023, `golden.20261019T153253Z`);
    - realtime throttling as booted.
  - Unchanged:
    - the project's Wine 11.13 build (patches 0108–0112 are inert without their switches; 0108's trace points are idle no-ops);
    - Live at SCHED_RR 10 and the performance power hold (upstream's launcher defaults);
    - the Focusrite on PipeWire's Pro Audio profile at 48 kHz and 64 frames;
    - the stock 7.2.11 kernel and ntsync module, Link off, the built-in screen on the Intel GPU.
- **Design:** 3 runs (A1 A2 A3), each from a fresh boot, settled as D0005's Linux runs were; Inbuilts, Max4Live and VSTs at 120 s each. Driver: `ORDER="A1 A2 A3" LINUX_CONFIG=upstream TRIAL_ID=D0006 profiler/windows/cross-os-trial.sh d0006` on the workstation.
- **Checks per run** (from the run records):
  - none of `WINE_POSIX_SPAWN`, `PIPEASIO_REALTIME`, `WINE_D3D_CONFIG`, `WINED3D_PRESENT_SKIP` or `ABLETON_MAX_AUDIO_THREADS` among the recorded switches;
  - no pins, 15 workers;
  - Live's log says "GPU Renderer: Off";
  - realtime throttling at its boot value.
- **Reported:** per Set, against D0005's Linux runs:
  - the DSP average and peak median;
  - peaks over 100 %;
  - PipeWire errors;
  - Live's CPU and the audio threads' CPU.

- **D0006 — RESULT (2026-10-19 21:41–22:11; three runs, each from a fresh boot, 9 Set results): with only upstream's fixes, Live under Linux needs 18–32 % more DSP time and about twice the CPU, and misses deadlines in every Set-run.**
  - **Checks:** all held in every run: upstream configuration, no pins, 15 workers (15 AudioCalc threads), none of our switches recorded (only Link off and the performance power hold), Live's log "GPU Renderer: Off (Platform default)".
  - Realtime throttling: this kernel boots with `sched_rt_runtime_us` = 1000000 (nothing sets it), so throttling was off in both configurations and is not a difference.
  - **Medians per Set** (Inbuilts / Max4Live / VSTs), upstream against D0005's kept runs. Every upstream run was worse than every kept run in every Set.
    - DSP average 11.31 / 11.79 / 10.95 against 9.54 / 8.94 / 8.61 (+18.5 / +31.9 / +27.2 %).
    - Peak median 21.45 / 22.73 / 21.11 against 17.70 / 17.55 / 16.84 (+21 / +30 / +25 %).
    - Missed deadlines (peaks over 100 %): 55 in 9 Set-runs (3–13 each) against 0.
    - PipeWire errors: 176 against 5.
    - Live's CPU 63.8 / 68.2 / 60.3 against 38.3 / 38.9 / 32.6 (+67 / +75 / +85 %).
    - Audio threads 51.3 / 55.4 / 50.0 against 27.0 / 25.5 / 22.2. The 15 AudioCalc workers take 44.9 / 48.4 / 43.7 against 19.1 / 18.8 / 15.5 for five. PipeASIO's thread, not realtime here, is slightly cheaper (6.4 / 6.9 / 6.5 against 7.9 / 7.2 / 6.8).
  - The missed deadlines are spread over the whole window, not only at the first pass's song positions where fork's page-fault storms land (D0003). That fits scheduling (PipeASIO's thread not realtime, 15 unpinned workers), as in T0003, where PipeASIO realtime cut PipeWire errors 204 → 30.
  - **Against native Windows** (D0005 corrected, a different session):
    - Upstream Linux's DSP average is 18–34 % higher (Windows 9.37 / 10.01 / 8.17), Live's CPU about twice Windows' (33.0 / 33.2 / 23.8), and it has 55 missed deadlines against Windows' 2.
    - With our fixes, Linux is level with Windows on DSP and steadier.
  - Not interleaved: D0005's Linux runs were 19:43–20:35, these 21:41–22:11, with the same procedure and display. Per-Set results: `profiler/plans/findings/d0006-results.jsonl`.

## The audio cores' clock (D0007, diagnostic, pre-registered 2026-10-19 ~22:55, before any of its runs)
- **Why:**
  - Live's own code is ~77 % of the audio threads' cycles, and its speed follows the clock.
  - In T0024 the workers ran at 3.2–3.5 GHz on cores rated 4.7 GHz.
  - T0027's kept runs drew ~21 W at ~60 °C on average, with the software power limits at 200 W, so K10's reading (power and thermal limited) looks wrong.
  - Windows' High performance plan (D0005) holds the minimum processor state at 100 %.
  - Bursty threads clock very low without a hold: in a test with three bursty threads on an idle system (EPP `balance_performance`), they ran at ~0.5 GHz.
- **Design:** kept configuration; two bench runs in one session (Inbuilts, Max4Live and VSTs, 120 s each).
  - A: as is (the bench's power hold sets EPP `performance`).
  - B: a clock floor on the P-cores: `scaling_min_freq` = `cpuinfo_max_freq` on CPUs 0–11, i.e. the HWP minimum at the top. Restored after B and on any exit.
  - Driver `profiler/kernel/clock/d0007.sh`, with `clock-capture` as the bench's tracer.
- **Measured per Set:**
  - the AudioCalc and `pipeasio-rt` threads' clock while running (cycles / task clock on the P-core PMU) and their IPC;
  - Live's DSP average, peak median and peaks over 100 %; PipeWire errors; Live's CPU;
  - package power, package and hottest-core temperature, thermal throttle events and time;
  - the P-cores' `scaling_min_freq` and EPP during the capture (the mechanism).
- **Decision:** register a trial (rule D, ABAB × 3, power and temperature reported) if B's AudioCalc clock is at least 5 % above A's on every Set; otherwise stop. One pair cannot decide the DSP effect, so it is reported only.
- **D0007 — RESULT (2026-10-19 23:44–23:59; both runs clean, physcore pinning held): the floor does not raise the workers' clock, so no trial (stop, as registered).**
  - **Clock while executing** (cycles / reference cycles × the 2.9 GHz TSC), A → B per Set (Inbuilts / Max4Live / VSTs):
    - AudioCalc 3.41 / 3.11 / 3.23 → 3.18 / 3.00 / 3.03 GHz (−4 to −7 %);
    - `pipeasio-rt` 3.53 / 3.69 / 3.39 → 4.08 / 3.95 / 3.94 GHz (+8 to +16 %).
  - The workers execute only 81–85 % of their on-CPU time (reference cycles / task clock); the rest is halted waiting inside their time slice.
  - **DSP average** 8.96 / 9.50 / 8.40 → 8.87 / 9.44 / 8.39 (−1.0 / −0.7 / −0.2 %); no peaks over 100 %, no PipeWire errors in either run.
  - **No power or thermal limit:** package 17–19 W in both runs, mean 54–58 °C, max 64–74 °C. In A, 9–20 ms of throttling per Set; none in B.
  - **Reading:**
    - The workers run at 3.0–3.4 GHz on cores rated 4.7–4.9 GHz, with power and heat far from any limit, and a floor does not move them up.
    - The likely limit is how the cores come back from sleep: they sleep between rounds, and two thirds of audio wakes leave C2 (D0004).
    - The follow-up check is D0008 (deep C-states off on the P-cores, with and without the floor).
  - Summary: `profiler/plans/findings/d0007-summary.txt`.

## Sleep depth and the clock (D0008, diagnostic, pre-registered 2026-10-20 ~00:20, before any of its runs)
- **Why:**
  - D0007: the workers execute at 3.0–3.4 GHz on cores rated 4.7–4.9 GHz, with no power or thermal limit, and a clock floor does not raise the clock.
  - Two thirds of audio wakes leave C2 (D0004). A core that powered down between rounds may run slower until it ramps back up.
  - T0028 (registered) judges the C-state limit on DSP; this check first measures whether it raises the clock.
- **Design:** kept configuration; three bench runs in one session (Inbuilts, Max4Live and VSTs, 120 s each).
  - A: as is.
  - B: C2 and C3 off on the P-cores (T0028's B, through the root helper).
  - C: B plus D0007's clock floor.
  - Everything is restored after each run and on any exit. Driver `profiler/kernel/clock/d0008.sh`; summary `clock_summary.py`.
- **Measured per Set:** as in D0007, plus each audio CPU's idle-state entries and residency (the mechanism: no C2 or C3 entries in B and C).
- **Decision:**
  - Run T0028 (rule D, ABAB × 3) if B's or C's AudioCalc clock while executing is at least 5 % above A's on every Set.
  - If only C qualifies, T0028's B gets the floor too.
  - Otherwise stop. DSP is reported either way.
- **D0008 — RESULT (2026-10-20 00:06–00:30; three runs clean, pinning held): deep C-states off does not raise the workers' clock consistently, so no T0028 (stop, as registered).**
  - **Mechanism held:**
    - In A the audio CPUs spent 60–62 % of their time in C2 (2,400–2,700 entries a second each) and 30–33 % in C1; C3 was never used.
    - In B and C: no C2 or C3 entries, C1 92–93 %.
  - **AudioCalc clock while executing, against A** (Inbuilts / Max4Live / VSTs):
    - B +6.1 / −4.8 / +10.2 %; C −11.5 / −8.1 / +22.1 %.
  - **DSP average:** B −2.6 / +2.5 / −4.0 %; C +8.3 / +3.5 / −7.6 % (C's Inbuilts had one peak over 100 %).
  - **Package** 17–18.6 W in every run, temperatures alike.
  - Same-configuration runs differ by up to 17 % in the workers' clock (VSTs: D0007's A 3.23 GHz, D0008's A 2.67 GHz), so single runs cannot resolve effects of this size.
  - **Not the turbo limit:** MSR_TURBO_RATIO_LIMIT allows 4.7 GHz with up to 8 active P-cores (4.9 GHz with one or two), and HWP's highest performance is 60. The workers execute at 2.7–3.6 GHz, so the limit is neither turbo, power nor heat.
  - **C1E is on** (MSR_POWER_CTL bit 1, every core): a C1 halt also drops voltage and clock. With C2/C3 off, the cores still drop into C1E between rounds, about 4,000 times a second.
  - Next: D0009, C1E off together with C2/C3 off. Summary: `profiler/plans/findings/d0008-summary.txt`.

## C1E and the clock (D0009, diagnostic, pre-registered 2026-10-20 ~00:55, before any of its runs)
- **Why:** see D0008. If C1E's voltage and clock drop on each of the ~4,000 halts a second is what keeps the workers at 2.7–3.6 GHz, then idle cores that only clock-gate should run their bursts near 4.7 GHz.
- **Design:** kept configuration; four bench runs in one session, A B A B (Inbuilts, Max4Live and VSTs, 120 s each).
  - A: as is.
  - B: C1E off on every CPU (MSR 0x1FC bit 1 cleared through `/dev/cpu/N/msr`) and C2/C3 off on the P-cores.
  - The saved values are restored after each run and on any exit, and the MSR resets at reboot. The msr driver taints the kernel CPU_OUT_OF_SPEC until the next reboot.
  - Driver `profiler/kernel/clock/d0009.sh`.
- **Measured per Set:** as in D0008, plus the C1E bit during each capture (the mechanism).
- **Decision:** register a trial (rule D, ABAB × 3, power and temperature reported) if B's AudioCalc clock while executing is at least 10 % above its paired A run's, in both pairs and on every Set; otherwise stop. The bar is 10 % because same-configuration single runs differed by up to 17 %.
- **D0009 — RESULT (2026-10-20 00:34–01:05; four runs clean, pinning held; C1E 0 on every CPU in both B runs, 1 in both A runs): C1E is what holds the workers' clock down. Every comparison passed the bar, so T0031 follows.**
  - B against its paired A, pair 1 / pair 2 (Inbuilts; Max4Live; VSTs):
    - **AudioCalc clock while executing:** 2.99 → 4.54 / 2.96 → 4.52 GHz; 3.33 → 4.55 / 3.05 → 4.53; 3.13 → 4.50 / 2.88 → 4.49 (+37 to +56 %). `pipeasio-rt` 4.6 GHz in every B run.
    - **DSP average:** 8.97 → 6.73 / 9.33 → 6.73; 8.84 → 6.86 / 9.12 → 6.78; 8.54 → 6.46 / 8.47 → 6.45 (−22 to −28 %).
    - **Peak median:** 17.1–17.8 → 14.5–15.1 (−12 to −18 %). No peaks over 100 % in any run; PipeWire errors 1 / 1 / 0 (B) against 0 / 1 / 0 (A).
    - **Live's CPU:** 34–41 % → 23–31 % (−23 to −31 %). AudioCalc CPU 15–20 % → 9–13 %.
  - **The workers execute more of their on-CPU time** (87–92 % against 80–86 %). Their idle is C1 only, about 4,800–5,100 entries a second per audio CPU.
  - **Cost:** package 17.6–18.4 W → 22.1–23.5 W (+4–5 W); mean temperature 52–53 → 55–56 °C, max ≤ 73 °C; 1–9 ms of throttling per Set.
  - **Reading:** with C1E on, every C1 halt drops the core's voltage and clock, and each of the workers' thousands of wakes a second starts from there. Off, an idle audio core only stops its clock and wakes at full speed. Neither change alone did it: C2/C3 off alone (D0008) left the cores in C1E, and the floor (D0007) cannot act inside a halt.
  - Summary: `profiler/plans/findings/d0009-summary.txt`.

## T0031: shallow idle on the audio cores (C1E off, C2/C3 off), pre-registered 2026-10-20 ~01:20, before any of its runs
- **From D0009:** with C1E off on every CPU and C2/C3 off on the P-cores, the workers execute at ~4.5 GHz instead of 2.9–3.3 GHz. DSP average −22 to −28 % in both pairs on every Set, Live's CPU −23 to −31 %, package +4–5 W.
- **A:** as is. **B:** D0009's B, applied before and undone after each B run (`profiler/trials/trial-T0031.sh`). ABAB × 3 on Inbuilts, Max4Live and VSTs at 120 s, kept configuration (physcore, 5 workers, new display, posix_spawn, PipeASIO realtime).
- **Rule D:**
  - D1: B lower in at least 8 of 9 Set-pairs (sign test, p = 0.02); D2: median paired change ≤ −3 %.
  - Guards: G1 no xruns in B; G2 B's PipeWire errors not significantly higher; G4 audio-thread CPU's median increase ≤ +5 %.
- **Mechanism** (from each run's record): every CPU's C1E bit is 0 and the audio CPUs make no C2/C3 entries during each B run (C1E 1 and C2/C3 entries during each A run).
- **Reported:** package power and temperature, Live's CPU, the peak median and the worst peak.
- **Verdicts:**
  - Keep = PASS with the mechanism; mechanism-confirmed = guards and mechanism hold but the primary fails; revert otherwise.
  - If kept, B joins the kept configuration for later trials (both arms). A lasting form is the user's call: applied only while Live runs, like the power hold, or at boot.
- **T0031 — RESULT (2026-10-20 01:08–01:55; six runs clean; the mechanism held in every run): rule D PASS, so keep. The largest single gain of the campaign.**
  - **DSP average** lower in 9 of 9 Set-pairs (p = 0.002), median paired change −29.4 %:
    - Inbuilts 9.07 → 6.49, Max4Live 9.34 → 6.52, VSTs 8.70 → 6.18;
    - 2.2–3.4× the A/A spread.
  - **G4:** audio-thread CPU −39.6 % (−9.75 points of one core): 26.0 / 26.5 / 22.3 → 15.7 / 16.7 / 12.7 %. Live's CPU 38.1 → 27.3 %.
  - **G1:** no xruns.
  - **G2:** PipeWire errors 6 → 12 (p = 0.12).
    - 9 of B's 12 came from one stall of about 12 ms (a 908 % peak) 8 s into B2's Inbuilts window, with the package at 22 W and 53 °C, so not thermal.
    - The other eight B Set-runs had 0–2 each.
  - **Worst-peak medians** 59.4 / 69.5 / 61.0 → 64.2 / 60.4 / 56.2 %. Worker run-queue wait 3.1 / 9.5 / 13.5 → 2.1 / 1.2 / 2.0 ms per window.
  - **Mechanism:** C1E 0 on every CPU and no C2/C3 entries on the audio CPUs in every B run (C1E 1 and 6.3–6.5 million entries in every A run).
  - **Cost:** package 17.4–17.9 → 22.6–22.8 W (+5 W); median temperature 51–52 → 54–55 °C, max 69–80 → 84–88 °C.
  - **Kept:** shallow idle on the audio cores joins the kept configuration for later trials (both arms). A lasting form (applied only while Live runs, like the power hold, or at boot) is the user's call.
  - **Against Windows** (D0005, Windows 9.37 / 10.01 / 8.17): Linux is now 24–35 % lower on DSP. But Windows ran with C1E on too and would likely gain from the same change, so a fair comparison needs Windows' idle limited as well (`powercfg` processor idle disable).

## T0031's change on Windows (D0010, diagnostic, pre-registered 2026-10-20 ~05:05, before any of its runs)
- **Why:** Windows runs with the firmware's C1E on too, and has no setting for it. Two pieces make T0031's change there without a kernel driver:
  - **The GRUB entry** `Windows Boot Manager, C1E off (profiler)` (`profiler/kernel/grub/46_profiler-c1e-off`, installed by `install-c1e-off.sh`) clears MSR_POWER_CTL bit 1 before chainloading Windows.
    - The register is shared by the whole CPU: clearing it on CPU 0 clears it on all 16.
    - A Linux boot through the same lines read C1E 0 on every CPU (0xf4005b → 0xf40059), with no kernel taint.
  - **LiveIdleGuard** (`profiler/windows/live-idle-guard/`, C++; built with MSVC by `build-msvc.cmd`, or mingw-w64 by `build.sh`) is a Windows service. While Live runs, the active power scheme's processor idle state maximum is 1 (C1); it is restored when Live exits.
    - Functional test: 0 → 1 within a second of Live starting, and back to 0 when Live exited.
  - **The driver route was rejected:** this Windows runs VBS with memory integrity and Microsoft's vulnerable-driver blocklist. A self-signed driver would need test-signing mode, and the hypervisor may block its register write.
- **Design:** Windows only; A1 B1 A2 B2, each run on a fresh boot through GRUB (`profiler/windows/d0010.sh`).
  - A: the normal Windows entry (C1E on), LiveIdleGuard stopped, IDLESTATEMAX 0.
  - B: the C1E-off entry, LiveIdleGuard running.
  - `bench-win.py` with 5 workers, Inbuilts, Max4Live and VSTs at 120 s, as D0005's Windows runs.
- **Measured per Set:**
  - DSP average, peak median, peaks over 100 %;
  - Live's CPU, the AudioCalc and ASIO callback threads' CPU;
  - the P-cores' effective clock while active (Windows' "% Processor Performance" × the nominal clock; the mechanism).
- **Reading:**
  - The change helps Live on Windows too if B's DSP average is lower than its paired A's in both pairs on every Set.
  - The mechanism holds if the P-cores' effective clock is higher in every B run, and the service log shows C1-only idle applied for each B Set and restored after.
- **D0010 — RESULT (2026-10-20 05:04–05:50; four runs clean): the mechanism carries over to Windows but Live's DSP time does not move, so the gain is Linux-specific.**
  - **Mechanism held:**
    - P-cores' effective clock while active: A 2.29–2.78 GHz → B 4.69–4.71 GHz (+69 to +105 %); E-cores 57–97 % → 194–198 % of nominal.
    - So the GRUB write survives Windows' boot, VBS included.
    - The service applied C1-only idle for each B Set and restored it after; the A runs had IDLESTATEMAX 0 and the service stopped.
  - **DSP average:** B lower in 3 of 6 Set-pairs, −3.2 to +3.2 % (Inbuilts −1.3 / +3.2; Max4Live +1.2 / −3.2; VSTs +0.7 / −0.1 %). Peak median −3.6 to +2.6 %. No peaks over 100 %.
  - **CPU:** Live's CPU −11.6 to +4.5 %, AudioCalc −25 to +17 %, the ASIO callback unchanged; all mixed.
  - The A runs reproduce D0005's corrected Windows figures: DSP 8.93–9.32 / 10.08–10.10 / 8.15 against 9.37 / 10.01 / 8.17.
  - **Reading:**
    - On native Windows the cores' clock is not what limits Live's blocks; something keeps its audio work fast without this change. Most likely that is Live's own thread placement and MMCSS "Pro Audio" scheduling, which work natively but not under Wine (Live's placement does not take effect there; MMCSS is stubbed).
    - Under Wine, with the workers pinned and halting thousands of times a second, C1E was what cost the time (T0031).
    - Linux with T0031 (DSP 6.49 / 6.52 / 6.18) is now 24–35 % below Windows in either configuration. That is across sessions, but far outside run-to-run spread.
  - Per-Set results: `profiler/plans/findings/d0010-results.jsonl`.
- **Lasting form (user decision 2026-10-20, before D0010's result: "We will leave it every boot for this test machine"):**
  - C1E off from GRUB on every boot, Linux and Windows (`01_profiler-c1e-off`, replacing the per-entry `46_profiler-c1e-off`).
  - The P-cores no deeper than C1 on Linux (`profiler-shallow-idle.service`, `profiler/kernel/idle/`).
  - IDLESTATEMAX 1 in Windows' power plan. Per D0010 it costs power there without a DSP gain; one command reverts it.
  - LiveIdleGuard stays installed (manual start) for a Live-only form.

## T0032: MMCSS, only Live's audio threads realtime (patch 0113), pre-registered 2026-10-20 ~07:00, before any of its runs
- **Why:**
  - On Windows, MMCSS raises only the threads an application registers for "Pro Audio". Wine's avrt is a stub, so the launcher runs the whole of Live with `chrt -r 10`: all 76 threads (UI, file loading, plugin windows) share the audio workers' realtime priority.
  - A diagnostic launch (`WINEDEBUG=+avrt,warn+threadname`) showed Live registering its AudioCalc workers (with `AVRT_PRIORITY_CRITICAL`) and two timer threads, nothing else.
  - D0010 suggested native Windows keeps Live's audio work fast through its own scheduling.
- **Patch 0113** (`WINE_MMCSS=1`; `notes/ABLETON-WINE-MMCSS.md`): a "Pro Audio" thread becomes SCHED_FIFO at `WINE_MMCSS_RTPRIO` (default 10) plus its MMCSS priority. AudioCalc runs at 12, below `pipeasio-rt`'s 15. The flag is reset on fork, and a revert restores the earlier scheduling.
  - **Probe:** `tools/mmcssprobe.c` passes in every mode on the dev runtime.
  - **Functional run** (dev runtime, `ABLETON_RT=off`): AudioCalc FIFO 12, `pipeasio-rt` FIFO 15, every other Live thread normal, DSP 7.0 %, no peaks over 100 %.
  - The trial runs on the official runtime after its build, audit and probe.
- **A:** as kept: `chrt -r 10` for all of Live, avrt the stub. **B:** `WINE_MMCSS=1 ABLETON_RT=off`.
  - Both arms: kept configuration (physcore, 5 workers, new display, posix_spawn, PipeASIO realtime, every-boot shallow idle).
  - ABAB × 3 on Inbuilts, Max4Live and VSTs at 120 s. Driver `profiler/trials/trial-T0032.sh`.
- **Rule D:**
  - D1: B lower in at least 8 of 9 Set-pairs (sign test, p = 0.02); D2: median paired change ≤ −3 %.
  - Guards: G1 no xruns in B; G2 B's PipeWire errors not significantly higher; G4 audio-thread CPU's median increase ≤ +5 %.
- **Mechanism** (a 10 s sampler of Live's threads in every run):
  - in B, AudioCalc SCHED_FIFO 12 and the UI thread (tid = pid) normal, with no other Live thread realtime except the timers;
  - in A, AudioCalc and the UI thread SCHED_RR 10.
- **Reported:** the peak median and worst peak, missed deadlines, Live's CPU, package power and temperature.
- **Verdicts:** keep = PASS with the mechanism; mechanism-confirmed = guards and mechanism hold but the primary fails; revert otherwise. If kept, `WINE_MMCSS=1 ABLETON_RT=off` joins the kept configuration.
- **T0032 — RESULT (2026-10-20 07:04–07:50; six runs clean, on the official runtime with 0113; build audit 194/194, probe 4/4 modes): rule D FAIL, so mechanism-confirmed (not kept).**
  - **DSP average:** B lower in 8 of 9 Set-pairs (p = 0.02) but by a median of only 0.3 % (Inbuilts 6.40 → 6.38, Max4Live 6.50 → 6.47, VSTs 6.18 → 6.19); D2 asks for 3 %.
  - **Guards:** G1 no xruns; G2 PipeWire errors 2 → 1; G4 audio-thread CPU +0.4 %. Live's CPU 27.3 → 28.0 %.
  - Worst-peak medians 59.8 / 77.5 / 60.8 → 76.8 / 66.4 / 60.4 %. Worker run-queue wait 1.8–2.1 → 2.2–2.8 ms per window.
  - **Mechanism held in every run:**
    - B: AudioCalc SCHED_FIFO 12, `pipeasio-rt` FIFO 15, the UI and every other Live thread normal (0 of about 3,200 samples realtime);
    - A: AudioCalc and the UI SCHED_RR 10, about 92 % of the other samples realtime.
  - **Reading:** with the workers pinned to their own cores (physcore), Live's other threads rarely compete with them at this load, so who else is realtime hardly matters. The switch stays opt-in. Under contention, the load ramp is where an effect could show.

## Load ramp: headroom (machinery 2026-10-20; exploratory run 07:52–08:21)
- **Why:** every trial so far plays the Sets at their own load, where Live's DSP average is now 6–7 % of the buffer period (T0031). What a musician feels is headroom: how much more Live can play before it misses deadlines. Contention, T0032's open question, only shows near that limit.
- **Method** (user, 2026-10-20: "lets duplicate all tracks for each pass"):
  - **Load:** scenario `profiler/scenarios/ramp-duplicate-all.json` (diagnostic grade; it needs the control surface).
    - The Set plays from the start. Every 51.4286 s (96 beats at 112 BPM), the bench handler's `/abl/bench/duplicate-all` duplicates every top-level track the Set had at the first pass (a group with its children).
    - Load k is the Set playing k times over, in sync.
  - **Bus trims** (user: "Send volume increases will distort returns. Should we add a gain to first device in returns to adjust down?"):
    - With N copies playing, the return tracks and the master receive N times the amplitude.
    - The first pass takes the Utility already first on each return track (when its gain is not automated) or puts a Utility first (on the master). Each pass then sets it to the Set's own gain − 20·log10 N dB.
    - Sends, faders and automation stay as the Set has them: setting an automated parameter would override its automation.
    - Live 12.4 calls Utility's gain "Output"; earlier versions call it "Gain".
  - **Steps:** `profiler/control/ramp-report.py` splits each Set's window at the duplications.
    - Step k runs from 10 s after the duplication that made it finished to the start of the next one. Live glitches while it builds the copies, and that belongs to neither step.
    - Steps last 20–40 s, getting shorter as duplication gets slower.
  - **Failure:** a step fails with 3 or more PipeWire errors from Live's nodes, or 3 or more peaks over 100 % (missed deadlines). **Headroom** is the load of the last step before the first failing one.
  - **Driver:** `profiler/trials/ramp-run.sh TAG [kept|mmcss] [SETS] [PASSES]`.
    - 10 passes give loads 1–10: about 9.5 min per Set, 28 min per run on the three Sets.
    - Since D0011 it also samples Live's threads' scheduling every 30 s and the package power every 5 s.
- **Exploratory run** (kept configuration, 2026-10-20 07:52–08:21). It ran before the trims existed, so the copies played at full level; level does not change the CPU cost.

  | Set | Headroom | DSP average: 1× → headroom → 10× | First failing step |
  |---|---|---|---|
  | Inbuilts | 5× | 6.75 → 13.47 → 23.16 % | 6×: 1 peak over 100 %, 5 PipeWire errors |
  | Max4Live | 4× | 6.68 → 11.97 → 24.25 % | 5×: 1 peak over 100 % (worst 143 %), 5 PipeWire errors |
  | VSTs | 5× | 6.48 → 9.57 → 16.24 % | 6×: 1 peak over 100 %, 3 PipeWire errors |

  - The DSP average rises by about 1.1–2.0 points per copy, yet steps fail at an average of only 11–15 % of the period. **The limit is single slow blocks (spikes), not throughput.**
  - Peak medians: 14–15 % at 1×, 20–25 % at the first failure. Worst peaks at the first failure: 101–143 %.
  - Duplicating took 2.3 s for the first copy. The ninth took 11 s (Inbuilts, VSTs) and 21 s (Max4Live).
- **Trims verified** (2026-10-20 09:05, Inbuilts, 2 passes):
  - 3 trims: the two returns' own Utilities, and a new Utility first on the master. Each display within 0.0 dB of its target.
  - DSP 6.62 % at 1×, 7.77 % at 2×.

### D0011: MMCSS under load (diagnostic, pre-registered 2026-10-20 09:12, commit 8f6e7da, before any of its runs)
- **Question:** T0032 found that MMCSS (only Live's audio threads realtime) makes no difference at the Sets' own load (−0.3 %). Does it raise the headroom, where more of Live's other threads are busy (UI, the copies' devices, streaming)?
- **Design:** A1 B1 A2 B2 load ramps, about 2 hours (`profiler/trials/d0011.sh`).
  - A: kept (`ramp-run.sh d0011-A1 kept`): `chrt -r 10` for all of Live.
  - B: `WINE_MMCSS=1 ABLETON_RT=off` (`ramp-run.sh d0011-B1 mmcss`).
  - Each run: Inbuilts, Max4Live, VSTs, 10 passes, trims on.
  - Both arms in the kept configuration: physcore with 5 workers, new display, posix_spawn, PipeASIO realtime, every-boot shallow idle, and the official runtime with 0113.
- **Measured per Set-run:**
  - the headroom;
  - per load: the DSP average, peak median, worst peak, peaks over 100 %, PipeWire errors and duplication time;
  - Live's threads' scheduling, and package power.
- **Mechanism:** in every B run, AudioCalc runs SCHED_FIFO 12, `pipeasio-rt` FIFO 15, and the UI and every other Live thread normal. In every A run, AudioCalc and the UI thread run SCHED_RR 10.
- **Reading** (pre-stated; `profiler/control/ramp-compare.py`), over six Set-pairs (3 Sets × 2 pairs):
  - MMCSS **raises the headroom** if B's is higher in at least 3 of the 6 pairs, lower in none, and higher on average by more than the A/A spread (the mean |A1 − A2| over the Sets).
  - It **lowers** the headroom by the mirror rule. Otherwise no difference in headroom is shown.
  - Secondary, reported: glitches (PipeWire errors plus peaks over 100 %) over all loads per Set-pair, and the DSP average and peak median at each load, B against A.
  - A run whose bench fails is rerun once in place, before the next run.
- **Not a trial:** a headroom gain would not change T0032's verdict by itself. A trial with a pre-registered ramp rule would follow.
- **D0011 — RESULT (2026-10-20 09:13–11:07; four runs clean, each with its 3 trims and the mechanism in place): no difference in headroom shown.**
  - **Headroom** (A1, A2 | B1, B2): Inbuilts 5, 4 | 4, 5; Max4Live 5, 4 | 4, 5; VSTs 5, 5 | 5, 5.
    - B higher in 2 of 6 Set-pairs and lower in 2; mean B − A 0.00 against an A/A spread of 0.67.
    - At this resolution the ramp's headroom varies by one step from run to run.
  - **Glitches** (PipeWire errors plus peaks over 100 %, all loads): A 96 / 103, 89 / 108, 72 / 81; B 109 / 95, 103 / 101, 69 / 71. Fewer in B in 4 of 6 Set-pairs.
  - **DSP average:** B lower at 26 of 30 Set-loads.
    - The median change over the loads is −0.9 % (Inbuilts), −2.1 % (Max4Live) and −1.9 % (VSTs).
    - At 1× it is −0.9 to +0.5 %, as in T0032.
  - **Mechanism held in every run:**
    - B: AudioCalc SCHED_FIFO 12, `pipeasio-rt` FIFO 15, the UI and every other Live thread normal (0 of 4,455 and 4,432 samples realtime).
    - A: AudioCalc and the UI SCHED_RR 10, 93 % of the other samples realtime.
  - **Power and heat:**
    - Package power per step is the same in both arms: 22–24 W at 1×, 28–33 W at 5×, 34–42 W at 10× (`ramp-report.py --power`).
    - The steps never ran hot: the package reached at most 66–79 °C.
    - The runs' highest temperatures (89–96 °C) and the CPU's thermal throttling fell during duplication and Set loading, outside the measured steps. The package throttled about 1 s in A2 and 6.5 s in B2, mostly worker core 6.
  - **Where the misses fall** (`profiler/control/ramp-beats.py`; `findings/d0011/beats.txt`):
    - 77–82 % of the misses at loads 4× and up fall in 4 of the loop's 24 bars: those starting at beats 60, 76, 92 and 96. PipeWire's report lags up to two beats.
    - The pattern is the same in all three Sets and in the exploratory run (79–83 %).
    - The bench Sets share one arrangement. Its track "7-Vocal 05" (Simpler: a one-second 44.1 kHz one-shot at the highest interpolation) plays at beats 60–64, 76–80 and 92–100 and nowhere else. Around beat 44, where four other tracks start clips, there are fewer misses.
    - The copies play in sync, so every copy's notes start in the same block. The ramp's limit is that burst, N times over, not the steady load.
  - **Reading:**
    - MMCSS makes Live's blocks slightly cheaper under load (1–3 % DSP) but does not move the spikes that end the ramp.
    - The headroom is limited by a burst at fixed points in the arrangement, not by scheduling.
    - The next question is what costs the time there; each copy's note-ons on "Vocal 05" are the lead.
  - Files: `profiler/plans/findings/d0011/` (per-run reports with per-step power, the comparison, the bar histograms).

## D0012: audio worker count 8–12, smoke test (2026-10-20, written before its runs)
- **User:** "lets run a test to figure out exactly the best audio worker count for linux machine", then "Lets do only a run of 8 to 12", "This is a quick smoke test to see what is better. We can do a full run later", "We just want current best across 8 to 12 workers one pass".
- **Counts in use today:** the trials keep 5 workers, one per physical P-core (T0022). The everyday launcher setting is auto, which gives 15 workers on this laptop (Options.txt `-MaxAudioThreads=15`), with nothing pinned.
- **Design:** one bench run per count (8, 9, 10, 11, 12), in the order 10, 8, 12, 9, 11 (`profiler/trials/d0012.sh`).
  - pipeasio-rt on CPU 0, and each AudioCalc thread on a CPU of its own: the P-cores' first threads (2, 4, 6, 8, 10), then their siblings (3, 5, 7, 9, 11), then the E-cores (12, 13).
  - So 8 adds three siblings, 10 fills every P-core thread outside pipeasio-rt's core, and 11 and 12 add one and two E-cores.
  - Everything else as kept: posix_spawn, PipeASIO realtime, the new display, every-boot shallow idle, `chrt -r 10` for all of Live.
- **Reading** (`profiler/trials/d0012_summary.py`):
  - The best count has the lowest DSP average over the three Sets (the mean of each Set's ratio to the five counts' mean).
  - Reported: peaks, PipeWire errors, xruns, the audio-thread and Live CPU, and the worker count seen.
  - Today's T0032 A runs (the kept 5 workers, same boot and configuration) are shown for context.
  - One run per count gives no verdict; a full run decides.
- **D0012 — RESULT (2026-10-20 12:22–13:01; five runs clean; the workers were where the design put them in every run): fewer is better across the whole range.**

  | Workers | DSP average % (Inbuilts / Max4Live / VSTs) | Score | Audio-thread CPU % | Live CPU % |
  |---|---|---|---|---|
  | 8 | 6.76 / 6.94 / 6.51 | 0.976 | 19.4 / 20.6 / 16.6 | 31.2 |
  | 9 | 6.85 / 7.00 / 6.60 | 0.988 | 20.6 / 21.8 / 17.9 | 34.1 |
  | 10 | 6.95 / 7.03 / 6.70 | 0.999 | 21.7 / 22.8 / 19.1 | 36.8 |
  | 11 | 7.06 / 7.14 / 6.81 | 1.015 | 23.1 / 24.3 / 20.6 | 35.0 |
  | 12 | 7.10 / 7.22 / 6.85 | 1.023 | 24.3 / 25.8 / 22.1 | 37.0 |
  | 5, kept (T0032 A, medians of 3) | 6.40 / 6.50 / 6.18 | — | 15.6 / 16.7 / 12.7 | 27.3 |

  - Each worker added costs about 1 % DSP and 1.2 points of audio-thread CPU. The order holds on every Set, although the runs went in the order 10, 8, 12, 9, 11.
  - No PipeWire errors, peaks over 100 % or xruns in any run. Worst peaks 55–78 %.
  - **Best of 8–12: 8.** The kept 5 (another session, same boot) is lower still: 5–6 % lower DSP and 3.8 points lower audio CPU than 8, so the optimum lies at 8 or below.
  - The everyday launcher setting (auto, 15 workers, nothing pinned) sits further up this curve; the trials' pinning is not in the launcher.
  - A full run should cover about 3 to 8 workers, with the kept 5 inside the same session.
  - Files: `profiler/plans/findings/d0012/`.

## D0013: audio worker count 1–5, smoke test (2026-10-20, written before its runs)
- **User:** "Lets try 5 all the down to 1 workers", after D0012.
- **Design:** as D0012, one bench run per count, in the order 3, 5, 1, 4, 2 (`profiler/trials/worker-smoke.sh D0013 3 5 1 4 2`).
  - pipeasio-rt on CPU 0; the workers on the P-cores' first threads, one each: 1 worker on CPU 2; 2 on CPUs 2 and 4; and so on up to 5 on 2, 4, 6, 8, 10.
  - 5 is the kept layout (physcore), so the reference is in the same session this time.
- **Reading** (`profiler/trials/d0012_summary.py --id d0013`): as D0012. One run per count gives no verdict.
- **D0013 — RESULT (2026-10-20 13:17–13:56; five runs clean; the workers were where the design put them in every run): block time is flat from 2 to 5 workers, and the CPU cost rises with each one.**

  | Workers | DSP average % (Inbuilts / Max4Live / VSTs) | Score | Audio-thread CPU % | Live CPU % |
  |---|---|---|---|---|
  | 1 | 7.16 / 7.54 / 5.62 | 1.048 | 11.6 / 12.4 / 8.1 | 23.2 |
  | 2 | 6.47 / 6.67 / 5.81 | 0.981 | 12.4 / 13.3 / 9.4 | 24.2 |
  | 3 | 6.46 / 6.57 / 5.98 | 0.985 | 13.7 / 14.7 / 10.6 | 24.1 |
  | 4 | 6.46 / 6.56 / 6.18 | 0.996 | 14.8 / 15.8 / 11.7 | 27.9 |
  | 5, kept | 6.41 / 6.50 / 6.18 | 0.990 | 15.6 / 16.7 / 12.7 | 27.1 |

  - The 5-worker run reproduced T0032's A arm (6.40 / 6.50 / 6.18), so D0012's 8–12 runs, an hour earlier, compare.
  - **2 to 5 workers lie within about 1.5 % of each other** (the score's spread; one run per count is noise at that size). 2 and 3 lead on VSTs (5.81, 5.98 against 6.18); 5 leads on Max4Live.
  - **The audio-thread CPU falls about 1.1 points per worker removed:** 3 workers use 1.9 points less than 5 on Inbuilts (−12 %), and Live's CPU is 3 points lower.
  - **1 worker** is 12–16 % slower on Inbuilts and Max4Live, but the fastest on VSTs, which has little to share out.
  - No missed deadlines or xruns; PipeWire errors 0–2 per run.
  - **With D0012:** block time is flat from 2 to 5 and rises from 8 to 12 by about 1 % per worker. At the Sets' own load a few workers suffice; the extra ones add synchronisation and CPU.
  - The kept 5 is not beaten on block time. A count of 3 would save CPU at equal block time. That is a rule H question (audio-thread CPU, with the DSP guard), and the load ramp is where fewer workers could cost headroom.
  - Files: `profiler/plans/findings/d0013/`.

## D0014: the best Linux configuration with 2 workers, against Windows and upstream (diagnostic, pre-registered 2026-10-20 14:04, commit 4ff77c7, before any of its runs)
- **User:** "Lets take the current best fixes on linux and run a full pass with two workers to get a comparison against windows and upstream baseline". This came after D0013, where 2 to 5 workers tied on block time and 2 used the least CPU without 1 worker's penalty.
- **Design:** as D0006, three Linux runs, each from a fresh boot with the boot settled first (`ORDER="A1 A2 A3" LINUX_CONFIG=kept-w2 TRIAL_ID=D0014 profiler/windows/cross-os-trial.sh d0014`).
  - The kept configuration: posix_spawn, PipeASIO realtime, the new display, Live at RR 10, and the every-boot shallow idle (C1E off from GRUB, the P-cores no deeper than C1).
  - `ABLETON_MAX_AUDIO_THREADS=2`: pipeasio-rt on CPU 0, the two AudioCalc threads on CPUs 2 and 4.
  - Inbuilts, Max4Live and VSTs at 120 s.
- **Compared with** (per Set, medians of three runs):
  - Windows as shipped: D0005's corrected Windows runs, which D0010's A arm reproduced.
  - The upstream Linux baseline: D0006.
  - The best Linux configuration with 5 workers: T0031's B arm, the earlier table's column; D0013's 5-worker run for reference.
- **Reported:** DSP average, peak median, missed deadlines (peaks over 100 %), PipeWire errors, Live's CPU and the audio-thread CPU. No verdict: it is the cross-OS table's new column.
- **D0014 — RESULT (2026-10-20 14:04–14:35; three runs clean, each from a fresh boot; 2 workers on CPUs 2 and 4 in every Set-run; C1E off and the P-cores no deeper than C1 at every boot):**

  | Per Set, medians of three runs | Linux upstream (D0006) | Linux best, 5 workers (T0031 B) | **Linux best, 2 workers (D0014)** | Windows as shipped (D0005, corrected) |
  |---|---|---|---|---|
  | DSP average % (Inbuilts / Max4Live / VSTs) | 11.3 / 11.8 / 11.0 | 6.5 / 6.5 / 6.2 | **6.4 / 6.8 / 5.8** | 9.4 / 10.0 / 8.2 |
  | Missed deadlines (9 Set-runs) | 55 | 1 | **0** | 2 |
  | PipeWire errors (9 Set-runs) | 176 | 12 | **3** | — |
  | Live CPU % | 63.8 / 68.2 / 60.2 | 27.3 / 29.4 / 22.7 | **25.8 / 25.3 / 20.1** | 33.0 / 33.2 / 23.8 |
  | Audio-thread CPU % (workers + callback thread) | 51.2 / 55.4 / 50.0 | 15.7 / 16.7 / 12.7 | **12.4 / 13.4 / 9.4** | 28.1 / 29.5 / 19.6 |

  - **Against 5 workers:** block time is level (−1 %, +4 %, −6 % per Set). The audio threads use 20–26 % less CPU and Live 5–14 % less; no missed deadline (1 with 5 workers), 3 PipeWire errors against 12.
  - **Against Windows:** DSP 29–32 % lower, Live's CPU 16–24 % lower, the audio threads at less than half of Windows' CPU (AudioCalc + the ASIO callback thread there, + pipeasio-rt here), 0 missed deadlines against 2. Windows ran Live with 5 workers and its stock power and idle settings (D0005); D0010 showed limiting Windows' idle does not change its DSP, and Windows with 2 workers is untested.
  - **Against upstream Linux:** DSP 43–47 % lower, missed deadlines 55 → 0, PipeWire errors 176 → 3, Live's CPU 60–67 % lower.
  - The three runs agree within about 2 % per Set (DSP 6.33–6.44 / 6.63–6.85 / 5.77–5.83).
  - Files: `profiler/plans/findings/d0014-results.jsonl` (with D0006's `~/profiler-crossos/d0006`, T0031 B and D0005's corrected figures above).

## D0015: the best Linux configuration with 3 workers, the same pass (diagnostic, written before any of its runs)
- **User:** "Now lets do the same run with 3 workers".
- **Design:** as D0014 with `ABLETON_MAX_AUDIO_THREADS=3`, the three AudioCalc threads on CPUs 2, 4 and 6 (`ORDER="A1 A2 A3" LINUX_CONFIG=kept-w3 TRIAL_ID=D0015 profiler/windows/cross-os-trial.sh d0015`).
- **Compared with:** D0014 (2 workers), T0031 B (5 workers), D0005 (Windows) and D0006 (upstream), as in D0014's table. No verdict.
- **D0015 — RESULT (2026-10-20 14:38–15:09; three runs clean, each from a fresh boot; 3 workers on CPUs 2, 4, 6 in every Set-run; C1E off and the P-cores no deeper than C1 at every boot):**

  | Per Set, medians of three runs | 2 workers (D0014) | **3 workers (D0015)** | 5 workers (T0031 B) | Windows as shipped (D0005, corrected) | Linux upstream (D0006) |
  |---|---|---|---|---|---|
  | DSP average % (Inbuilts / Max4Live / VSTs) | 6.4 / 6.8 / 5.8 | **6.4 / 6.6 / 6.0** | 6.5 / 6.5 / 6.2 | 9.4 / 10.0 / 8.2 | 11.3 / 11.8 / 11.0 |
  | Missed deadlines (9 Set-runs) | 0 | **0** | 1 | 2 | 55 |
  | PipeWire errors (9 Set-runs) | 3 | **2** | 12 | — | 176 |
  | Live CPU % | 25.8 / 25.3 / 20.1 | **25.4 / 26.4 / 20.5** | 27.3 / 29.4 / 22.7 | 33.0 / 33.2 / 23.8 | 63.8 / 68.2 / 60.2 |
  | Audio-thread CPU % | 12.4 / 13.4 / 9.4 | **13.7 / 14.6 / 10.5** | 15.7 / 16.7 / 12.7 | 28.1 / 29.5 / 19.6 | 51.2 / 55.4 / 50.0 |

  - Block time with 2, 3 and 5 workers is level within the runs' spread. 3 against 2: −0.5 %, −3.4 %, +2.8 %. 3 against 5: −1.4 %, +0.5 %, −3.4 %.
  - The audio threads cost about 1.2 points more with 3 workers than with 2, and 12–18 % less than with 5.
  - Against Windows, 3 workers are 27–35 % lower on DSP. The three runs agree within about 1 % per Set.
  - Files: `profiler/plans/findings/d0015-results.jsonl`.

## D0016: Live's first buffer and play instant against PipeWire's cycle (diagnostic, written before its run)
- **User:** "Lets focus on the first buffer that live gets as that determines if they are all insync"; "The start play instant in ableton if this isnt aligned internally with pipewire we have a window for unders".
- **Background:** PipeASIO calls Live's `bufferSwitch` inside PipeWire's process callback, one block per graph cycle. It does so only while the graph's quantum equals Live's buffer size. Until then it mutes and runs Live on a wall-clock cadence (`patches/pipeasio/0005`).
- **Design:** `profiler/trials/first-buffer.sh d0016 2 Inbuilts 30`.
  - PipeASIO's USDT probes are armed by file before Live starts, so every cycle and block is recorded in full from the first one.
  - pw-profiler runs from before Live starts. The bench's commands are marked by a sendto probe on the same clock.
  - One bench window: Inbuilts, 30 s, kept configuration with 2 workers, `PIPEASIO_TELEMETRY=on`.
- **Questions:**
  1. The graph's quantum at Live's first buffer, and the first block's flags and phase.
  2. The muted stretch, and when one block per cycle begins.
  3. Whether, from then on, every cycle carries exactly one block at a steady phase, with no missed frames.
  4. At the play instant: when the transport's first heavy block runs, its phase and slack, and whether any block in the next 3 s is late, muted or off the one-per-cycle pattern.
- No verdict: it tells whether the start and the play instant are aligned.
- **D0016 — RESULT (2026-10-20 15:10–15:12; one run; 36,716 cycles and blocks from Live's first buffer, every probe hit recorded):** the start and the play instant are aligned. The graph's cycles are not evenly spaced: they alternate 1.0, 1.5, 1.5 ms.
  - **First buffer:** the graph was already at 64 frames, so there was no size mismatch and no muted stretch. Blocks 1–3 were not admitted (Live not yet running its callback). From block 4, 10 ms after the first, there was exactly one block per cycle for all 36,712 blocks: no skipped or extra cycles, no missed frames, no muting.
  - **Steady phase:** Live's `bufferSwitch` is entered 7 µs after the cycle's start (p99 22 µs). Live spends 74 µs in it (p99 163 µs).
  - **Play instant:** the transport's first heavy block ran 10.6 ms after the play command, 8.5 µs into its cycle, with 1.5 ms of slack. In the 3 s after play: no late block, no muting, minimum slack 1.5 ms.
  - **Late blocks: 3, all during Live's start-up, 8–9.5 s before play:**
    - block 5 entered 6 ms after its cycle's start;
    - block 951's callback ran 4.5 ms, 3.8 ms of it CPU (PipeASIO's telemetry), start-up work on the audio thread;
    - block 705 "late" by 0.6 µs with 20 µs of work, an artefact of the deadline estimate (below).
  - In the measured window (play + 5 s to + 35 s) no block exceeded 1 ms. The bench's stop, after the window, brought blocks of 1.0–1.2 ms.
  - **The cycle pattern:** the cycles' starts (clock.nsec) are spaced 1,000 µs (12,205 cycles) or 1,500 µs (24,403), repeating 1.0, 1.5, 1.5 ms. The mean is 1,333.4 µs, which is 64 frames at 48 kHz; the position advances 64 frames every cycle.
    - PipeWire drives the Focusrite from its period interrupt (`api.alsa.disable-tsched = true`, the pro-audio profile).
    - snd-usb-audio completes the high-speed stream's 125 µs packets in 0.5 ms transfers, so a 1.333 ms period ends on a 0.5 ms boundary.
    - **Every third cycle gives Live 1.0 ms instead of 1.333 ms.** A block of 1.0–1.33 ms, which Live's meter shows as 75–100 % and fine, misses the graph's deadline when it falls in a short cycle. That fits PipeWire errors without missed deadlines (D0014: 3 against 0).
  - **The deadline estimate:** PipeWire's next-cycle estimate (`clock.next_nsec`, PipeASIO's deadline) lies a median 248 µs after the real next start, and before it in 16 % of cycles. PipeASIO's slack and late counts are therefore unreliable on this device; the real deadline is the next cycle's start.
  - **Next:** make the cycles even, either with timer scheduling for the Focusrite (`api.alsa.disable-tsched = false`, with the headroom its 0.5 ms pointer needs) or with a period that is a multiple of 0.5 ms (72 frames: an even 1.5 ms). Then count PipeWire errors and the ramp's headroom.
  - Files: `profiler/plans/findings/d0016/analysis.txt`; the raw probes on the laptop (`~/.local/share/profiler/runs/first-d0016`).

## D0017: timer scheduling for the Focusrite, even cycles (diagnostic, written before its runs)
- **User:** "Lets schedule 1 for testing". Option 1 after D0016: timer scheduling with headroom.
- **Switch:** `profiler/kernel/pipewire/focusrite-tsched.sh on` installs a WirePlumber rule for the Focusrite's pro-audio nodes (`api.alsa.disable-tsched = false`, `api.alsa.headroom = 32`, since the hardware pointer moves in 0.5 ms = 24-frame steps) and restarts PipeWire. `off` removes the rule.
- **Steps:**
  1. **Mechanism:** the two nodes report `disable-tsched` false and headroom 32. Then `first-buffer.sh d0017 2 Inbuilts 30`, as D0016, checking:
     - the cycles' spacing within 1,333 ± 100 µs at p1 and p99 (D0016: 1,000 and 1,500);
     - one block per cycle;
     - no errors on the Focusrite's own nodes (pw-top ERR);
     - PipeWire errors on Live's node over the run;
     - Live's reported latency against D0016's.
  2. **If the cycles are even:** a full pass as D0014 (three runs from fresh boots, `kept-w2`) with the rule in place, compared with D0014 (3 PipeWire errors in 9 Set-runs; DSP 6.4 / 6.8 / 5.8).
  3. The rule is removed afterwards unless the user keeps it.
- **Reading:**
  - Even cycles confirm the mechanism.
  - Over 18 minutes, fewer PipeWire errors than D0014's 3 would be suggestive only. The load ramp, where errors are frequent, is the test of effect; it follows if steps 1 and 2 hold.
  - Errors on the Focusrite's nodes, or xruns, would mean the headroom is too small.
- **D0017 step 1 — RESULT (2026-10-20 15:30–15:31; one first-buffer run, Inbuilts, 2 workers, 35,829 cycles): the mechanism holds.**
  - The Focusrite's nodes report `disable-tsched` false and headroom 32 (before: true, none).
  - **Cycle spacing:** p1 1,333.2, p50 1,333.3, p99 1,335.1 µs (D0016: 988.8, 1,499.9, 1,511.2). The cycles are even; no 1.0 ms ones remain.
  - **PipeWire's next-cycle estimate is exact:** 0.0 µs from the real next start at p1, p50 and p99, early in 2 of 35,728 cycles (D0016: median +248 µs, early in 16 %). PipeASIO's slack and late counts are accurate now.
  - One block per cycle from block 3; no muting, no missed frames. Live's `bufferSwitch` is entered 12 µs into the cycle (p99 25 µs; D0016: 7 and 22).
  - **Late blocks: 2, both at start-up, 7.1 s before play.** Live's callback ran 4.4 ms (the start-up work D0016 also showed), and the next block started 1.8 ms late behind it. None in the play window or the measured window.
  - **Play instant:** the first heavy block ran 17 ms after the command, 11.6 µs into its cycle, with 1.0 ms of slack. No late block in the next 3 s.
  - **Errors on the Focusrite's input node** (the graph's driver) over the bench's record: 2 (D0016: 19).
  - **Latency:** Live reports 2.67 ms overall in both modes. The 32 frames of headroom (0.67 ms) are not in what PipeASIO reports to Live; a loopback measurement would give the real figure.

## Context
- `WINE_POSIX_SPAWN=1` (T0020) removed the fork-induced page-fault storms, and dropouts are now rare. **T0022 (one audio thread per physical P-core, 5 workers) is a keep**: audio-thread CPU −26 %, Live CPU 46.9 → 35.0 %, DSP average lower. The goal now is more headroom: shorter, steadier audio blocks and less CPU, through kernel-level changes.
- User (2026-10-19): "We want ableton specific improvement… lets get clever and esoteric for this ableton only kernel patch concept"; then "complete implementation plan for kernel level items".
  - **mitigations: all off** (as a boot entry);
  - **the in-kernel spin replaces T0025** (the Wine-side ioctl-polling spin is dropped);
  - extras in scope: **boot-time isolation, pre-wake before each block, direct NT syscall entry, a sched_ext audio scheduler**.
- Evidence (D0001, D0003, T0021, T0022):
  - Audio-thread cycles: Live's code ~64 %; the kernel side of the AudioCalc fan-out (ntsync ioctls, ~245 sync calls per 1.33 ms block: ~32 SetEvent, ~70 ResetEvent, ~75 waits) ~21 %; RT balancing ~9 %; other kernel ~6 %.
  - Worker sleeps: median ~20 µs. Block wake latency: p50 31–44 µs, max ~320 µs.
  - P-cores idle via intel_idle with BIOS states C1 / C2 / C3 (exit latency 1 / 127 / 1048 µs); 72 % of C2 entries were too deep. T0001's C1-only cap (all CPUs) changed nothing, in the older, noisier configuration.
  - The RFDS mitigation runs VERW on every return to user space.
  - T0021: removing RT balancing did not lower CPU. T0022: removing SMT sharing between audio threads did.
- Guardrails:
  - Every change is opt-in, with a probe or verification, a note in `notes/`, a pre-registered ABAB trial and a ledger line.
  - The stock kernel, boot entry and ntsync module stay the default after any reboot (one-shot `grub-reboot` only; custom modules loaded per run, never installed).
  - Live is never modified, hooked or disassembled; reading its imports and logs is allowed.
  - No heavy analysis on the laptop while a trial measures.

## Platform facts the plan relies on (explored 2026-10-19)
- Kernel 7.2.11-1-cachyos:
  - Built with clang 23.1.3, LLD and ThinLTO. `MODVERSIONS` off, so only vermagic must match. Secure Boot off, lockdown none, `sig_enforce=N`: unsigned modules load (taint E).
  - Build tree at `/usr/lib/modules/$(uname -r)/build`. `NO_HZ_FULL`, `RCU_NOCB_CPU`, `CPU_ISOLATION`, `SCHED_CLASS_EXT`, `DEBUG_INFO_BTF_MODULES`, `KPROBES`/`FPROBE` and `HZ=1000` are built in.
  - `scx-scheds` 1.1.3 is installed (`scx_layered`, `scx_lavd`, …).
- ntsync is a module (in-tree, signed, no parameters, misc device `ntsync`, mode 0666). `ntsync.c` is not on the laptop and must come from the 7.2.11 source. Upstream structure: `ntsync_obj` (spinlock; union with `event{bool manual, signaled}`; `any_waiters`/`all_waiters`; `all_hint`), `ntsync_lock_obj()` (device `wait_all_lock` only when wait-all waiters exist), `setup_wait()` (kmalloc'd `ntsync_q`, `atomic_t signaled = -1`), `try_wake_any_event()`/`try_wake_all()`, `ntsync_schedule()`. There is no mmap.
- Wine 11.13 fork:
  - wineserver creates every ntsync object on its own device fd and sets and resets events itself.
  - Clients receive object fds lazily (`get_inproc_sync_fd`, SCM_RIGHTS) and cache them per handle in `struct inproc_sync {refcount, fd, access, type, closed}` (`dlls/ntdll/unix/sync.c`). Duplicated handles mean several fds per object.
  - Event calls are one ioctl on the object fd; waits are WAIT_ANY/WAIT_ALL on the shared device fd, with the thread's alert event when alertable.
  - Thread names reach `/proc/…/comm` (`AudioCalc`, `pipeasio-rt`).
  - The ntsync UAPI is vendored and pinned (`vendor/ntsync-uapi/linux/ntsync.h`).
- Repo:
  - Nothing handles cpuidle, boot variants or modules yet.
  - `profiler/bin/boot-kernel` only knows `normal|rt` and verifies through `uname -v`. grub.cfg is regenerated by a pacman hook, so variants must come from `/etc/grub.d/`.
  - Root goes through `profiler/setup/root-helper/profiler-root-helper` (allowlisted knobs, no cpuidle or module verbs).
  - The ledger lacks a `kernel` change kind (`profiler/bin/ledger-report`, `profiler/LEDGER.md`).
  - Probe precedents: `tools/syncbench_native.c` (raw `/dev/ntsync`) and `scripts/check-ntsync.sh` (27 tests).
  - The campaign tooling (`trial-lib.sh`, `campaign_tools.py`, `ledger_campaign.py`, drivers, `d0003-capture`) lives only on the laptop in `~/.local/state/profiler/`.

## Work items
| ID | Item | Kind | Gate | Trial / rule |
|---|---|---|---|---|
| I0 | Infrastructure (tooling into repo, root-helper verbs, GRUB variants, boot-kernel table, ledger kind) | tooling | — | — |
| K0 | ntsync and wake census | diagnostic D0004 | — | none |
| K1 | SMT siblings of the audio cores offline | runtime config | — | rule H |
| K2 | `mitigations=off` boot entry | boot config | I0 | reboot per run, rule H |
| K3 | ntsync-live stage 1: in-kernel optimistic spin (= **T0025**) | kernel module | K0 (spin budget) | rule D + CPU guard |
| K4 | Per-core C-state limit (C1 max on audio cores; teo variant) | runtime config | K0: ≥10 % of audio wakes from C2/C3 | rule D |
| K5 | LiveSync: shared-memory event state (module stage 2 + Wine patch 0113) | kernel module + Wine | K3 built and verified, K0 fast-path share | rule D (+H reported) |
| K6 | Boot-time isolation (`nohz_full`, `rcu_nocbs`, `irqaffinity`, `isolcpus=managed_irq`) | boot config | I0; T0024 result informs | reboot per run, rule D |
| K7 | Pre-wake before each block (PipeASIO-timed), esoteric form = custom cpuidle governor | PipeASIO + daemon/module | K4 kept but power cost, or K0 shows C-state exits | rule D, power reported |
| K8 | Direct NT syscall entry (handle-based ioctls, thin stub) | kernel module + Wine | K5 kept; ≥100 remaining sync syscalls per block | rule D |
| K9 | sched_ext audio policy (`scx_layered` first, then a custom `scx_ableton`) | BPF scheduler + launcher | feasibility study | rule D |

Trial IDs are assigned when each item is registered. The campaign's pending T0023 (display) and T0024 (runtime core clearing) keep their places and run on the new `physcore` layout.

## Trial rules
- **Rule H (CPU):** as in the campaign. M is the audio-thread CPU from `proc-delta.json`.
  - H1: B lower in ≥8 of 9 Set-pairs.
  - H2: median change ≤ −3 %.
- **Rule D (block time):** the primary metric is Live's DSP average per Set-run.
  - D1: B lower in ≥8 of 9 Set-pairs (sign test, p = 0.02).
  - D2: median paired change ≤ −3 %.
- **Guards:**
  - G1: no xruns in B.
  - G2: B's PipeWire errors not significantly higher (one-sided binomial, p ≥ 0.05).
  - G3: no Set's DSP average worse by more than 2× its A/A spread (rule H items).
  - G4 (rule D items): M's median increase ≤ 5 %. For spin items (K3 = T0025, K5b) the limit is +15 points of one core (0.15 CPU), and a larger cost turns a keep into mechanism-confirmed for the user to decide.
- **Verdicts:**
  - keep = PASS and the mechanism holds;
  - mechanism-confirmed = guards and mechanism hold, but the primary criterion fails;
  - revert otherwise.
- Always reported: worst DSP peak, Live CPU, RAPL package power and temperature.
- Reboot-per-run items (K2, K6) use the T0015 machinery: a one-shot `grub-reboot` and boot settling before every run.

## I0 Infrastructure (workstation work, in parallel with trials)
1. **Campaign tooling into the repo** under `profiler/trials/`:
   - Today's laptop-only copies of `trial-lib.sh`, `campaign_tools.py`, `ledger_campaign.py`, the T0021–T0024 drivers and `d0003-capture` move here.
   - The laptop then runs them from its checkout.
   - Add `campaign_main_reboot VARIANT_A VARIANT_B`, ported from the T0015 step driver and hub waiter.
   - Add rule D to `campaign_tools.py` (`rule-d TRIAL`, with G4).
2. **Root-helper verbs** (`profiler/setup/root-helper/profiler-root-helper`), each regex-validated and covered by `snapshot`/`reset`:
   - `knob set cpuidle.<cpu>.<state> 0|1`
   - `knob set cpuidle-governor menu|teo`
   - `knob set cpu-online.<cpu> 0|1` (only CPUs 1–11)
   - `module load <path> [k=v…]`: the path must be under `~/Projects/ableton-linux/profiler/kernel/build/` and match the sha256 recorded by the build script.
   - `module unload ntsync`, which refuses while `/dev/ntsync` is held.
   - `module param ntsync.<name> <value>`
   - Drivers use these verbs instead of bare `sudo -n`.
3. **GRUB variants:**
   - `profiler/kernel/grub/45_profiler-variants`, installed to `/etc/grub.d/` by `profiler/kernel/grub/install.sh`, emits entries titled `CachyOS Linux, with Linux linux-cachyos (profiler: <name>)` after the normal entries (45, not 09: earlier entries would shift the saved default's position).
   - Each entry clones the normal entry's `linux`/`initrd` lines, which `install.sh` reads from `grub.cfg` and templates. The extra arguments come from `/etc/default/profiler-grub-variants` (`name|args`).
   - `install.sh` runs `grub-mkconfig` and checks the titles appear. `GRUB_DEFAULT` is never touched.
4. **`profiler/bin/boot-kernel`:** replace the `normal|rt` case with a table: name → title regex → expected `/proc/cmdline` tokens → extra check.
   - `mitigations-off`: vulnerabilities report "Vulnerable".
   - `isolated`: `/sys/devices/system/cpu/nohz_full` lists the audio CPUs.
   - The health line adds the cmdline variant tokens.
5. **Ledger kind `kernel`** in `profiler/bin/ledger-report` (`CHANGE_KINDS`) and `profiler/LEDGER.md`. `change.switch` holds the boot entry, module parameters or knob values.
6. **Notes:** one per item in `notes/ABLETON-KERNEL-<ITEM>.md` (Switch, Why, Design, Verification, Effect in Live), following `notes/ABLETON-WINE-POSIX-SPAWN.md`.

## K0 Census (diagnostic D0004; first laptop slot after recording T0022)
- **Tool:** `profiler/kernel/census/ntsync-census.bt`, started by `census-capture`. That is a bench-tracer stand-in with `d0003-capture`'s start/stop contract (`ABLETON_BENCH_TRACER` plus `ABLETON_BENCH_ROOT_HELPER=/nonexistent`).
- One 60 s window each on Inbuilts and Max4Live, kept configuration (`physcore`, 5 workers).
- Probes are fentry/kprobe/tracepoint programs (non-preemptible, small stacks) plus the two PipeASIO USDT block markers (single thread, under 64 B of stack):
  - `ntsync_event_set`: per caller role (comm prefix), whether the event was already signaled (`u.event.signaled`), whether any waiter was queued (`any_waiters` non-empty or `all_hint`), and pulse.
  - `ntsync_event_reset`: whether the event was already reset.
  - WAIT_ANY entry and exit, and `ntsync_schedule`: per thread, whether the wait was satisfied immediately or slept, and how long the sleep lasted.
  - `sched_waking` / `sched_switch` for audio threads: wake latency. `power:cpu_idle`: each CPU's current idle state, giving the state an audio wake came out of.
  - IRQ and softirq entry/exit time on the audio CPUs.
  - Everything is aggregated per block and per second.
- **Analyzer:** `profiler/kernel/census/analyze.py`. It feeds three gates:
  - K3's spin budget: the intra-block sleep CDF.
  - K5's expected syscall reduction: the share of sets with no sleeper, resets of already-reset events, and waits that found the event signaled.
  - K4/K7: the share of audio wakes from C2/C3 and the latency they add. K6 also uses the IRQ time on audio CPUs.
- **Result (D0004, 2026-10-19 11:33–11:37; kept configuration: `physcore`, 5 workers, new display; Inbuilts and Max4Live, 66 s each, 750 blocks/s):**
  - **Sync calls per block: about 83.** AudioCalc 18.7 sets, 19.4 resets, 19.1 waits; pipeasio-rt 16.7 sets, 3.1 resets, 2.7 waits; wineserver 0.5 sets, 2.0 resets; Live's other threads under 1. With 9 workers (D0001) it was about 245, so part of T0022's saving is the smaller fan-out.
  - **K5:**
    - Every reset found no waiter queued (100 %), and 71 % reset an event that was already reset.
    - 24 % of sets found no waiter, and 21 % set an event that was already signaled.
    - Only 3–4 % of waits were satisfied without sleeping.
    - No audio wait is alertable or waits on more than one object, so K5 v1 (single-object, non-alertable) covers them all.
    - Syscall-free share without any spin: about 40 % of the calls. Most waits sleep, so a user-space spin (K5b) is what would turn sets with a waiter into lock-free ones.
  - **K3, spin budget:**
    - AudioCalc sleeps: median 14 µs; 25 % ≤ 10 µs, 57 % ≤ 20 µs, 69 % ≤ 40 µs, 73 % ≤ 100 µs. The other 27 % are the sleep between blocks.
    - pipeasio-rt sleeps: median 9 µs; 51 % ≤ 10 µs, 79 % ≤ 20 µs, 93 % ≤ 40 µs.
    - So G3's 20 and 40 µs candidates are the relevant ones.
  - **K4/K7:**
    - About two-thirds of audio wakes come out of C2 (AudioCalc 66–68 %, pipeasio-rt 55–61 %), the rest out of C1. The gate (≥ 10 % from C2 or deeper) fires.
    - But the median wake latency is about 1 µs from either state, so C2 exits look cheap: the BIOS's 127 µs is a worst-case figure. The analyser now also reports p90/p99 per state, and K4 waits for those tails.
  - **K6:** CPU 4, an audio core, spends 50–54 ms per second (5 %) in interrupts, mostly `xhci_hcd`, the controller of the Focusrite's USB port (plus `vmd0`, i915 and one iwlwifi queue). The other audio CPUs spend 0.5–5 ms/s, and the non-audio CPUs about 0.34 ms/s. T0024's B arm moves all of it (xhci to CPU 12), so T0024 tests exactly this.

## K1 SMT siblings offline (new; follows directly from T0022) — trial T0026
- **B:** before each B run, set CPUs 1, 3, 5, 7, 9, 11 offline (`cpu-online.<n> 0`); bring them back online afterwards.
  - Each audio core then runs one hardware thread, so no other task can share its execution resources, and fewer active threads may leave more turbo headroom.
  - Everything else uses 6 P-core threads plus 4 E-cores.
- **Mechanism:** `/sys/devices/system/cpu/online` is `0,2,4,6,8,10,12-15` during B runs, and the affinity records show `physcore`.
- **Rule H.** Reported: DSP, peaks, power, kwin and Xwayland CPU.
- **First attempt invalid (13:09–13:33):** the bench refused every B run. It holds the `performance` power profile for each run, and power-profiles-daemon cannot apply it while CPUs are offline. `smt_siblings_off` now takes that hold before offlining, and the runs are set aside (`t0026-aborted-1`).
- **T0026 — MECHANISM-CONFIRMED (2026-10-19, 13:39–14:25, second attempt; all six runs clean):** the siblings cost the audio threads nothing measurable.
  - Rule H FAIL: B's audio-thread CPU was lower in 2 of 9 Set-pairs, median +2.9 %.
  - Live's CPU rose 34.8 → 39.7 %: its other threads had ten CPUs instead of sixteen.
  - Guards pass: xruns 0 → 0, errors 11 → 15 (p = 0.28), DSP average 8.87 / 9.60 / 8.71 → 9.47 / 9.80 / 8.91, within the spread.
  - Package power unchanged (about 20 W).
  - Mechanism held: CPUs 0, 2, 4, 6, 8, 10 and 12–15 online in every B run, all 16 in every A run.
  - All CPUs stay online (`KEPT_SMT=on`).

## K2 `mitigations=off` boot entry (user: all off) — trial T0027
- **B:** the `mitigations-off` GRUB variant (`mitigations=off` added to the normal command line). **A:** the normal entry.
- Reboot per run (A1 B1 A2 B2 A3 B3, about 70 min), kept configuration.
- **Mechanism:** `/proc/cmdline` contains the token; every vulnerability file reports "Vulnerable" in B and today's mitigations in A.
- **Rule H** (fewer cycles per kernel entry and exit); DSP reported.
- The note records the security trade-off: dedicated audio laptop, never the default entry.
- **Keep:** the variant becomes the entry the trials boot. `GRUB_DEFAULT` stays normal, and booting it for daily use is the user's call.

## K3 ntsync-live, stage 1: in-kernel optimistic spin (= T0025)
- **Source and build**
  - Source, under `profiler/kernel/ntsync-live/`:
    - `upstream/`: pristine v7.2.11 `drivers/misc/ntsync.c`, the uapi header and the upstream ntsync selftests, with `SOURCE.txt` and `SHA256SUMS`;
    - `include/ntsync_live.h`;
    - `patches/0001…0008`, plus `SERIES` and `SERIES.sha256`;
    - `Kbuild` (`obj-m := ntsync.o`) and a `Makefile`;
    - `bin/ntsync-live` (`build|status|load|params|stats|restore-stock|verify`) and `tests/`.
  - Build on the laptop under `live-session.lock`, between runs only. Preflight checks:
    - the running kernel is `7.2.11-1-cachyos`;
    - clang and LLD are the kernel's exact versions;
    - pahole and `build/vmlinux` are present (module BTF stays available for wine-trace);
    - the uapi sha256 matches.
  - Then patch with `--fuzz=0` and `make LLVM=1 -C /usr/lib/modules/$(uname -r)/build M=<work>`. The result must have the vermagic, the module name, the parameter list and a `.BTF` section.
  - Output goes to `~/.local/opt/ntsync-live/<series8>/`, never into the repo or `/lib/modules`.
- **Identity:**
  - The module keeps the name `ntsync`, the misc device, the uapi and its function names, because wine-trace attaches to `ntsync_char_ioctl`/`ntsync_obj_ioctl`.
  - `MODULE_VERSION("live-<series8>")` (`/sys/module/ntsync/version`; stock has none).
  - New `NTSYNC_IOC_LIVE_GET_FEATURES` (`_IOR('N', 0xC0, …)`, a private range) returns version, feature bits (F_SPIN 0x1, F_EVENT_MMAP 0x2, F_WAIT_NOSPIN 0x4), word layout and page size. The stock module answers ENOTTY.
- **Parameters** (0644 unless noted; setters clamp; all off by default):

  | Parameter | Meaning |
  |---|---|
  | `spin_ns` | ≤100000; 0 disables all stage-1 code |
  | `spin_comm` | ≤4 comm prefixes, RCU-published, e.g. `AudioCalc,pipeasio-rt` |
  | `spin_rt` | 1 = also require `rt_task()` |
  | `spin_adaptive` | Use the per-task predictor |
  | `onstack_q` | Keep `ntsync_q` on the stack when ≤4 entries |
  | `livesync` | Stage 2; 0444, set at load only |
  | `stats` / `stats_reset` | Per-CPU counters |

- **The spin:**
  - `ntsync_wait_any()` decides once whether this wait may spin (`likely(!READ_ONCE(spin_ns))` first, so the disabled cost is one load and one branch; then NOSPIN, `rt_task`, the comm prefix) and stores the answer in `q->gated`.
  - `ntsync_schedule()` gets a prologue that calls `noinline ntsl_spin_wait()`. Its budget is clamped to the wait's deadline (realtime through `ktime_get_real()`, monotonic through `timens_ktime_to_host()`). Zero or already-expired timeouts never spin.
  - The loop exits on `atomic_read_acquire(&q->signaled) != -1` and aborts on `need_resched()`, `signal_pending()` or `!single_task_running()`, so it never starves a lower-priority waker (RT throttling is off). It reads `local_clock()` every 16 iterations and calls `cpu_relax()` between reads.
  - Then the unchanged stock loop runs (`set_current_state` and a re-check before sleeping), so no wake-up can be lost.
  - WAIT_ALL never spins.
- **Adaptive predictor** (`spin_adaptive=1`):
  - 64 slots keyed by `hash_32(pid, 6)`. Each u64 slot holds the pid, the last 4 wait outcomes and 16 two-bit counters; the owning task writes it with `WRITE_ONCE`.
  - Whoever claims a gated waiter stamps `q->sat_ns` before `wake_up_process()`, so a wait is judged by when it was satisfied.
  - The task spins only when the counter for its history is ≥ 2. That learns Live's cycle: one long wait between blocks, about four short ones between rounds.
- **Wake side unchanged:** waking a still-spinning (TASK_RUNNING) task takes only `pi_lock`; no runqueue lock and no IPI.
- **Load and verify (root-helper verbs):**
  - `ntsync install S8`: sha-checked copy to `/usr/local/lib/profiler/ntsync-live/S8/`.
  - `ntsync load S8 [p=v…]`:
    - refuses unless the module refcount is 0, no Wine process or wineserver runs, and the vermagic matches;
    - runs `rmmod`, then `insmod`;
    - checks `/dev/ntsync` (0666), the version, the parameters and a 1 s smoke test;
    - on any failure runs `modprobe ntsync` (stock) and exits 1.
  - `ntsync restore-stock`.
  - `knob set ntsync.<param> V` writes the runtime parameters between runs.
  - Every reboot returns to stock.
- **Recording results:**
  - `bench-report.py` snapshots `/sys/module/ntsync/{version,parameters/*}` and the stats delta per Set window into `raw/ntsync-module.json`.
  - Non-default values go into `benchmark_gates` (`NTSYNC_LIVE`, `NTSYNC_SPIN_NS`, `NTSYNC_SPIN_COMM`, `NTSYNC_SPIN_ADAPTIVE`, `NTSYNC_ONSTACK_Q`, `NTSYNC_LIVESYNC`) and from there into the history `switches`.
  - Ledger kind `kernel-module`.
- **Gates before T0025:**
  - **E0 provenance:** the pristine build must match the in-tree module (srcversion, or the disassembly with addresses stripped). If it doesn't, take the source from the linux-cachyos package instead.
  - **E1 equivalence with defaults:**
    - the native suite, upstream selftests and `check-ntsync.sh` give the same results as stock;
    - `syncbench_native` stays within ±3 %;
    - an A/A bench of stock against live-with-defaults (D0004b) stays within 2× the spread.
  - **G2:** the native suite passes with spinning on. Optional: one run on a lockdep/KASAN 7.2.11 kernel in a QEMU VM on the workstation, since the old VMware VM is retired.
  - **G3, fan-out microbenchmark** (`syncbench`/`syncbench_native`, extended to the `physcore` layout with 5 workers):
    - coordinator named `pipeasio-rt` (FIFO 15), workers named `AudioCalc`;
    - a 1333 µs period with 5 rounds per block;
    - work per round calibrated to K0's medians.
    - Choose the smallest `spin_ns` from {5, 10, 20, 40 µs} within 2 % of the best. Required: ≥10 % lower median block time than spin off, p99 no worse, CPU per round ≤1.5×. Otherwise stop and record the mechanism only.
- **Gate results (2026-10-19, live-8b5e287b = 0001–0003, on the laptop after a fresh boot):**
  - **E0 PASS:** the pristine build's srcversion (2C65A4C2795A6FEE73E9F96) equals the in-tree module's.
  - **E1 PASS:** `ntsync-live verify` ran the suite on stock and on live with defaults.
    - The selftest results are identical. Only `wake_all` fails, on stock too: upstream's v7.2.11 test checks `EXPECT_EQ(0, fd)` where `EXPECT_LE` is meant.
    - The selftest is built unoptimised, as upstream builds it. At -O2 `stress_wait` miscounts a static variable the compiler keeps in a register.
    - The native torture and ping-pong (10⁶ rounds each) have no lost wake-ups or double consumptions, timings match within 1 %, and the kernel log is clean.
  - **G2 PASS:** the same suite with 20 µs spinning for every thread passes. Torture is 35 % faster (4.38 → 2.85 µs per round) and ping-pong 68 % faster (3.03 → 0.98 µs); 99.96 % of spins were satisfied while spinning.
  - **G3 FAIL (non-adaptive), recorded as mechanism only.** The D0004-calibrated fan-out bench (5 workers, 4 rounds of 13 µs per 1333 µs block):

    | spin_ns | block p50 | p99 | CPU per round | spins satisfied |
    |---|---|---|---|---|
    | 0 | 193.1 µs | 221.6 µs | 146 µs | — |
    | 5 µs | 191.5 | 219.4 | 182 | 0 % |
    | 10 µs | 200.0 | 229.4 | 222 | 0.3 % |
    | 20 µs | 162.6 | 235.1 | 242 | 66 % |
    | 40 µs | 148.9 (−23 %) | 169.8 (−23 %) | 252 (1.72×) | 79 % |

    - 40 µs is the pick: −23 % median and a better p99. But at 1.72× the CPU it breaks the ≤ 1.5× limit.
    - Much of the extra CPU should be the futile spin on each thread's long wait between blocks.
  - **Next:** patch 0004 (the adaptive predictor), then G3 again with `spin_adaptive=1` at 20 and 40 µs as its own evaluation (T0025's B arm allows `spin_adaptive=P*`), with E1/G2 repeated on the 0001–0004 build.
- **Gate results with 0004 (live-7a94c377 = 0001–0004, 2026-10-19 ~13:05):**
  - **E1 and G2 PASS again:**
    - The selftest fails only `wake_all`, as on stock.
    - No lost or doubled wake-ups.
    - Defaults are within ±3 % of stock (torture 4.40 vs 4.38 µs, ping-pong 3.05 vs 2.99 µs).
    - Adaptive spinning for every thread passes and is the fastest: torture 2.64 µs, ping-pong 0.92 µs, misses 142.
  - **G3 PASS with the predictor:**

    | configuration | block p50 | p99 | CPU per round | notes |
    |---|---|---|---|---|
    | spin off | 194.0 µs | 221.1 µs | 146.5 µs | |
    | 40 µs fixed | 147.8 | 168.9 | 250.7 (1.71×) | too costly |
    | **40 µs adaptive** | **142.9 (−26 %)** | **164.1 (−26 %)** | **193.1 (1.32×)** | 100,134 long waits skipped; 99.9 % of spins satisfied |
    | 20 µs adaptive | 193.7 | 220.1 | 148.3 | the predictor switched itself off: unspun waits include their wake-up and look longer than 20 µs |

  - **T0025's parameters are settled by this procedure: S* = 40000 ns, P* = 1.** (The largest block was 4.3 ms once with adaptive 40 µs, against 1.6 ms with no spin; p99 is the registered criterion.)
- **T0025:**
  - A: `spin_ns=0`. B: `spin_ns=S*`, `spin_comm=AudioCalc,pipeasio-rt`, `spin_rt=1`, `spin_adaptive=P*`. The same module binary runs in both arms; parameters change between runs.
  - **Rule D with G4:** M's median increase ≤ +15 points of one core. A bigger CPU cost turns a keep into mechanism-confirmed for the user to decide.
  - **Mechanism:**
    - gated waits only on audio threads, ≥1 per block, ≥30 % satisfied while spinning;
    - audio-thread voluntary context switches per second ≥25 % lower;
    - in one traced perf run per arm, the RT-balancing and scheduler share of audio cycles is ≥⅓ lower.
- **T0025 — REVERT (2026-10-19, 14:38–15:27; all six runs and both traced runs clean; live-7a94c377, `spin_ns=40000 spin_adaptive=1`):** the spin works, but Live's blocks do not get shorter and the audio CPU doubles.
  - Rule D FAIL: B's DSP average was lower in 5 of 9 Set-pairs, median −0.4 % (Inbuilts 9.25 → 9.02, Max4Live 9.17 → 9.30, VSTs 8.66 → 8.24).
  - G4 FAIL: audio-thread CPU +96 % (+22.9 points of one core, limit +15); Live CPU 35.9 → 57.6 %.
  - G1, G2 pass: xruns 0 → 0, errors 11 → 9.
  - Mechanism held:
    - Per B run, about 6.9 M waits were gated and 5.45 M spun; 85 % of spins were satisfied while spinning, and the predictor skipped 1.46 M long waits.
    - The audio threads' voluntary context switches fell 64 % (2.13 M → 0.75 M per window).
    - Traced, the scheduler's cycles fell 0.96 G → 0.54 G.
  - **Why no gain:**
    - Traced, Live's own (user) cycles were the same in both arms (37.2 G → 36.3 G per 60 s), while the spin added about 43 G cycles inside ntsync (7.9 G → 51.3 G).
    - Wake-up latency is not what limits Live's blocks. G3's bench gained because its work per round was tiny.
    - Package power rose only about 0.5 W (PAUSE spinning).
  - **Consequence for K5 and K8:** without spinning, ntsync calls are 16 % of the audio threads' cycles. That is the ceiling for a syscall-free path (LiveSync), and the gain would be CPU, not block time. K5 and K8 drop down the list.

## K5 LiveSync: shared-memory event state (module stage 2 + Wine 0113)
- **Kernel storage:**
  - Each event's state becomes one atomic word. It starts inline; the first `mmap` of the event's fd moves it to a per-event page.
    - The page is `GFP_KERNEL_ACCOUNT|__GFP_ZERO` and allocated before any lock.
    - The word is copied and the pointer switched while both `wait_all_lock` and the object lock are held.
    - The page is freed in `ntsync_free_obj`.
  - mmap is allowed only on event objects: exactly one page at offset 0, `VM_SHARED`, no exec, with `VM_DONTEXPAND|VM_DONTDUMP`. Each mapping holds a reference on the object's file.
  - Page layout: u32 state word, then u32 magic `0x314C534E` ("NSL1").
- **State word:**
  - bit 0 **S**, signaled;
  - bit 1 **K**, a multi-step kernel operation (pulse) is in progress;
  - bit 2 **M**, manual-reset, informational;
  - bits 3–31 **W**, registered kernel wait entries (any, all and alert) × 8.
- **Kernel operations:** every one is a single, fully ordered RMW under the existing locks, never a cmpxchg loop, so a hostile writer cannot hold a spinlock forever.
  - EVENT_SET: `fetch_or(S)`, then the wake loops.
  - EVENT_RESET: `fetch_andnot(S)`.
  - EVENT_PULSE: `fetch_or(S|K)`, wake, then `fetch_andnot(S|K)`.
  - Registering a wait entry: `list_add`, then `fetch_add(8)`. Unregistering: `list_del`, then `fetch_sub(8)`.
  - `try_wake_*` consume an auto-reset event with `fetch_andnot(S)` while holding the lock.
  - The kernel never reads W and acts only on S.
- **User-space operations** (Wine, `WINE_LIVESYNC=1`). "Eligible" means K = 0 and W = 0. A cmpxchg is retried at most 16 times before falling back to the ioctl.
  - SetEvent and ResetEvent: one cmpxchg when eligible.
  - Auto-reset wait: a cmpxchg consume when eligible and S is set.
  - Manual-reset wait: an acquire load when K = 0 and S is set, even with W > 0.
  - Zero-timeout non-alertable wait on a clear event: STATUS_TIMEOUT with no syscall.
  - Gated threads spin with acquire loads and PAUSE, stopping on auto-reset events once W > 0, then call WAIT_ANY with `NTSYNC_WAIT_LIVE_NOSPIN` (0x80000000, accepted only when `livesync=1`).
- **Correctness argument** (every access is atomic, so all writes to the word have one total order):
  - C1, no lost wake-up: a lock-free set succeeds only while W = 0, before any waiter registers, so the waiter's locked check sees S.
  - C2, one consumer per auto-reset signal: lock-free consumers need W = 0, and kernel consumers hold the lock.
  - C3, wait-all stays atomic: each of its objects has W ≥ 1, so lock-free writes cannot land while `try_wake_all` runs under `wait_all_lock`, and no rollback is needed.
  - C4, every operation takes effect at one point.
  - C5, data written before a set is visible after the wait (ACQ_REL and ACQUIRE pairs).
  - Known gap: an unregistered user-space spinner can miss a Set immediately followed by a Reset. That window already exists for a thread just entering its wait; Live cannot hit it, because each worker resets its own event; it is documented and name-gated.
- **Security and cross-process behaviour:**
  - The page holds no pointers or indices, and the kernel never loops on page values.
  - A writer can only corrupt events it could already set or reset.
  - Every process that maps an event shares one page. wineserver and processes without LiveSync keep using ioctls alongside.
- **Wine patch `0113-ntdll-livesync`** (reuses the number from the dropped spin candidate; revert dev-tree commit `cd5ca47` first):
  - New `dlls/ntdll/unix/ntsync_live.h`: a guarded copy of the module header. A repo test checks its constants match `profiler/kernel/ntsync-live/include/ntsync_live.h`; the vendored `ntsync.h` stays untouched.
  - `livesync_init()` (pthread_once):
    - `WINE_LIVESYNC` with strict boolean parsing;
    - `WINE_LIVESYNC_SPIN_US` (0–200, default 0);
    - `WINE_LIVESYNC_SPIN_THREADS` (default `AudioCalc,pipeasio-rt`);
    - `WINE_LIVESYNC_STATS`.
    - It requires version 1, layout 1 and F_EVENT_MMAP, and logs one winediag line, "enabled" or "requested but unavailable".
  - `struct inproc_sync` gains `LONG *ls_word` and grows from 16 to 24 bytes, so `INPROC_SYNC_CACHE_ENTRIES` goes from 128 to 192.
  - `get_server_inproc_sync()` maps event handles under `fd_cache_mutex`, before the cache publishes the entry, and checks the magic; a mismatch turns LiveSync off for the process.
  - `release_inproc_sync()` unmaps at refcount 0. An uncached handle is unmapped immediately.
  - Fast paths go into `inproc_set_event`/`inproc_reset_event`. A new `livesync_wait_one()` handles count = 1 waits on mapped events, sharing a timeout helper split out of `linux_wait_objs()`.
  - Alertable waits, v1: the lock-free acquire only, then the stock path. v2 polls the alert word too, only if K0 shows Live's hot waits are alertable.
  - The thread-name gate re-reads `prctl(PR_GET_NAME)` every 1024 waits.
  - Pulse, query, mutexes, semaphores, multi-object waits, WaitAll and SignalAndWait are unchanged.
  - Fallbacks: no device → server path; ENOTTY, a bad version or a failed mmap → today's ioctls (per process or per handle).
  - Plumbing: `REQUIRED_WINE_TAIL`, FINGERPRINTS `0113|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_LIVESYNC`, `--freeze`, `BENCHMARK_WINE_ENV_KEYS`, launcher help, `notes/ABLETON-WINE-LIVESYNC.md`.
- **Tests:**
  - **Native suite** (`tests/ntsl_stress.c`, built on `syncbench_native.c`'s event layer; `run-suite.sh` fails on any WARN, BUG, lockdep, soft-lockup or hung-task line in dmesg). Every group runs with spin off/on × livesync off/on:
    - unit tests and parameter clamping;
    - semantics: auto versus manual reset, set followed by reset releasing registered waiters, pulse, the lowest index winning, wait-all across event, mutex and semaphore while other threads write lock-free, abandoned mutexes, alerts;
    - torture: 10⁷ round trips with double-wake and lost-wake detectors;
    - cross-process sharing over SCM_RIGHTS;
    - a hostile writer to the shared word;
    - mapping lifecycle and refused mappings;
    - 20 load/unload cycles;
    - upstream's v7.2.11 ntsync selftests.
  - **Wine matrix**: {stock module, live with `livesync=1`} × {`WINE_LIVESYNC` unset, `=1`}:
    - `scripts/check-ntsync.sh` (27 checks);
    - `tools/livesyncprobe.c` (semantics, cross-process, duplicated handles, close-while-waiting, 10⁶ torture rounds with AudioCalc-named spinners);
    - `kernel32:sync` and `ntdll:sync` conformance tests built in wine-dev, which must fail exactly as in the stock/unset cell;
    - `tools/livesync-observer.c` (LD_PRELOAD): zero EVENT_SET/RESET/WAIT_ANY ioctls during uncontended phases, plus fault injection.
  - **Live smoke runs:** `d0003-capture-light` on the 3 Sets, 60 s each: no hangs, no extra late blocks, and the share of alertable audio waits reported.
- **Gates:**
  - Stage-2 equivalence: E1 again with `livesync=0`, and with `livesync=1` and `WINE_LIVESYNC` unset.
  - **G8:** in the PE fan-out with no spin, LiveSync must be ≥10 % faster, use less CPU and make ≥60 % fewer ioctls per round. Use `perf c2c` to see whether the handle-cache refcount lines are shared between threads, and pad entries to 64 bytes if they are.
  - Then the official Wine build, the audit, and the probe on the official runtime.
- **Trials:**
  - **K5a, fast paths:**
    - both arms `livesync=1` with K3's kernel setting;
    - A: `WINE_LIVESYNC` unset; B: `=1`, `SPIN_US=0`;
    - mechanism: the winediag line in B only, and EVENT_SET+RESET+WAIT_ANY ioctls per second in B ≤50 % of A in every pair;
    - rule D, with rule H reported.
  - **K5b, user-space spin against the kernel spin:** both arms `WINE_LIVESYNC=1`; B adds `SPIN_US=U*`. Mechanism: WAIT_ANY ioctls and audio-thread voluntary context switches each ≥25 % lower. Rule D with G4.
- **Effort, K3 + K5:** about 19–20 working days.
  - Scaffolding and verbs: 2 days.
  - Stage-1 patches: 2. Native suite and microbenchmark: 2.5. Gates and T0025: 3.
  - Stage-2 patches: 2.5. Protocol tests: 2.
  - Wine 0113 with probes: 3. Wine matrix and official build: 1.
  - Trials: 1–2.

## K6 Boot-time isolation — trial T0029
- Variant `isolated`: `nohz_full=0,2,4,6,8,10 rcu_nocbs=0,2,4,6,8,10 irqaffinity=12-15 isolcpus=managed_irq,0,2,4,6,8,10`.
  - No `domain` flag: Live's non-audio threads still use the P-cores, unlike T0005.
  - At runtime the unbound-workqueue cpumask is set to 12–15, as in T0024.
- Combined with `mitigations=off` if K2 keeps.
- Reboot per run; **rule D**. The mechanism checks `/sys/devices/system/cpu/nohz_full`, the IRQ affinities and that the audio CPUs' RCU callback (rcuo) threads are offloaded.
- T0024's runtime result predicts the size of the effect.

## K4 Per-core C-state limit (gated by K0) — trial T0028
- **B:** C2 and C3 disabled on CPUs 0–11 (`cpuidle.<cpu>.2|3 = 1`); E-cores untouched. A core's depth follows both siblings, so all 12 are limited, or only the 6 audio CPUs if K1 kept.
- Variant B2: governor `teo` instead of the limit.
- **Rule D.** Power and temperature reported. The mechanism checks the per-state usage counters: no C2/C3 entries on audio CPUs in B.
- It differs from T0001 in three ways: per core rather than global, on the new baseline, and judged on block time.

## K7 Pre-wake before each block (gated: K4 helps but costs power, or K0 shows C2/C3 exits matter)
- **Stage a, simple:**
  - Patched PipeASIO (`patches/pipeasio/0018`, opt-in `PIPEASIO_CYCLE_SHM=1`) publishes each cycle's expected next start (`next_nsec`, CLOCK_MONOTONIC) and the audio CPUs in a small shared-memory page.
  - A native daemon `profiler/kernel/prewake/prewaked`, at SCHED_FIFO 1 with one thread pinned per audio CPU, sleeps (`clock_nanosleep` TIMER_ABSTIME) until `next_nsec − lead`. Lead is 150 µs, covering C2's 127 µs exit.
  - It then sets that CPU's `pm_qos_resume_latency_us = 1` until the block ends and restores it afterwards. Cores stay shallow only around block starts and sleep deep in between.
- **Stage b, esoteric:** a custom cpuidle governor module `audiogov`.
  - It runs menu's logic, plus period awareness read from the shared page: it never picks a state whose exit latency exceeds the time to the next block.
  - When it picks a deep state, it arms a per-CPU hrtimer at `next − lead` (allowed with interrupts off) to wake the CPU early.
  - It is selected through `/sys/devices/system/cpu/cpuidle/current_governor`.
- Rule D against K4's configuration, as non-inferiority on DSP plus lower package power.

## K8 Direct NT syscall entry (after K5)
- Gate: the post-K5 census shows at least 100 sync syscalls per block remaining.
- **Module:**
  - `NTSYNC_IOC_BIND_HANDLE(handle, fd)` builds a per-process handle → object table; Wine calls it when it caches a handle's fd.
  - Handle-based ioctls on the device fd: `NT_SET_EVENT`, `NT_RESET_EVENT`, `NT_WAIT_SINGLE` (timeout, alert).
- **Wine:**
  - A thin stub inside unix `ntdll.so` (so syscall user dispatch allows it) issues the ioctl. It preserves the Windows non-volatile registers without Wine's full dispatcher save (`xsavec`).
  - The PE thunks of the three NT calls reach it through a pointer published in shared user data, next to the dispatcher pointer. Switch `WINE_DIRECT_NTSYNC=1`.
- **Probe:** `syncbench` calls per second, plus a correctness suite.
- **Rule D.** Expected saving: about 80–150 ns per remaining call.

## K9 sched_ext audio policy (research)
- RT tasks bypass sched_ext, so the study runs Live without the launcher's blanket `chrt` (opt-in launcher switch, added if absent).
  - `scx_layered` with an `audio` layer (comm `AudioCalc`, `pipeasio-rt`; confined to CPUs 0,2,4,6,8,10; exclusive; preempt), a `live` layer and a `system` layer.
  - PipeWire's own RT threads stay RT.
- **Feasibility gate:** a census plus a short bench against the RT baseline shows no more dropouts and an equal or lower DSP average.
- Then a custom `scx_ableton` (BPF): each audio thread dispatched to its own CPU's local queue on wake with `SCX_KICK_PREEMPT`, and block-aware boosting from a uprobe on PipeASIO's `block_start`.
- sched_ext's watchdog falls back to the normal scheduler on failure. **Rule D.**

## K10 The P-cores' frequency policy (new, from T0024) — trial T0030, WITHDRAWN unrun
- **Withdrawn the same day:** the bench holds the `performance` power profile for every run, so EPP is already `performance` during every trial run (bench log: "governor powersave, EPP performance, profile performance"). B would equal A.
  - The workers' 3.2–3.5 GHz under six busy P-cores, with the package at 85–93 °C, looks like the all-core power and thermal limit, so a frequency floor would not raise it either.
  - Revisit only with per-core turbo data (turbostat) showing headroom.
  - The design below is kept as registered.
- **Evidence:** in T0024's traced runs the audio workers averaged 3.51 GHz (A) and 3.23 GHz (B) on cores that turbo to 4.7 GHz.
  - The laptop runs intel_pstate's `powersave` governor with EPP `balance_performance` (power profile `balanced`, HWP dynamic boost off).
  - The hardware clocks bursty, mostly idle cores down. Clearing the audio cores (T0024 B) idled them more and lowered the clock further, which is why the audio CPU rose there.
- **B:** EPP `performance` on every CPU, through the root helper's existing `epp` knob, before each B run; `balance_performance` restored after it. **A:** as is.
- **Rule D** (G4: audio-thread CPU ≤ +5 %); rule H reported, since higher clocks should also lower the audio threads' CPU time.
- **Mechanism:** EPP reads `performance` during every B run, and the power sampler's mean P-core clock is higher in every B run than in its paired A run.
- **Reported:** package power and temperature, the cost of the higher clock.
- **Follow-ups if it keeps:** per-core EPP (only the audio cores; needs a per-CPU knob) and HWP dynamic boost.
- Driver `profiler/trials/trial-T0030.sh`.

## Execution order
1. Record T0022 (keep): ledger line, plan, commit and push. `physcore` with 5 workers becomes the kept layout. This plan is `profiler/plans/kernel-plan.md`.
2. Laptop: **K0 census**, about 10 min. Workstation, in parallel: **I0**, then ntsync-live source import and the stage-1 build (K3).
3. Laptop: T0023 (display) and T0024 (core clearing), already registered, on `physcore`.
4. Laptop: **K1** (SMT siblings offline). Then **K2** (`mitigations=off`, reboot per run) once I0's GRUB variant and boot-kernel table exist.
5. **K3** (= T0025) once the stage-1 module passes its probes. **K4** if K0's gate fires.
6. **K5** LiveSync (module stage 2 plus Wine 0113, with the official Wine build) after K3 is verified.
7. **K6** (isolation, on the K2 entry if kept), **K7** (pre-wake, if gated in), **K8** (direct entry, after K5), **K9** (sched_ext study).
- After each item: score, ledger line, notes, a `kernel-plan.md` status update, commit and push.

## Verification (every item)
- **Mechanism checks** from the system itself: `/proc/cmdline`, vulnerability files, `/sys/devices/system/cpu/online`, cpuidle usage counters, `/sys/module/ntsync/parameters`, module `srcversion`/vermagic. They are recorded per run by the driver's `arm_record` and fail the trial when they don't hold.
- **Probes before any trial:**
  - module items: the native ntsync stress suite and `scripts/check-ntsync.sh` (27 tests) on the custom module, with features off (equivalence with stock) and on; the fan-out probe;
  - Wine items: a PE probe in `tools/`.
- **Smoke runs:** a 60 s census capture in Live, checking late blocks and faults, before registering each trial.
- **Trials:** pre-registered ABAB × 3 on Inbuilts, Max4Live and VSTs at 120 s, scored by `campaign_tools.py rule-h|rule-d`, with the ledger line generated by script.
- **Rollback:** reboot gives the stock entry and module. `module unload` plus a stock `modprobe ntsync`. Knobs return to baseline through the root helper's `reset`.

## Risks
- **Correctness of the custom module (K3, K5):** lost wake-ups or broken event semantics stall Live or Wine. Mitigations: the native torture suite, Wine's ntsync tests, features off by default, loading per run only, and a stock fallback in Wine when capabilities are missing.
- **`mitigations=off`:** a security exposure while that entry is booted. It is never the default; the note says so.
- **SMT offline and isolation:** the desktop has fewer threads, so it may stutter. kwin and Xwayland CPU are reported, and changes are undone after each B run.
- **Spinning (K3, K5):** costs CPU and thermal headroom; guard G4 caps it.
- **sched_ext (K9):** taking Live off RT is a big change; it stays a study until its feasibility gate passes.
- **T0001 precedent:** C-state limits may again show nothing; K4 stays gated.

## Critical files
- New:
  - `profiler/kernel/` (`grub/`, `census/`, `ntsync-live/`, `prewake/`, `scx/`) and `profiler/trials/` (campaign tooling);
  - `notes/ABLETON-KERNEL-*.md` and `profiler/plans/kernel-plan.md`;
  - `patches/0113-ntdll-livesync.patch` (K5), `patches/pipeasio/0018-…` (K7), and the Wine patch for K8.
- Changed:
  - `profiler/setup/root-helper/profiler-root-helper`, `profiler/bin/boot-kernel`;
  - `profiler/bin/ledger-report`, `profiler/LEDGER.md`;
  - `scripts/build-audit.sh` (`REQUIRED_WINE_TAIL`, FINGERPRINTS), `patches/BASE.txt`, `scripts/bench-report.py` (`BENCHMARK_WINE_ENV_KEYS`), `scripts/ableton-live` (help, and the K9 no-chrt switch);
  - `dlls/ntdll/unix/sync.c` in the Wine dev tree (K5, K8).
