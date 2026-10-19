# Resume plan — serial blocks after the usage cut-off

Date: 2026-10-16 (evening) · Branch `profiler` @ `2af87dd` (WIP checkpoint 3, everything on disk is committed)

## Where things stand

| Area | Done and reviewed | Done, unreviewed or partial | Missing |
|---|---|---|---|
| Setup script (wf1) | core libs, driver, phase 00, phases 09–18, bin tools, dev loop | `01-sudo.sh` (partial), root helper (905 lines), `verify.sh` (809 lines), templates | phases 02–08, `profiler/README.md`, `setup/bootstrap.md` |
| Control + suite (wf2) | vendored AbletonOSC, bench handler, client + scenarios, suite shell, report tool, ledger/history tooling | fixers were stopped mid-way | — |
| Patches + tracer (wf3) | Wine 0108, PipeASIO 0017, build-audit wiring + `SERIES.sha256`, bpftrace prototype + tables, symbolizer | `traceprobe.c` (911 lines), `wine-trace.bpf.c` (1420 lines); `0017` touched by a dying fixer | libbpf loader `wine-trace.c`, `BUILD.md` |
| Dashboard (wf4) | design + scaffold, all six views, integration (builds) | data layer files exist | data-layer tests; review/fix/verify never ran |

Open blocker/major findings from the reviews that did complete:

- Setup: phases 02–08 missing (driver cannot run); **the VM uses Plasma Login Manager, not SDDM** — the autologin drop-in would be ignored; `16-claude` breaks `~/.bash_profile` on a host without one; `14-golden --force` silently overwrites the golden snapshot; `state restore` rolls the runtime back after a kept trial (golden never refreshed after `build-official.sh`); Live-pid detection matches the setup driver's own `--live-installer …Live 12…exe` argument; `wine-trace stop` aborts under `pipefail` in the normal case; `wine-dev.sh sync --artifacts` misses the unix `.so`; `wine-dev.sh` aborts after `format-patch` (`_series_drift` pipefail).
- Suite/report: `interface` ignores the `caller` field the tracer writes and only reads `stacks` (every call site collapses); `--scenario` runs without the wrapper talk to two different OSC endpoints. (The `.gitignore` and executable-bit blockers are already fixed in `9df03d7`.)
- Tracer: loader missing; BPF records junk stack samples for server-request entries; `gen_tables.py` drops real unix-call codes ending in `_count`.

## Rules for every block

- One block at a time: one small workflow (≤ 4 agents, mostly sequential: author/fixer → one adversarial reviewer → verifier), or plain commands with no agents.
- Every block ends with a checkpoint commit and a short report to you; nothing starts until the previous block is committed.
- Agents get a "partial files may exist; keep what is correct" note and touch only the files the block owns.
- If a limit hits mid-block: the block's files are on disk and committed at the last checkpoint; the workflow resumes from its journal.

## Blocks, in order

The critical path is: **B1 → B2 → VM build → your 3-minute step → B4**. Everything after B4 improves tooling but does not block the first real measurements.

### Target change (2026-10-16 evening): the native CachyOS laptop replaces the VM

`ssh ableton-laptop` (on the LAN): MSI Katana 15 B13VFK, i7-13620H (6P+4E, 16 threads; P-core CPUs 0-11, E-core 12-15), 16 GB RAM + zram, 954 GB NVMe btrfs, Intel UHD + RTX 4060 Mobile, Intel SOF audio, kernel 7.2.9-cachyos with NTSync/BTF/uprobes, Plasma Wayland via **Plasma Login Manager**, Wi-Fi (power save on), on AC, lid-close = suspend, ananicy-cpp active. Bare metal, so **timing claims are valid** and the agent loop can give real A/B verdicts. The VM is powered off (snapshot `pre-build` kept).

Decisions: passwordless sudo; laptop dedicated to the project (any system change allowed; the root helper keeps a baseline for `reset`); PipeASIO drives the **built-in SOF speaker sink, muted** (real hardware clock), not the null sink. Setup runs as `--profile baremetal --passwordless-sudo --autologin`.

Laptop-specific setup work (goes into B1): Plasma Login Manager autologin; logind `HandleLidSwitchExternalPower=ignore` + `HandleLidSwitchDocked=ignore`; Wi-Fi power save off (NetworkManager drop-in + `iw` now, without restarting NetworkManager over the SSH link); `ananicy-cpp` disabled through the helper; preflight checks AC power, records battery state, hybrid P/E topology and Wi-Fi vs Ethernet; PipeASIO `output_device` = `alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink` with the sink muted; JOBS ≈ 9 (16 GB RAM).

### B0 — Laptop onboarding (no agents) — done except the media copy
SSH key installed, aliases pinned by IP, inventory taken, repo cloned at `~/Projects/ableton-linux` (branch `profiler` @ `aceb236`), installer media copying to `~/Proprietary/ableton`.

### B1 — Finish the setup script (gates the VM) · ~4 agents, serial
1. Author: phases 02–08 per design A (finish `01-sudo.sh`), with phase 05 targeting **Plasma Login Manager** autologin (verify its config path on the VM read-only) instead of SDDM.
2. Fixer: the setup/dev-loop majors listed above (`16-claude`, `14-golden`, `state`, live-pid matching, `wine-trace stop`, `wine-dev.sh` ×2), plus `profiler/README.md` and `setup/bootstrap.md`; read-through of root helper and `verify.sh`.
3. One adversarial reviewer (bash correctness + contract + VM facts in one pass).
4. Verifier: `--dry-run` of the whole script on the VM from `/tmp`, `verify.sh` read-only run, fix loop.
Exit: dry run prints all 19 phases with no sudo and no crash.

### B2 — Patch integrity (gates the build) · 1 agent
Confirm `0108` applies with `git am --3way` after the full series and `0017` with `patch -p1` (it was touched by a dying fixer), `SERIES.sha256` matches (`build-audit.sh --freeze`), `test-release-policy.sh` passes; apply the asm/patch-hygiene minors.
Exit: both patches apply cleanly; policy test green.

### Laptop build (no agents, ~1 h)
Commit → `git bundle` → laptop `~/Projects/ableton-linux` → `setup-machine.sh --profile baremetal --passwordless-sudo --autologin` through phase 12 (packages, podman, limits, session, audio, repo, media, **Wine build with 0108/0017**, silent Live install, plug-ins, AbletonOSC). The real build is the strongest test of the asm probes. Fallback if 0108/0017 fail to compile: iterate in `wine-dev.sh` and rebuild.

### B3 — Suite/report fixes (runs during the VM build; local only) · 2 agents
Fixer: `interface` uses the crossing `caller`; scenario runs default to the AbletonOSC ports; `gen_tables.py` `_count` fix (regenerate `tables/wine-11.13.json`); wf2 minors. Verifier: `scripts/test-bench-report.py`, `make test-profiler` pieces locally.

### Your step (~3 min)
Live opens on the VM desktop: accept licence, continue **unauthorised (demo)**, Audio → ASIO → PipeASIO 48 kHz, Control Surface → AbletonOSC, auto-update/usage data off, **Ctrl+Q**. Then the script takes the golden snapshot (phases 13–18 finish: tracecheck, Claude Code, dashboard service).

### B4 — First real runs (no agents unless something breaks)
`smoke-test.sh` (AbletonOSC ping/play/stop/cpu), `bpftrace -l` shows the 8 `wine:` + 7 `pipeasio:` probes in the shipped build, an untraced baseline `profiler/bin/bench`, a traced run with the bpftrace prototype (`wine-trace --proto`), `history-add` → dashboard at `http://abletonlinux:5173`.
Exit: one untraced and one traced report with an Interface section (VM: "no timing claims").

### B5 — Production tracer · 3 agents, serial
Author: libbpf loader `wine-trace.c` + `BUILD.md`, fix the BPF stack-sample major. Reviewer. Verifier **on the VM with real attach** (sudo now works): `traceprobe.exe` counts match via `validate.py`, block join vs PipeASIO telemetry.

### B5b — libbpf rewrite, real callers, robustness fixes · DONE (commit 8150671, 2026-10-17)
Shipped to the laptop; tracer rebuilt there (ABI 4); phase audio re-applied (input pro-input-0); golden re-baselined (previous kept as golden.20261017T165405Z). Verified: libbpf is the default backend, 0 risky programs, validate.py PASS, traced suite clean. Left for B5c: bench-report/reduce double counting, lost-events confounder threshold, `-t .` test discovery.
Was workflow `wf_42af6292-9d3` (script `plans/workflows/b5b-libbpf-callers-and-fixes.js`). A2 (leftover helpers, Focusrite input pairing, bench audio gate) reported clean. After it lands: commit by explicit paths with `--chmod=+x` for the new tests, add the new tests to the Makefile, fix the `10-install.sh` header comment, re-apply setup phase 06 (explicit Focusrite input), re-baseline golden.

### B5c — Tracer overhead · DONE (432f754; nop10 runtime built by build-official.sh, audit 189/189, installed, golden re-baselined 2026-10-17 ~16:45 EDT)
Result on the new runtime (Focusrite, 30 s, Inbuilts / VSTs, untraced→traced in the same session): Live CPU +19.8 / +21.3 points of one core (old runtime +42.0 / +50.2); tracer estimate 0.257 / 0.279 ms per block (old 0.438 / 0.474); trap 201 ns per hit P-core, 448 ns E-core (calibration saved); PipeWire ERR traced 10 / 11 (old 20 / 10; untraced 5 / 6); [uprobes-trampoline] present in traced Live. Untraced Live CPU this session 62.8 / 62.7 vs the verifier's 58.4 / 52.4 — unexplained (ran right after a 10-min build; thermal?) → the A/A noise floor must be measured before any A/B.
Verified on the old (nop5) runtime: tracer 0.4.0/ABI 5, USDT programs ≈100 ns/run, BPF ≈101–114 µs/block, measured trap 445 ns (P-core) / 596 ns (E-core), estimated cost 0.44/0.47 ms per block (B5b 0.61/0.66), untraced→traced Live CPU +42/+50 points; attribution: NtWaitForSingleObject (AudioCalc idle waits) gets ≈96 % of lost slack → critical-path attribution is the slack-budget design question.
Was workflow `wf_cbc41d07-181` (script `plans/workflows/b5c-tracer-overhead.js`).
After it: commit, ship, build from the laptop's working repo (warm ccache), install the runtime, build-audit (new nop10 check must pass), re-baseline golden, confirm `[uprobes-trampoline]` + rewritten site bytes in a traced Live, run the calibration and the untraced-vs-traced comparison on the new runtime.
Why: on the VST Set the libbpf tracer costs about 1016 probe hits per block × (≈500 ns trap + ≈555 ns BPF runtime in summary mode, ≈1 µs in drill-down), so about 1.07 ms of a 1.33 ms block, and 25 % of blocks were late in traced runs.
1. **10-byte USDT nop.** Kernel 7.2.9 only takes the fast uprobe path (`lea -0x80(%rsp),%rsp; call [uprobes-trampoline]`) for the exact nop `66 2e 0f 1f 84 00 00 00 00 00`; our vendored `sdt.h` in `patches/0108-…` and `patches/pipeasio/0017-…` emits the 5-byte nop, so every hit traps. Laptop microbenchmark (trivial counting probe): 429 ns/hit with nop5, 173 ns/hit with nop10. Change both `sdt.h` copies to emit those 10 bytes with `.byte` (gas shrinks `nopl` forms), add a `build-audit.sh` check that every `wine`/`pipeasio` USDT site is exactly that sequence and does not cross a page boundary within 10 bytes, `--freeze`, rebuild (warm ≈15–20 min), reinstall the runtime, re-baseline golden. Verify: `/proc/<pid>/maps` shows `[uprobes-trampoline]` in traced Wine processes and the site bytes read back as `48 8d 64 24 80 e8 …`; `traceprobe` EXPECT lines still pass; a traced VST run reports the new `estimate_ns_per_block`.
2. **BPF program cost.** ≈555 ns per hit (summary) is several times what small programs usually cost (≈50–150 ns). Profile with `bpftool prog profile`/run-time stats per program; look at per-event ring-buffer records in summary mode, per-tid hash churn, stack-window copies; keep every multi-thread program under 64 bytes of stack (kernel 7.2 private-stack hazard).
3. Exit: an untraced vs traced A/A on the Focusrite (same Set) showing the traced overhead, before and after.
Later, if still needed: the in-process recorder (per-thread shared-memory buffers written by Wine/PipeASIO, decoded after the run into the same `blocks.jsonl`), with Intel PT + PTWRITE as a research spike (supported on both core types here).

### Proving gains (user decision 2026-10-17: no upstream PR until a gain is proven)
**A/A noise floor (2026-10-17, Focusrite, nop10 runtime, untraced, 3 × all 5 Sets, golden restored each run; runs aa-focusrite-1..3, in history, aa-focusrite-1 = Focusrite baseline):** DSP average range 7–11 % of mean (≈ ±0.5 pt), DSP typical peak (median) 2–7 % → the primary metrics. Live CPU % drifts per run (7–17 %; run 2 was +4–9 pt on every Set) → trials must interleave (ABAB). PipeWire ERR, worst peak and peaks>100 % are rare-event counts (47–225 % ranges) → no-regression guards, not primary. Untraced baseline already has dropouts: heavier Sets 4–6 PipeWire ERR per 30 s and occasional peaks >100 %. Live idles at ≈38 % of a core on Zero/Empty (UI cost).
**Trial T0001 — REVERT (no gain):** idle-state cap — PM QoS /dev/cpu_dma_latency = 10 µs (C1 allowed, C2 127 µs and C3 1048 µs blocked) vs default; ABAB × 3, all 5 Sets. The cap held (0 C2/C3 entries in B runs vs ≈7 M per A run), but DSP average/typical peak moved within the A/A spread on every Set and dropouts did not fall (PipeWire ERR 63 vs 73, peaks >100 % 18 vs 18 over 15 Set-runs per arm). Deep idle states are not the cause. Ledger line + run records in b8145ee.
**Finding that motivates T0002:** the launcher starts Live with `chrt -r 10 wine`, so all 94 Live threads (main, 15 AudioCalc, graphics…) run SCHED_RR 10 — except `pipeasio-rt`, the thread that starts every block by calling Live's bufferSwitch: PipeASIO's shipped `realtime=false` (patch pipeasio/0009, "the scheduling A/B decides any flip separately") demotes it to SCHED_OTHER. In T0001-A1 (Inbuilts, 30 s) pipeasio-rt waited **754 ms** for a CPU (≈34 µs per block on average) vs 1.1–2.7 ms for each AudioCalc thread and 1.5 ms for MainThread.
**Trial T0002 — INCONCLUSIVE (promising):** `PIPEASIO_REALTIME=1` vs the shipped default; ABAB × 3, all 5 Sets. Mechanism confirmed: pipeasio-rt SCHED_FIFO 15 in every B run, CPU wait 595–706 ms → 1.2–2.4 ms per 30 s. Dropouts: PipeWire ERR 67 → 32, peaks >100 % 13 → 9 (15 Set-runs per arm; Max4Live 36 → 15, VSTs 13 → 5). DSP meter mixed within ≈2× A/A (Max4Live avg −1.5 / 1.9×, VSTs typical peak −1.2, Inbuilts avg +1.3 / 1.1×). Ledger + runs in 204b74c.
**Trial T0003 (confirmation, pre-registered before running):** same switch; ABAB × 3; Sets Inbuilts, Max4Live, VSTs; `--duration 120` (18 min of audio per arm). PASS iff (a) B has fewer PipeWire ERR than its paired A in ≥ 8 of the 9 Set-pairs (sign test, p ≈ 0.02 under no effect), (b) total PipeWire ERR at least 40 % lower in B, and (c) no Set's median DSP average worse in B by more than 2× its A/A spread. Otherwise the default stays as is. Driver ~/.local/state/profiler/trial-T0003.sh.
**Trial T0003 — KEEP (first proven gain, 2026-10-17):** PASS on all three tests.
- (a) B fewer PipeWire ERR in **9 of 9** Set-pairs (sign test p = 0.002).
- (b) **204 → 30 (−85 %)**: Inbuilts 66 → 5, Max4Live 83 → 13, VSTs 55 → 12.
- (c) Median DSP average moved ≈0.5× the A/A spread on every Set (−0.59 / +0.45 / −0.45 pt).
- Mechanism in all 18 Set-runs: pipeasio-rt was SCHED_FIFO 15 with 1.9–6.6 ms CPU wait per 120 s, against SCHED_OTHER with 2.67–3.18 s.
- Also: worst DSP peaks fell (VSTs 141–214 % → 106–131 %, Max4Live 146–225 % → 132–135 %), xruns went 2 → 0, and Live CPU was unchanged.
- Recorded in ledger + runs 918d06a; scored by `plans/tools/trial-analyze.py T0003` (run on the laptop: `ssh ableton-laptop python3 - T0003 < plans/tools/trial-analyze.py`). The ledger's `xruns` field for T0001/T0002 holds their PipeWire ERR totals; T0003 records `xruns` and `pipewire_errors` separately.
- From T0004 on, both arms export `PIPEASIO_REALTIME=1` (the kept change); aa-focusrite-1..3 stays the reference for cumulative gains.
- Upstream candidate (patch pipeasio/0009 left the flip to "the scheduling A/B"): ship `realtime=true`, or have the launcher export the switch. PR timing is the user's call.

