# Profiler loop — agent prompt

You are Claude Code on the profiler machine, in `~/Projects/ableton-linux` (branch `profiler`).
`CLAUDE.md` applies in full; this file is the loop it points to. `/profiler-loop [budget-hours] [K]
[vm|baremetal]` starts it; without arguments the budget is 6 hours and K is 3. Everything you run is
one of the exact commands in `CLAUDE.md`; nothing else touches Live, the prefix or the runtime.

## 1. Objective and priorities

Make Ableton Live under this Wine runtime miss fewer audio deadlines, then cost less CPU, without
changing anything by default. In order:

0. Zero xruns and zero PipeWire `ERR` increments in every measured run (`xruns`, `pipewire_errors`
   in the history record). A change that adds one is rejected whatever else it does.
1. Fewer late and near-late audio blocks: `late_blocks`, `near_late_blocks`, `slack_p01_ns`,
   `lost_slack_total_ns` from traced runs; `share_of_lost_slack` per call site says where the
   slack goes.
2. Lower Live and Wine CPU per core: `live_cpu_pct_per_core`, `wine_cpu_pct_per_core`,
   `voluntary_switches_per_s`, `dsp_peak` from untraced runs.

Whole-app view: traced runs also carry `hotspots_non_audio` (main, loader and UI threads), and the
UI scenarios (`view-flip`, `track-churn`, `load-devices`) show what the non-audio threads do.
Report those findings in every session; trial them only after the audio hotspots are exhausted.

Untraced runs decide (the tracer adds overhead; outcome metrics are comparable only between
untraced runs). Traced runs explain (interface metrics are comparable only between traced runs).
Never compare across trace modes; `bench-report.py compare` refuses it.

## 2. Arguments and the phase gate

- `budget-hours` (default 6): wall-clock from the first command of this session. Record the start:
  `session=$(date -u +%Y%m%dT%H%M%SZ); mkdir -p ~/.local/state/profiler/loop/$session; date -u +%s > ~/.local/state/profiler/loop/$session/start`.
- `K` (default 3): consecutive trials without a positive result that end the session (section 7).
- `vm` or `baremetal`: `vm` forces the VM phase even on bare metal (a dry run of the loop).
  `baremetal` counts only when the host is bare metal; on a virtualised host it is ignored and the
  report says so. There is no override that permits timing claims on a virtualised host.

Virtualisation decides what a verdict may claim. Read it twice: `systemd-detect-virt || true`
before the first run (prints `none` and exits 1 on bare metal), then `system.virtualization.value`
in `<run>/bench/profile/profile.json` after the first run of the session:

```bash
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["system"]["virtualization"])' <run>/bench/profile/profile.json
```

The profile wins when the two disagree.

| Phase | `virtualization.value` | Ledger `host` | Verdicts allowed | What the loop proves |
|---|---|---|---|---|
| bare metal | `none` | `bare-metal` | `keep`, `revert`, `inconclusive`, `tooling`, `mechanism-confirmed` | gains, by the acceptance rule |
| VM | anything else (`vmware`, `kvm`, `unknown`, absent) | `vm:<value>` | `tooling`, `mechanism-confirmed` | the tooling works end to end; a change removes the call site it targets |

In the VM phase no number is a timing claim: every report carries the `NO TIMING CLAIMS` banner,
A/B numbers go into `rationale` as mechanism evidence only, and a trial whose mechanism did not
confirm is recorded as `tooling` with those numbers. The first VM trial, when the ledger is empty,
is the hello-world trial: switch `WINE_APC_FASTPATH=1` (`patches/performance/0001-…`, probe
`tools/apcprobe.c`, note `notes/MOONSHOT-CPU-WINE-BOUNDED-FASTPATHS.md`, `commit` null) through
the full protocol of section 4, verdict `mechanism-confirmed` or `tooling`. Later VM trials may
shorten step 7 to the A/A pair, one A/B pair and the traced pair.

## 3. Session start (once)

Log every long command: `set -o pipefail; <cmd> 2>&1 | tee ~/.local/state/profiler/logs/<ts>-<what>.log`
with `ts=$(date -u +%Y%m%dT%H%M%SZ)`. Notes, counters and comparison output live in
`~/.local/state/profiler/loop/$session/`, never in the repository.

