# profiler/history — compact run summaries

Committed input for the gains dashboard (`profiler/dashboard/`) and for
`profiler/bin/ledger-report`. Raw suite output stays outside the repo in
`~/.local/share/profiler/runs/<run-id>/bench/`; this directory keeps one small
JSON file per run plus the baselines map.

| File | Written by | Content |
|---|---|---|
| `runs/<run_id>.json` | `profiler/bin/history-add RUN_DIR [--trial T0007 --arm A\|B\|AA]` | one `ableton-linux-profiler-history/v1` record |
| `baselines.json` | `profiler/bin/history-add RUN_DIR --baseline` | `{machine_id: {"<structure>/<scenario or ->": run_id}}`; a traced run is keyed `"<structure>/<scenario or ->@<trace_mode>"` (`benchmark/-@interface`) so the untraced and the traced baseline coexist; a run with a known audio device appends `" [<node.name>]"` so each interface keeps its own baseline |

`RUN_DIR` is the suite output directory (`run.json`, `report.json`, `profile/profile.json`,
`sets/NN-<Set>/measurement.json`) or its parent when the output lives in `RUN_DIR/bench`.
`--history-dir DIR` redirects both files (tests use it).

## Record (`ableton-linux-profiler-history/v1`)

Top-level keys, in this order. A value the run did not produce is `null`; the tool never fails on a
missing field.

| Key | Source | Notes |
|---|---|---|
| `schema` | — | `ableton-linux-profiler-history/v1` |
| `run_id` | `run.json` `id`; else the run directory name (its parent's name when the directory is `bench`) | characters outside `A-Za-z0-9_.-` become `-`; the file is `runs/<run_id>.json` |
| `tag` | `run.json` `tag` | |
| `started_at` | `run.json` `created_at` | UTC ISO 8601 |
| `machine_id` | `run.json` `machine.id`, else `profile.json` `machine.id` | 32 hex characters, stable per user |
| `hostname` | `profile.json` `system.hostname`, else the second word of `system.uname` | |
| `virtualization` | `profile.json` `system.virtualization.value` | `none` = bare metal; `null` = detector absent, treat as unknown (no timing claims) |
| `audio_device` | first Set's `measurement.json` `endpoint_identity.audio.before.default_sink` (`node.name`) | the PipeWire default sink, e.g. `alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0`; part of the identity; `null` = unknown (records written before the field existed) |
| `structure` | `run.json` `structure`; else `benchmark` when `set_order` is the canonical five and there is no scenario, otherwise `diagnostic` | |
| `scenario` | `run.json` `scenario` (its `name` when an object) | |
| `trace_mode` | `run.json` `trace.mode`; `off` when the run has no trace record | `off`, `interface`, `drilldown` |
| `duration_s` | `run.json` `duration_seconds_per_set` | |
| `runtime` | `profile.json` `runtime` | `dist_version` and `source_tree_sha` from `build_info` (`ABLETON-WINE-BUILD-INFO.txt`: `dist-version:`, `source-tree:`); `dev_info` = `runtime.dev_info` or the text of `<runtime root>/PROFILER-DEV-INFO.txt` as it is when the record is written |
| `switches` | `profile.json` `configuration.benchmark_gates` | `ENV: value` pairs the suite recorded; `{}` = none. The suite records `PIPEASIO_*`, the `ABLETON_*` names in `BENCHMARK_ABLETON_ENV_KEYS` and the `WINE_*` names in `BENCHMARK_WINE_ENV_KEYS` (`scripts/bench-report.py:83`): a new `WINE_*` switch is added there as part of its trial, or the record never shows it |
| `harness_sha` | `run.json` `harness.identity_hash` | |
| `commit` | `git rev-parse HEAD` of this repository when `history-add` ran | `null` outside a checkout |
| `trial`, `arm` | command line | `T0007`; `A`, `B` or `AA` |
| `source_dir` | the suite directory, written `~/…` when under `$HOME` | |
| `sets` | one object per Set in `run.json` `set_order` | below |

Per Set (`sets.<Set>`), from that Set's `measurement.json`:

| Key | Source |
|---|---|
| `mode` | `mode` |
| `host_cpu_pct` | `process.details.host_cpu_percent.cpu` |
| `live_cpu_pct_per_core`, `wine_cpu_pct_per_core`, `pipewire_cpu_pct` | `process.summary.{live,wine_prefix,pipewire}.cpu_percent_of_one_core` |
| `irq_per_s`, `softirq_per_s` | `kernel_counters.{interrupts,softirqs}.total_rate_per_second` |
| `pipewire_errors` | `pipewire.pw_top.err_delta` |
| `xruns` | `logs.xrun_line_count` |
| `dsp_avg`, `dsp_peak` | `osc_dsp.{average_percent,peak_percent}` |
| `audio_workers` | `process.summary.live.audio_worker_count` |
| `voluntary_switches_per_s` | sum of `voluntary_context_switches` over `process.summary.live.pids` in `process.details.processes`, divided by `process.details.elapsed_seconds`; `null` unless every Live process has a count |
| `late_blocks`, `near_late_blocks` | `interface.blocks.{late,near_late}` |
| `slack_p01_ns`, `slack_p50_ns` | `interface.blocks.slack_ns.{p01,p50}` |
| `lost_slack_total_ns` | `interface.lost_slack.total_ns` |
| `call_sites_top` | first 10 of `interface.call_sites` as `{key, share, total_ns_in_late_blocks}` (`share` = `share_of_lost_slack`) |
| `hotspots_non_audio_top` | first 10 of `interface.hotspots_non_audio` as `{role, kind, caller, n, total_ns}` |

Interface metrics are `null` on untraced runs. Outcome metrics are comparable only between untraced
runs, interface metrics only between traced runs (`profiler/dashboard/README.md`).

## Rules

- `history-add` after every suite run, before the next one. The dashboard picks the file up by HMR.
- Record the session baseline with `--baseline` on an untraced run without switches, trial or arm
  (`history-add` warns otherwise and refuses an incomplete run), then once more on the traced
  baseline run: it lands under the `…@interface` key and is the hotspot source of
  `ledger-report`. Without a traced baseline, the newest traced run recorded without switches
  or trial is the hotspot source. The dashboard reads both key forms.
- Recording the same run twice changes nothing; `commit` is the only field that can differ between
  two recordings (HEAD moved).
- Commit a trial's history files in the same commit as its ledger line (`CLAUDE.md`).
- Never edit these files by hand; re-run `history-add` instead.