**Trial T0004 (pre-registered before running): P-core affinity for the audio threads.**
- Setup:
  - Both arms export `PIPEASIO_REALTIME=1` (kept in T0003).
  - B pins `pipeasio-rt` and Live's 15 `AudioCalc` workers to the P-core CPUs 0–11 (`/sys/devices/cpu_core/cpus`) with `taskset`, from a 1 s watcher.
  - A runs the same watcher without pinning, so both arms carry the same overhead.
  - ABAB × 3; Sets Inbuilts, Max4Live, VSTs; `--duration 120`.
- Why: in T0003-B the workers waited 0.40–0.60 s per 120 s for a CPU, and 1–4 of the 15 ended on an E-core (CPUs 12–15). Live sets no affinity of its own (all audio threads are allowed on 0-15).
- PASS iff [D] or [E] holds, and both guards hold:
  - [D] median DSP average lower in B by more than 2× the A/A spread (aa-focusrite: Inbuilts 1.18, Max4Live 0.82, VSTs 0.86) on at least one heavy Set;
  - [E] total PipeWire ERR in B ≤ 0.6 × A, with a one-sided binomial test of B given A + B at p < 0.05;
  - guard: no Set's median DSP average worse in B by more than 2× its spread;
  - guard: total PipeWire ERR not higher in B.
- Mechanism check: `proc-delta.json` shows `cpus_allowed_list` 0-11 for the audio threads in every B Set-run, and 0-15 in A.
- Driver: ~/.local/state/profiler/trial-T0004.sh. Scored by `plans/tools/trial-analyze.py --rule t0004`.

**Trial T0004 — KEEP (2026-10-17):** PASS via [E], with both guards.
- PipeWire ERR 38 → 17 (−55 %, one-sided binomial p = 0.003); B fewer in 7 of 9 Set-pairs.
- [D] not met: the median DSP average fell on every Set (−0.68 / −0.92 / −0.37 pt), but within 2× the spread.
- Mechanism: B had the audio threads on 0-11 and none on an E-core at the end, against 3–5 of 15 on E-cores in A.
- Pinning raised the workers' total CPU wait ~9× (0.5 → 3.9–5.9 s per 120 s: 16 audio threads on 12 logical CPUs). Even so, dropouts halved and the worst peaks tightened (Max4Live 75–136 % → 81–88 %).
- Ledger + runs 7095b3f. From T0005 on, both arms pin the audio threads.
- Upstream candidate: on hybrid Intel CPUs the launcher could pin the audio threads to the P-cores by thread name.

**Trial T0005 (pre-registered before running): reserve the P-cores for audio.**
- Setup:
  - Both arms keep `PIPEASIO_REALTIME=1` and pin `pipeasio-rt` + `AudioCalc*` to the P-core CPUs 0–11 (T0003, T0004).
  - B also pins every other thread of Live's process (main/UI, graphics, Wine service threads: ~78 threads at the same SCHED_RR 10) to the E-core CPUs 12–15 (`/sys/devices/cpu_atom/cpus`), from the same 1 s watcher.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: in T0004-B the audio workers queued 3.9–5.9 s per 120 s for the 12 P-core CPUs, which they share with Live's own non-audio threads.
- PASS rule: the same as T0004. PASS iff [D] or [E] holds, and both guards hold:
  - [D] median DSP average lower in B by more than 2× the A/A spread on at least one heavy Set;
  - [E] total PipeWire ERR in B ≤ 0.6 × A, one-sided binomial p < 0.05;
  - guard: no Set's median DSP average worse in B by more than 2× its spread;
  - guard: total PipeWire ERR not higher in B.
- Mechanism check: in B, the non-audio Live threads show `cpus_allowed_list` 12-15 and the audio threads 0-11, and the AudioCalc CPU wait is reported per run.
- Driver: ~/.local/state/profiler/trial-T0005.sh. Scored by `plans/tools/trial-analyze.py T0005 --rule t0004`.

**Trial T0005 — REVERT (2026-10-18):** rule FAIL.
- Dropouts: PipeWire ERR 13 → 16 (B fewer in 3 of 9 pairs, p = 0.77), so the error guard failed.
- DSP: the median DSP average was lower on every Set, but within noise.
- Mechanism held: ~315 non-audio Live threads were on the E-cores in each B run, yet the AudioCalc CPU wait was unchanged (4–5 s per 120 s).
- Conclusion: the audio threads queue behind each other — 16 threads on 12 logical P-core CPUs (6 physical cores) — not behind Live's UI threads.
- Current best configuration (kept: realtime PipeASIO + P-core audio threads): 13–17 PipeWire ERR per 9 Set-runs of 120 s, against 204 before T0003. Worst DSP peaks are now 65–110 % (were 130–225 %).
- Ledger + runs 298955f.

Next candidates (user to choose; none pre-registered yet):
- (a) Fewer audio workers (Live's own setting; the installer's `--audio-threads`), e.g. 11 or 6, so the fan-out fits the P-cores.
- (b) One audio thread per physical P-core (CPUs 0,2,4,…), with the rest on the E-cores.
- (c) `WINE_APC_FASTPATH=1` (existing opt-in patch; no evidence yet that alertable zero-object sleeps sit on the audio path).
- (d) The slack budget first (tracer), to find the next lever from data instead of guessing.

**Trial T0006 (user decision 2026-10-18; pre-registered before running): six audio workers, one per physical P-core.**
- Setup:
  - Both arms keep `PIPEASIO_REALTIME=1` and pin `pipeasio-rt` to the P-core CPUs 0–11.
  - A: Live's current 15 workers (launcher auto), pinned to 0–11 (the T0004 configuration).
  - B: `ABLETON_MAX_AUDIO_THREADS=6` (the launcher writes Live's own `-MaxAudioThreads=6` before Live starts). The 1 s watcher pins each `AudioCalc` worker to its own physical P-core: one CPU each from 0, 2, 4, 6, 8, 10, least-used first, so no two workers share a core.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s; golden restored before every run (it brings back Live's own Options.txt).
- Why:
  - In T0004/T0005 the 15 workers plus the callback queued 4–5 s per 120 s for 12 logical CPUs on 6 physical cores, and moving other threads away did not change that (T0005).
  - Fewer workers also mean fewer wake-ups: about 110 `SetEvent` + 64 waits per block today come from the fan-out.
- PASS rule: the same as T0004 ([D] or [E], plus both guards); the DSP guard matters most here, because fewer workers mean less parallel capacity.
- Mechanism check: B runs show 6 `AudioCalc` threads, each allowed on exactly one CPU from {0,2,4,6,8,10} and all different, and `audio_workers` = 6 in the history records (A: 15). The AudioCalc CPU wait is reported per run.
- Driver: ~/.local/state/profiler/trial-T0006.sh. Scored by `plans/tools/trial-analyze.py T0006 --rule t0004`.

**Trial T0006 — INCONCLUSIVE (2026-10-18):** rule FAIL on the error guard.
- [D] PASS: VSTs median DSP average −1.75 pt (2.03× spread); Inbuilts −1.30, Max4Live −0.51 (all lower). DSP guard PASS.
- Error guard failed: PipeWire ERR 13 → 17, concentrated in Max4Live (2, 1, 1 → 0, 5, 5).
- Largest efficiency gain so far: Live CPU median 64.0 % → 40.1 % of one core (−37 %), and the AudioCalc CPU wait went from 3.6–5.4 s to 21–705 ms per 120 s.
- The default stays at Live's 15 workers; T0007 runs on that base, as pre-registered.
- Open question: is the Max4Live rise real (six workers lengthen its critical path) or noise? A confirmation with longer windows, or a middle count (8–9 workers), would decide.
- Ledger + runs d44375b.

**Trial T0007 (user decision 2026-10-18; pre-registered before running): wineserver at realtime priority.**
- Setup:
  - Both arms: the kept configuration — `PIPEASIO_REALTIME=1` and P-core audio threads.
  - Both arms also carry T0006's arm per T0006's own rule: B's six per-core workers if T0006 passes, else A's 15 workers on 0–11.
  - B: the 1 s watcher sets the prefix's `wineserver` to SCHED_RR 10 (`chrt -a -r -p 10`), the same class and priority as the Live threads it serves. A leaves it SCHED_OTHER.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: the launcher's `chrt -r 10` covers Live but not wineserver, which ran SCHED_OTHER in every recent run. It waited 0.24–0.48 s per 120 s for a CPU while using only ~1.5 % of a core. It was woken 340–390 k times per 120 s (~4 times per audio block), so Live talks to it every block. That is the same inversion pattern as pipeasio-rt before T0003.
- PASS rule: the same as T0004 ([D] or [E], plus both guards).
- Mechanism check: in B, wineserver shows `policy_at_end` = RR with priority 10 in `proc-delta.json` (A: OTHER), and its CPU wait (`schedstat run_delay`) is lower.
- Driver: ~/.local/state/profiler/trial-T0007.sh. Scored by `plans/tools/trial-analyze.py T0007 --rule t0004`.

**Trial T0007 — REVERT (2026-10-18):** rule FAIL.
- Dropouts: PipeWire ERR 9 → 18 (B fewer in 1 of 9 pairs; B worse at one-sided p = 0.06).
- DSP: the median DSP average was within 0.13 pt on every Set.
- Mechanism held: wineserver ran SCHED_RR 10 with a 2–3 ms CPU wait per 120 s, against 252–336 ms at SCHED_OTHER.
- Conclusion: its waiting is not what makes blocks late, and at the audio workers' priority it may compete with them.
- Ledger + runs 7477ea9.
- Next: a traced diagnostic run on the kept configuration, to name the ~4 per-block wineserver requests and count the Wine crossings per block. That leads into the first Wine hot-path patch (the event fast path for the worker fan-out).

**Trial T0008 (user decision 2026-10-18: "the 8–9 worker trial"; pre-registered before running): nine audio workers.**
- Setup:
  - Both arms keep the kept configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to the P-core CPUs 0–11 (shared, as in T0004).
  - A: Live's 15 workers (launcher auto).
  - B: `ABLETON_MAX_AUDIO_THREADS=9`. Only the worker count changes; T0006 changed both count and per-core pinning.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: T0006's six workers cut Live's CPU 37 % and lowered DSP load, but Max4Live dropouts rose. Nine workers plus the callback (10 threads) still fit the 12 P-core CPUs with no queueing, keep more parallel capacity, and should keep most of the fan-out saving (syncbench: ~11 → ~8 µs per round).
- PASS rule: the same as T0004 ([D] or [E], plus both guards).
- Mechanism check: 9 `AudioCalc` threads in every B Set-run (15 in A), all allowed on 0–11.
- Driver: ~/.local/state/profiler/trial-T0008.sh. Scored by `plans/tools/trial-analyze.py T0008 --rule t0004`. If it passes or is inconclusive, eight workers is the follow-up.

**Trial T0008 — KEEP (2026-10-18):** PASS via [E], with both guards.
- Dropouts: PipeWire ERR 20 → 10 (−50 %). B was fewer in 6 of 9 Set-pairs (one-sided p = 0.049), so the evidence clears the bar only just.
- DSP: the median DSP average was lower on every Set (Inbuilts −0.61, Max4Live −1.06, VSTs −0.84 pt), but within 2× the A/A spread, so [D] was not met.
- Efficiency: Live CPU 64.2 → 49.4 % of one core (−23 %). The AudioCalc CPU wait fell from 3.9–5.7 s to 38–93 ms per 120 s. Worst DSP peaks fell from 112 to 82 % (Inbuilts) and from 111 to 84 % (Max4Live); VSTs stayed at 107–111 %.
- Mechanism held: 9 `AudioCalc` threads in every B Set-run (15 in A), all on CPUs 0–11.
- Kept: nine workers (`ABLETON_MAX_AUDIO_THREADS=9`) join the configuration, and later trials run both arms on it.
- Ledger + runs 79cfd52.

**Trial T0009 (the follow-up T0008 pre-registered; registered before running): eight audio workers.**
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared).
  - A: `ABLETON_MAX_AUDIO_THREADS=9`, T0008's kept count.
  - B: `ABLETON_MAX_AUDIO_THREADS=8`.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: going from 15 to 9 workers halved the dropouts and cut Live's CPU by 23 %. Six workers (T0006) cut CPU further but raised Max4Live dropouts. Eight workers plus the callback leave three P-core CPUs for Live's other threads, while keeping more parallel capacity than six. The trial shows whether the curve still improves below nine or has turned.
- PASS rule: the same as T0004 ([D] or [E], plus both guards). If it fails, nine workers stay.
- Mechanism check: 8 `AudioCalc` threads in every B Set-run (9 in A), all allowed on 0–11.
- Driver: ~/.local/state/profiler/trial-T0009.sh. Scored by `plans/tools/trial-analyze.py T0009 --rule t0004`.

**Trial T0009 — REVERT (2026-10-18):** rule FAIL.
- Dropouts: PipeWire ERR 4 → 14. B was fewer in only 1 of 9 Set-pairs, so the error guard failed.
- DSP: the median DSP average moved by at most 0.28 pt on any Set, all within noise.
- No efficiency gain: Live CPU 47.8 vs 47.5 % of a core. With nine workers the AudioCalc CPU wait was already only 35–77 ms per 120 s.
- Mechanism held: 8 `AudioCalc` threads in every B Set-run (9 in A).
- Nine workers stay, so the curve has turned between nine and eight. The nine-worker A arm had 4 PipeWire errors in 9 Set-runs, the fewest of any arm so far.
- Ledger + runs 7e38650.

**Trial T0010 (user decision 2026-10-18: "Ableton minimized before the play command is issued so the UI does not render"; pre-registered before running): Live minimised during playback.**
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared). The worker count is whatever T0009 leaves: eight if it passes, nine otherwise.
  - A: Live's window stays as it is, on screen and rendering.
  - B: `--live-window minimized` (59a5b83). The suite minimises Live's main window after the Set has loaded and before `rewind`/`play`, and restores it after the measurement. The switch is recorded as `ABLETON_BENCH_LIVE_WINDOW=minimized`.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: Live's UI renders all the time (~38 % of a core earlier). All of Live's threads, the UI included, run SCHED_RR 10 through the launcher's `chrt`, the same priority as the audio workers, and the UI threads are not pinned. So the UI competes with the callback and the workers for the P-cores, memory bandwidth and the shared power budget. Minimising removes the rendering without touching the audio path.
