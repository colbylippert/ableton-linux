#!/usr/bin/env python3
"""Drive a benchmark scenario against Live through AbletonOSC.

Usage:
  scenario-run.py --validate NAME
  scenario-run.py setup --scenario NAME [--timeout SECONDS]
  scenario-run.py run --scenario NAME [--duration SECONDS]

NAME is a file in profiler/scenarios/ without the .json suffix, or a path to
a scenario file. profiler/scenarios/SCHEMA.md describes the format.

setup runs before the measurement window: it waits for the bench handler,
sends the setup commands, waits for the replies that confirm them and fails
when Live reports an error. run executes the timeline from its start time
and prints one line per event, "offset_seconds<TAB>marker<TAB>NAME" or
"offset_seconds<TAB>op<TAB>OP<TAB>MESSAGE", without waiting for replies: the
reply port belongs to bench-osc.py dump during the window. The run ends at
--duration or on SIGTERM with a final "end" marker followed by the teardown
commands.
"""

from __future__ import annotations

import argparse
import heapq
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import sys
import threading
import time
from typing import Callable, Iterator


HERE = Path(__file__).resolve().parent
SCENARIOS_DIR = HERE.parent / "scenarios"
SCENARIO_SCHEMA = "ableton-linux-scenario/v1"
KINDS = ("benchmark", "diagnostic")
BASE_SETS = ("any", "Benchmark_Zero", "Benchmark_Empty", "Benchmark_Inbuilts", "Benchmark_Max4Live", "Benchmark_VSTs")
DEVICE_KINDS = ("instruments", "audio_effects", "plugins", "max_for_live")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
PERIODIC_MARKER_RE = re.compile(r"^at-[0-9.]+s$")
RESERVED_MARKERS = ("start", "end")
POLL_SECONDS = 0.05


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


liveosc = load("liveosc", HERE / "liveosc.py")


class ScenarioError(Exception):
    """A scenario file is missing, unreadable or invalid, or setup failed."""


def looks_numeric(value: str) -> bool:
    # bench-osc.py encode() sends numeric-looking strings as numbers.
    try:
        float(value)
    except ValueError:
        return False
    return True


def number(value: object) -> bool:
    """must be a finite number"""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def positive(value: object) -> bool:
    """must be a number above 0"""
    return number(value) and value > 0


def index(value: object) -> bool:
    """must be an integer of 0 or more"""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def insert_index(value: object) -> bool:
    """must be an integer of -1 (append) or more"""
    return isinstance(value, int) and not isinstance(value, bool) and value >= -1


def tempo(value: object) -> bool:
    """must be a number between 20 and 999"""
    return number(value) and 20 <= value <= 999


def quantization(value: object) -> bool:
    """must be an integer between 0 and 13"""
    return index(value) and value <= 13


def text(value: object) -> bool:
    """must be a printable string without surrounding spaces that is not a number"""
    return (
        isinstance(value, str) and value != "" and value == value.strip()
        and value.isprintable() and not looks_numeric(value)
    )


def device_kind(value: object) -> bool:
    """must be one of instruments, audio_effects, plugins, max_for_live"""
    return value in DEVICE_KINDS


def marker_name(value: object) -> bool:
    """must match ^[a-z][a-z0-9-]*$ and not be start, end or at-...s"""
    return (
        isinstance(value, str) and bool(NAME_RE.match(value))
        and value not in RESERVED_MARKERS and not PERIODIC_MARKER_RE.match(value)
    )


def notes(value: object) -> bool:
    """must be a non-empty list of [pitch 0-127, start >= 0, duration > 0, velocity 0-127, mute 0|1]"""
    if not isinstance(value, list) or not value:
        return False
    for note in value:
        if not isinstance(note, list) or len(note) != 5:
            return False
        pitch, start, duration, velocity, mute = note
        if not (index(pitch) and pitch <= 127 and number(start) and start >= 0 and positive(duration)):
            return False
        if not (number(velocity) and 0 <= velocity <= 127 and mute in (0, 1) and not isinstance(mute, bool)):
            return False
    return True


