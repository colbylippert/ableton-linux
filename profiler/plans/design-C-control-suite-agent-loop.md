# Design C — control layer (AbletonOSC), suite/report integration, scenarios, agent loop, tests

Companion to `wine-interface-profiler-plan.md`. Verified against aceb236 and AbletonOSC master `0ca68214bd62c9b5cb641ca34006cfd70ba94430` (2025-11-19, MIT, `LICENSE.md`; vendored `pythonosc/`; `client/` depends on `pythonosc.udp_client`, so it is not reusable stdlib-only).

Key facts:

- The suite cannot run at aceb236: preflight needs the five `.als` and `bench/SHA256SUMS` (`scripts/bench-suite.sh:144-149`). Step 0 is restoring `bench/` from `aceb236^` (kept out of git via `.git/info/exclude`). The harness hash lists `bench/SHA256SUMS` (`bench-report.py:2314-2318`); `sha256_file` records `exists:false` instead of raising (196-210).
- AbletonOSC: `OSCServer` binds `0.0.0.0:11000`, replies to `(sender host, 11001)` and re-points its default reply address to the most recent client; `add_handler(address, fn)`, `send(address, params=(), remote_addr=None)`; `Manager(ControlSurface)` runs `tick()` every 100 ms via `schedule_message(1, self.tick)` and processes the socket on the main thread (no threads); `/live/api/reload`, `/live/api/set/log_level`, `/live/test`; log at `<script dir>/logs/abletonosc.log`; handler errors are relayed to `/live/error`. `abletonosc/application.py` already exposes `/live/application/get/average_process_usage` using `Live.Application.get_application().average_process_usage` — the attribute name is confirmed by upstream code (the old M4L device used the same name on 12.4.3). `view.py` has only `selected_*` get/set, `device.py` `/live/device/set/parameter/value (track, device, param, value)`, `clip.py` `/live/clip/fire (track, clip)` and `/live/clip/add/notes`, `clip_slot.py` `/live/clip_slot/create_clip (track, clip, length)`, `scene.py` `/live/scene/fire (scene)`, `track.py` `/live/track/get/output_meter_level`, `/live/track/delete_device`, `/live/track/get/devices/name`.
- Live API: `Application.browser`, `Browser.instruments/audio_effects/plugins/max_for_live/user_library`, `Browser.load_item(item)`, `BrowserItem.name/children/iter_children/is_loadable/is_device/uri`; `Application.View.show_view/focus_view/is_view_visible/available_main_views`; `Live.Base.Timer` has `start/stop/restart/running`.
- `scripts/bench-osc.py` encodes only `i/f/s` (37-55) and decodes only `i/f/s`, silently skipping other tags and desynchronising afterwards (69-78); binds `127.0.0.1:RECV` for `dump`/`probe` (104, 130); sends to `127.0.0.1:SEND` (91, 135).

---

## A. Control layer — `profiler/control/`

**Port decision: run the `/abl/bench/*` protocol on AbletonOSC's own server (11000 in, 11001 out).** Reasons: (1) the canonical sets still embed the M4L device, whose `udpreceive 19001` would collide with a second socket opened by a Remote Script handler on 19001; on 11000/11001 the M4L device keeps reporting to 19002 unheard (Max runtime cost stays in the measurement, as before); (2) AbletonOSC replies to `(sender host, 11001)` and `bench-osc.py` already binds `127.0.0.1:RECV`, so `probe`/`dump`/`send` work unchanged from localhost; (3) one socket, one tick loop, no threading inside Live. Implementation: leave the scripts' defaults alone; `profiler/bin/bench` exports `ABL_BENCH_OSC_SEND=11000 ABL_BENCH_OSC_RECV=11001`. Consequence: only one process can own 127.0.0.1:11001, so `liveosc.py` queries must not run while the `osc` collector (`dump`) is active (never inside a measurement window). Preflight gains `check-udp --port 11000`.

Files:

```
profiler/control/
  VENDOR.txt              upstream URL, pinned commit 0ca68214…, tarball SHA-256, "MIT, LICENSE.md kept"
  vendor.sh               curl the pinned tarball, sha256sum -c, unpack LICENSE.md README.md __init__.py manager.py abletonosc/ pythonosc/ into vendor/AbletonOSC/ (no tests/, client/, .github/)
  vendor/AbletonOSC/      pristine copy (committed)
  overlay/manager.py      upstream manager.py + 2 lines: import BenchHandler, append to the handler list in init_api()
  overlay/abletonosc/bench.py
  install.sh              --prefix DIR [--user NAME] [--dry-run]
  liveosc.py              stdlib client + CLI
  scenario-run.py         TimedCommand driver (section C)
  smoke-test.sh
  tests/test_bench_handler.py, tests/test_liveosc.py
```