1. `git status --short` shows no modified tracked file and `git branch --show-current` prints
   `profiler`. Anything else is someone's work in progress: stop and report.
2. `make test-profiler` passes (`make test` is the per-trial gate).
3. `profiler/bin/ledger-report` exits 0. Note the `Next trial id` line and the `Open hotspots`
   table.
4. `profiler/bin/state list` shows `golden`, then `profiler/bin/state restore`.
5. Baselines, unless `profiler/history/baselines.json` already names runs for this machine whose
   `runtime.dist_version`, `runtime.source_tree_sha` and `harness_sha` equal the current ones
   (then reuse them and say so in the report):
   - `profiler/bin/bench --tag baseline`, then `profiler/bin/history-add <run> --baseline`
     (untraced, all five Sets: the outcome baseline, key `benchmark/-`).
   - `profiler/bin/bench --tag baseline-traced --trace interface`, then
     `profiler/bin/history-add <run> --baseline` (key `benchmark/-@interface`: the hotspot source).
   - `profiler/bin/bench --tag baseline-clip-launch-storm --scenario clip-launch-storm --sets Inbuilts --trace interface`
     and `profiler/bin/bench --tag baseline-view-flip --scenario view-flip --sets Inbuilts --trace interface`,
     each followed by `history-add <run> --baseline`; add `param-sweep`, `tempo-ramp` (Inbuilts),
     `track-churn`, `load-devices` (Empty) when the budget allows.

   `<run>` is the directory `profiler/bin/bench` prints last (`bench: run directory … (exit 0)`,
   under `~/.local/share/profiler/runs/`); `history-add` takes it or its `bench` child, and the
   run id is its basename `<UTC>-<tag>`. Commit the history files on `profiler`:
   `git add profiler/history && git commit -m "history: baselines $session"`.
6. Read the phase from the baseline profile (section 2) and write it down.
7. If the suite reports `no /abl/bench/pong`, follow its diagnosis: `profiler/control/smoke-test.sh`
   while Live runs, `profiler/control/install.sh --prefix "$ABLETON_WINEPREFIX"` while Live is
   closed. Selecting AbletonOSC as a Control Surface is a human step: if it is missing, stop and
   report it.

## 4. The trial loop

Repeat until a stop criterion (section 7) hits. One hypothesis per trial, one trial at a time, the
golden state restored before each. A full trial on bare metal takes about 90–150 minutes
(10 suite runs plus the official build for a `keep`).

1. **Pick the target.** `profiler/bin/ledger-report`: the first `Open hotspots` row with share
   >= 0.10 on the Set that matters most (`Benchmark_VSTs`, then `Inbuilts`, `Max4Live`, `Empty`,
   `Zero`). Read its mechanism:
   `python3 scripts/bench-report.py interface-drilldown --run-dir <baseline-traced>/bench --set <Set> --top 10`
   lists the latest blocks and the crossings inside them; `report.md` of that run has the
   `Interface crossings` table (caller chain, per late block, share of lost slack). No row >= 0.10
   left: the audio hotspots are exhausted; turn to `hotspots_non_audio_top` of the traced runs
   (whole-app) or stop with that finding.
2. **Write the hypothesis before touching code**, one falsifiable sentence: "<mechanism> at
   <call site> costs <ns> per late block on <Set> because <reason>; <change> behind <SWITCH>
   removes it; expect <primary metric> to fall by >= <amount> on <Set> with no Set regressing."
   Choose the primary metric now: an outcome metric measured untraced (`live_cpu_pct_per_core` by
   default; `voluntary_switches_per_s`, `dsp_peak` or `wine_cpu_pct_per_core` when the mechanism
   says so). Late blocks are confirmed by the traced pair, never by the untraced verdict.
3. **Branch.** `T=<next trial id>`; `git switch -c trial/$T-<slug> profiler`; note the time
   (`minutes` in the ledger runs from here to the record commit).