# op -> (required fields, optional fields); every field names its check.
OPS: dict[str, tuple[dict[str, Callable[[object], bool]], dict[str, Callable[[object], bool]]]] = {
    "play": ({}, {}),
    "stop": ({}, {}),
    "rewind": ({}, {}),
    "set_tempo": ({"bpm": tempo}, {}),
    "set_quantization": ({"quantization": quantization}, {}),
    "fire_clip": ({"track": index, "clip": index}, {}),
    "fire_scene": ({"scene": index}, {}),
    "set_param": ({"track": index, "device": index, "param": index, "value": number}, {}),
    "create_midi_track": ({"index": insert_index}, {}),
    "create_audio_track": ({"index": insert_index}, {}),
    "delete_track": ({"index": index}, {}),
    "create_clip": ({"track": index, "clip": index, "length": positive}, {}),
    "add_notes": ({"track": index, "clip": index, "notes": notes}, {}),
    "show_view": ({"view": text}, {}),
    "load_device": ({"kind": device_kind, "name": text}, {"track": index}),
    "duplicate_all": ({}, {}),
    "marker": ({"name": marker_name}, {}),
    "sleep": ({"seconds": positive}, {}),
}
PHASES = ("setup", "timeline", "teardown")
PHASE_OPS = {
    "setup": set(OPS),
    "timeline": set(OPS) - {"sleep"},
    "teardown": set(OPS) - {"sleep"},
}
# A benchmark scenario keeps the set topology and the browser out of the
# window; it may still prepare clips before the window starts.
BENCHMARK_FORBIDDEN = {"load_device", "create_midi_track", "create_audio_track", "delete_track", "show_view",
                       "duplicate_all"}
BENCHMARK_SETUP_ONLY = {"create_clip", "add_notes", "set_quantization"}
TOP_KEYS = {"schema", "name", "kind", "base_set", "description", "requires", "setup", "timeline", "teardown"}
REQUIRED_TOP = TOP_KEYS - {"description"}
REQUIRES_KEYS = {"control_surface": bool, "max_for_live": bool, "plugins": list}
TIMELINE_KEYS = {"steps", "repeat", "period_s", "marker_every_s"}

SENDERS: dict[str, Callable[[dict], liveosc.Message]] = {
    "play": lambda step: liveosc.play(),
    "stop": lambda step: liveosc.stop(),
    "rewind": lambda step: liveosc.rewind(),
    "set_tempo": lambda step: liveosc.set_tempo(step["bpm"]),
    "set_quantization": lambda step: liveosc.set_quantization(step["quantization"]),
    "fire_clip": lambda step: liveosc.fire_clip(step["track"], step["clip"]),
    "fire_scene": lambda step: liveosc.fire_scene(step["scene"]),
    "set_param": lambda step: liveosc.set_param(step["track"], step["device"], step["param"], step["value"]),
    "create_midi_track": lambda step: liveosc.create_midi_track(step["index"]),
    "create_audio_track": lambda step: liveosc.create_audio_track(step["index"]),
    "delete_track": lambda step: liveosc.delete_track(step["index"]),
    "create_clip": lambda step: liveosc.create_clip(step["track"], step["clip"], step["length"]),
    "add_notes": lambda step: liveosc.add_notes(step["track"], step["clip"], step["notes"]),
    "show_view": lambda step: liveosc.show_view(step["view"]),
    "load_device": lambda step: liveosc.load_device(step["kind"], step["name"], step.get("track")),
    "duplicate_all": lambda step: liveosc.duplicate_all(),
    "marker": lambda step: liveosc.marker(step["name"]),
}


