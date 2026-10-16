# CLAUDE.md — ableton-linux fork with the `profiler/` workbench

This is a local fork of shibco/ableton-linux (base `aceb236`, branch `profiler`). It ships a patched Wine fork + the PipeASIO driver that run Ableton Live 12 on Linux. The `profiler/` directory is our addition: a machine setup script, a Wine dev loop, an eBPF/USDT interface tracer, an AbletonOSC-based control layer, scenario drivers, an agent loop and a gains dashboard. The approved plan and the detailed designs live outside the repo in `../plans/` (`wine-interface-profiler-plan.md`, `design-A-setup-and-dev-loop.md`, `design-B-tracer-and-probes.md`, `design-C-control-suite-agent-loop.md`, `research-*.md`). Read the plan before changing anything under `profiler/`, `patches/` or `scripts/bench-*`.

## Project map

- `scripts/ableton-live` — the launcher (env knobs: `ABLETON_WINE_ROOT`, `ABLETON_WINEPREFIX`, `ABLETON_RT`, `ABLETON_POWER`, `ABLETON_MAX_AUDIO_THREADS`; passes through `WINE_APC_FASTPATH` and all `PIPEASIO_*`).
- `scripts/bench-suite.sh`, `bench-run.sh`, `bench-report.py`, `bench-osc.py` — the benchmark suite and report tool. `bench/` (Sets, SHA256SUMS) is restored locally from `aceb236^` and kept out of git via `.git/info/exclude`; never redistribute it.
- `patches/` — Wine series `0001`–`0107` (+ ours from `0108`), `performance/0001` (locked to exactly one file by policy), `pipeasio/0001`–`0016` (+ ours from `0017`). `scripts/build-audit.sh` enforces numbering, `REQUIRED_WINE_TAIL`/`REQUIRED_PIPEASIO_TAIL`, FINGERPRINTS/STAMP_ONLY and `patches/SERIES.sha256` (`--freeze`).
- `tools/` — PE probe programs (PASS/FAIL/SKIP lines, exit code = FAIL count), built like `tools/build_apcprobe.sh`.
- `notes/` — one note per investigation (Result / Scope / Verification).
- `profiler/setup/` — `setup-machine.sh --profile vm|baremetal` (idempotent phases, colourful log, `--dry-run`), `verify.sh`, root helper, templates.
- `profiler/bin/` — `with-session-env`, `state` (golden prefix snapshot/restore), `bench` (suite wrapper), `wine-trace`, `trace-prereqs`, `profile-app`, `history-add`, `ledger-report`.
- `profiler/dev/` — `wine-dev.sh` (persistent `wine-dev` podman container: `init|apply|build|sync|format-patch`), `build-official.sh` (the "keep" gate: full `build.sh` + `installer.sh runtime install --yes`).
- `profiler/tracer/`, `profiler/control/`, `profiler/scenarios/`, `profiler/dashboard/`, `profiler/history/`, `profiler/ledger.jsonl` — see the plan.

## Commands (Linux)

```bash
profiler/setup/setup-machine.sh --profile vm        # once per machine; resumable
profiler/setup/verify.sh --profile vm               # read-only health check
profiler/bin/state restore                          # golden prefix + config before every trial
profiler/control/install.sh --prefix "$ABLETON_WINEPREFIX"   # AbletonOSC + bench overlay into the User Library (Live closed; select it once in Preferences)
profiler/control/smoke-test.sh                      # /abl/bench/* protocol against a running Live; explains a missing pong
profiler/bin/bench --tag <tag> [--trace interface] [--scenario NAME] [--sets A,B]   # suite wrapper (OSC ports, session env, output dir)
profiler/dev/wine-dev.sh init|apply <patch>|build|sync|format-patch --number 0108 --name <slug>
ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev profiler/bin/bench --tag dev/x   # run against the dev runtime
profiler/dev/build-official.sh                      # 15–60 min; no repo edits while it runs
python3 scripts/bench-report.py compare --before <run>/bench --after <run>/bench --output <dir>
python3 scripts/bench-report.py interface-drilldown --run-dir <run>/bench --set <Set> --top 10   # the latest blocks and their crossings
profiler/bin/history-add <run> [--trial T0007 --arm A|B|AA] [--baseline]   # after every suite run (profiler/history/README.md)
profiler/bin/ledger-report [--output FILE]          # validate profiler/ledger.jsonl (exit 2 on a bad line), open hotspots
make test && make test-profiler
```

Log every long command: `set -o pipefail; <cmd> 2>&1 | tee ~/.local/state/profiler/logs/<ts>-<what>.log`.

The agent loop: `cd ~/Projects/ableton-linux && claude`, then `/profiler-loop [budget-hours] [K] [vm|baremetal]` (defaults 6 h and K = 3; the prompt is `profiler/AGENT-PROMPT.md`, the ledger schema `profiler/LEDGER.md`).

## Guardrails

- Never modify, hook or disassemble Live. Never edit Live's Preferences, Options.txt or Sets by hand (only the launcher and the suite write there). Live frames stay `module+offset`.
- Restore the golden state (`profiler/bin/state restore`) before every trial. Close Live with Ctrl+Q / `liveinject.exe ctrlq`, never SIGTERM (it leaves crash-recovery state that silently reopens the Set).
- One hypothesis per trial. Every Wine/PipeASIO change ships behind an opt-in env switch (default off, strict boolean parse), with a PE probe in `tools/` and a note in `notes/`. Never make a fix default.
- A/B on ONE runtime with the switch flipped (dev runtime for iteration; official runtime for a "keep"). Accept only on untraced, interleaved ABAB (n ≥ 3) beating 2× the A/A spread with no Set regressing; xruns or PipeWire `ERR` = reject; then confirm the mechanism with one traced run per arm.
- Timing claims only on bare metal. Reports from a virtualised host carry a "NO TIMING CLAIMS" banner; verdicts there are limited to `tooling` / `mechanism-confirmed`.
- Root only through `sudo -n` for the tracer (VM) or `profiler-root-helper` allowlisted verbs (bare metal).
- `build.sh` snapshots every non-ignored file and aborts if the tree changes: never write non-ignored files in the repo during a build; keep run output in `~/.local/share/profiler/runs/`. Never `git add -A` after a build (`dist/BUILD-INFO*.txt` and `.sha256` change).
- New Wine patch = next number (`0108+`): update `REQUIRED_WINE_TAIL` (`scripts/build-audit.sh:13`), add a FINGERPRINTS or STAMP_ONLY entry, run `scripts/build-audit.sh --freeze`, keep `make test` green (if `VERSION` changes, the first `## ` heading in `CHANGELOG.md` must match).
- Commit each trial on its own branch `trial/T<id>-<slug>` with its ledger line and `profiler/history/` files in the same commit.
- Never run `profiler/control/liveosc.py` queries during a measurement window (one owner of UDP 11001).
- Stop and report when the time budget is spent, after 3 consecutive revert/inconclusive trials, after 2 consecutive build failures, or on any guardrail violation.