4. **Change, behind an opt-in switch** (default off, strict boolean parse: `1`, `on`, `true`,
   `yes` in any case; warn on an invalid value). Audio-thread safety rules go into the note.
   - `wine-patch`: `profiler/dev/wine-dev.sh edit` prints the tree (`~/wine-dev/work/wine-src`);
     commit there with a Result / Scope / Verification body;
     `profiler/dev/wine-dev.sh build --dir dlls/ntdll` (or `build` for the whole tree);
     `profiler/dev/wine-dev.sh sync --artifacts --dir dlls/ntdll` (or `sync` after a whole-tree
     build) updates the dev runtime `~/.local/opt/wine-d2d1-nspa-11.13-dev`;
     `profiler/dev/wine-dev.sh format-patch --number <next, 0108 or later> --name <slug>` writes
     `patches/<NNNN>-<slug>.patch` and prints the build-audit checklist: `REQUIRED_WINE_TAIL`
     (`scripts/build-audit.sh:13`), a `FINGERPRINTS` or `STAMP_ONLY` line,
     `scripts/build-audit.sh --freeze`. Add the switch name to `BENCHMARK_WINE_ENV_KEYS`
     (`scripts/bench-report.py:83`) so the history record's `switches` shows it, and document it
     under RUNTIME VARIABLES in `scripts/ableton-live` next to `WINE_APC_FASTPATH` (the launcher
     forwards the environment as it is).
   - `pipeasio-patch`: `profiler/dev/wine-dev.sh pipeasio-init` once; edit `~/wine-dev/work/pipeasio`;
     `profiler/dev/wine-dev.sh pipeasio-build --test`; `profiler/dev/wine-dev.sh sync`;
     `format-patch --pipeasio --number <next, 0017 or later> --name <slug>`;
     `REQUIRED_PIPEASIO_TAIL`. A `PIPEASIO_*` switch is recorded as it is.
   - `launcher`: `scripts/ableton-live` behind `ABLETON_<NAME>`; add the name to
     `BENCHMARK_ABLETON_ENV_KEYS` (`scripts/bench-report.py:95`).
   - `config`: only what a `PIPEASIO_*` or `ABLETON_*` switch expresses. A file edit under
     `~/.config` is machine state that `state restore` undoes; it is not a trial.
   - `tooling`: a change to `profiler/`, `scripts/bench-*` or `tools/` only; no switch, no A/B,
     verdict `tooling`.
5. **Probe and note.** `tools/<name>probe.c` plus `tools/build_<name>probe.sh` modelled on
   `tools/build_apcprobe.sh`: PASS/FAIL/SKIP lines, exit code = FAIL count. Run it while Live is
   closed, against the dev runtime, with and without the switch:
   `WINEDEBUG=-all WINEPREFIX=~/.wine-ableton <SWITCH>=1 ~/.local/opt/wine-d2d1-nspa-11.13-dev/bin/wine tools/<name>probe.exe 2>&1 | tee ~/.local/state/profiler/logs/<ts>-<name>probe.log`.
   `probe_result` is the PASS/FAIL/SKIP count of the switched-on run (`grep -c '^PASS'` and so
   on). Any FAIL: fix it or record `revert`. Write `notes/ABLETON-WINE-<SLUG>.md` with Result /
   Scope / Verification. Then `profiler/bin/state restore` (the probe used the prefix).
6. **Gate.** `make test` green, `make test-profiler` green. Commit the change on the branch with
   `git add <each file>` (patch, `patches/SERIES.sha256`, `scripts/build-audit.sh`,
   `scripts/bench-report.py`, launcher, probe sources, note), never `git add -A`. This commit's
   hash is the ledger's `commit`.
7. **Measure on the dev runtime.** `export ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev`.
   `profiler/bin/state restore` once before the first run; `profiler/bin/state clean-crash` before
   every later run (the suite closes Live with SIGTERM, which leaves crash-recovery state). After
   every run, before the next: `profiler/bin/history-add <run> --trial $T --arm <arm>`. Tags, in
   this order:
   - A/A pair, switch off: `profiler/bin/bench --tag $T-AA1` and `--tag $T-AA2` (arm `AA`).
   - ABAB, untraced, alternating, A first: `profiler/bin/bench --tag $T-A1`;
     `<SWITCH>=1 profiler/bin/bench --tag $T-B1`; then `A2`, `B2`, `A3`, `B3` (arms `A`, `B`).
     Three pairs minimum; a fourth pair when the ratio lands between 1.5 and 2.5.
   - Traced confirmation, one run per arm: `profiler/bin/bench --tag $T-traced-A --trace interface`
     and `<SWITCH>=1 profiler/bin/bench --tag $T-traced-B --trace interface`.

   A run that fails or is interrupted: `profiler/bin/state restore`, repeat it once; the same
   failure twice in a row is a tooling failure (section 7).
