# Scenario files — `ableton-linux-scenario/v1`

A scenario is one JSON file `profiler/scenarios/NAME.json` that tells
`profiler/control/scenario-run.py` what to send to Live before, during and
after a measurement window. `scenario-run.py --validate NAME` and
`profiler/scenarios/tests/test_scenarios.py` enforce every rule below;
`bench-suite.sh --scenario NAME` runs `setup` before the window and
`bench-report.py capture` runs `run` inside it.

## Document

| Key | Type | Rule |
|---|---|---|
| `schema` | string | exactly `ableton-linux-scenario/v1` |
| `name` | string | `^[a-z][a-z0-9-]*$`, equal to the file name without `.json` |
| `kind` | string | `benchmark` or `diagnostic` (see "Benchmark grade") |
| `base_set` | string | the set the schedule was written against: `Benchmark_Zero`, `Benchmark_Empty`, `Benchmark_Inbuilts`, `Benchmark_Max4Live`, `Benchmark_VSTs` or `any`. The suite's `--sets` decides what runs; the driver does not check it |
| `description` | string | optional free text |
| `requires` | object | `control_surface` (bool), `max_for_live` (bool), `plugins` (list of strings); recorded for the suite, not checked by the driver |
| `setup` | list of ops | sent before the window; may wait for replies |
| `timeline` | object | fired inside the window, see below |
| `teardown` | list of ops | sent after the final `end` marker |

No other keys are allowed. Files are UTF-8 with LF line endings.

## Ops

Every op is an object with `"op"` and the fields of its row; unknown fields
are errors. The driver sends each op as one OSC message through
`profiler/control/liveosc.py`; `/abl/bench/*` addresses are served by the
bench handler (`profiler/control/overlay/abletonosc/bench.py`), the others by
upstream AbletonOSC.

| `op` | Fields | OSC message | Phases |
|---|---|---|---|
| `play` | — | `/abl/bench/play` | all |
| `stop` | — | `/abl/bench/stop` | all |
| `rewind` | — | `/abl/bench/rewind` | all |
| `set_tempo` | `bpm` number 20–999 | `/live/song/set/tempo BPM` | all |
| `set_quantization` | `quantization` integer 0–13 (`Live.Song.Quantization`: 0 none, 4 one bar, 7 one quarter note) | `/live/song/set/clip_trigger_quantization Q` | all; benchmark: setup only |
| `fire_clip` | `track`, `clip` indices | `/live/clip/fire T C` | all |
| `fire_scene` | `scene` index | `/live/scene/fire S` | all |
| `set_param` | `track`, `device`, `param` indices, `value` number | `/live/device/set/parameter/value T D P V` | all |
| `create_midi_track` | `index` integer ≥ −1 (−1 appends) | `/live/song/create_midi_track I` | all; never in benchmark |
| `create_audio_track` | `index` integer ≥ −1 | `/live/song/create_audio_track I` | all; never in benchmark |
| `delete_track` | `index` index | `/live/song/delete_track I` | all; never in benchmark |
| `create_clip` | `track`, `clip` indices, `length` beats > 0 | `/live/clip_slot/create_clip T C L` (MIDI tracks, empty slot) | all; benchmark: setup only |
| `add_notes` | `track`, `clip`, `notes` list of `[pitch 0–127, start ≥ 0, duration > 0, velocity 0–127, mute 0 or 1]` | `/live/clip/add/notes T C (P S D V M)…` | all; benchmark: setup only |
| `show_view` | `view` text (`Session`, `Arranger`, `Detail/DeviceChain`, …) | `/abl/bench/show-view NAME` | all; never in benchmark |
| `load_device` | `kind` one of `instruments`, `audio_effects`, `plugins`, `max_for_live`; `name` text; optional `track` index | `/abl/bench/load-device KIND NAME [T]` | all; never in benchmark |
| `marker` | `name` marker name | `/abl/bench/scenario-marker NAME` (echoed with song time into `osc.tsv`) | all |
| `sleep` | `seconds` > 0 | nothing; the driver waits | setup only |

Field types: *index* is an integer ≥ 0; *number* is a finite JSON number;
*text* is a non-empty printable string without surrounding spaces that does
not parse as a number (the encoder sends numeric-looking strings as numbers);
*marker name* matches `^[a-z][a-z0-9-]*$` and is not `start`, `end` or
`at-…s`, which the driver emits itself. JSON integers travel as OSC `int32`
and fields typed *number* (`bpm`, `value`, `length`, note `start`, `duration`,
`velocity`) always travel as `float32`.

## Timeline

```json
"timeline": {"period_s": 2.0, "repeat": true, "marker_every_s": 5.0,
             "steps": [{"at_s": 0.0, "op": "fire_clip", "track": 1, "clip": 0},
                       {"at_s": 0.5, "op": "fire_clip", "track": 3, "clip": 0}]}
```