def validate_step(step: object, where: str, phase: str, kind: object) -> list[str]:
    if not isinstance(step, dict):
        return [f"{where}: must be an object"]
    op = step.get("op")
    if op not in OPS:
        return [f"{where}.op: unknown op {op!r}"]
    problems = []
    if op not in PHASE_OPS[phase]:
        problems.append(f"{where}.op: {op} is not allowed in {phase}")
    if kind == "benchmark":
        if op in BENCHMARK_FORBIDDEN:
            problems.append(f"{where}.op: {op} is not allowed in a benchmark scenario")
        elif op in BENCHMARK_SETUP_ONLY and phase != "setup":
            problems.append(f"{where}.op: {op} is allowed only in the setup of a benchmark scenario")
    required, optional = OPS[op]
    allowed = {"op", *required, *optional}
    if phase == "timeline":
        allowed.add("at_s")
    for key in sorted(set(step) - allowed):
        problems.append(f"{where}.{key}: unknown field for {op}")
    for key in required:
        if key not in step:
            problems.append(f"{where}.{key}: missing")
    for key, check in {**required, **optional}.items():
        if key in step and not check(step[key]):
            problems.append(f"{where}.{key}: {check.__doc__}")
    return problems


def validate_timeline(timeline: dict, kind: object) -> list[str]:
    problems = [f"timeline.{key}: unknown key" for key in sorted(set(timeline) - TIMELINE_KEYS)]
    steps = timeline.get("steps")
    repeat = timeline.get("repeat")
    period = timeline.get("period_s")
    if not isinstance(steps, list):
        problems.append("timeline.steps: must be a list")
        steps = []
    if not isinstance(repeat, bool):
        problems.append("timeline.repeat: must be true or false")
    if repeat is True and not positive(period):
        problems.append("timeline.period_s: must be a number above 0 when repeat is true")
    if repeat is not True and "period_s" in timeline:
        problems.append("timeline.period_s: only valid when repeat is true")
    if "marker_every_s" in timeline and not positive(timeline["marker_every_s"]):
        problems.append("timeline.marker_every_s: must be a number above 0")
    previous = None
    for position, step in enumerate(steps):
        where = f"timeline.steps[{position}]"
        problems += validate_step(step, where, "timeline", kind)
        if not isinstance(step, dict):
            continue
        at = step.get("at_s")
        if "at_s" not in step:
            problems.append(f"{where}.at_s: missing")
        elif not number(at) or at < 0:
            problems.append(f"{where}.at_s: must be a number of 0 or more")
        else:
            if previous is not None and at < previous:
                problems.append(f"{where}.at_s: must not decrease ({at:g} after {previous:g})")
            if repeat is True and positive(period) and at >= period:
                problems.append(f"{where}.at_s: must stay below period_s ({at:g} >= {period:g})")
            previous = at
    return problems


def validate(scenario: object, expected_name: str | None = None) -> list[str]:
    """Return every problem of a scenario document; an empty list means valid."""
    if not isinstance(scenario, dict):
        return ["scenario: must be a JSON object"]
    problems = [f"{key}: unknown key" for key in sorted(set(scenario) - TOP_KEYS)]
    problems += [f"{key}: missing" for key in sorted(REQUIRED_TOP - set(scenario))]
    if scenario.get("schema") != SCENARIO_SCHEMA:
        problems.append(f"schema: must be {SCENARIO_SCHEMA!r}")
    name = scenario.get("name")
    if not (isinstance(name, str) and NAME_RE.match(name)):
        problems.append("name: must match ^[a-z][a-z0-9-]*$")
    elif expected_name is not None and name != expected_name:
        problems.append(f"name: {name!r} does not match the file name {expected_name!r}")
    kind = scenario.get("kind")
    if kind not in KINDS:
        problems.append("kind: must be benchmark or diagnostic")
    if scenario.get("base_set") not in BASE_SETS:
        problems.append("base_set: must be a canonical set name or any")
    if "description" in scenario and not isinstance(scenario["description"], str):
        problems.append("description: must be a string")
    requires = scenario.get("requires")
    if not isinstance(requires, dict):
        problems.append("requires: must be an object")
    else:
        problems += [f"requires.{key}: unknown key" for key in sorted(set(requires) - set(REQUIRES_KEYS))]
        for key, expected in REQUIRES_KEYS.items():
            if not isinstance(requires.get(key), expected):
                problems.append(f"requires.{key}: must be a {expected.__name__}")
        if isinstance(requires.get("plugins"), list):
            problems += [
                f"requires.plugins[{position}]: must be a string"
                for position, plugin in enumerate(requires["plugins"]) if not isinstance(plugin, str)
            ]
    for phase in ("setup", "teardown"):
        steps = scenario.get(phase)
        if not isinstance(steps, list):
            problems.append(f"{phase}: must be a list")
            continue
        for position, step in enumerate(steps):
            problems += validate_step(step, f"{phase}[{position}]", phase, kind)
    timeline = scenario.get("timeline")
    if not isinstance(timeline, dict):
        problems.append("timeline: must be an object")
    else:
        problems += validate_timeline(timeline, kind)
    return problems