`install.sh`: locate the User Library the way `beta/scripts/ableton-linux-profiler.sh:187-200` does (`drive_c/users/<user>/{Documents,My Documents}/Ableton/User Library`, following the `Documents` symlink with `readlink -f`), refuse if absent ("start Live once so it creates the User Library" or honour `ABLETON_LIBRARY_PATH`), refuse if Live is running (`ableton_live_running` from `scripts/lib/lifecycle.sh:163-171`), then copy `vendor/AbletonOSC/` + `overlay/` to `…/Remote Scripts/AbletonOSC/`, write `…/AbletonOSC/INSTALLED.txt` (pinned commit + overlay sha256s), never touch `ProgramData/Ableton/*/Resources/MIDI Remote Scripts`.

**One-time human step** (control surfaces are enumerated at Live start, so install first): start Live → Preferences → Link, Tempo & MIDI → Control Surface slot: `AbletonOSC`, Input/Output `None` → close Preferences (flushes `Preferences.cfg`, `scripts/ableton-live:1265-1267`) → quit with Ctrl+Q → **then** take the golden snapshot. Detection when missing: `bench-osc.py probe` times out → `smoke-test.sh`/the suite print: "no /abl/bench/pong within N s on UDP 11001: AbletonOSC is installed at <path> but not selected as a Control Surface (Preferences > Link, Tempo & MIDI), or Live was started before install" and report whether `<path>/logs/abletonosc.log` was modified after the Live process start time.

`overlay/abletonosc/bench.py` — `class BenchHandler(AbletonOSCHandler)` (`class_identifier = "bench"`), registered in `init_api()`:

| Address (in) | Behaviour | Reply (out, to the default reply address) |
|---|---|---|
| `/abl/bench/ping [args]` | echo | `/abl/bench/pong [args]` |
| `/abl/bench/play` / `stop` / `rewind` | `song.start_playing()` / `stop_playing()` / `song.current_song_time = 0.0` | none |
| `/abl/bench/poll` | one CPU report | `/abl/bench/cpu AVG PEAK` |
| `/abl/bench/cpu-period MS` | 0 stops, default 500; rescheduled via `self.manager.schedule_message(max(1, round(ms/100)), self._cpu_tick)` (one-shot, re-armed each tick; 100 ms resolution; main thread) | periodic `/abl/bench/cpu AVG PEAK` (`-1 -1` while unavailable) |
| (init) | `app = Live.Application.get_application()`; probe `average_process_usage`; `song.add_is_playing_listener(cb)` | `/abl/bench/ready 0|1` once; `/abl/bench/playing 0|1` on change |
| `/abl/bench/scenario-marker NAME` | timestamp a scenario step Live-side | `/abl/bench/scenario-marker NAME SONG_TIME IS_PLAYING` |
| `/abl/bench/info` | runtime self-check | `/abl/bench/info LIVE_VERSION PY_VERSION CPU_ATTR_OK SCRIPT_PATH` |
| `/abl/bench/views` | `app.view.available_main_views()` | `/abl/bench/views NAME…` |
| `/abl/bench/show-view NAME` / `focus-view NAME` | `app.view.show_view(NAME)` / `focus_view` | `/abl/bench/view NAME VISIBLE` |
| `/abl/bench/load-device KIND NAME [TRACK]` | select track, DFS over `browser.{instruments,audio_effects,plugins,max_for_live}` children by `name` with `is_loadable`, `browser.load_item(item)`; index cached per KIND | `/abl/bench/load-device NAME ok|missing` |
| `/abl/bench/subscribe PORT` / `unsubscribe PORT` | add `(127.0.0.1, PORT)` to a subscriber set; every report above is also `send(..., remote_addr=sub)` | — |