- PASS rule: the same as T0004 ([D] or [E], plus both guards).
- What a verdict means: this is a diagnostic, a measurement of what the UI costs the audio path. Nobody performs with Live minimised, so later trials keep the normal window whatever the verdict. A PASS makes UI-side changes, such as a lower UI priority or cheaper rendering, the next trials. A FAIL with the mechanism confirmed rules the UI out as a cause of dropouts.
- Mechanism check:
  - In B, every Set's `raw/live-window.txt` shows the main window iconic after minimising and still iconic at the end of the measurement. A has no such file.
  - Live's CPU is lower in B than in A. If it is not, minimising did not stop the rendering, and the trial says nothing about the UI.
- Driver: ~/.local/state/profiler/trial-T0010.sh. Scored by `plans/tools/trial-analyze.py T0010 --rule t0004`.

**Trial T0010 — REVERT (diagnostic, 2026-10-18):** rule FAIL. Started by a laptop-side queue runner (`queue-T0010.sh`) when T0009 ended, on nine workers.
- Dropouts: PipeWire ERR 16 → 28. B was fewer in only 2 of 9 Set-pairs, so the error guard failed.
- DSP: the median DSP average was within 0.11 pt on every Set. Live CPU was 47.0 vs 46.6 % of a core.
- Mechanism: the window stayed minimised for the whole measurement in 9 of 9 B Set-runs. But minimising removes little of the UI's work. Medians over 9 Set-runs, in % of one core:
  - Live's UI thread (thread id = pid): 10.6 → 9.8;
  - `wined3d_cs`: 2.3 → 1.6;
  - wineserver: 1.5 → 1.0.
  (47 of Live's threads are named `MainThread`, because unnamed threads inherit the name, but the UI thread is almost all of their CPU.)
- Conclusion: what minimising removes does not cause dropouts, and the normal window stays. Live's log reads `GPU Renderer: Off (Platform default)`: Live draws its UI on the CPU and presents it through D3D11 on the Intel iGPU, which led to T0011.
- Caution: this A arm had 16 errors on the configuration that gave T0009's A arm 4. Error counts vary widely between trials, so only the paired comparison counts.
- Ledger + runs 36e4295.

**Trial T0011 (user decision 2026-10-18: turn on Live's GPU renderer; pre-registered before running): Live's GPU renderer on.**
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared), nine workers, and Live's window normal.
  - A: snapshot `golden`. Live logs `GPU Renderer: Off (Platform default)`.
  - B: snapshot `golden-gpu`. This is golden with the GPU renderer switched on once in Live's settings by the user, and `state diff` must show Live's preferences as the only real change.
  - Every run restores its arm's snapshot first; the driver restores `golden` at the end.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why: Live's UI thread takes ~10 % of a core during playback (T0010), and it does Live's CPU drawing. The GPU renderer moves the drawing to the GPU through wined3d. That should free the UI thread, which runs at the audio threads' realtime priority, and the CPU's shared power budget. It may also add work in wined3d's command-stream and GL driver threads.
- PASS rule: the same as T0004 ([D] or [E], plus both guards). Unlike T0010, a PASS is kept: `golden-gpu` becomes the baseline (`state snapshot --rebaseline`).
- Mechanism check: Live's `Log.txt` reads `GPU Renderer: On` for every B launch and `Off` for every A one. The driver aborts after B1 unless all three of its launches ran with the GPU renderer on. The per-thread CPU of the UI thread and `wined3d_cs` is reported per arm.
- Driver: ~/.local/state/profiler/trial-T0011.sh. Scored by `plans/tools/trial-analyze.py T0011 --rule t0004`.

**Trial T0011 — REVERT (2026-10-18):** rule FAIL; both guards pass.
- Dropouts: PipeWire ERR 18 → 18 (B fewer in 3 of 9 Set-pairs).
- DSP: the median DSP average was within 0.19 pt on every Set.
- Mechanism held: the GPU renderer was on in 9 of 9 B launches (`GPU Renderer: OnAlways (User setting)`).
- Under Wine the GPU renderer costs CPU instead of saving it. Medians, % of one core: UI thread 10.7 → 11.4, `wined3d_cs` 2.3 → 3.0, wineserver 1.6 → 1.7, Live 48.1 → 51.1.
- Why: Wine translates Live's D3D11 drawing to OpenGL on the CPU, on the calling thread.
- `golden` (renderer off) stays the baseline. `golden-gpu` is kept for a later test with a different Wine rendering path (DXVK or wined3d's Vulkan renderer).
- Ledger + runs 9573c20.

**Trial T0012 (user decision 2026-10-18: "q t0012"; pre-registered before running): the APC fast path.**
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared), nine workers, the normal window, and snapshot `golden`. If T0011 passes, its snapshot becomes the baseline first, and the queue holds for that.
  - A: Wine's regular wait route, the runtime's default.
  - B: `WINE_APC_FASTPATH=1`, the runtime's `performance/0001` patch. Alertable zero-handle sleeps (`NtDelayExecution`) then wait on the NTSync alert event instead of a wineserver select; APC routing itself stays in wineserver.
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s.
- Why:
  - The patch's own measurement: an empty Live Set caused about 3,650 wineserver context switches per second, one per alertable delay.
  - D0001 counted about 370 wineserver requests per second on the heavy Sets.
  - wineserver runs SCHED_OTHER, unpinned (T0007), so its wakeups land on the CPUs the audio threads use. Removing them changes nothing on the audio path itself.
  - This is also the first trial of a Wine patch, and it is already in the runtime.
- PASS rule: the same as T0004 ([D] or [E], plus both guards). A PASS keeps the switch for later trials; making it a default stays the user's call.
- Mechanism check: wineserver's voluntary context switches and CPU fall in every B Set-run (`proc-delta.json`), and `WINE_APC_FASTPATH=1` is recorded as a switch on B.
- Driver: ~/.local/state/profiler/trial-T0012.sh, started by `queue-T0012.sh` after T0011. Scored by `plans/tools/trial-analyze.py T0012 --rule t0004`.

**Trial T0012 — REVERT (2026-10-18):** rule FAIL; both guards pass; the mechanism did not show.
- Dropouts: PipeWire ERR 12 → 6, with B fewer in 5 of 9 Set-pairs (one-sided p = 0.12): noise.
- DSP: the median DSP average was within 0.41 pt on every Set. Live CPU was 47.4 vs 48.6 %.
- Mechanism: `WINE_APC_FASTPATH=1` was recorded as a switch on every B run. But wineserver's voluntary context switches did not fall: 3,063–3,069 per second in A against 3,049–3,066 in B, and its CPU did not change either.
- So either the fast path did not engage on these Sets, or Live's alertable zero-handle sleeps are not where wineserver's ~3,000 wakeups per second come from on the heavy Sets. The patch's own figure (3,650 per second) came from an empty Set.
- The trial says nothing about the fast path itself. The switch stays off.
- Open question: what wakes wineserver ~3,000 times per second during playback? A traced run with server requests by type, or `strace -c` on wineserver, would name it.

**Trial T0013 (user decision 2026-10-18: "Lets queue T0013 now"; pre-registered before running): user-mode QueryPerformanceCounter (patch 0109).**
- Runtime: the official build with 0109 (cf2fe55). It was built on the workstation and installs on the laptop when T0012 releases the session lock; the queue starts T0013 only once that runtime is in place.
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared), nine workers, the normal window, and snapshot `golden`.
  - Both arms also carry T0012's verdict: `WINE_APC_FASTPATH=1` on both if it passes.
  - A: `WINE_QPC_TSC` unset (the syscall route).
  - B: `WINE_QPC_TSC=1` (user mode).
  - ABAB × 3; Inbuilts, Max4Live, VSTs; 120 s. Then one traced run per arm (`--trace interface`, 60 s per Set).
- Why: D0001 shows Live calls `RtlQueryPerformanceCounter` about 67 times per block: two Live sites at ~31.5 each, `timeGetTime` 1.5 and Max's msvcp140 1.8. Each call is a 76 ns syscall; in user mode it takes 14 ns. That is about 4 µs of audio-thread CPU per 1.33 ms block, below what the dropout count can detect. The trial mainly guards against a regression under real load and confirms the mechanism.
- PASS rule: the same as T0004. Verdicts:
  - PASS: keep (later trials run with the switch);
  - FAIL with both guards passing and the mechanism confirmed: mechanism-confirmed (no regression; the switch stays available, off by default);
  - a failed guard: revert.
- Mechanism check:
  - In every B Set-run, Live's view of the shared user data page shows the mapping enabled: offset `0xf04` = 1, read through `/proc/<pid>/mem`. A shows 0.
  - The traced runs show about 67 `NtQueryPerformanceCounter` syscalls per block in A and about 0 in B.
- Driver: ~/.local/state/profiler/trial-T0013.sh, started by `queue-T0013.sh` after T0012 and the 0109 install. Scored by `plans/tools/trial-analyze.py T0013 --rule t0004`.

**Trial T0013 — REVERT (2026-10-18):** rule FAIL; the DSP guard passes, the error guard fails.
- Dropouts: PipeWire ERR 5 → 17. B had more errors in 4 Set-pairs, fewer in 2 and the same in 3 (sign test p = 0.34); 10 of B's 17 came from B3.
- DSP: the median DSP average was within 0.21 pt on every Set. Live CPU was 47.3 vs 48.8 %.
- Mechanism: the user-mode mapping was enabled in 9 of 9 B sessions and 0 of 9 A sessions. Traced A counted 66.6, 71.8 and 77.2 `NtQueryPerformanceCounter` syscalls per block (Inbuilts, Max4Live, VSTs). `qpcprobe` on the official runtime passed 4 of 4.
- Traced B did not run: the Focusrite was unplugged by accident at 14:29, during traced A's Max4Live Set. Only traced A's Inbuilts Set ran on the interface, so the traced pair is not cited, and traced A's record stays out of history.
- Context, not part of the rule: earlier arms on the kept configuration had 10, 4, 16, 18 and 12 errors (T0008–T0012). B's 17 is inside that range and A's 5 near its floor. The trial shows neither clear harm nor that the switch is harmless.
- `WINE_QPC_TSC` stays off by default and remains available as an opt-in switch.

**Trial T0014 (user decision 2026-10-18: "Lets reorder this nvidia gpu test before rt bore test"; pre-registered before running): the built-in screen on the NVIDIA GPU (discrete mode).**
- Setup:
  - Both arms keep the configuration: `PIPEASIO_REALTIME=1`, with pipeasio-rt and every `AudioCalc` worker pinned to CPUs 0–11 (shared), nine workers, the normal window, snapshot `golden` (Live draws its UI on the CPU) and the normal kernel. Both arms also carry T0013's verdict: `WINE_QPC_TSC=1` on both if it is kept.
  - A: hybrid, today's firmware setting. The Intel iGPU (`i915`) drives the built-in screen (`eDP-1`); KWin, Xwayland and Live's presents run on it.
  - B: discrete. The firmware's GPU switch (the MUX) connects the built-in screen to the NVIDIA GPU (`eDP-2`, `nvidia` 615.78.08). KWin, Xwayland and Live's presents run on it, and the iGPU is off.
  - Every run starts from a fresh boot, so both arms start from the same state:
    - Once the desktop session is up, the driver stops the three timers that fire after every boot, for that boot only: snapper-cleanup (10 min), systemd-tmpfiles-clean (15 min) and the user's arch-update (2 min).
    - It then waits at least 120 s, and until the 1-minute load average is below 1.0 (at most 10 min).
  - Switching arms is a firmware change by the user, so the runs go in blocks: A1 | B1 B2 B3 | A2 A3.
    - Between runs of the same arm, the driver reboots.
    - At a block boundary it reboots into the firmware setup (`systemctl reboot --firmware-setup`). The user switches the GPU mode and saves, and the next run starts after that boot.
    - The A runs on both sides of the B block show drift.
  - Inbuilts, Max4Live, VSTs; 120 s. About 11 minutes per run including the boot: about 70 minutes, plus the two firmware changes.
- Why:
  - The user asked whether the NVIDIA GPU could do Live's normal 2D drawing faster. With the renderer off, Live draws on the CPU in both arms. What changes is everything after the drawing: the presents, the compositor and the memory the frames live in.
  - For: the CPU package stops powering the iGPU, and display traffic moves from system RAM, which the CPU shares, into VRAM.
  - Against: the NVIDIA GPU has to stay awake, and its heat goes into the cooling the CPU shares. In hybrid it is already awake in P0 today, because KWin holds its device.
  - The net effect on audio is unknown; only a measurement settles it.
- PASS rule: the same as T0004 ([D] or [E], plus both guards), plus a drift guard for the blocks: on every heavy Set, A1's DSP average must lie within 2× the A/A spread of the mean of A2 and A3. If the drift guard fails, the verdict is inconclusive.
  - PASS: discrete becomes the configuration, and the RT kernel trials run in it; the RT kernel's NVIDIA module then drives the screen.
  - Otherwise hybrid stays, which is also the mode the trial ends in.
- Mechanism check:
  - At every boot the driver records which GPU drives the built-in screen (the connected `eDP` connector and its DRM driver) and which DRM devices KWin holds. A run whose arm does not match the screen's GPU does not start; the driver stops and reports the mismatch.
  - Secondary readouts per run: CPU package power (RAPL) and temperature, P-core frequency, the NVIDIA GPU's power state and draw, and Live's per-thread CPU.
- Driver: ~/.local/state/profiler/trial-T0014.sh runs one step per boot. A waiter on the controlling host starts each step once the laptop is back, and reports when a firmware change is due. Scored by `plans/tools/trial-analyze.py T0014 --rule t0004`; the drift guard is computed beside it.
- Status (2026-10-18 14:50): not started.
  - The user changed a firmware setting after T0013. It made the NVIDIA GPU the boot VGA device: the iGPU now reports PCI class 0x0380, and the DRM card numbers swapped.
  - The built-in screen stayed on the Intel GPU (`eDP-1` on `i915`; `eDP-2` on NVIDIA disconnected). KWin composites on Mesa Intel, and GLX clients such as wined3d render on Mesa Intel. So the MUX did not switch.
  - MSI documents the GPU switch for this model in MSI Center on Windows (FAQ 8805), not in the firmware setup.
  - Also changed since T0013: the laptop is on wired Ethernet (`enp3s0`) with Wi-Fi off.
- **Display setup from 2026-10-18 15:03 (user decision: "apply the changes to go to external monitor"):** the desktop runs on the NVIDIA GPU only, on an external monitor on the HDMI port, which is wired to the NVIDIA GPU. The lid is closed.
  - udev rule `/etc/udev/rules.d/61-profiler-gpu-names.rules` gives the GPUs stable names without colons: `/dev/dri/nvidia-dgpu` and `/dev/dri/intel-igpu`. The card numbers change with the firmware's boot-VGA setting, and `KWIN_DRM_DEVICES` is colon-separated.
  - `~/.config/environment.d/90-profiler-kwin-gpu.conf` sets `KWIN_DRM_DEVICES=/dev/dri/nvidia-dgpu`, so KWin opens only the NVIDIA GPU, and Xwayland's GL follows it.
  - The kernel option `video=eDP-1:d` (in `/etc/default/grub`; the old file is kept as `grub.profiler-<timestamp>`) turns off the built-in panel's connector on the Intel GPU. Without it, the Intel GPU keeps the console on the panel. The Intel driver stays loaded, so the iGPU still idles in its low-power state.
  - The monitor runs at 1920×1080, 59.94 Hz, to match the built-in panel's 60 Hz.
  - Verified after a reboot: KWin and Xwayland report the RTX 4060. Live's log reads `TD3dSurface: Adapter: 'NVIDIA GeForce RTX 4060M'` (`Intel(R) Graphics` before). The NVIDIA GPU ran at 31–44 % load in P8 during playback.
  - Smoke run (Inbuilts, 60 s, unpinned): 0 PipeWire errors, DSP 10.6 / 19.8, 64 frames.
  - The firmware's boot graphics device stays NVIDIA, so the firmware and GRUB screens appear on the monitor.
  - Undo: remove the environment.d file and the kernel option, run `grub-mkconfig`, and reboot.
  - T0014 needs a new design for this setup; the one above assumed the firmware MUX.