def resolve(name: str) -> Path:
    """NAME.json in profiler/scenarios, or a path to a scenario file."""
    if name.endswith(".json") or "/" in name or os.sep in name:
        return Path(name)
    return SCENARIOS_DIR / f"{name}.json"


def load_scenario(name: str) -> tuple[dict, Path]:
    path = resolve(name)
    try:
        scenario = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ScenarioError(f"no such scenario: {path}") from None
    except ValueError as error:
        raise ScenarioError(f"{path}: invalid JSON: {error}") from None
    problems = validate(scenario, path.stem)
    if problems:
        raise ScenarioError(f"{path}: invalid scenario:\n  " + "\n  ".join(problems))
    return scenario, path


def periodic_marker(at: float) -> dict:
    return {"op": "marker", "name": "at-%gs" % at}


def timeline_events(timeline: dict, duration: float | None) -> Iterator[tuple[float, int, dict]]:
    """Yield (at_s, order, step) in time order: cycles of steps and periodic markers.

    Markers sort before steps at the same time. Cycle n fires each step at
    n * period_s + at_s, so the schedule does not drift. Without a duration
    a repeating timeline is endless.
    """
    def steps() -> Iterator[tuple[float, int, dict]]:
        period = timeline.get("period_s") if timeline.get("repeat") else None
        cycle = 0
        while True:
            for step in timeline["steps"]:
                at = step["at_s"] + (cycle * period if period else 0.0)
                if duration is not None and at >= duration:
                    return
                yield at, 1, step
            if period is None or not timeline["steps"]:
                return
            cycle += 1

    def markers() -> Iterator[tuple[float, int, dict]]:
        every = timeline.get("marker_every_s")
        count = 1
        while every:
            at = count * every
            if duration is not None and at >= duration:
                return
            yield at, 0, periodic_marker(at)
            count += 1

    return heapq.merge(markers(), steps(), key=lambda event: (event[0], event[1]))


def emit(offset: float, kind: str, text: str) -> None:
    print("%.6f\t%s\t%s" % (offset, kind, text), flush=True)


def perform(step: dict) -> liveosc.Message:
    return SENDERS[step["op"]](step)


def run_timeline(
    scenario: dict,
    duration: float | None,
    send: Callable[[dict], object] = perform,
    report: Callable[[float, str, str], None] = emit,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    stopped: Callable[[], bool] = lambda: False,
) -> int:
    """Fire the timeline from clock() at entry; return the number of events fired.

    Late events fire immediately. The loop wakes every POLL_SECONDS to notice
    stopped(); the end marker and the teardown follow either way.
    """
    start = clock()

    def fire(step: dict) -> None:
        now = clock() - start
        message = send(step)
        if step["op"] == "marker":
            report(now, "marker", step["name"])
        else:
            report(now, "op", "%s\t%s" % (step["op"], message))

    fired = 0
    fire({"op": "marker", "name": "start"})
    for at, _, step in timeline_events(scenario["timeline"], duration):
        while not stopped():
            remaining = at - (clock() - start)
            if remaining <= 0:
                break
            sleep(min(remaining, POLL_SECONDS))
        if stopped():
            break
        fire(step)
        fired += 1
    while not stopped() and (duration is None or clock() - start < duration):
        remaining = POLL_SECONDS if duration is None else duration - (clock() - start)
        sleep(max(0.0, min(remaining, POLL_SECONDS)))
    fire({"op": "marker", "name": "end"})
    for step in scenario["teardown"]:
        fire(step)
    return fired