- `steps`: list, may be empty. Each step is an op plus `at_s`, seconds after
  the window start, ≥ 0 and non-decreasing in file order. Steps with equal
  `at_s` fire in file order.
- `repeat`: `true` or `false`. With `true`, `period_s` (> 0) is required,
  every `at_s` must stay below it, and cycle *n* fires each step at
  `n × period_s + at_s` until the duration ends. With `false`, `period_s`
  must be absent and the driver idles after the last step until the duration
  ends or SIGTERM arrives.
- `marker_every_s` (optional, > 0): the driver sends a marker named
  `at-<k×marker_every_s>s` (`%g` formatting: `at-5s`, `at-2.5s`) at every
  multiple inside the window.

Timing: offsets are `time.monotonic()` seconds since `run` started; the loop
wakes every 50 ms and fires late events immediately, so a step is never
skipped. AbletonOSC drains its socket once per 100 ms tick on Live's main
thread, so events closer than 100 ms arrive bunched (a 20 Hz sweep is handled
two steps per tick) and a slow handler delays everything behind it.

## Phases and output

`scenario-run.py setup --scenario NAME [--timeout S]` binds the reply port
(UDP 11001), pings until the bench handler answers, sends the `setup` ops in
order, waits for the echo of every `marker`, the `ok` of every `load_device`
and the reply of every `show_view`, then pings again: AbletonOSC handles
commands in order on one thread, so the pong proves that every op ran. Any
`/live/error` received meanwhile fails the setup (exit 1). Lines:
`offset<TAB>ready<TAB>…`, `offset<TAB>op<TAB>OP<TAB>MESSAGE`,
`offset<TAB>marker<TAB>NAME SONG_TIME IS_PLAYING`, `offset<TAB>reply<TAB>…`.
The suite runs setup before the window, so the reply port is free.

`scenario-run.py run --scenario NAME [--duration S]` never binds the reply
port (`bench-osc.py dump` owns it during the window) and never waits for
replies. It sends a `start` marker, fires the timeline, idles until
`--duration` or SIGTERM, sends an `end` marker and then the `teardown` ops.
Every event prints one line:

```
0.000312	marker	start
0.000401	op	fire_clip	/live/clip/fire 1 0
5.000198	marker	at-5s
30.000094	marker	end
30.000210	op	stop	/abl/bench/stop
```

`bench-report.py capture` prefixes each line with its own offset and stores
the result as `raw/scenario.tsv`; the `marker` lines are what it records
under `measurement.scenario.markers`, and the Live-side echoes
(`/abl/bench/scenario-marker NAME SONG_TIME IS_PLAYING`) land in
`raw/osc.tsv`.

Exit codes: 0 done (also after SIGTERM), 1 invalid scenario, Live error or
timeout, 2 usage.

## Benchmark grade

`kind: benchmark` scenarios keep a fixed schedule on a fixed set:
`load_device`, `create_midi_track`, `create_audio_track`, `delete_track` and
`show_view` are not allowed anywhere, and `create_clip`, `add_notes` and
`set_quantization` only in `setup`. They are comparable only through
`bench-report.py compare --structure diagnostic` with identical scenario,
sets, duration and trace mode. `kind: diagnostic` scenarios may use every
op; their reports are for mechanism evidence, not for A/B claims.

## Shipped scenarios

| Name | Kind | Base set | Load |
|---|---|---|---|
| `idle-playing` | benchmark | any | the canonical protocol (rewind, play) with markers every 5 s |
| `clip-launch-storm` | benchmark | Benchmark_Inbuilts | four MIDI clips created in setup on tracks 1 (Operator) and 3 (Wavetable), fired alternately every 500 ms with quarter-note quantization |
| `param-sweep` | benchmark | Benchmark_Inbuilts | three Drum Buss parameters (track 0, device 2) swept 0→1→0 at 20 Hz |
| `tempo-ramp` | benchmark | Benchmark_Inbuilts | tempo 90→150→90 in 1 BPM steps every 250 ms (30 s cycle) |
| `track-churn` | diagnostic | Benchmark_Empty | a MIDI track inserted at index 1 and deleted again every 2 s |
| `view-flip` | diagnostic | Benchmark_Inbuilts | Session, Arranger and Detail/DeviceChain shown in turn each second |
| `load-devices` | diagnostic | Benchmark_Empty | ten stock instruments and effects loaded from the browser, one every 3 s |

The canonical sets are arrangement sets with eight empty scenes, so clip
scenarios create their own session clips in `setup`; firing an empty scene
would stop the arrangement on every track. Device and parameter indices come
from the set files (`Benchmark_Inbuilts.als`: track 0 is "LD Core Kit" with
Drum Group, Hybrid Reverb and Drum Buss; track 1 is Operator, Roar,
Compressor; track 3 is Wavetable) and must be confirmed once against the
running Live with `liveosc.py query /live/device/get/parameters/name 0 2`.
