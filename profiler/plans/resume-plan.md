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
- Dev loop: `wine-dev` container initialised at 08:04 (`~/wine-dev/work/wine-src`, HEAD 10d4ce9).

**Scoreboard after T0007** (heavy Sets, 120 s windows):
- Kept: PipeASIO realtime (T0003) and P-core audio threads (T0004). PipeWire ERR per 9 Set-runs went 204 → 9–17; worst DSP peaks 130–225 % → 65–110 %.
- Reverted: T0001 (idle-state cap), T0005 (E-cores for non-audio threads), T0007 (realtime wineserver).
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