def run_command(scenario: dict, duration: float | None) -> int:
    stop = threading.Event()
    previous = {
        signum: signal.signal(signum, lambda signum, frame: stop.set())
        for signum in (signal.SIGTERM, signal.SIGINT)
    }
    try:
        run_timeline(scenario, duration, stopped=stop.is_set)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    return 0


def setup_command(scenario: dict, timeout: float) -> int:
    """Run the setup commands and confirm them before the window opens.

    AbletonOSC handles commands in order on one thread, so a pong after the
    last command proves that every command ran; any /live/error seen until
    then belongs to this setup.
    """
    start = time.monotonic()

    def offset() -> float:
        return time.monotonic() - start

    def first_argument_is(address: str, value: str) -> Callable[[str, list], bool]:
        return lambda reply_address, arguments: reply_address == address and arguments[:1] == [value]

    with liveosc.Replies() as replies:
        replies.sync(timeout)
        emit(offset(), "ready", "pong on UDP %d" % liveosc.RECV_PORT)
        for step in scenario["setup"]:
            op = step["op"]
            now = offset()
            if op == "sleep":
                emit(now, "op", "sleep\t%g" % step["seconds"])
                time.sleep(step["seconds"])
                continue
            message = perform(step)
            emit(now, "op", "%s\t%s" % (op, message))
            if op == "marker":
                reply = replies.wait(
                    first_argument_is("/abl/bench/scenario-marker", step["name"]),
                    "echo of marker %s" % step["name"], timeout,
                )
                emit(offset(), "marker", " ".join(str(value) for value in reply))
            elif op == "load_device":
                reply = replies.wait(
                    first_argument_is("/abl/bench/load-device", step["name"]),
                    "reply to load_device %s" % step["name"], timeout,
                )
                emit(offset(), "reply", "/abl/bench/load-device " + " ".join(str(value) for value in reply))
                if reply[1:2] != ["ok"]:
                    raise ScenarioError("load_device %s %s: %s" % (step["kind"], step["name"], reply[1:2] or "no status"))
            elif op == "show_view":
                reply = replies.wait(
                    first_argument_is("/abl/bench/view", step["view"]),
                    "reply to show_view %s" % step["view"], timeout,
                )
                emit(offset(), "reply", "/abl/bench/view " + " ".join(str(value) for value in reply))
        replies.sync(timeout)
        if replies.errors:
            raise ScenarioError("Live reported errors during setup:\n  " + "\n  ".join(replies.errors))
        emit(offset(), "ready", "setup complete, %d commands confirmed" % len(scenario["setup"]))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    root.add_argument("--validate", metavar="NAME", help="check a scenario file and exit")
    commands = root.add_subparsers(dest="command")
    setup = commands.add_parser("setup", help="run the setup commands before the window")
    setup.add_argument("--scenario", required=True, metavar="NAME")
    setup.add_argument("--timeout", type=liveosc.osc.positive, default=30.0,
                       help="maximum wait for the handler and for each reply in seconds")
    run = commands.add_parser("run", help="fire the timeline during the window")
    run.add_argument("--scenario", required=True, metavar="NAME")
    run.add_argument("--duration", type=liveosc.osc.positive,
                     help="seconds to run; without it the run ends on SIGTERM")
    return root


def main(argv: list[str] | None = None) -> int:
    root = parser()
    args = root.parse_args(argv)
    if args.validate is None and args.command is None:
        root.error("a command (setup, run) or --validate NAME is required")
    try:
        if args.validate is not None:
            scenario, path = load_scenario(args.validate)
            print("%s: valid %s scenario %s (%d setup, %d timeline, %d teardown commands)" % (
                path, scenario["kind"], scenario["name"], len(scenario["setup"]),
                len(scenario["timeline"]["steps"]), len(scenario["teardown"]),
            ))
            return 0
        scenario, _ = load_scenario(args.scenario)
        if args.command == "setup":
            return setup_command(scenario, args.timeout)
        return run_command(scenario, args.duration)
    except (ScenarioError, liveosc.LiveError, liveosc.LiveTimeout) as error:
        print(f"scenario-run: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