**Feasibility check G0: leaving OpenGL (user decision 2026-10-18: "yes lets do feasibility check"; a diagnostic, no verdicts)**
- Setup: the NVIDIA-only external display above, and the kept configuration (pinning, nine workers). Benchmark_Inbuilts, one 60 s window per run, with screenshots during playback. Driver `~/.local/state/profiler/dxvk-check.sh`; summary `fc-summary.py`.
- DXVK 3.1.1 (tarball sha256 `40565b4a…f54e608`, kept outside the repo):
  - Snapshots `golden-dxvk` and `golden-dxvk-gpu` (golden / golden-gpu plus DXVK's 64-bit `d3d10core.dll`, `d3d11.dll` and `dxgi.dll` in system32).
  - Launch settings: `WINEDLLOVERRIDES=d3d10core,d3d11,dxgi=n,b`, `ABLETON_DCOMP=off` (DXVK refuses composition swap chains) and `DXVK_FILTER_DEVICE_NAME=NVIDIA`.
  - Without DXVK's `d3d10core.dll`, Live aborted at "Starting Max…": Wine's own `d3d10core` called `dxgi.dll.DXGID3D10CreateDevice`, which DXVK does not export.
- Results (one run each, so indicative only; Live's CPU in % of one core):

  | Path | Live | Graphics threads | UI thread | DSP avg / peak | Errors |
  |---|---|---|---|---|---|
  | OpenGL (wined3d), renderer off (today) | 48.3 | 2.5 | 9.2 | 10.00 / 17.93 | 0 |
  | OpenGL, renderer on | 67.0 | 21.4 | 8.8 | 10.11 / 17.89 | 1 |
  | wined3d's Vulkan back end (`WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan`), renderer off | 47.7 | 1.6 | 10.2 | 9.73 / 17.81 | 0 |
  | wined3d's Vulkan back end, renderer on | 42.1 | 1.7 | 9.5 | 8.70 / 17.32 | 1 |
  | DXVK, renderer off | 83.0–91.0 | 1.8–5.8 (+40 spinning) | 9.6–10.1 | 8.81–9.74 | 1, 1, 4 |
  | DXVK, renderer on | 158.7 | 1.0 (+40 spinning) | 51.3 | 18.95 / 89.78 | 208 |

- DXVK spins. Live paces its UI with `IDXGIOutput::WaitForVBlank`, which DXVK emulates with a sleep ("Inaccurate", per its log). Its sleep busy-waits for 4 × the timer resolution plus a sixth of each wait. Wine reports a 1 ms resolution, so that is about 6.8 ms of every 16.7 ms frame: one Live thread at 40 % of a core, at Live's realtime priority.
  - `perf`: 56 % in `ntdll.so`, 19 % in `clock_gettime` (vDSO), 17 % in DXVK's `dxgi.dll`.
  - Forcing vsync (`dxgi.syncInterval = 1`) does not change it, and DXVK's HUD shows 59.9 fps, so Live does not redraw without limit.
  - A fix needs a DXVK source change: skip the busy-wait under Wine, whose sleep is already precise.
- wined3d's Vulkan back end renders Live correctly in the screenshots. It keeps Wine's dxgi/dcomp code and the runtime's presentation fixes, and with the GPU renderer on it gave the lowest Live CPU of the day. OpenGL with the renderer on costs 21 % of a core in `wined3d_cs` on the NVIDIA GPU.
- Next: the user checks the Vulkan path by hand (Learn View, plugin windows, resizing, browser). Then a pre-registered ABAB trial: A today (OpenGL, renderer off) vs B wined3d-Vulkan with the GPU renderer on. DXVK is parked unless that path fails.

**Feasibility check G0b: a 30 fps cap (user decision 2026-10-18: "lets do a feasability test with 30 fps wine vulkan back end first")**
- Wine's `fps` channel shows Live presenting at 60 fps through one swapchain, both on OpenGL and on the Vulkan back end. With DirectComposition on, no Live thread waits for vblank. That wait only showed up under DXVK, which runs with DirectComposition off.
- Experimental change in the dev tree (not yet a series patch; diff kept in the session scratchpad): `WINED3D_PRESENT_FPS=N` caps each swapchain at N presents per second.
  - In `wined3d_swapchain_present`, the presenting thread sleeps (`NtDelayExecution`, never a spin) until the swapchain's next slot. It does so before it takes the wined3d lock, so other threads are not held up.
  - The swapchain gains one field, `present_cap_next`. wined3d logs the cap once on the winediag channel.
- Verified: Wine's `fps` channel reads 30.0 fps (`wined3d_cs_exec_present` and `vkQueuePresentKHR`), and the screenshots show Live drawing correctly.
- Results on the dev runtime (one 60 s Inbuilts run each, interleaved; % of one core; compositor = kwin_wayland + Xwayland over the whole run):

  | Config | UI thread | wined3d_cs | Compositor | Sum | DSP avg / peak | Errors |
  |---|---|---|---|---|---|---|
  | OpenGL, renderer off (today) | 8.4 | 2.6 | 4.4 | 15.4 | 9.67 / 17.66 | 5 |
  | OpenGL, renderer off, 30 fps | 8.9 | 1.9 | 2.8 | 13.6 | 10.20 / 18.90 | 5 |
  | Vulkan, renderer on | 8.9 | 1.7 | 3.9 | 14.5 | 10.23 / 18.15 | 0 |
  | Vulkan, renderer on, 30 fps (two runs) | 7.4–7.8 | 1.3 | 2.9–3.0 | 11.6–12.1 | 9.27–9.51 / 20.5–21.8 | 3, 5 |

- Halving the frame rate saves about 2–3 points of a core across Live's UI thread, `wined3d_cs` and the compositor. That is less than hoped: Live's UI thread wakes about 2,000 times a second for far more than drawing.
- The best combination (Vulkan, renderer on, 30 fps) is about 3.5 points below today's display cost.
- No effect on the audio side is visible in single runs. The DSP averages and the errors stay within run-to-run noise: Live's total CPU swings by about 4 points between identical runs because the audio workers' CPU varies.
- Correction to G0: on the same runtime, the Vulkan back end with the renderer on is not clearly cheaper than OpenGL with the renderer off (14.5 vs 15.4). The earlier 42.1 % was a favourable run.
- The DSP peak median was higher in both capped Vulkan runs (20.5 and 21.8 vs 18.2). A trial should check that.
- Lower caps (user: "lets try one run at 5 fps", then 10 fps, then 15 fps; Vulkan, renderer on, dev runtime):

  | Cap | Present wait | UI thread | wined3d_cs | Compositor | Sum | DSP avg / peak | Errors |
  |---|---|---|---|---|---|---|---|
  | none (60 fps) | — | 8.9 | 1.7 | 3.9 | 14.5 | 10.23 / 18.15 | 0 |
  | 30 fps | up to 33 ms | 7.4–7.8 | 1.3 | 2.9–3.0 | 11.6–12.1 | 9.27–9.51 / 20.5–21.8 | 3, 5 |
  | 20 fps | up to 50 ms | 6.0 | 1.0 | 2.3 | 9.3 | 9.62 / 34.24 | 5 |
  | 15 fps | up to 67 ms | 5.0 | 0.8 | 2.0 | 7.8 | 8.07 / 24.19 | 19 |
  | 10 fps | up to 100 ms | 3.8 | 0.6 | 1.5 | 5.9 | 5.58 / 36.30 | 20 |
  | 5 fps | up to 200 ms | — | — | — | — | — | Live hung at startup and was killed |

- The cap holds the rate exactly at every setting, but it does so by making Live's UI thread sleep inside each present. The longer that sleep, the worse the audio: the DSP peak climbs from 18 to 36, and the PipeWire errors jump to 19–20 at 15 and 10 fps.
  - Likely cause: Live's main thread does work the audio engine depends on, or does its work in bursts after each long sleep.
  - 30 fps is the only cap that looks harmless in single runs, and even there the peaks rise.
- A cap that blocks presents is therefore the wrong mechanism below 30 fps. Lowering the frame rate safely needs Live itself to draw less often, with its UI thread free. One candidate: report a lower display refresh rate to Live (Wine's display frequency, which `DwmFlush` and the composition timing follow) instead of sleeping in `Present`.

**Feasibility check G0c: report a lower refresh rate (user decision 2026-10-18: "lets try to report 30Hz to live", then "actually lets try 20 hz")**
- Experimental change in the dev tree: `WINE_REPORTED_REFRESH_RATE=N` (1–240) makes `NtUserEnumDisplaySettings(ENUM_CURRENT_SETTINGS)` report N Hz. The real mode is unchanged. `DwmFlush`, `DwmGetCompositionTimingInfo`, DirectComposition's frame statistics, `GetDeviceCaps(VREFRESH)` and DXGI's current mode all read it there. win32u logs it once on the winediag channel.
- At 20 Hz (Vulkan, renderer on, no present cap) Live presented at 20.0 fps by itself (Wine's `fps` channel), so its UI thread stays free between frames. Display work fell exactly as with the 20 fps cap: UI thread 6.1, `wined3d_cs` 0.8, compositor 2.4, sum 9.3 (14.5 at 60 Hz).
- The audio got worse anyway: 18 PipeWire errors and a DSP peak of 33.11. For comparison, every 60 fps run today had 0–5 errors, and the 15 and 10 fps caps had 19 and 20.
  - So the extra dropouts come from Live running its UI loop slower, not from the cap's blocking. T0010 points the same way: minimising Live (no drawing) raised errors from 16 to 28.
  - Live's audio side evidently depends on the main loop's cadence.
  - The higher DSP peak is partly a measuring artifact: Live reports the worst buffer since its last UI update, so the window grows as the frame rate falls. The PipeWire errors are measured outside Live.
- Implication: a frame rate below 30 fps works against the primary metric. The opposite direction is untested: a faster UI loop (the monitor's real 75 or 100 Hz modes, or a higher reported rate) might reduce dropouts, at some CPU cost.
- 100 Hz test (user: "okay lets try 100hz"; the monitor's real 1920×1080 100 Hz mode, dev runtime, no switches; back to 59.94 Hz afterwards):

  | Config | Live presents | UI thread | Graphics | Compositor | DSP avg / peak | Errors |
  |---|---|---|---|---|---|---|
  | OpenGL, renderer off, 60 Hz | 60 fps | 8.4 | 2.6 | 4.4 | 9.67 / 17.66 | 5 |
  | OpenGL, renderer off, 100 Hz | — | 11.1 | 2.4 | 4.3 | 9.35 / 17.06 | 4 |
  | Vulkan, renderer on, 60 Hz | 60 fps | 8.9 | 1.7 | 3.9 | 10.23 / 18.15 | 0 |
  | Vulkan, renderer on, 100 Hz | 59.6–62.2 fps | 11.3 | 1.8 | 3.9 | 9.40 / 17.70 | 1 |

  - Live caps its own drawing at about 60 fps, but its UI loop follows the refresh rate, costing about 2.5 more points of a core on the UI thread. No change in audio.
- Conclusion of G0b/G0c: keep 60 Hz. Lower frame rates save display CPU but raise dropouts below 30 fps; higher refresh rates cost CPU and change nothing. Both switches (`WINED3D_PRESENT_FPS`, `WINE_REPORTED_REFRESH_RATE`) stay in the dev tree only, uncommitted. 30 fps remains the only candidate for saving CPU, and it would need a proper trial.

**Feasibility check G0d: present skipping (user: "Vulkan, GPU renderer on, 60 Hz is the way to go" ... "lets try present skipping")**
- Experimental change in the dev tree: `WINED3D_PRESENT_SKIP=N` (2–60) shows only every Nth present of each swapchain; the others return at once. It sits in `wined3d_swapchain_present`, before the present cap.
  - Live's loop keeps its 60 Hz pace and keeps drawing every frame. Buffers rotate only on a real present, so the frames drawn in between land in the same back buffer and every frame shown is complete.
  - A skipped present still balances the frame-latency handshake. With a waitable object it releases the semaphore the worker would have released after presenting. Without one, the present path neither waits nor releases.
- At N = 6 (Vulkan, renderer on, dev runtime) Wine's `fps` channel reads 10.0 executed presents per second, and the screenshot is complete and correct.

  | Config | Shown | UI thread | wined3d_cs | Compositor | Sum | DSP avg / peak | Errors |
  |---|---|---|---|---|---|---|---|
  | Vulkan, renderer on, 60 fps | 60 fps | 8.9 | 1.7 | 3.9 | 14.5 | 10.23 / 18.15 | 0 |
  | 10 fps cap (Live's loop slowed) | 10 fps | 3.8 | 0.6 | 1.5 | 5.9 | 5.58 / 36.30 | 20 |
  | Present skipping, N = 6 (Live's loop at 60) | 10 fps | 9.3 | 1.2 | 1.6 | 12.1 | 9.18 / 17.96 | 0 |

- This confirms the hypothesis: Live's audio side needs its loop at the display rate, not the frames shown. Skipping keeps the audio as it is (0 errors, normal DSP peak) and saves the presentation work: about 2.4 points of a core (compositor 3.9 → 1.6, `wined3d_cs` 1.7 → 1.2). Live's own drawing on its UI thread is unchanged; Wine cannot skip it.
- Trade-off: the screen and input feedback update at 60/N fps.
- Next: the user tries it by hand. Then a pre-registered trial: A today (OpenGL, renderer off) vs B Vulkan + GPU renderer + present skipping at the N the user accepts. If kept, the switch becomes a numbered patch with its audit entries and an official build.
- Occluded variant (user: "lets try setting live is occluded during draw"): `WINED3D_PRESENT_SKIP_OCCLUDED=1` makes skipped presents return `DXGI_STATUS_OCCLUDED` (0x087a0001), the status DXGI gives a hidden window, in the hope that Live would also skip its own drawing.
  - Both winediag lines confirm the switch was active. Live ignores the status: it kept presenting 60 times a second (10.0 fps shown at N = 6), its UI thread stayed at 9.6, and the audio was unchanged (DSP 9.89 / 18.49, 0 errors).
  - So Live's own drawing cannot be reduced from Wine without slowing its loop, which raises dropouts (G0b/G0c). Present skipping, at about 2.4 points, is the most the presentation side gives.

**RT-BORE kernel phase (user decision 2026-10-18: after T0013, stop and try the RT-BORE kernel with the NVIDIA driver; the same day the user moved it after T0014; pre-research only so far)**
- What the laptop has:
  - Bootloader: GRUB with grub-btrfs and grub-hook (the menu is regenerated by a pacman hook), `GRUB_DEFAULT=0`, a 5 s menu, and the other kernels in a submenu.
  - Running kernel: `linux-cachyos` 7.2.9-2 with `PREEMPT=y` (dynamic, mode `full`), HZ=1000, `NO_HZ_FULL` available but not enabled, `NTSYNC=m`, BTF and uprobes. Neither PREEMPT_RT nor BORE is in its config.
  - Also installed: `linux-cachyos-lts` 6.18.55. sched_ext schedulers are installed but inactive.
  - Graphics: the Intel Raptor Lake-P iGPU runs on `i915` (`xe` is loaded, unused). The RTX 4060 Laptop runs on `nvidia` 615.78.08 (open modules, `nvidia-prime`/`prime-run` present). The dGPU is awake in P0 while Live renders on the Intel GPU; why (an external display, KWin) is a pre-check item.
  - Autologin (plasmalogin: colby, plasma, Relogin=true) brings the desktop session and PipeWire back after a reboot, so runs can follow a reboot unattended.
- Install, with no system upgrade: `linux-cachyos-rt-bore` 7.2.9-2, `-headers` and `-nvidia-open` 7.2.9-2. That is the running kernel's version; the kernel depends only on coreutils/kmod/initramfs, and the NVIDIA module needs exactly the installed `nvidia-utils` 615.78.08. The sync database also lists 7.2.7-1 builds, so name the 7.2.9-2 repository explicitly. Install only when no trial runs (download plus initramfs builds).
- GRUB:
  - Use a flat menu (`GRUB_DISABLE_SUBMENU=y`), `GRUB_DEFAULT=saved`, and the normal kernel as the saved default.
  - A helper, `profiler/bin/boot-kernel normal|rt`, sets the next boot with `grub-reboot` (one-shot), reboots, waits for SSH and the session, and checks `uname -v`.
  - One-shot boots mean a failed RT boot falls back to the normal kernel on the next power cycle. `grub-set-default` makes a choice persistent.
- Checks before any trial: R1 boot check on RT (PREEMPT_RT in `uname -v`, SSH, autologin, PipeWire + Focusrite, `/dev/ntsync`, the NVIDIA module, `trace-prereqs`, `dmesg`); R2 a Live smoke test (one Set, 60 s); R3 `cyclictest` on both kernels under load, for context (optional; needs rt-tests).
- Done 2026-10-18 (user decision: "present skipping it is. lets move to rt bore kernel testing"):
  - The user updated the OS first (`cachyos` update, 64 packages): the normal kernel moved from 7.2.9-2 to 7.2.11-1, and `linux-cachyos-nvidia-open` moved with it. `nvidia-utils` 615.78.08, Mesa 26.2.4, PipeWire 1.6.9, WirePlumber 0.5.18 and KWin 6.8.0 did not change.
    - The baseline therefore moved with the kernel. Trial numbers before and after are not directly comparable; both arms of T0015 run on the new stack.
    - The first install attempt failed: the regular mirrors no longer carried 7.2.9-2, and the main mirror's 7.2.9-2 file did not match the sync database's checksum. Nothing was installed.
  - Installed from cachyos-v3: `linux-cachyos-rt-bore`, `-headers` and `-nvidia-open` 7.2.11-1, matching the normal kernel and `nvidia-utils` 615.78.08.
    - Config: `PREEMPT_RT=y`, `SCHED_BORE=y`, `HZ=1000`, `NTSYNC=m`. The NVIDIA and NTSync modules are built for it.
  - GRUB: `GRUB_DEFAULT='saved'` and `GRUB_DISABLE_SUBMENU='y'` (the old file is kept as `/etc/default/grub.profiler-<timestamp>`). The flat menu is linux-cachyos, linux-cachyos-rt-bore, linux-cachyos-lts; the saved default is the normal kernel. Every entry carries `video=eDP-1:d`.
  - `profiler/bin/boot-kernel normal|rt|status` runs on the controlling host: it sets a one-shot `grub-reboot`, reboots, waits for a new boot ID and the desktop session, and prints a health line.
  - R1 (RT boot): back in 39 s. PREEMPT_RT, desktop session on the NVIDIA GPU, Focusrite node, `/dev/ntsync`; 82 IRQ threads (25 on the normal kernel); 2 kernel error lines (TDX not supported, harmless).
    - RT throttling is off (`sched_rt_runtime_us` = period = 1000000).
    - Every IRQ thread runs FIFO 50 (`irq/123-xhci_hcd` for the Focusrite's USB controller, `irq/150-nvidia`, NVMe), above pipeasio-rt (FIFO 15) and Live (RR 10).
  - R2 (Live smoke run on RT: official runtime, golden, OpenGL, kept configuration, Inbuilts, 60 s): exit 0, PipeWire errors 5, DSP 10.37 / 18.49.
    - CPU was higher than the last normal-kernel run (old 7.2.9 kernel, dev runtime): Live 59.5 vs 46.5 %, UI thread 13.1 vs 8.4, AudioCalc 33.5 vs 26.8. That is typical of PREEMPT_RT's overhead, but it is one run.
- Planned trials, ABAB × 3 on the heavy Sets with 120 s windows and the T0004 rule. Kernel arms reboot before every run, with the same boot settling as T0014:
  - **T0015, normal vs RT-BORE kernel:** everything else equal, including the switches and GPU mode T0012–T0014 keep.
    - Pre-registered 2026-10-18, before running:
      - A: `linux-cachyos` 7.2.11-1 (PREEMPT dynamic, full). B: `linux-cachyos-rt-bore` 7.2.11-1 (PREEMPT_RT and the BORE scheduler, which the package bundles).
      - Both arms: `PIPEASIO_REALTIME=1`, pipeasio-rt and every `AudioCalc` pinned to CPUs 0–11, nine workers, the normal window, snapshot `golden` (OpenGL, renderer off), the official runtime with `WINE_QPC_TSC` and `WINE_APC_FASTPATH` off. Also the NVIDIA-only external display at 59.94 Hz, wired Ethernet, and the same priorities (FIFO 50 IRQ threads on B are the kernel's default).
    - Every run starts from a fresh boot into its arm's kernel (one-shot `grub-reboot`), with T0014's boot settling: the per-boot timers are stopped for that boot, then a 120 s wait and a wait for the 1-minute load average to fall below 1.0 (at most 10 min in all).
    - Order A1 B1 A2 B2 A3 B3. The laptop switches kernels itself, with no user steps; about 70 minutes.
    - Inbuilts, Max4Live, VSTs; 120 s.
    - PASS rule: the T0004 rule ([D] or [E], plus both guards), with the T0002 A/A spreads as in every trial since T0004.
      - PASS: the RT-BORE kernel becomes the configuration, and T0016/T0017 run on it.
      - Otherwise the normal kernel stays.
    - Mechanism check: every run records its kernel (`uname -r`/`-v`). A run on the wrong kernel does not start; the driver stops and reports it.
    - Secondary readouts: CPU package power (RAPL) and temperature, P-core frequency, Live's per-thread CPU, wineserver.
    - Driver `~/.local/state/profiler/trial-T0015.sh` (one step per boot; it picks the next boot's kernel and reboots). A waiter on the controlling host starts each step after a boot. Scored by `plans/tools/trial-analyze.py T0015 --rule t0004`.
  - **T0015 — REVERT (2026-10-18, 16:53–17:56, all six runs clean, every one on its arm's kernel):** rule FAIL; the DSP guard passes, the error guard fails.
    - Dropouts: PipeWire ERR 5 → 7. B was fewer in 2 of 9 Set-pairs and more in 2 (p = 0.81). xruns 0 in both arms.
    - DSP average: higher on RT on every Set, within the guard: +1.06 / +0.71 / +0.98 (0.90 / 0.86 / 1.14 × the spread).
    - CPU: Live 46.9 → 60.8 % of one core (median); wineserver 1.23 → 1.83 %. CPU package 20.5 → 21.3 W, P-core median 2428 → 2361 MHz; package temperature peaks 88 → 75 °C.
    - Context, not part of the rule: Live's worst DSP peak per Set-run was lower on RT on every Set (medians 97.7 / 105.9 / 97.7 → 90.2 / 92.4 / 88.8 %). It passed 100 % in 4 of 9 Set-runs on the normal kernel against 0 of 9 on RT, but the dropout count did not follow.
    - Reading: PREEMPT_RT costs Live about 14 points of a core (rt_mutex locks, threaded IRQs) without reducing dropouts at the stock priorities. Every IRQ thread runs FIFO 50, above pipeasio-rt (FIFO 15) and Live (RR 10), which is what T0016 changes.
    - The normal kernel stays the configuration. The RT kernel stays installed for T0016.
  - **Configuration from 2026-10-18 (user decision: "make 3 permanent, then run 16 and 17"):**
    - Patch 0110 (`WINED3D_PRESENT_SKIP`) is in the series and in the official runtime.
    - Live runs on wined3d's Vulkan back end (`WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan`), with its GPU renderer on, showing every 6th frame (`WINED3D_PRESENT_SKIP=6`, 10 fps at 60 Hz).
      - golden is rebaselined from golden-gpu; the previous golden is kept as `golden.<UTC>`.
      - Desktop launches get the two variables from `~/.config/environment.d/90-profiler-ableton-display.conf`. `with-session-env` copies only display and D-Bus variables, so trials stay unaffected and set their switches explicitly.
    - Not trial-verified: adopted on the G0 and G0d feasibility data. Trials from T0016 on run with it in both arms.
    - Done 2026-10-18:
      - Patch 0110 committed (79ec25c). The workstation's official build took 4 minutes (source tree `273eb76e183d`), the audit passed (patch stack, fingerprints including 0110's, source digest), and the runtime is installed on the laptop.
      - Of `make test`, 22 of 23 scripts pass; `test-installer-lifecycle.sh` needs `xdg-mime`, which the WSL build host lacks, and fails at an unrelated point there even on the previous commit.
      - The probe on the official runtime (Vulkan back end) passes. Switch off: 240 frames in 3.93 s (16.4 ms per frame, one per refresh). `WINED3D_PRESENT_SKIP=6`: 0.59 s (2.5 ms per frame). Every present returned S_OK, and the waitable-object loop did not hang (0.60 s).
        - The first Wine start after a runtime install updates the prefix, and without the launcher's `WINEDLLOVERRIDES=mscoree,mshtml=` that update stops at Wine's Mono installer dialog. Probe runs must set it.
      - golden was rebaselined from golden-gpu (previous golden: `golden.20261018T223420Z`), and `~/.config/environment.d/90-profiler-ableton-display.conf` is written.
  - **T0016, the RT-BORE kernel with raised audio priorities vs the normal kernel.** As first registered, both arms ran the RT kernel with B adding the priorities. After T0015 the useful question is the normal kernel against RT with the priorities fixed, so it was redesigned before running (user: "run 16 and 17"):
    - A: `linux-cachyos` 7.2.11-1 with stock priorities (pipeasio-rt FIFO 15, Live RR 10; IRQs are not threaded).
    - B: `linux-cachyos-rt-bore` 7.2.11-1 with raised priorities: the Focusrite's USB controller IRQ thread (`irq/N-xhci_hcd`) at FIFO 90, pipeasio-rt at FIFO 85 and every AudioCalc at FIFO 80. The driver's watcher sets them for every Live process. Other Live threads keep RR 10; other IRQ threads keep FIFO 50.
    - Both arms: the configuration above, plus `PIPEASIO_REALTIME=1`, pinning, nine workers and the normal window. RT throttling is set to 950000/1000000 µs at every boot, a safety net for audio threads running above the IRQ threads: a runaway thread then leaves 5 % of each second to the rest.
    - Every run starts from a fresh boot, with T0014's settling. Order A1 B1 A2 B2 A3 B3, about 70 minutes; Inbuilts, Max4Live, VSTs, 120 s.
    - PASS rule: the T0004 rule.
      - PASS: the RT-BORE kernel with these priorities becomes the configuration, and T0017 runs on it.
      - Otherwise the normal kernel stays.
    - Mechanism check: for every Live process the driver records how many AudioCalc threads run FIFO 80, whether pipeasio-rt runs FIFO 85 and whether the xhci thread runs FIFO 90. A B run whose processes do not all show 9, 1 and FIFO 90 is reported.
    - Driver `~/.local/state/profiler/trial-T0016.sh`, with the T0015 waiter.
    - **T0016 — REVERT (2026-10-18, 18:34–19:37, all six runs clean, each on its arm's kernel):** rule FAIL ([D] no, [E] no); both guards pass.
      - Dropouts: PipeWire ERR 20 → 12 (40 % fewer on RT with the priorities; B fewer in 5 of 9 Set-pairs). One-sided p = 0.11, so [E]'s p < 0.05 is not met.
      - DSP average: higher on RT on every Set, within the guard (+0.74 / +1.06 / +0.92).
      - CPU: Live 44.9 → 58.4 % of one core; package 20.7 → 22.0 W.
      - Context: Live's worst DSP peak per Set-run was lower on RT again (medians 100.0 / 104.0 / 99.1 → 90.7 / 89.0 / 81.2 %).
      - Mechanism held in every B run: the USB controller IRQ thread at FIFO 90. The watcher raised AudioCalc to FIFO 80 54 times per run (Live builds its nine workers twice per launch) and pipeasio-rt to FIFO 85 three times per run, once per launch.
        - The driver's per-process record was fixed after B1 (deployed by rename, so the running step was untouched). It had counted the moment the nine workers appeared, before the watcher's next pass raised them. B1's priorities were confirmed directly with `ps` during the run.
        - pipeasio-rt starts with playback, after the record, so the record's pipeasio count stays 0 and the pin log is the evidence.
      - Concern: T0016's normal-kernel arm had 20 errors (1/6/4, 1/1/0, 1/5/1, spread over all three runs, mostly Max4Live and VSTs), against 5 in T0015's normal-kernel arm two hours earlier.
        - The arms differ in the display setup adopted in between (Vulkan back end, GPU renderer, present skipping; its feasibility runs covered Inbuilts only) and in the RT throttling safety net.
        - A controlled display trial is due: the old display setup vs the new one on the normal kernel, all three Sets.
      - The normal kernel stays; T0017 runs on it.
  - **T0017, a 32-frame buffer (pre-registered before running; it runs after T0016, on its winner):**
    - A: PipeASIO's 64-frame buffer (`~/.config/pipeasio/config.ini`). B: 32 frames, through `PIPEASIO_PREFERRED_BUFFERSIZE=32`, the launcher's per-launch override. That halves the buffer period from 1.33 to 0.67 ms.
    - Both arms: T0016's winning kernel and priorities, plus the configuration above. The runs go back to back on one boot (ABAB × 3), since the kernel does not change.
    - Rule: dropouts only. The DSP meter is load per buffer period, so it rises at a shorter period by construction and is reported, not ruled on. Keep 32 frames iff:
      - B has no xruns;
      - B's PipeWire errors are not significantly higher than A's (a one-sided binomial test of B's share of all errors, p ≥ 0.05);
      - the bench measured a 32-frame quantum in every B Set-run.
    - Otherwise 64 frames stays.
  - **T0017 — REVERT (2026-10-18, 19:43–20:29, normal kernel, back to back on one boot):** the 64-frame buffer stays.
    - Dropouts: PipeWire errors 19 → 677 (Inbuilts 5/2/2 → 87/48/63, Max4Live 6/0/2 → 107/104/68, VSTs 0/0/2 → 94/56/50); xruns 0 → 3. The rule needs p ≥ 0.05; it is about 0.
    - The bench measured a 32-frame quantum in 9 of 9 B Set-runs and 64 frames in 9 of 9 A Set-runs.
    - Reported, not ruled on: DSP average 9.84 / 9.67 / 9.24 → 13.79 / 14.45 / 14.41; worst DSP peak medians 104 / 96 / 99 → 195 / 196 / 110 %; Live CPU 46.2 → 68.4 % of one core.
    - The 64-frame arm (new display setup, 95 % RT throttling) had 19 errors, close to T0016's normal-kernel arm (20) and against T0015's 5. T0018 tests that.
  - **T0018, the display setup** (user decision 2026-10-18: "That sounds good queue it up"; pre-registered before running; queued after T0017). It follows from T0016's normal-kernel arm, which had 20 errors against 5 in T0015's after the display setup changed.
    - A: the old display setup. wined3d on OpenGL (the launcher's default `WINE_D3D_CONFIG=csmt=0x1`), Live's GPU renderer off (the previous golden, `golden.20261018T223420Z`), every frame shown (`WINED3D_PRESENT_SKIP` unset).
    - B: the new display setup. wined3d's Vulkan back end, the GPU renderer on (golden), `WINED3D_PRESENT_SKIP=6`.
    - Both arms:
      - the normal kernel 7.2.11-1 with stock priorities, and the official runtime with 0110 (the switch acts only in B);
      - `PIPEASIO_REALTIME=1`, pinning, nine workers, the normal window, 64 frames;
      - the NVIDIA-only external display and wired Ethernet;
      - RT throttling off (`sched_rt_runtime_us` = period, as in T0015; T0016 and T0017 had the 95 % safety net, the other difference to T0016's arm).
    - ABAB × 3, back to back on T0017's boot (its per-boot timers are already stopped); Inbuilts, Max4Live, VSTs; 120 s.
    - Rule (non-inferiority: the new setup was adopted to save display CPU, so the question is whether it costs dropouts). Keep the new setup iff:
      - B has no xruns;
      - its PipeWire errors are not significantly higher than A's (a one-sided binomial test of B's share, p ≥ 0.05);
      - no Set's median DSP average is worse in B by more than 2× its A/A spread.
    - Otherwise revert to the old display setup: golden back to the old snapshot, and the environment.d file removed. Patch 0110 stays in the runtime as an opt-in switch.
    - Mechanism check: each Set-run's Live log shows the GPU renderer off in A and on in B, and Wine logs the Vulkan renderer and the skip only in B.
    - Secondary readouts: compositor CPU (kwin_wayland + Xwayland) per run, Live's per-thread CPU (UI thread, `wined3d_cs`), DSP peaks.
    - Driver `~/.local/state/profiler/trial-T0018.sh`, started by `queue-T0018.sh` when T0017 ends.
    - **T0018 — REVERT (2026-10-18, 20:29–21:15, normal kernel, all six runs clean):** back to the old display setup.
      - Dropouts: PipeWire errors 1 → 22. Old setup: 1/0/0, 0/0/0, 0/0/0. New setup: Inbuilts 1/5/5, Max4Live 0/7/2, VSTs 0/0/2. One-sided p ≈ 0.000, so non-inferiority fails.
      - xruns 0 → 0, and the DSP guard passes (DSP average 10.25 / 9.52 / 9.12 → 9.90 / 10.04 / 9.49).
      - The mechanism held in every run: Live's GPU renderer off in A (`Off (Platform default)`) and on in B (`OnAlways (User setting)`); Wine logged the Vulkan renderer and the skip only in B.
      - The new setup does save display CPU (medians, % of one core): Live's UI thread 9.9 → 9.3, `wined3d_cs` 2.4 → 1.3, compositor 4.8 → 1.6, about 5 points in all. But it costs dropouts.
      - RT throttling was off in both arms, so the display setup alone explains the higher errors of T0016's and T0017's normal-kernel arms (20 and 19). The new setup bundles three changes (Vulkan back end, GPU renderer, present skipping), and this trial does not separate them.
      - Done:
        - golden is restored from the old snapshot and rebaselined. The GPU-renderer golden is kept as `golden.20261019T011657Z`.
        - `~/.config/environment.d/90-profiler-ableton-display.conf` is removed, and the user manager's environment is reloaded clean.
        - Patch 0110 stays in the runtime as an opt-in switch (`WINED3D_PRESENT_SKIP`, default off).
      - The configuration is again OpenGL with the renderer off and every frame shown. `KWIN_DRM_DEVICES` (NVIDIA-only external display) is unchanged.
- GPU mode: whatever T0014 keeps.
  - The earlier "T0017, Live on the NVIDIA GPU" was dropped ("As we will not use GPU rendering lets stay on the intel driver"). The user then moved the discrete-mode test ahead of this phase, as T0014.
  - The laptop (MSI Katana 15 B13VFK) has a MUX: the NVIDIA card has its own built-in-screen output (`eDP-2`), switchable only in the firmware.
  - The NVIDIA driver stays installed on both kernels, so the kernel A/B loads the same drivers. If T0014 keeps discrete mode, the RT kernel's `nvidia-open` module drives the screen, and R1 must pass before any RT trial.
  - Open option (hybrid): the idle dGPU stays awake in P0 because the compositor holds its DRM device. Letting it power down (runtime D3) could cut heat in the cooling the CPU shares.

**Diagnostic D0002: what wakes wineserver ~3,000 times per second (user decision 2026-10-18: "Lets do item 3"; open since T0012)**
- Question: wineserver sleeps and wakes about 3,060 times per second during playback (T0012, both arms). D0001 counted only ~370 server requests per second from Live's own process, so either other Wine processes (Max, explorer, services, plugin hosts) talk to it, or something besides requests wakes it, such as timers.
- Setup: kept configuration, normal kernel, golden (OpenGL, renderer off). Inbuilts and Max4Live (Max4Live had the most errors in T0016–T0018 and runs the separate Max process); one 60 s window each.
  - Part 1, official runtime: for 30 s inside the window, `bpftrace` counts wineserver's syscalls by number, how its `epoll_wait`/`epoll_pwait2` calls return (timeout vs client events, plus ready fds), and its voluntary sleeps.
  - Part 2, the dev runtime with `bin/wineserver` wrapped to run with `-d1`, wineserver's own request log: the requests of a 30 s slice of the window by type and by client thread. A `/proc` snapshot taken during the window names the threads. The wrapper is removed on exit.
- Script `~/.local/state/profiler/d0002.sh`; summary `d0002_analyze.py`.
- **Result (2026-10-18 22:51–22:58; the same on both Sets):**
  - Part 1: wineserver sleeps and wakes about 2,300 times per second. Its epoll waits return with client events about 2,290 times per second and time out only 10 times per second. The syscalls per second are the request cycle: `epoll_pwait2` 2,294, `read` 2,293, `ioctl` 2,239, `write` 2,106. So every wakeup is a client request; timers do not matter.
  - Part 2: about 2,260 requests per second, about 1,735 of them from Live's UI thread (its main thread).
    - By type: `get_message` ~515, `get_hook_info` ~314, `start_hook_chain` ~254, `finish_hook_chain` ~254, `send_message` ~246, `set_queue_mask` ~190, `reply_message` ~120, `get_update_region` ~120.
    - The hooks were all installed by Live's UI thread on itself:
      - `WH_GETMESSAGE` with its procedure in **wined3d.dll** (offset `0xe1520`, mapped in a running session), called ~194 times per second;
      - `WH_CALLWNDPROC` from **MaxPlug.dll** (Max for Live's integration, installed twice), ~60 per second;
      - a WinEvent hook for focus events, which does not fire during playback.
    - The posted messages come from Live itself: three unnamed Live threads post message `0x47B` to the UI thread's window about 60 times per second each, and `DWM-Sync` posts `0x401` 60 times per second.
  - Reading:
    - Each of those ~246 messages per second costs about five wineserver round trips: the post, the `get_message`, and about three for wined3d's hook chain (`start_hook_chain`, `get_hook_info` for `CallNextHookEx`, `finish_hook_chain`).
    - wined3d installs that `WH_GETMESSAGE` hook on every thread that owns a swap-chain window, only to catch Alt+Enter for DXGI's exclusive-fullscreen toggle (`dlls/wined3d/wined3d_main.c`, `wined3d_hook_proc`, installed at line 922). Live never uses that toggle.
    - Not installing the hook would remove about 600–750 wineserver requests per second, about a third of its wakeups, and three round trips from every message Live's UI loop handles.
    - The MaxPlug hook and the posted messages are Live's and Max's own design.

**T0019, wined3d's Alt+Enter hook (patch 0111; user decision 2026-10-18: "Lets try the wineserver wake reduction"; pre-registered before running)**
- Change: patch 0111 (49c5030). With `WINED3D_NO_ALT_ENTER_HOOK=1`, wined3d installs no `WH_GETMESSAGE` hook on the threads that own swap-chain windows. Alt+Enter then no longer toggles DXGI's exclusive fullscreen, which Live does not use (its full-screen mode is a window mode). Unset, nothing changes.
- Probe (`tools/msghookprobe.c`, dev runtime): PASS with and without the switch. The hook adds 8.6 µs to every message after the swap chain is created (11.09 → 19.67 µs); with the switch nothing is added (12.67 → 9.37 µs). The probe is repeated on the official runtime before the trial.
- Expected size:
  - It should remove about 580 wineserver requests per second (wined3d's ~194 hook calls per second × 3 round trips), about a quarter of wineserver's ~2,300 wakeups.
  - The CPU saving is small: under half a point of one core across Live's UI thread and wineserver. An audio gain beyond the noise floor is not expected.
  - The trial checks that the reduction is real and harmless, and whether it moves dropouts.
- A: the kept configuration, with `WINED3D_NO_ALT_ENTER_HOOK` unset. B: the same with `WINED3D_NO_ALT_ENTER_HOOK=1`.
- Both arms:
  - the official runtime with 0111, built on the workstation from 49c5030;
  - the normal kernel 7.2.11-1 with stock priorities;
  - `PIPEASIO_REALTIME=1`, pinning, nine workers, the normal window, 64 frames;
  - golden (OpenGL, renderer off, every frame shown), RT throttling off, the NVIDIA-only external display and wired Ethernet;
  - one harness: the laptop's checkout fast-forwarded before A1, so the bench records the switch.
- ABAB × 3, back to back on T0017's boot (its per-boot timers are stopped). Inbuilts, Max4Live, VSTs; 120 s; untraced.
- Rule: the T0004 rule ([D] or [E], plus both guards), with the T0002 A/A spreads.
- Mechanism check, untraced runs: wineserver's voluntary context switches per second over each Set-run's window, from the bench's `proc-delta.json`. It holds iff, on every Set, B's median is at least 400 per second below A's (about 70 % of the expected 580), and Wine logs `Not installing the Alt+Enter message hook` in B only.
- Traced confirmation, after the ABAB runs (the patch kind needs one traced run per arm): D0002's part 2 on the dev runtime (the same 0108–0111 series, unstripped).
  - wineserver's request log (`-d1`) covers 30 s inside a 60 s window, on Inbuilts and Max4Live, A then B.
  - It confirms iff in B, Live's UI thread makes no `start_hook_chain( id=3` (WH_GETMESSAGE) requests (A: about 190 per second), and wineserver's total requests per second are at least 400 lower than in A on both Sets.
- Verdict:
  - keep: the rule passes, both mechanism checks hold, and the probe passes on the official runtime. The configuration then adds `WINED3D_NO_ALT_ENTER_HOOK=1`: trials from T0020 set it in both arms, and desktop launches get it from an environment.d file.
  - mechanism-confirmed: both guards and both mechanism checks hold, but neither [D] nor [E] is met. The switch stays opt-in and the configuration does not change.
  - revert: a guard fails, or a mechanism check does not hold. The switch stays opt-in (default off).
- Secondary readouts: wineserver CPU (% of one core) and voluntary switches per second, per Set; Live's UI-thread CPU; Live CPU; DSP peaks; xruns.
- Driver `~/.local/state/profiler/trial-T0019.sh`. Scored by `plans/tools/trial-analyze.py T0019 --rule t0004` plus a mechanism summary, `t0019_mechanism.py`.
- Before the trial (2026-10-18): the official build of 49c5030 took 4m45s on the workstation, the audit passed (192 checks, including 0111's fingerprint), and the runtime is installed on the laptop. The probe on the official runtime passes both ways: the hook adds 11.0 µs to every message after the swap chain (10.89 → 21.87 µs), and with the switch nothing is added (10.00 → 7.93 µs).
- **T0019 — MECHANISM-CONFIRMED (2026-10-18/19, 23:35–00:28, normal kernel; all six runs and the four traced runs clean):** the switch does what it should, but it brings no audio gain under the rule.
  - Rule FAIL: [D] no, [E] no; both guards pass.
    - Dropouts: PipeWire errors 14 → 10 (Inbuilts 0/0/5 → 1/0/1, Max4Live 5/1/0 → 2/0/1, VSTs 1/1/1 → 0/4/1). B was fewer in 4 of 9 Set-pairs; one-sided p = 0.27. xruns 0 → 0.
    - DSP average 9.52 / 9.65 / 9.20 → 9.57 / 9.90 / 9.19, at most 0.31 × the spread.
  - Both mechanism checks held, as predicted:
    - wineserver wakeups (voluntary switches per second, Set medians) fell by about 570, a quarter, against the predicted 580: Inbuilts 2,271 → 1,702, Max4Live 2,284 → 1,698, VSTs 2,272 → 1,706. Every run is within 6 of its arm's median.
    - wined3d's winediag line appears in every B run and in no A run.
    - Traced (dev runtime, `-d1`, 30 s): wineserver requests fell from 2,262 to 1,673 per second on Inbuilts and from 2,258 to 1,676 on Max4Live. Live's UI thread fell from 1,736 to 1,148 per second, and its WH_GETMESSAGE hook chains from 193 to 0. The 60 hook chains per second that remain are MaxPlug's WH_CALLWNDPROC.
  - CPU (% of one core, Set medians): wineserver 1.23 / 1.22 / 1.24 → 1.11 / 1.11 / 1.07; Live's UI thread 9.8 / 10.1 / 7.7 → 9.3 / 9.3 / 7.5; Live 45.9 vs 46.3 overall.
  - Reading: the hook made up a quarter of wineserver's requests, but wineserver's whole load is about one point of a core and off the audio path. Removing it does not move dropouts or DSP load, which fits D0001: the dropouts come from work spikes in Live's own audio callback.
  - Context, not part of the rule: this A arm had 14 errors, against 1 in T0018's A arm (the old display setup) and 5 in T0015's normal-kernel arm. Dropout counts drift between sessions by more than most trial effects, and only the interleaved ABAB design absorbs that drift.
  - Kept as is: patch 0111 stays in the series and the runtime as an opt-in switch, default off. The configuration does not change.

**Diagnostic D0003: what happens in late audio blocks (user decision 2026-10-19: "Lets dig into late blocks")**
- Question: D0001 saw a few late blocks per Set in which an audio worker runs about 1.1 ms while the callback waits, with 10–50 `FlushInstructionCache` calls. Where does that time go, and does Wine add to it?
- Method:
  - D0001's traced blocks re-read: every late and near-late block, placed on the song.
  - A capture run as the bench's tracer (`~/.local/state/profiler/d0003-capture`, started right after play).
    - bpftrace on PipeASIO's block markers: every block over 700 µs.
    - Every user page fault in Live (address, faulting IP, error code), and `handle_mm_fault` timed.
    - `/proc/PID/smaps` at start and stop.
    - Optionally perf: CPU samples with cycles, instructions and reference cycles; scheduler switches and wakeups of the audio threads; IRQs.
  - Smoke runs on the kept configuration; analysis `d0003_analyze.py`, `d0003_faults.py`.
- Findings:
  - The three heavy Sets are the same song (112 BPM, loop beats 16–112, clips starting on the same beats), so their late blocks coincide.
    - In every run they fall at beats 16.4, 17.4, 46.4 and 49.4, about 0.4 beats after bars where clips start, and only in the loop's first pass.
    - D0001 shows the same beats once its trace start is placed correctly (1.2 s after play).
  - In each late block, one audio thread (a worker or the callback) runs 1.3–2.4 ms at about 4.7 GHz.
    - The time is page faults: 1,140–1,560 per block. All have error code 7, a write to a present but write-protected page, one per 4 KiB page, in Live's ordinary heap regions (16–80 MB anonymous mappings, almost fully resident before the storm).
    - The faulting code is Live's first-use copies (`vcruntime140.dll` memcpy, `Live.exe+0x4a68210` and others).
    - About 60 % of Live's page faults in a window fall inside these four blocks.
    - perf's per-process page-fault tracepoint missed most of them; bpftrace counts are the reliable ones.
  - Ruled out: swap (zram unused), THP compaction (0 stalls), KSM (off), and Wine's userfaultfd write-watch (no `uw` regions, no write-watch calls).
  - Cause: Wine's `spawn_process()` (`dlls/ntdll/unix/process.c`) starts every new process with `fork()`.
    - Live starts four helper processes while the Set loads, 7.3–6.5 s before play.
    - Each `fork()` write-protects all of Live's private writable memory for copy-on-write. Once the short-lived intermediate child is gone, the pages are Live's alone again, but the first write to each one still takes a fault.
    - Huge pages do not help: Wine's 64 KiB-granular heap pieces are not backed by them.
    - Windows has no fork, so this cost exists only under Wine.
  - Probe `spawncowprobe.c` (1 MiB chunks, so not huge-page-backed): after `CreateProcess`, writing 32,768 populated pages takes 17.6 ms (0.53 µs per page, one fault per page) against 0.6 ms warm.
- Candidate fix (dev tree e3fcf96): `WINE_POSIX_SPAWN=1` starts processes with `posix_spawn()`, which shares the address space until exec (CLONE_VM | CLONE_VFORK), so nothing is copied or write-protected.
  - The probe passes: 0.6 ms after the child, and the child even starts faster (5–9 ms against 12 ms).
  - Dev-runtime A/B, kept configuration, heavy Sets, one 60 s window each (the whole first pass), block and fault capture:

    | Set | fork: late / longest / Live faults | posix_spawn: late / longest / Live faults |
    |---|---|---|
    | Inbuilts | 5 / 1856 µs / 12,632 | 0 / 890 µs / 325 |
    | Max4Live | 4 / 1863 µs / 13,583 | 0 / 897 µs / 295 |
    | VSTs | 3 / 1897 µs / 11,879 | 0 / 895 µs / 295 |

  - Live, Max for Live and the helpers ran normally. The remaining slow blocks (about 0.9 ms) are Live's own first-use work, within the 1.33 ms period.
- Side observations: while workers go to sleep, the kernel's RT balancing (`balance_rt` → `double_rq_lock`) spins on runqueue locks. The audio threads switch about 53,000 times per second (the AudioCalc fan-out).
- Next: patch 0112 and a pre-registered trial (T0020).

**T0020, starting processes with posix_spawn (patch 0112; follows from D0003; pre-registered before running)**
- Change: patch 0112 (9378f44). With `WINE_POSIX_SPAWN=1`, `spawn_process()` starts new processes with `posix_spawn()` instead of `fork()`, so starting Live's helpers no longer write-protects Live's memory. Unset, nothing changes.
- A: the kept configuration, with `WINE_POSIX_SPAWN` unset. B: the same with `WINE_POSIX_SPAWN=1`.
- Both arms:
  - the official runtime with 0112, built on the workstation from 9378f44;
  - the normal kernel 7.2.11-1 with stock priorities;
  - `PIPEASIO_REALTIME=1`, pinning, nine workers, the normal window, 64 frames;
  - golden (OpenGL, renderer off), RT throttling off, the NVIDIA-only display and wired Ethernet;
  - one harness, with the laptop's checkout fast-forwarded first so the bench records the switch.
- ABAB × 3, back to back on the current boot (its per-boot timers are stopped). Inbuilts, Max4Live, VSTs; 120 s; untraced.
- Expected: the first-pass late blocks (beats 16.4, 17.4, 46.4, 49.4) disappear, so PipeWire errors should fall sharply. T0019's A arm, the same configuration, had 14 errors in 9 Set-runs.
  - Risk: error counts drift between sessions (T0018's A arm had 1). A quiet A arm can leave [E] short of significance even if B has none.
- Rule: the T0004 rule ([D] or [E], plus both guards), with the T0002 A/A spreads.
- Mechanism checks:
  - Untraced runs: Wine logs `Starting new processes with posix_spawn` in every B run and in no A run.
  - Traced, after the ABAB runs: one run per arm on the three heavy Sets, 60 s windows (the loop's whole first pass), with `d0003-capture-light` as the bench's tracer (block markers and page faults).
    - It holds iff A shows a fault storm on every Set: at least one block over 700 µs with 500 or more page faults.
    - And B shows none: no block over 700 µs with 500 or more faults, and Live's page faults per window at most 10 % of A's on every Set.
- Verdict:
  - keep: the rule passes, both mechanism checks hold, and the probe passes on the official runtime. The configuration then adds `WINE_POSIX_SPAWN=1`: trials from T0021 set it in both arms, and desktop launches get it from an environment.d file.
  - mechanism-confirmed: both guards and both mechanism checks hold, but neither [D] nor [E] is met. The switch stays opt-in and the configuration does not change.
  - revert: a guard fails, or a mechanism check does not hold.
- Context readouts: worst DSP peak medians, Live CPU, wineserver CPU, xruns.
- Driver `~/.local/state/profiler/trial-T0020.sh`. Scored by `plans/tools/trial-analyze.py T0020 --rule t0004` plus `t0020_mechanism.py`.
- Before the trial (2026-10-19): the official build of 9378f44 took 4m19s, the audit passed (193 checks, including 0112's fingerprint), and the runtime is installed on the laptop. The probe on the official runtime fails without the switch (17.4 ms, 0.53 µs per page after the child) and passes twice with it (0.6 ms): 4 PASS, 0 FAIL.
- **T0020 — KEEP (2026-10-19, 02:24–03:19, normal kernel; all six runs and both traced runs clean):** the first trial whose verdict comes from a Wine patch.
  - Rule PASS on [E]; both guards pass.
    - Dropouts: PipeWire errors 11 → 1, 91 % fewer (A: Inbuilts 2/0/0, Max4Live 0/0/1, VSTs 0/0/8; B: VSTs 1/0/0, otherwise 0). One-sided p = 0.0032. xruns 0 → 0.
    - DSP average 9.68 / 9.89 / 9.43 → 9.94 / 9.69 / 9.37, at most 0.24 × the spread.
  - Both mechanism checks held:
    - Wine logged the posix_spawn line in every B run and in no A run.
    - Traced (60 s windows):

      | Set | A: late / longest / storm blocks / Live faults | B: late / longest / storm blocks / Live faults |
      |---|---|---|
      | Inbuilts | 3 / 1948 µs / 5 / 12,744 | 0 / 906 µs / 0 / 309 |
      | Max4Live | 5 / 1951 µs / 5 / 19,695 | 0 / 963 µs / 0 / 409 |
      | VSTs | 4 / 1889 µs / 5 / 11,571 | 0 / 951 µs / 0 / 289 |

      The biggest fault count in any B block was 46; in A blocks it was up to 1,582.
  - Context, not part of the rule:
    - Worst DSP peak medians 99.8 / 86.6 / 99.1 → 66.5 / 63.0 / 62.7 %, and no B Set-run peaked over 75 %.
    - Live CPU 47.1 vs 46.9 % of one core.
    - PipeWire's error counter at the window start (errors since Live opened, Set load included) was 29–33 in A runs against 9 in B1, so the forks also glitched the load.
  - Kept:
    - From T0021, trials set `WINE_POSIX_SPAWN=1` in both arms.
    - Desktop launches get it from `~/.config/environment.d/91-profiler-wine-posix-spawn.conf`; it takes effect at the next login.
    - Patch 0112 stays opt-in in the series, as every fix does.
  - Upstream candidate (the user's call): the change is generic Wine, not Ableton-specific. Any Wine process that starts other processes pays this copy-on-write cost afterwards.

**Headroom campaign T0021–T0025 (user decision 2026-10-19: "We want ableton specific improvement… What else can we try", then "Lets test all of this"; pre-registered before running)**
- Why now:
  - With `WINE_POSIX_SPAWN=1`, dropouts are rare (T0020's B arm: 1 error in 9 Set-runs), so the next gains are headroom: less CPU and a lower DSP load.
  - D0003's perf data splits Live's audio-thread cycles into: Live's own code 60 %; the kernel side of the AudioCalc fan-out (ntsync waits and wakes, about 245 per block) 23 %; the kernel's RT balancing (`balance_rt`, `pull_rt_task`, `double_rq_lock` spinning while workers sleep and wake about 53,000 times a second) 11 %; other kernel work 6 %.
- Facts used below:
  - CPUs 0–11 are the P-cores, in sibling pairs (0,1) (2,3) (4,5) (6,7) (8,9) (10,11); CPUs 12–15 are the E-cores.
  - The Focusrite's USB controller (xhci, IRQ 123, PCI 0000:00:14.0) currently fires on CPU 4. irqbalance is not installed.
  - Live runs in the trial driver's session scope; PipeWire runs in the desktop session's `pipewire.service`.
  - Audio-thread CPU per Set-run varies by about ±2 points around 30–37 % of one core (T0019, T0020).
- Every trial in the campaign:
  - The kept configuration at its start, including `WINE_POSIX_SPAWN=1` and every earlier verdict of the campaign.
  - Normal kernel, the current boot (per-boot timers stopped).
  - ABAB × 3 back to back; Inbuilts, Max4Live, VSTs; 120 s; untraced.
- **Headroom rule (H)**, for T0021, T0022 and T0024:
  - M is the audio-thread CPU of a Set-run: the summed CPU of Live's `AudioCalc*` and `pipeasio-rt` threads over the window, in % of one core, from the bench's `proc-delta.json`.
  - PASS iff:
    - [H1] B's M is below its paired A's in at least 8 of the 9 Set-pairs (one-sided sign test, p = 0.02);
    - [H2] the median of the 9 paired changes in M is −3 % or larger in size;
    - and the guards hold:
      - [G1] B has no xruns;
      - [G2] B's PipeWire errors are not significantly higher than A's (one-sided binomial test of B's share of all errors, p ≥ 0.05);
      - [G3] no Set's median DSP average is worse in B by more than 2× its A/A spread (T0002).
  - The guards replace T0004's "B errors ≤ A", which counts of 0 or 1 errors would decide by noise.
  - Verdicts:
    - keep: PASS and the mechanism holds;
    - mechanism-confirmed: guards and mechanism hold, but [H1] or [H2] fails;
    - revert: a guard fails, or the mechanism does not hold.
  - Reported, not ruled on: DSP average and peak medians, Live CPU, worker run-queue waits.
- **T0021, one CPU per audio thread (item 1).**
  - A: the kept pinning: pipeasio-rt and every AudioCalc thread on CPUs 0–11 (shared mask).
  - B: 1:1 pinning. pipeasio-rt on CPU 0 (its sibling, CPU 1, stays free). Each AudioCalc thread gets its own CPU from 2–10, in thread-id order, released when the thread exits; until a CPU is free, a new worker keeps the shared mask.
  - Expected: a thread allowed on one CPU cannot be pushed or pulled, so most of the 11 % RT-balancing time should go.
  - Rule H. Mechanism:
    - (a) In every B Set-run, `proc-delta.json` shows each AudioCalc thread and pipeasio-rt on a single CPU, with no two sharing one; in A, all show 0–11.
    - (b) Traced, after the ABAB: one 60 s Inbuilts run per arm with `d0003-capture` (perf). The RT-balancing share of audio-thread cycles in B is under a third of A's.
  - Keep: B's pinning becomes the trial watcher's default.
  - **T0021 — MECHANISM-CONFIRMED (2026-10-19, 08:19–09:08; all six runs and both traced runs clean; restarted once at 08:19 after an analysis had run on the laptop during the first A1):** the balancing goes, the CPU does not.
    - Rule H FAIL: B's audio-thread CPU was lower in 5 of 9 Set-pairs (median −0.4 %). Max4Live rose in all three pairs (+13 %, +2 %, +6 %); VSTs fell in all three (−6 %, −2 %, −4 %).
    - Guards pass: xruns 0 → 0, PipeWire errors 0 → 1 (p = 0.5), DSP average 9.63 / 9.53 / 9.51 → 9.30 / 9.98 / 9.06.
    - Mechanism held:
      - The pinning applied in every Set-run.
      - Traced, the RT-balancing share of audio-thread cycles fell from 8.6 % to 1.9 %, and the traced B run used 9 % fewer audio cycles.
    - Reading: the shared mask had already removed most of the 11 % measured unpinned in D0003, and forcing workers onto sibling hyperthreads seems to cost what is left. Live CPU 44.8 vs 46.6 %, worst DSP peaks 62–71 % in both arms, 0 errors in 17 of 18 Set-runs.
    - The shared pinning stays.
- **T0022, one audio thread per physical P-core (item 2; re-registered 2026-10-19 before any B run).**
  - Why re-registered: the user pointed out that Ableton deliberately puts one audio thread on each hyperthreaded core ("Ableton intentionally allocated threads to only one core on a hyperthreaded core. Can we do that?").
    - The first registration put six workers on CPUs 0, 2, 4, 6, 8, 10 and pipeasio-rt on CPU 1, the sibling of a worker, so one core carried two audio threads.
    - It was stopped during A1, before any B run; A1 is set aside.
  - What Live does under Wine:
    - Its log computes `High-Performance Cores Processor Mask(s): 0000111111111111` (CPUs 0–11).
    - It imports `GetLogicalProcessorInformationEx`, `SetThreadAffinityMask` and `AvSetMmThreadCharacteristicsW`.
    - In runs without our watcher, all its audio threads run on CPUs 0–15, so its placement does not take effect here.
  - A: the kept configuration after T0021: nine workers, all audio threads on CPUs 0–11 (shared mask).
  - B: `ABLETON_MAX_AUDIO_THREADS=5`, so six audio threads for the six physical P-cores:
    - pipeasio-rt alone on core 0 (CPU 0);
    - the five AudioCalc threads alone on cores 1–5 (CPUs 2, 4, 6, 8, 10);
    - every sibling hyperthread (CPUs 1, 3, 5, 7, 9, 11) left free of audio threads.
  - Context: T0006 cut Live CPU 64 → 40 % with six workers but was judged amid the fork-storm noise. T0021's 1:1 layout forced workers onto sibling hyperthreads and saved nothing.
  - Rule H; [G3] guards against the per-block wall time growing with fewer workers.
  - Mechanism: every B Set-run shows five AudioCalc threads on CPUs 2, 4, 6, 8, 10 and pipeasio-rt on CPU 0; A shows nine on 0–11.
  - Keep: that layout (`physcore`) becomes the configuration.
  - **T0022 — KEEP (2026-10-19, 09:14–10:00; all six runs clean):** one audio thread per physical core cuts the audio threads' CPU by a quarter.
    - Rule H PASS: B's audio-thread CPU was lower in 9 of 9 Set-pairs (sign test p = 0.002), median paired change −26.0 %. Set medians (% of one core): Inbuilts 34.5 → 23.9, Max4Live 34.7 → 27.4, VSTs 32.0 → 21.0.
    - Guards pass: xruns 0 → 0, PipeWire errors 10 → 11 (p = 0.5), DSP average 9.74 / 9.51 / 9.36 → 8.96 / 9.40 / 8.56.
    - Mechanism held: in every B Set-run pipeasio-rt was on CPU 0 and the five workers on CPUs 2, 4, 6, 8, 10, one each; in every A Set-run all ten audio threads were on 0–11. The workers' run-queue wait fell from 43 / 47 / 42 to 16 / 11 / 18 ms per window.
    - Also: Live CPU 46.9 → 35.0 %. Worst DSP peak medians 67.7 / 62.1 / 68.4 → 64.7 / 81.6 / 66.5 %, so Max4Live's peak rose, with no xruns.
    - **Kept:** `physcore` with 5 workers (`ABLETON_MAX_AUDIO_THREADS=5`, pipeasio-rt on CPU 0, workers on CPUs 2, 4, 6, 8, 10) is the configuration. T0023 and T0024 run on it (`KEPT_LAYOUT=physcore KEPT_WORKERS=5`).
    - The kernel-level work that follows is planned in `profiler/plans/kernel-plan.md`.
- **T0023, the display setup again (item 4; runs after T0022).**
  - A: the current display: OpenGL, renderer off (golden), every frame shown.
  - B: wined3d's Vulkan back end (`WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan`), Live's GPU renderer on (`golden.20261019T011657Z`), and `WINED3D_PRESENT_SKIP=6`.
  - Context: T0018 reverted it on dropouts (1 → 22) while it saved about 5 points of display CPU. The fork storms may have amplified those dropouts.
  - Rule: T0018's non-inferiority rule. Keep iff B has no xruns, its PipeWire errors are not significantly higher (one-sided binomial, p ≥ 0.05), and no Set's median DSP average is worse by more than 2× its spread.
  - Mechanism as in T0018: Live's GPU-renderer line per Set-run, and the Vulkan and skip lines in B only.
  - Reported: display CPU (UI thread, `wined3d_cs`, kwin + Xwayland).
  - Keep: golden becomes the GPU-renderer snapshot, and desktop launches get the two variables from environment.d.
  - **T0023 — KEEP (2026-10-19, 10:40–11:26; all six runs clean; on `physcore` with 5 workers):** with the fork storms gone, T0018's dropouts do not come back.
    - Non-inferiority PASS: xruns 0 → 0, PipeWire errors 3 → 2 (p = 0.81), DSP average 9.05 / 9.16 / 8.61 → 9.01 / 9.32 / 8.43 (every Set within 0.2× its A/A spread).
    - Mechanism held: Live's GPU renderer was `Off (Platform default)` in every A run and `OnAlways (User setting)` in every B run; B logged the Vulkan line (6 per run) and the present-skip line (2 per run), A neither.
    - Display CPU in B (% of one core): kwin 2.8 → 1.0, Xwayland 1.6 → 0.4, Live's UI thread −0.2 and `wined3d_cs` −0.8 per Set. Live CPU 37.0 → 35.9 %. Audio-thread CPU unchanged (+0.3 %); worst DSP peak medians 65.7 / 64.0 / 67.0 → 65.2 / 62.5 / 61.1 %.
    - **Kept:** the GPU-renderer snapshot becomes golden (the previous golden is kept under a timestamped name), and desktop launches get `WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan` and `WINED3D_PRESENT_SKIP=6` from `~/.config/environment.d/92-profiler-display.conf`. T0024 runs with `KEPT_DISPLAY=new`.
  - Also reported for T0022 (not its criterion): scored with rule D, `physcore` lowered the DSP average in 8 of 9 Set-pairs (median −5.3 %).
- **T0024, audio cores kept clear (item 5; runs after T0023).**
  - A: as is.
  - B, applied before and undone after each B run:
    - every IRQ whose affinity can change moves to CPUs 12–15, except the xhci controller's, which goes to CPU 11 if T0021 kept 1:1 pinning (CPU 11 is then outside the audio layout) and to CPU 12 otherwise;
    - `system.slice`, `init.scope`, and in the user manager `app.slice`, `background.slice` and every `session.slice` unit except `pipewire.service` (kwin, Xwayland, plasmashell, WirePlumber…) get `AllowedCPUs=12-15`;
    - the unbound-workqueue cpumask goes to CPUs 12–15;
    - Live (the driver's session scope) and PipeWire stay unrestricted.
  - Rule H. Mechanism:
    - (a) each B run records kwin's and a system service's CPU mask (12–15) and the xhci IRQ's effective CPU;
    - (b) traced, one 60 s Inbuilts run per arm with `d0003-capture`: IRQ time and preemptions on the audio threads are lower in B by at least half.
- **Ideas backlog** (user, 2026-10-19: "lets remember these ideas and keep discussing"; not yet registered):
  - Evidence:
    - P-cores idle through ACPI C1 / C2 / C3 with exit latencies of 1 / 127 / 1048 µs; block wake latency p50 31–44 µs, max ~320 µs (D0001).
    - The RFDS mitigation clears registers (VERW) on every return to user space.
    - 76 Live threads run RR 10, the UI thread included.
    - Live imports `AvSetMmThreadCharacteristicsW` (MMCSS "Pro Audio", stubbed in Wine), `SetThreadAffinityMask` and `GetLogicalProcessorInformationEx`. It logs its P-core mask, but unpinned its audio threads run on CPUs 0–15.
  - Kernel and configuration:
    - C2/C3 disabled on P-cores 0–11 (the top pick);
    - poll-only idle on the audio cores;
    - `reg_file_data_sampling=off` or `mitigations=off` as a boot entry;
    - an ntsync module with in-kernel optimistic spinning for RT waiters;
    - nohz_full / rcu_nocbs / isolcpus;
    - period-aware pre-wake of the audio cores before each block;
    - a sched_ext audio policy.
  - Wine, specific to Live:
    - MMCSS "Pro Audio" mapped to SCHED_FIFO above Live's other threads;
    - a fixme-logging launch to list the APIs Live calls that Wine stubs;
    - huge pages for Live's heap and its ~100 MB of code (measure TLB walks first);
    - a lighter syscall dispatcher for the hot sync calls;
    - a re-test of 0109.
  - The "LiveSync" concept (bake the fan-out's hot path into kernel and Wine together):
    - ntsync event state in shared memory (a patched module mmaps a per-event slot; the kernel stays authoritative through atomics);
    - Wine makes ResetEvent, SetEvent with no sleeper, and the acquire of a signaled event syscall-free;
    - AudioCalc and pipeasio-rt spin on the memory word before sleeping in the kernel.
- **T0025, spinning before sleeping (item 3).** A Wine patch (0113) that lets threads named AudioCalc or pipeasio-rt spin briefly on their event before sleeping. It will be pre-registered with its probe once built; it is not run before then.

**Wine hot-path research (2026-10-18 morning)**

Diagnostic D0001: one traced run on the kept configuration (heavy Sets, 60 s each, 45,000 blocks per Set; history `diag-D0001-traced`).
- Per 1.33 ms block, Live makes 320–360 Wine syscalls:
  - `NtSetEvent` at `Live.exe+0x33f587e`: 105–118;
  - `NtWaitForSingleObject` at `Live.exe+0x4f8c119`: 70–78;
  - `NtResetEvent` at `Live.exe+0x33f41d2`: 68–77 (manual-reset events re-armed by each worker);
  - `NtQueryPerformanceCounter` (two Live sites): ~65.
  - The fan-out alone is ~245 per block.
- The callback's elapsed time is p50 150–196 µs, p99 256–289 µs, max ~1.45 ms. Late blocks: 1–4 per 45,000.
- In every late block the callback, not PipeASIO, is slow (`live_ns` 1.28–1.47 ms; PipeASIO pre ~10 µs, post 1–2 µs, wake 29–55 µs).
- In late blocks the callback makes ~3× the usual rounds (30–47 `NtSetEvent` against 15) and 10–36 `NtFlushInstructionCache` (normally 0–1), i.e. Live generates code on the audio thread. There is no `NtAllocateVirtualMemory` or `NtProtectVirtualMemory`, so Wine's VM lock is not involved.
- The late blocks land at the same offsets in each Set's run (~8.1, 23.7 and 25.3 s): song-position events, not scheduling.

Microbenchmarks (`tools/syncbench.c` under Wine, `tools/syncbench_native.c` with raw `/dev/ntsync` and futexes; threads SCHED_RR 10, pinned identically):

| | Wine | raw ntsync | futex |
|---|---|---|---|
| QPC | 76 ns (Windows TSC path ~10 ns) | — | — |
| SetEvent / ResetEvent | 190 ns | 105–108 ns | — |
| Wait, already signaled | 350 ns | 314–336 ns | — |
| Ping-pong, same core | 1.9 µs | 1.77 µs | 1.37 µs |
| Ping-pong, cross core | 3.0 µs | 2.63 µs | 1.87 µs |
| Fan-out, 6 workers (own CPUs) | 6.1 µs | 4.57 µs | 4.35 µs |
| Fan-out, 15 workers (CPUs 0–11) | 11.1 µs | 8.71 µs | 8.71 µs |

- Wine's own share is ~80 ns per call (the syscall dispatcher's register and xsavec save and restore), i.e. ~1.5–2.4 µs per fan-out round (20–25 %).
- NTSync already runs the fan-out at the kernel's sleep/wake floor.
- With ~5 rounds per block, 15 workers cost ~54 µs per block and 6 workers ~31 µs. That matches T0006's DSP drop.

Implications:
- Wine-side patches can save roughly 5–25 µs of CPU per block: a user-mode QPC (TSC bypass, which Wine's own tests list as missing) and a lighter dispatcher path for the hot event calls.
- The dropouts come from Live's own work spikes. Next evidence: scheduler and page-fault tracing of the callback in late blocks.
- First Wine patch: `0109` user-mode QPC behind an opt-in switch, measured with syncbench + a traced run + ABAB.
- `0109` keeps QPC in 100 ns ticks at 10 MHz (design correction, 2026-10-18). Wine's own code calls `NtQueryPerformanceCounter(&now, NULL)` and treats the result as 100 ns ticks: the threadpool timers, the wait timeouts in `unix/sync.c` and `unix/server.c`, win32u input, nsiproxy and the OSS/CoreAudio drivers. So the Windows layout (`QpcBypassEnabled` with a TSC-derived `QpcFrequency`) would break them. Instead, the TSC is scaled to 100 ns ticks, and `NtQueryPerformanceCounter` uses the same formula, so both paths agree. The parameters live in the shared user data, so every process in the prefix gets the same values.
- **Built and tested (2026-10-18, on the workstation build host, then on the laptop's dev runtime between T0011 and T0012):**
  - wineserver calibrates the TSC over 1 s, publishes a two-copy latch at offset 0xf00 of the shared user data page, and re-anchors it on every refresh.
  - The rate is re-measured every second; the phase is slewed by at most 1 %, never stepping.
  - `tools/qpcprobe.exe` passed every check on the laptop.
  - Cost per call: QPC 76 → 14 ns (`syncbench` qpc median 76.5 → 15.0 ns).
  - 2,000,000 alternating values from both routes never went backwards, and the routes agree (mean gap 0.49 ticks).
  - Tracking: `WINE_QPC_TSC=debug` logged QPC +955 ns from `CLOCK_BOOTTIME`, settling to −62…−106 ns, with the rate within 1 ppm.
  - WSL is not a valid place to test tracking: timesyncd slews WSL's clock by ±5 %.
- The mapping must follow the kernel clock's rate, not a fixed calibration. PipeASIO stamps the ASIO system time with PipeWire's `clock.nsec` (`CLOCK_MONOTONIC`), and Wine's QPC (`CLOCK_BOOTTIME`) runs at that same rate today. A fixed TSC calibration would drift from those stamps by the NTP correction, a few ppm, which is tens of ms per hour. So wineserver, which already refreshes the shared user data every ~16 ms, re-anchors the published TSC mapping against `CLOCK_BOOTTIME` under a seqlock, the way the kernel's vDSO data works, and slews rather than steps so QPC stays monotonic.
- Dev loop: `wine-dev` container initialised at 08:04 (`~/wine-dev/work/wine-src`, HEAD 10d4ce9).

**Build host (2026-10-18):** Wine builds moved off the laptop, so they no longer perturb trials or wait for them.
- Where: the workstation's WSL distro `ableton-build` (i9-12900K, 24 threads; rootless podman, the same image).
- Speed: `wine-dev.sh init` took ~10 min, including a 5.5 min cold build; an official build plus audit ~6 min (the laptop takes ~10 min warm).
- Reproducibility: an official workstation build of the same sources matches the laptop's installed runtime. All 288 unix-side libraries are byte-identical except `pipeasio64.dll.so`, whose log banner embeds `__DATE__ __TIME__`. The 1568 PE files differ only in their link timestamps.
- Deploys: they go over ssh to the laptop under its session lock (`deploy_host`, 2064dba): `wine-dev.sh sync` for the dev runtime, `build-official.sh` for an installer kit. The laptop only runs trials.

**Scoreboard after T0010** (heavy Sets, 120 s windows; T0010 was a diagnostic, Live minimised, which changed nothing):
- Kept: PipeASIO realtime (T0003), P-core audio threads (T0004) and nine audio workers (T0008). PipeWire ERR per 9 Set-runs went 204 → 4–10; Live CPU 64 → 48 % of a core; worst DSP peaks 130–225 % → 73–111 %.
- Reverted: T0001 (idle-state cap), T0005 (E-cores for non-audio threads), T0007 (realtime wineserver), T0009 (eight workers).
- Inconclusive: T0002 (confirmed by T0003) and T0006 (six workers: Live CPU −37 % and DSP lower, but Max4Live dropouts rose).
**Testing plan (2026-10-17).** Every trial: ABAB × 3, golden restored per run, all 5 Sets, untraced; accept iff the median DSP average or typical peak improves by more than 2× the A/A spread on at least one heavy Set, no Set regresses beyond noise, and the dropout guards (PipeWire ERR, peaks >100 %) are not worse; ledger + history + commit/push per trial.
1. Scheduling / configuration (no Wine code; PR-able as defaults or launcher options): PipeASIO realtime (T0002 → **kept in T0003**) → next, on top of it: tune the pipeasio-rt priority (PIPEASIO_RT_PRIORITY) vs Live's RR 10 → P-core affinity for pipeasio-rt + AudioCalc → real-time only for audio threads (today the launcher makes all 94 Live threads RR 10, UI and graphics included). Dropout trials use T0003's shape (heavy Sets, 120 s, pre-registered sign test on PipeWire ERR).
2. Existing Wine patch: WINE_APC_FASTPATH=1 (awaiting loaded-Set evidence).
3. Measurement upgrades before Wine-code trials: the slack budget with critical-path attribution (agent block); stress modes for rare dropouts — 60–120 s windows on the heavy Sets and 32-frame runs.
4. Wine hot-path changes (opt-in switch + probe + traced confirmation), ordered by the slack budget: userspace QueryPerformanceCounter; event fast path for the AudioCalc fan-out (≈110 SetEvent + 64 waits per block); lighter dispatcher; leftover wineserver requests; UI idle cost (≈38 % of a core).
Later: hand repeatable trials to /profiler-loop (B7).

### Strategy (decided 2026-10-17): optimise Live's audio hot path, don't strip Wine
Unused Wine code costs nothing at run time, and Live plus in-process VST plugins need a broad API surface, so the work is specialising the narrow hot path, not cutting features. Every change is pattern-based (never Live addresses), Wine/PipeASIO/kernel/scheduler side only, behind an opt-in switch with a probe and A/B proof, with a fallback so plugins stay correct.
1. **Slack budget first** (after B5c, on the Focusrite): per block, µs spent in Live's own compute, in Wine crossings, in wake-up/scheduling delay, and in the PipeWire → PipeASIO handoff. This sets the ceiling and picks the lever.
2. **Scheduling experiment early** (cheap, no Wine change): SCHED_FIFO + P-core affinity for the AudioCalc workers and the PipeASIO callback thread via `chrt`/`taskset` by thread name; later a sched_ext policy (CachyOS ships sched_ext).
3. Then, in the order the slack budget suggests: userspace fast path for Live's event pattern (auto-reset, single waiter → shared flag + futex, short spin, NTSync fallback); userspace `QueryPerformanceCounter`; a lighter dispatcher for the hot sync syscalls; wineserver requests left in the audio window; UI cost (laptop thermal/turbo headroom).
Early evidence: about 345 Wine syscalls per block on the VST Set, dominated by `SetEvent` at `Live.exe+0x33f587e` (≈100/block) and `WaitForSingleObject` at `Live.exe+0x4f8c119` (≈75/block), i.e. the AudioCalc fan-out.

### B6 — Dashboard review · 3 agents, serial
Data-layer tests, one combined reviewer (build + dataviz + gain semantics), fixer/verifier against real history from B4.

### B7 — Agent-loop dry run (Claude Code inside the VM)
`/profiler-loop` with `WINE_APC_FASTPATH` as the hello-world trial; verdict limited to `mechanism-confirmed` in the VM.

## After the VM phase
Bare-metal setup (`--profile baremetal`), overhead proof, A/A noise floor, then real optimisation trials (plan §13 milestones 7–8).