8. **Verdict arithmetic** (section 5). Then
   `python3 scripts/bench-report.py compare --before <traced-A>/bench --after <traced-B>/bench --output ~/.local/state/profiler/loop/$session/$T-traced`
   for the targeted call site's share before and after (`comparison.md`, `Interface crossings`)
   and the late and near-late deltas.
9. **`keep` needs the official runtime.** Only when the dev-runtime numbers pass the gate on bare
   metal: `unset ABLETON_WINE_ROOT`; `profiler/dev/build-official.sh` (15–60 min; touch nothing in
   the repository meanwhile); repeat step 7 on the official runtime; the verdict uses those
   numbers. Otherwise the verdict is `revert` or `inconclusive` from the dev-runtime numbers.
10. **Record.** Append the ledger line (`profiler/LEDGER.md`), `profiler/bin/ledger-report` must
    exit 0, then the record commit on the same branch:
    `git add profiler/ledger.jsonl profiler/history/runs/<every run id of this trial>.json profiler/history/baselines.json && git commit -m "$T: <verdict>: <hypothesis>"`.
11. `git switch profiler`. Kept trials stay on their branches for a human to merge; list them in
    the report. Update the counters of section 7 and continue with step 1.

## 5. Verdict arithmetic

From the history records of the trial (untraced runs of one runtime), per Set:

```bash
python3 - "$T" live_cpu_pct_per_core dev <<'EOF'     # metric, then dev|official
import json, statistics, sys
from pathlib import Path
trial, metric, which = sys.argv[1:4]
runs = [json.loads(p.read_text()) for p in sorted(Path("profiler/history/runs").glob("*.json"))]
runs = [r for r in runs if r.get("trial") == trial and r.get("trace_mode") == "off"
        and bool(r["runtime"]["dev_info"]) == (which == "dev")]
def values(arm, name, key):
    return [r["sets"][name][key] for r in runs if r.get("arm") == arm and r["sets"].get(name, {}).get(key) is not None]
for name in sorted({name for r in runs for name in r["sets"]}):
    aa, a, b = values("AA", name, metric), values("A", name, metric), values("B", name, metric)
    spread = round(abs(aa[0] - aa[1]), 4) if len(aa) == 2 else None
    a_median = statistics.median(a) if a else None
    b_median = statistics.median(b) if b else None
    delta = None if a_median is None or b_median is None else round(b_median - a_median, 4)
    ratio = None if delta is None or not spread else round(abs(delta) / spread, 2)
    guards = {key: max(values("A", name, key) + values("B", name, key) + [0]) for key in ("xruns", "pipewire_errors")}
    print(json.dumps({"set": name, "a_median": a_median, "b_median": b_median, "aa_spread": spread,
                      "delta": delta, "ratio_to_spread": ratio, "runs": [len(aa), len(a), len(b)], "guards_max": guards}))
EOF
```

- `aa_spread` = |AA1 − AA2|; `a_median` and `b_median` over the A and B runs;
  `delta = b_median − a_median`; `ratio_to_spread = |delta| / aa_spread`. The five fields go into
  `metrics.per_set` for every Set; `runs` and `guards_max` do not.
- `keep` (bare metal, official runtime) only if: on every Set cited in `evidence` the delta
  improves the primary metric (lower) with `ratio_to_spread > 2`; on every Set no regression beyond
  its spread (`delta <= aa_spread` for a lower-is-better metric); `guards_max` is 0 everywhere;
  the probe has 0 FAIL; the traced pair shows the targeted call site's share down and
  `late_blocks + near_late_blocks` not up.
- A spread of 0 means the A/A pair is suspiciously identical: run a second pair and use the
  larger spread.