Rules: all reports use only `int/float/str` args (bools cast to int) so `parse_osc` (`bench-report.py:705-736`) keeps working; CPU values multiplied by `CPU_SCALE` (1.0 or 100.0, settled by the smoke test against Live's CPU meter — VERIFY); every handler wrapped so a failing LOM call sends `/live/error` and never kills the tick loop; `clear_api()` removes the listener and cancels the period (upstream calls it on `/live/api/reload`).

`profiler/control/liveosc.py` (stdlib; loads `scripts/bench-osc.py` with the `importlib.spec_from_file_location` trick from `scripts/test-bench-report.py:24-33` and reuses `encode/decode/probe_nonce`): `ping(timeout)`, `wait_ready(timeout)`, `play()`, `stop()`, `rewind()`, `set_tempo(bpm)`, `fire_clip(t,c)`, `fire_scene(s)`, `set_param(t,d,p,v)`, `create_midi_track(i)`, `create_audio_track(i)`, `delete_track(i)`, `load_device(kind,name,track)`, `show_view(name)`, `marker(name)`, `query(address, args, timeout)` (binds 11001 only for the call), `listen(duration)`; CLI mirrors them. Extend `bench-osc.py decode()` to handle `T F N I b d h` (python-osc emits `T/F` for bools) with a unit test.

`profiler/control/smoke-test.sh`: refuses if Live is not running; `probe --timeout 20`; `send /abl/bench/info`, `/abl/bench/views`; `rewind`, `play`, `dump --duration 2` must show `playing 1` and ≥2 `cpu` lines with values ≥ 0; `stop` → `playing 0`; exit = failure count (PASS/FAIL/SKIP lines).

---

## B. Suite and report integration

**`scripts/bench-suite.sh`** (minimal diff, same style):

- New options: `--trace off|interface|drilldown` (env `ABLETON_BENCH_TRACE`, default off), `--scenario NAME` (env `ABLETON_BENCH_SCENARIO`), `--sets A,B,C` (names with or without the `Benchmark_` prefix, validated like `--crackle` at 77-82, order preserved), overrides `ABLETON_BENCH_TRACER` (default `$root/profiler/bin/wine-trace`), `ABLETON_BENCH_ROOT_HELPER` (default `profiler-root-helper` on PATH), `ABLETON_BENCH_SUDO` (default `sudo`), `ABLETON_BENCH_SCENARIO_TOOL` (default `$root/profiler/control/scenario-run.py`).
- `structure`: `benchmark` only when `--sets` is absent/canonical and `--scenario` is absent; otherwise `diagnostic`. Passed to `init-run --structure … --trace-mode … --scenario …`.
- Preflight additions (after 167): tracer executable exists; privilege route = root helper on PATH else `"$sudo" -n true`, else `fail "tracing needs profiler-root-helper or passwordless sudo"`; `check-udp --port ${ABL_BENCH_OSC_SEND:-19001}`; scenario JSON validates (`scenario-run.py --validate NAME`); `profiler/sets/SHA256SUMS` checked when any chosen set lives there.
- Dry-run (179-188) prints `trace=<mode> privilege=<route> structure=<s> scenario=<name|none>` and N rows; banners `== %d/5` (344, 368) become `%d/${#sets[@]}`.
- Per-set flow (332-393): after `/abl/bench/play` (362) and before `sleep "$settle"` (363) call `trace_start` so the settle absorbs uprobe attach stalls; for Benchmark_Zero add `trace_start; sleep "$settle"` after `wait_log_quiet` (365). After `bench-run.sh` (380) and before `/abl/bench/stop` (381): `trace_stop`, then `python3 bench-report.py interface --set-dir "$set_dir"`. Scenario runs: `mode=scenario`, `osc=on`, pre-window `python3 "$scenario_tool" setup --scenario NAME`, and `capture_args+=(--scenario NAME --scenario-tool "$scenario_tool")`. `finish()` (315-326) calls `trace_stop` before `stop_owned_session`.
- `trace_start`: `mkdir -p "$set_dir/raw/interface"` as the user, then either `"$root_helper" trace start --tool wine-trace --run-dir … -- --pid … --out DIR --mode summary|drilldown` or `"$sudo" -n -- "$tracer" start …` (repeat `--pid` for every owned PID from `wait_for_owned_live`, 348); `trace_stop`: same route with `stop --out DIR`. Contract: `start` returns after attaching and writes `tracer.json` with `started_monotonic_ns`; `stop` flushes and writes `stopped_monotonic_ns`, `lost_events`; output files readable by the invoking user; summary mode ↔ suite `interface`.
- `bench-run.sh`: accept `scenario` in the mode check (64) and pass through `--scenario`/`--scenario-tool`/`--set-sha256` (the suite computes `sha256sum "$set_file"`).

**`scripts/bench-report.py`:**

- `capture` (1761-2013): new args `--scenario`, `--scenario-tool`, `--set-sha256`, `--trace-mode`; `--mode` choices gain `scenario` (3416). When `--scenario` is set append `TimedCommand("scenario", [sys.executable, tool, "run", "--scenario", name, "--duration", str(duration)], raw, start_ns)` next to the osc command (1804-1807); the driver prints `offset_seconds\tmarker\tNAME` lines → `raw/scenario.tsv`. Record `measurement["scenario"] = {"name", "kind": benchmark|diagnostic, "file", "sha256", "markers": [...]}`, `measurement["set_file"] = {"path", "sha256"}`, `measurement["trace"] = {"mode", "directory": "raw/interface"}` and `measurement["interface"] = None` placeholder. Skip `playback_state_confounder` when mode is `scenario` (1885). The four collector-name sites become one tuple `COLLECTORS = ("pw-top", "pw-metadata", "osc")` plus `"scenario"` when a scenario ran: capture confounders (1888), `measurement_confounders` (2820), `set_metric_values` (2915); the edge set (2752) unchanged. Evidence map (1990-2010) gains `scenario` and `interface_*` paths.
- The tracer is **shell-started, not a TimedCommand**. Window filtering is clock-safe because `window.monotonic_start_ns/deadline_ns` are `time.monotonic_ns()` = CLOCK_MONOTONIC, the same clock as the tracer's `monotonic_start_ns`.
- New subcommand `interface --set-dir DIR [--near-late-fraction 0.15] [--top 20]`: reads `measurement.json` + `raw/interface/{blocks,threads}.jsonl` + `tracer.json` (+ `summary.json` if present), keeps blocks with `window.start ≤ t_start < deadline`, rewrites `measurement["interface"]` (atomic `dump_json`), exit 2 if the tracer files are missing while `trace.mode != off` (adds confounder `interface-tracer-output-missing`).
- `measurement["interface"]` shape:

```json
{"schema": "ableton-linux-interface/v1", "mode": "interface",
 "tracer": {"version": "…", "mode": "summary", "sample_rate": 64, "attach": ["…"], "lost_events": 0,
            "overhead": {}, "started_offset_seconds": -5.1, "stopped_offset_seconds": 30.4, "coverage_complete": true},
 "evidence": {"blocks": "raw/interface/blocks.jsonl", "threads": "raw/interface/threads.jsonl",
              "tracer": "raw/interface/tracer.json", "stacks": "raw/interface/stacks.jsonl"},
 "window": {"blocks_in_file": 16000, "blocks_in_window": 14062},
 "thresholds": {"near_late_fraction": 0.15, "deadline_ns_mode": 1333333, "near_late_slack_ns": 200000},
 "blocks": {"count": 14062, "late": 3, "near_late": 41, "late_per_minute": 6.0,
            "slack_ns": {"min": -210000, "p01": 150000, "p50": 900000, "p99": 1100000},
            "elapsed_ns": {"p50": 430000, "p99": 1180000, "max": 1540000},
            "deadline_ns": {"min": 1333333, "max": 1333333}},
 "lost_slack": {"definition": "sum over late and near-late blocks of (near_late_slack_ns - slack_ns)",
                "total_ns": 2100000, "attributed_ns": 1900000, "unattributed_ns": 200000},
 "call_sites": [{"rank": 1, "key": "ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1",
                 "kind": "ntsync_wait", "name": "NtWaitForSingleObject", "caller": "ntdll+0x7f3a1 <- Ableton Live 12 Trial.exe+0x1a2b3c",
                 "late_blocks": 3, "near_late_blocks": 20, "n_in_late_blocks": 12, "per_late_block": 4.0,
                 "total_ns_in_late_blocks": 540000, "max_ns": 210000, "share_of_lost_slack": 0.62,
                 "n_all_blocks": 28124, "total_ns_all_blocks": 1200000000,
                 "woken_by": [{"tid": 1234, "role": "audio_worker", "count": 10}]}],
 "kinds": {"syscall": {"n": 0, "total_ns": 0}, "unixcall": {}, "server_req": {}, "ntsync_wait": {}},
 "roles": {"audio_worker": {"bins": 300, "crossings_per_100ms": {"p50": 40, "p99": 110}, "total_ns_per_100ms": {}},
           "main": {}, "loader": {}},
 "hotspots_non_audio": [{"role": "main", "kind": "server_req", "caller": "…", "n": 1800, "total_ns": 90000000}],
 "confounders": []}
```

  Confounders from this section (also emitted by `measurement_confounders` with the `before:`/`after:` prefix): `interface-tracer-coverage-incomplete`, `interface-lost-events`, `interface-tracer-output-missing`.
- `render` (`markdown_report`, 2356-2553): after the Results table (2442) and before "Run details" (2471) add `## Interface crossings` with one `### <Set>` block per set that has `interface`: a bullet line (`blocks, late, near-late, slack p01, lost slack attributed %`, tracer coverage) and the table `| Rank | Crossing | Caller | Per late block | Share of lost slack |` (rows start with `| 1 |`, so the 18-pipe assertion on `| Benchmark_Zero |` rows, `test-bench-report.py:1087-1090`, is untouched). Header bullets gain `- Trace: <mode>`, `- Structure: <s>`, `- Scenario: <name>` from `run.json`. `report.json` already embeds every measurement (3334-3342).
- `profile` (2115-2301): add `"virt": ["systemd-detect-virt"]` to the command dict (2133-2152) and `system.virtualization = {"detector": "systemd-detect-virt", "value": stdout.strip() or "unknown", "dmi_product": /sys/class/dmi/id/product_name, "timing_claims_allowed": value == "none"}` (the tool exits 1 for "none"; `command_capture` records returncodes). `IDENTITY_SPECS` (2662-2693) gains `("virtualization", "Virtualization", ("system", "virtualization", "value"), True)`. `markdown_report` and `comparison_markdown` print `> NO TIMING CLAIMS: this run executed under <value>; use it for mechanism and tooling evidence only.` when either side is not `none`.
- `init-run` (2304-2344): new `--structure benchmark|diagnostic`, `--trace-mode`, `--scenario`; `run.json` gains `"structure"`, `"trace": {"mode", "tracer", "privilege"}`, `"scenario"`.
- `compare`: `load_completed_run(path, structure)` (2566-2624) keeps the canonical checks for `benchmark`; `--structure diagnostic` accepts any identical `set_order`, identical `scenario`, duration ≥ 10. `comparison_report` (2930-3003) adds beside the duration `ValueError` (2931-2936): `if (before trace mode or "off") != (after trace mode or "off"): raise ValueError("trace mode mismatch: before=…, after=…; traced and untraced runs are not comparable")` (hard, exit 2 via 3311-3313) and, next to the `harness` identity (2937-2941), `identity_comparison("trace", "Interface tracer", before_run["trace"], after_run["trace"])` (soft `identity:trace:different`). Per set: `interface` key with `metric_comparison` for `late_blocks, near_late_blocks, slack_p01_ns, lost_slack_total_ns, tracer_lost_events`, plus `call_sites: [{key, before, after, delta_total_ns_in_late_blocks, delta_share}]` joined on `key`, and `appeared/disappeared` lists; `set-identity:set-file` when `set_file.sha256` differs. `comparison.md` gains `## Interface crossings` (top-N by |delta share|).
- New subcommand `interface-drilldown --run-dir DIR --set NAME --top N [--output FILE]`: lists the N latest blocks (most negative slack) with their crossing timeline and, in drilldown mode, the matching `stacks.jsonl` entries; Markdown to stdout. `annotate --set-name` keeps `choices=CANONICAL_SETS` (3472).
- Harness hash: `bench-report.py`, `bench-suite.sh`, `bench-run.sh`, `bench-osc.py` all change → comparisons against pre-change runs show `identity:harness:different` (soft) — expected. No CSV schema change.

---

## C. Scenarios — `profiler/scenarios/*.json` + `profiler/control/scenario-run.py`

Schema (`SCHEMA.md`, validated by `scenario-run.py --validate` and `tests/test_scenarios.py`, stdlib checks):

```json
{"schema": "ableton-linux-scenario/v1", "name": "clip-launch-storm", "kind": "benchmark",
 "base_set": "bench/BenchmarkSets Project/Benchmark_Inbuilts.als",
 "requires": {"control_surface": true, "max_for_live": false, "plugins": []},
 "setup": [{"op": "stop"}, {"op": "rewind"}, {"op": "set_tempo", "bpm": 120.0}, {"op": "marker", "name": "setup-done"}],
 "timeline": {"period_s": 0.5, "steps": [{"at_s": 0.0, "op": "play"}, {"at_s": 0.5, "op": "fire_scene", "scene": 0}, {"at_s": 1.0, "op": "fire_scene", "scene": 1}],
              "repeat": true, "marker_every_s": 5.0},
 "teardown": [{"op": "stop"}]}
```

Ops → OSC: `play/stop/rewind` → `/abl/bench/*`; `set_tempo` → `/live/song/set/tempo`; `fire_clip` → `/live/clip/fire`; `fire_scene` → `/live/scene/fire`; `set_param` → `/live/device/set/parameter/value`; `create_midi_track/create_audio_track/delete_track` → `/live/song/*`; `create_clip` → `/live/clip_slot/create_clip`; `add_notes` → `/live/clip/add/notes`; `show_view` → `/abl/bench/show-view`; `load_device` → `/abl/bench/load-device`; `marker` → `/abl/bench/scenario-marker` (echoed with Live song time into `osc.tsv`); `sleep`. `run` phase is fire-and-forget (no replies, never binds 11001), logs `offset\tmarker\tname` and `offset\top\t…` to stdout, honours `--duration` and SIGTERM, and emits a final `end` marker; `setup` runs pre-window and may `query`. Commands are processed by AbletonOSC in 100 ms ticks, so 20 Hz param sweeps arrive bunched — documented.

| Name | Kind | Base set | Load exercised |
|---|---|---|---|
| `idle-playing` | benchmark | each canonical set | the canonical protocol expressed as a scenario (rewind, play) |
| `clip-launch-storm` | benchmark | Benchmark_Inbuilts | scene/clip fires every 500 ms |
| `param-sweep` | benchmark | Benchmark_Inbuilts | N device params at 20 Hz → automation + UI redraw |
| `tempo-ramp` | benchmark | Benchmark_Inbuilts | tempo 90→150→90 in 1 BPM steps every 250 ms |
| `track-churn` | diagnostic | Benchmark_Empty | create/delete MIDI track every 2 s → loader, heap, wineserver |
| `view-flip` | diagnostic | Benchmark_Inbuilts | `show_view` Session/Arranger/Detail each second → d2d/UI |
| `load-devices` | diagnostic | Benchmark_Empty | `load_device` of N instruments → browser/loader |

Benchmark-grade = fixed schedules, no browser, no track creation; compare-able only via `compare --structure diagnostic` with identical scenario/sets/duration/trace mode. Diagnostic = report-only.

Base sets: the restored canonical sets. New minimal sets: in demo mode build them live each run from `Benchmark_Empty` via `setup` ops; when saving is allowed (VERIFY), `profiler/bin/make-set --from Benchmark_Empty --build load-devices --save-as profiler/sets/Bench_Devices.als` builds via OSC then saves with `liveinject.exe` (Ctrl+Shift+S + `type <path>`; LOM has no save API), then `profiler/bin/sets freeze` regenerates `profiler/sets/SHA256SUMS`; preflight runs `sha256sum -c` on it.

---

## D. Agent loop

**`CLAUDE.md`** (fork root):

- *What this repo is* — Wine runtime + launcher for Live on Linux; `profiler/` is the local optimisation workbench (not upstream).
- *Project map* — `scripts/ableton-live` (launcher, env knobs), `scripts/bench-*.{sh,py}` (suite), `bench/` (restored, local-only), `profiler/{control,scenarios,tracer,dev,bin,history,dashboard}`, `patches/` (Wine series ends at 0107 → 0108+; `performance/` locked to 0001 by `scripts/test-release-policy.sh:403-440`; `pipeasio/` ends at 0016 → 0017+), `tools/` (PE probes, PASS/FAIL/SKIP, exit = FAIL count), `notes/` (one trial = one note: Result / Scope / Verification).
- *Exact commands* — restore state `profiler/bin/state restore`; install control `profiler/control/install.sh --prefix "$ABLETON_WINEPREFIX"`; smoke `profiler/control/smoke-test.sh`; dev loop `profiler/dev/wine-dev.sh init|apply|build|sync` then `ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev profiler/bin/bench …`; full build `profiler/dev/build-official.sh` (15–25 min+); traced run `profiler/bin/bench --tag … --trace interface`; scenario run `--scenario NAME --sets Inbuilts`; A/B `scripts/bench-report.py compare --before … --after … --output …`; drill-down `bench-report.py interface-drilldown --run-dir … --set … --top 10`; history `profiler/bin/history-add RUN_DIR`; tests `make test` and `make test-profiler`; log every long command with `set -o pipefail; … 2>&1 | tee ~/.local/state/profiler/logs/<ts>-<what>.log`.
- *Guardrails* — never modify Live's installation, Preferences, Options.txt or sets by hand; restore the golden state before every trial; one hypothesis per trial; every change = opt-in env switch (default off) + PE probe in `tools/` + note in `notes/`; never make a fix default; root only through `profiler-root-helper` allowlisted verbs (bare metal) or `sudo -n` for the tracer (VM); never `git add -A` after a build; never write non-ignored files during `build.sh`; new Wine patch = next number (0108+), update `REQUIRED_WINE_TAIL` (`scripts/build-audit.sh:13`), a `FINGERPRINTS`/`STAMP_ONLY` entry (351-424), `scripts/build-audit.sh --freeze`, and `make test` must pass (CHANGELOG heading must equal VERSION if VERSION changes, `test-release-policy.sh:54-58`); commit each trial on its own branch `trial/T<id>-<slug>` with the ledger line and history files in the same commit; no timing claims from a virtualised host; never run `liveosc.py` queries during a measurement window.
- *Acceptance rule* — untraced interleaved ABAB, n ≥ 3 pairs, after one A/A pair for spread; accept only if the median improvement in the primary metric > 2× the A/A spread and no set regresses beyond the A/A spread; then one traced run per arm to confirm the mechanism; PipeWire errors/xruns = automatic reject.
- *Stop criteria* — time budget (`--budget-hours`, default 6), K = 3 consecutive `revert|inconclusive` trials, 2 consecutive build failures, any guardrail violation → stop and write the report.

**`profiler/AGENT-PROMPT.md`**: 1. Objective and priorities — (0) zero xruns / PipeWire `ERR` increments, (1) fewer late and near-late audio blocks (slack), (2) lower Live/Wine CPU per core; whole-app: also report `hotspots_non_audio` and UI-scenario findings. 2. Phase gate — read `profile.json.system.virtualization`; VM ⇒ verdicts limited to `tooling|mechanism-confirmed`; bare metal ⇒ A/B verdicts. 3. Loop — restore → baseline traced run (all sets + relevant scenarios) → pick the top call site by `share_of_lost_slack` not already in the ledger → hypothesis → change behind an opt-in switch (+ probe + note) → `make test` + probe PASS → A/A pair → ABAB ×3 untraced → traced confirmation → ledger line + `history-add` → commit on branch → next. 4. Ledger discipline — one JSON line per trial, append-only, run directories by relative path. 5. Report format — `profiler/bin/ledger-report` output + narrative.

**`profiler/ledger.jsonl`** (`ableton-linux-profiler-ledger/v1`):
```json
{"schema":"ableton-linux-profiler-ledger/v1","trial":"T0007","date":"2026-10-17T10:00:00Z","host":"bare-metal|vm:vmware",
 "branch":"trial/T0007-ntsync-wait-coalesce","hypothesis":"…",
 "evidence":[{"run":"20261016T120000Z-baseline","set":"Benchmark_VSTs","call_site":"ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1","share_of_lost_slack":0.62}],
 "change":{"kind":"wine-patch|pipeasio-patch|launcher|config","patch":"patches/0108-….patch","switch":"WINE_FOO=1","probe":"tools/fooprobe.c","note":"notes/ABLETON-WINE-FOO.md"},
 "probe_result":{"pass":5,"fail":0,"skip":1,"log":"…"},
 "runs":{"aa":[["runA1","runA2"]],"abab":[{"a":"run","b":"run"},{"a":"run","b":"run"},{"a":"run","b":"run"}],"traced":{"a":"run","b":"run"}},
 "metrics":{"primary":"late_blocks","per_set":{"Benchmark_VSTs":{"a_median":3,"b_median":1,"aa_spread":1,"delta":-2,"ratio_to_spread":2.0}},"xruns":{"a":0,"b":0},"cpu_live_pct":{"a":41.2,"b":39.9}},
 "traced_confirmation":{"call_site_share_before":0.62,"after":0.11},
 "verdict":"keep|revert|inconclusive|tooling|mechanism-confirmed","rationale":"…","commit":"abc1234","minutes":95}
```

**`profiler/bin/ledger-report`** (Python, stdlib): validates every line, renders Markdown: summary counts by verdict, a table (trial, date, host, hypothesis, switch, primary delta vs spread, verdict, commit), per-kept-trial comparison links, open hotspots = baseline call sites with no trial, and the virtualisation banner when any cited run is virtualised.

**Launch**: `.claude/commands/profiler-loop.md` containing `Follow @profiler/AGENT-PROMPT.md exactly. Arguments: $ARGUMENTS (budget-hours, K, host phase override).` — `/profiler-loop 6 3` from `cd ~/Projects/ableton-linux && claude`.

---

## E. Tests

- `scripts/test-bench-report.py`: fixtures `interface_blocks()` (12 JSON lines: 2 late, 3 near-late, 2 outside the window) and `interface_tracer()`; tests: window filtering and counts; ranking and `share_of_lost_slack` ≤ 1 with `unattributed_ns`; coverage confounder when `stopped_monotonic_ns < deadline`; `interface` subcommand rewrites `measurement.json`; `render` adds `## Interface crossings`, the 5-column table, and the `| Set | Mode |` header/`| Benchmark_Zero |` row still count 18 pipes; `compare` raises `ValueError("trace mode mismatch")`; same mode with different tracer version → `identity:trace:different`; per-set `interface.call_sites` deltas; `virtualization` identity + banner text; `scenario` mode skips `playback-state-changed`; `scenario` collector appears in confounders/metrics only when present; `bench-osc.decode` handles `T/F/b` tags; `--structure diagnostic` compare accepts a 2-set run and refuses mismatched scenarios.
- `scripts/test-bench-suite.sh` (fixture env at 33-49): fake `$bin/wine-trace` and `$bin/profiler-root-helper` (copies of `true`), `$bin/sudo-fail` (`exit 1`); `--dry-run --trace interface` prints `trace=interface privilege=root-helper`; with `ABLETON_BENCH_ROOT_HELPER=/nonexistent ABLETON_BENCH_SUDO=$bin/sudo-fail` it refuses; `--sets Zero,VSTs` → 2 rows and `structure=diagnostic`; `--scenario clip-launch-storm` → `mode=scenario`; unknown scenario refused; default run still prints 5 rows.
- `profiler/control/tests/test_bench_handler.py`: fake `Live` module in `sys.modules`, fake manager (`osc_server.add_handler/send` recorders, `schedule_message` recorder, `song` with `start_playing/stop_playing/current_song_time/is_playing/add_is_playing_listener`); asserts all addresses registered, pong echo, play/stop/rewind calls, `cpu-period 0` cancels, `-1 -1` when the attribute raises, `ready 1`, `playing` listener, marker echo, subscribe fan-out, `clear_api` removes the listener.
- `profiler/control/tests/test_liveosc.py`: loopback fake server on ephemeral ports; `wait_ready` nonce matching; timeout message names the Control Surface step; CLI argument typing.
- `profiler/scenarios/tests/test_scenarios.py`: every JSON validates; ascending `at_s`; known ops; benchmark-grade scenarios contain no `load_device/create_*/delete_*/show_view`.
- `profiler/bin/tests/test-ledger-report.py`: valid/invalid lines; verdict counts; banner.
- `Makefile`: `test-profiler` target running the above plus `test-bench`; append to `test` (CI runs `make test`). `.gitignore`: `profiler/runs/`, `profiler/control/vendor/AbletonOSC/logs/`.

---

## VERIFY (in order of risk)

1. `Live.Application.get_application().average_process_usage` / `peak_process_usage` exist on Live 12.4.x Python and their unit (percent vs 0–1) → `/abl/bench/info` + smoke test vs the CPU meter; set `CPU_SCALE`.
2. `ControlSurface.schedule_message(ticks, callback)` semantics (one-shot, 100 ms ticks, main thread) in Live 12; fallback `Live.Base.Timer(callback=…, interval=…, repeat=True)` ctor signature.
3. `/live/api/reload` reloads the new `abletonosc.bench` module; otherwise restart Live during handler development.
4. User Library location inside the prefix (`Documents` symlink vs real dir); Python version in Live 12's Remote Script runtime (expected 3.11 — avoid 3.12+ syntax).
5. `Browser.load_item` semantics: loads onto `song.view.selected_track`, asynchronous device appearance → poll `/live/track/get/num_devices`.
6. `available_main_views()` names on Live 12 (`Browser`, `Arranger`, `Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`).
7. Trial status on the VM (saving sets; Max for Live availability for Benchmark_Max4Live).
8. Tracer contract: `start/stop` verbs, `tracer.json` fields, file ownership, multiple `--pid` handling, `caller` string format used as the join key.
9. `profiler-root-helper trace start|stop` argument pass-through matches the same verbs.
10. python-osc emits `T/F` for Python bools in `/live/*` replies (decoder extension).

Critical files: `scripts/bench-suite.sh` (lines 12, 133-175, 179-188, 332-396), `scripts/bench-report.py` (capture 1761-2013, `interface` subcommand, `markdown_report` 2356-2553, `load_completed_run`/`comparison_report`/`IDENTITY_SPECS` 2566-3003, `profile` 2115-2301, parser 3410-3479), `scripts/bench-osc.py` (port defaults 27-28, `encode/decode` 37-79), `profiler/control/overlay/abletonosc/bench.py`, `scripts/test-bench-report.py` and `scripts/test-bench-suite.sh` (fixtures 38-220, dry-run harness 33-75), `Makefile` (22-48).