- `revert`: a regression beyond the spread on any Set, a guard hit, or a probe FAIL.
  `inconclusive`: everything else on bare metal (inside the noise, budget cut, tooling trouble).
  `mechanism-confirmed`: the traced share dropped by at least half with the guards holding, on a
  VM or on bare metal when the session ends before the official-runtime A/B.

## 6. Ledger discipline

- One JSON line per trial, appended with the snippet in `profiler/LEDGER.md`; never edited or
  deleted. A correction is a new trial whose `rationale` names the old one.
- `profiler/bin/ledger-report` exits 0 before every record commit; the bad lines it names are
  fixed in the line you are appending, never in old ones.
- Every run a line cites exists in `profiler/history/runs/` (`history-add` after every suite run,
  before the next). Runs are cited by run id; paths in the line are repo-relative or `~/`-relative.
- `evidence` = the targeted call site(s) with the share from the baseline traced run;
  `metrics.per_set` = the five fields of section 5 for every Set; `traced_confirmation` from the
  traced pair; `rationale` = the numbers behind the verdict, including the runtime they came from.
- `host` from the profile (section 2); `minutes` from branch creation to the record commit;
  `commit` = the change commit of step 6 (`null` for a trial that changed no tracked file).

## 7. Stop criteria

Check before step 1 of every trial, and after every step that can fail:

- **Budget**: `now − start + estimate > budget`, where the estimate is the median `minutes` of
  this session's trials, else 90 (150 when a `keep` candidate still needs the official build).
- **K**: bare metal: K consecutive `revert` or `inconclusive` verdicts; VM: K consecutive trials
  that are not `mechanism-confirmed`.
- **Builds**: 2 consecutive failures of `wine-dev.sh build`, `pipeasio-build` or
  `build-official.sh`.
- **Tooling**: the suite failing twice in a row for the same reason (no pong, UDP port busy,
  launch timeout, tracer refused).
- **Guardrail violation** (`CLAUDE.md`), yours or found: drift in `profiler/bin/state diff` you did
  not cause, a preflight refusal you would have to bypass, Live that needed a SIGKILL, a root
  action outside `sudo -n` for the tracer or the helper's verbs. Never work around it.

On stop: let the running suite finish (it closes Live itself); `profiler/bin/state restore`; record
the current trial if it has measurements (`inconclusive` on bare metal, `tooling` on a VM), with
the stop reason in `rationale`; then the report.

## 8. Report

Write `~/.local/state/profiler/reports/$session-profiler-loop.md` and print it as the final
message:

```markdown
# Profiler loop report — <session UTC>
## Session
- host <hostname>, virtualization <value> → phase <bare metal|VM>; runtime <dist_version> (dev: <dev_info>); harness <harness_sha>
- budget <used> of <budget> h; stop reason: <which criterion>
- trials: <n>, verdicts: <counts>; kept branches: <trial/T…-… list, or none>
## Ledger report
<the verbatim output of profiler/bin/ledger-report>
## Trials
### T<id> — <hypothesis>
- target: <Set> <call_site> share <before> (run <baseline-traced run id>)
- change: <kind> <patch> behind <SWITCH>; probe <pass>/<fail>/<skip>; note <path>
- numbers: per-Set table (a_median, b_median, aa_spread, delta, ratio_to_spread) on <runtime>; guards; traced share <before> → <after>; late+near-late <before> → <after>
- verdict <verdict>: <rationale>; branch <name>; commits <change>, <record>
## Whole-app findings
- top hotspots_non_audio_top rows (role, kind, caller, n, total_ns) from the traced baseline and the scenario runs; what the UI scenarios showed
## Next
- the open hotspots left (from the ledger report), what to try next, what blocked you
## VERIFY
- every fact you assumed without measuring it
```

## 9. Never

Never SIGTERM Live yourself (Ctrl+Q or `liveinject.exe ctrlq`); never `git add -A`; never write a
non-ignored file during `build-official.sh`; never run `profiler/control/liveosc.py` or any other
owner of UDP 11001 during a measurement window; never edit or delete a ledger line, a history
record or `baselines.json` by hand; never make a switch default; never claim timing on a
virtualised host; never bypass a preflight refusal; never use `sudo` outside `sudo -n` for the
tracer (VM) or `profiler-root-helper` (bare metal).
