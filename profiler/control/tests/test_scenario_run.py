#!/usr/bin/env python3
"""Driver tests: timeline timing with a fake clock, setup and run against a loopback fake."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_scenario_run():
    if hasattr(signal, "SIGPIPE"):
        return load("scenario_run", HERE.parent / "scenario-run.py")
    # Windows has no SIGPIPE; bench-osc.py installs the Unix default at import.
    with mock.patch.object(signal, "SIGPIPE", signal.SIGTERM, create=True), mock.patch.object(signal, "signal"):
        return load("scenario_run", HERE.parent / "scenario-run.py")


scenario_run = load_scenario_run()
liveosc = scenario_run.liveosc
osc = liveosc.osc
SCENARIOS = HERE.parents[1] / "scenarios"


def scenario(**overrides) -> dict:
    document = {
        "schema": "ableton-linux-scenario/v1", "name": "fixture", "kind": "benchmark", "base_set": "any",
        "requires": {"control_surface": True, "max_for_live": False, "plugins": []},
        "setup": [{"op": "stop"}, {"op": "rewind"}, {"op": "play"}],
        "timeline": {"period_s": 1.0, "repeat": True, "marker_every_s": 1.5, "steps": [
            {"at_s": 0.0, "op": "fire_clip", "track": 1, "clip": 0},
            {"at_s": 0.5, "op": "fire_scene", "scene": 2},
        ]},
        "teardown": [{"op": "stop"}],
    }
    document.update(overrides)
    return document


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class FakeLive:
    """Stand-in for AbletonOSC: receives on an ephemeral port, answers to the reply port."""

    def __init__(self) -> None:
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.05)
        self.port = self.socket.getsockname()[1]
        self.reply_port = free_port()
        self.received: list[tuple[str, list[object]]] = []
        self.handlers: dict = {
            "/abl/bench/ping": lambda arguments: [("/abl/bench/pong", arguments)],
            "/abl/bench/scenario-marker": lambda arguments: [("/abl/bench/scenario-marker", [arguments[0], 0.0, 0])],
            "/abl/bench/load-device": lambda arguments: [("/abl/bench/load-device", [arguments[1], "ok"])],
            "/abl/bench/show-view": lambda arguments: [("/abl/bench/view", [arguments[0], 1])],
        }
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while not self.stopping.is_set():
            try:
                packet, _ = self.socket.recvfrom(65536)
            except socket.timeout:
                continue
            address, arguments = osc.decode(packet)
            self.received.append((address, arguments))
            handler = self.handlers.get(address)
            for reply_address, reply_arguments in (handler(arguments) if handler else ()):
                packet = osc.encode(reply_address, liveosc.wire_arguments(reply_arguments))
                self.socket.sendto(packet, ("127.0.0.1", self.reply_port))

    def addresses(self) -> list[str]:
        return [address for address, _ in self.received if address != "/abl/bench/ping"]

    def close(self) -> None:
        self.stopping.set()
        self.thread.join(timeout=1)
        self.socket.close()


class FakeClock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class Recorder:
    """Replaces liveosc.send: records the wire message without a socket."""

    def __init__(self) -> None:
        self.sent: list[liveosc.Message] = []
        self.lines: list[str] = []

    def send(self, address: str, *values: object) -> liveosc.Message:
        message = liveosc.Message(address, liveosc.wire_arguments(values))
        self.sent.append(message)
        return message

    def report(self, offset: float, kind: str, text: str) -> None:
        self.lines.append("%.6f\t%s\t%s" % (offset, kind, text))


def write_scenario(directory: str, document: dict) -> Path:
    path = Path(directory) / f"{document['name']}.json"
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return path


class TimelineTests(unittest.TestCase):
    def run_offline(self, document: dict, duration, stopped=lambda: False):
        recorder, clock = Recorder(), FakeClock()
        with mock.patch.object(liveosc, "send", recorder.send):
            fired = scenario_run.run_timeline(
                document, duration, report=recorder.report, clock=clock, sleep=clock.sleep, stopped=stopped,
            )
        return fired, recorder

    def test_repeating_timeline_fires_on_schedule_with_markers_and_end(self):
        fired, recorder = self.run_offline(scenario(), 3.0)
        self.assertEqual(recorder.lines, [
            "0.000000\tmarker\tstart",
            "0.000000\top\tfire_clip\t/live/clip/fire 1 0",
            "0.500000\top\tfire_scene\t/live/scene/fire 2",
            "1.000000\top\tfire_clip\t/live/clip/fire 1 0",
            "1.500000\tmarker\tat-1.5s",
            "1.500000\top\tfire_scene\t/live/scene/fire 2",
            "2.000000\top\tfire_clip\t/live/clip/fire 1 0",
            "2.500000\top\tfire_scene\t/live/scene/fire 2",
            "3.000000\tmarker\tend",
            "3.000000\top\tstop\t/abl/bench/stop",
        ])
        self.assertEqual(fired, 7)
        self.assertEqual(recorder.sent[0], ("/abl/bench/scenario-marker", ["start"]))
        self.assertEqual(recorder.sent[4], ("/abl/bench/scenario-marker", ["at-1.5s"]))
        self.assertEqual(recorder.sent[-2:], [
            ("/abl/bench/scenario-marker", ["end"]), ("/abl/bench/stop", []),
        ])

    def test_single_pass_timeline_idles_until_the_duration(self):
        document = scenario(timeline={"repeat": False, "steps": [
            {"at_s": 0.0, "op": "play"}, {"at_s": 0.2, "op": "fire_scene", "scene": 0},
        ]})
        fired, recorder = self.run_offline(document, 1.0)
        self.assertEqual(fired, 2)
        self.assertEqual(recorder.lines[1:], [
            "0.000000\top\tplay\t/abl/bench/play",
            "0.200000\top\tfire_scene\t/live/scene/fire 0",
            "1.000000\tmarker\tend",
            "1.000000\top\tstop\t/abl/bench/stop",
        ])

    def test_stop_request_ends_the_run_with_end_marker_and_teardown(self):
        sent: list = []
        recorder = Recorder()
        recorder.sent = sent
        clock = FakeClock()
        with mock.patch.object(liveosc, "send", recorder.send):
            fired = scenario_run.run_timeline(
                scenario(), None, report=recorder.report, clock=clock, sleep=clock.sleep,
                stopped=lambda: len(sent) >= 4,
            )
        self.assertEqual(fired, 3)
        self.assertEqual(recorder.lines[-2:], ["1.000000\tmarker\tend", "1.000000\top\tstop\t/abl/bench/stop"])

    def test_late_events_fire_immediately_without_skipping(self):
        recorder = Recorder()
        clock = FakeClock()

        def slow_sleep(seconds: float) -> None:
            clock.now += seconds + 0.4

        with mock.patch.object(liveosc, "send", recorder.send):
            fired = scenario_run.run_timeline(
                scenario(), 1.0, report=recorder.report, clock=clock, sleep=slow_sleep,
            )
        self.assertEqual(fired, 2)
        ops = [line.split("\t")[2] for line in recorder.lines if "\top\t" in line]
        self.assertEqual(ops, ["fire_clip", "fire_scene", "stop"])

    def test_timeline_events_are_ordered_and_endless_without_a_duration(self):
        timeline = scenario()["timeline"]
        timeline["marker_every_s"] = 0.5
        events = list(itertools.islice(scenario_run.timeline_events(timeline, None), 6))
        self.assertEqual([(at, order) for at, order, _ in events], [
            (0.0, 1), (0.5, 0), (0.5, 1), (1.0, 0), (1.0, 1), (1.5, 0),
        ])
        self.assertEqual(events[1][2], {"op": "marker", "name": "at-0.5s"})
        single = scenario(timeline={"repeat": False, "steps": [{"at_s": 0.0, "op": "play"}]})["timeline"]
        self.assertEqual(len(list(scenario_run.timeline_events(single, None))), 1)
        self.assertEqual(len(list(scenario_run.timeline_events(single, 0.0))), 0)


class CommandLineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.live = FakeLive()
        self.addCleanup(self.live.close)
        for name, value in (("SEND_PORT", self.live.port), ("RECV_PORT", self.live.reply_port), ("PING_INTERVAL", 0.02)):
            patcher = mock.patch.object(liveosc, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def main(self, argv: list[str]) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = scenario_run.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_resolve_names_and_paths(self):
        self.assertEqual(scenario_run.resolve("idle-playing"), SCENARIOS / "idle-playing.json")
        self.assertEqual(scenario_run.resolve("sets/custom.json"), Path("sets/custom.json"))
        self.assertEqual(scenario_run.resolve(str(Path(self.directory.name) / "x")), Path(self.directory.name) / "x")

    def test_validate_reports_shipped_and_broken_scenarios(self):
        code, stdout, _ = self.main(["--validate", "idle-playing"])
        self.assertEqual(code, 0)
        self.assertIn("valid benchmark scenario idle-playing", stdout)
        code, _, stderr = self.main(["--validate", "no-such-scenario"])
        self.assertEqual(code, 1)
        self.assertIn("no such scenario", stderr)
        broken = write_scenario(self.directory.name, scenario(name="broken", kind="smoke"))
        code, _, stderr = self.main(["--validate", str(broken)])
        self.assertEqual(code, 1)
        self.assertIn("kind: must be benchmark or diagnostic", stderr)
        broken.write_text("{", encoding="utf-8")
        code, _, stderr = self.main(["--validate", str(broken)])
        self.assertEqual(code, 1)
        self.assertIn("invalid JSON", stderr)
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            scenario_run.main([])
        self.assertEqual(caught.exception.code, 2)

    def test_run_fires_the_timeline_without_binding_the_reply_port(self):
        document = scenario(timeline={"period_s": 0.2, "repeat": True, "marker_every_s": 0.3, "steps": [
            {"at_s": 0.0, "op": "play"}, {"at_s": 0.1, "op": "fire_scene", "scene": 0},
        ]})
        path = write_scenario(self.directory.name, document)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as holder:
            holder.bind(("127.0.0.1", self.live.reply_port))
            started = time.monotonic()
            code, stdout, stderr = self.main(["run", "--scenario", str(path), "--duration", "0.5"])
            elapsed = time.monotonic() - started
        self.assertEqual((code, stderr), (0, ""))
        self.assertGreaterEqual(elapsed, 0.5)
        self.assertLess(elapsed, 2.0)
        rows = [line.split("\t") for line in stdout.splitlines()]
        self.assertEqual([row[1:] for row in rows], [
            ["marker", "start"],
            ["op", "play", "/abl/bench/play"],
            ["op", "fire_scene", "/live/scene/fire 0"],
            ["op", "play", "/abl/bench/play"],
            ["marker", "at-0.3s"],
            ["op", "fire_scene", "/live/scene/fire 0"],
            ["op", "play", "/abl/bench/play"],
            ["marker", "end"],
            ["op", "stop", "/abl/bench/stop"],
        ])
        offsets = [float(row[0]) for row in rows]
        for offset, scheduled in zip(offsets, (0.0, 0.0, 0.1, 0.2, 0.3, 0.3, 0.4, 0.5, 0.5)):
            self.assertGreaterEqual(offset, scheduled - 0.001)
            self.assertLess(offset, scheduled + 0.2)
        time.sleep(0.1)
        self.assertEqual(self.live.addresses(), [
            "/abl/bench/scenario-marker", "/abl/bench/play", "/live/scene/fire", "/abl/bench/play",
            "/abl/bench/scenario-marker", "/live/scene/fire", "/abl/bench/play",
            "/abl/bench/scenario-marker", "/abl/bench/stop",
        ])
        self.assertEqual(self.live.received[-2][1], ["end"])

    def test_run_refuses_an_invalid_scenario(self):
        path = write_scenario(self.directory.name, scenario(timeline={"repeat": True, "steps": []}))
        code, _, stderr = self.main(["run", "--scenario", str(path), "--duration", "1"])
        self.assertEqual(code, 1)
        self.assertIn("timeline.period_s: must be a number above 0 when repeat is true", stderr)
        self.assertEqual(self.live.received, [])

    @unittest.skipIf(sys.platform == "win32", "SIGTERM delivery needs a POSIX host")
    def test_sigterm_ends_the_run_with_end_marker_and_teardown(self):
        path = write_scenario(self.directory.name, scenario())
        environment = dict(os.environ, ABL_BENCH_OSC_SEND=str(self.live.port), ABL_BENCH_OSC_RECV=str(self.live.reply_port))
        process = subprocess.Popen(
            [sys.executable, "-I", str(HERE.parent / "scenario-run.py"), "run", "--scenario", str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        assert process.stdout is not None
        first = process.stdout.readline()
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual((process.returncode, stderr), (0, ""))
        rows = [line.split("\t") for line in (first + stdout).splitlines()]
        self.assertEqual(rows[0][1:], ["marker", "start"])
        self.assertEqual([row[1:] for row in rows[-2:]], [["marker", "end"], ["op", "stop", "/abl/bench/stop"]])

    def test_setup_confirms_every_command_and_waits_for_replies(self):
        document = scenario(kind="diagnostic", setup=[
            {"op": "stop"}, {"op": "rewind"}, {"op": "marker", "name": "clips-ready"},
            {"op": "load_device", "kind": "instruments", "name": "Operator", "track": 1},
            {"op": "show_view", "view": "Session"}, {"op": "sleep", "seconds": 0.01}, {"op": "play"},
        ])
        path = write_scenario(self.directory.name, document)
        code, stdout, stderr = self.main(["setup", "--scenario", str(path), "--timeout", "2"])
        self.assertEqual((code, stderr), (0, ""))
        kinds = [line.split("\t")[1:] for line in stdout.splitlines()]
        self.assertEqual(kinds, [
            ["ready", f"pong on UDP {self.live.reply_port}"],
            ["op", "stop", "/abl/bench/stop"],
            ["op", "rewind", "/abl/bench/rewind"],
            ["op", "marker", "/abl/bench/scenario-marker clips-ready"],
            ["marker", "clips-ready 0.0 0"],
            ["op", "load_device", "/abl/bench/load-device instruments Operator 1"],
            ["reply", "/abl/bench/load-device Operator ok"],
            ["op", "show_view", "/abl/bench/show-view Session"],
            ["reply", "/abl/bench/view Session 1"],
            ["op", "sleep", "0.01"],
            ["op", "play", "/abl/bench/play"],
            ["ready", "setup complete, 7 commands confirmed"],
        ])
        self.assertEqual(self.live.addresses(), [
            "/abl/bench/stop", "/abl/bench/rewind", "/abl/bench/scenario-marker",
            "/abl/bench/load-device", "/abl/bench/show-view", "/abl/bench/play",
        ])
        self.assertEqual(self.live.received[0][0], "/abl/bench/ping")
        self.assertEqual(self.live.received[-1][0], "/abl/bench/ping")

    def test_setup_fails_on_live_errors_missing_devices_and_silence(self):
        path = write_scenario(self.directory.name, scenario(setup=[{"op": "rewind"}, {"op": "marker", "name": "go"}]))
        self.live.handlers["/abl/bench/rewind"] = lambda arguments: [("/live/error", ["bench: boom"])]
        code, _, stderr = self.main(["setup", "--scenario", str(path), "--timeout", "2"])
        self.assertEqual(code, 1)
        self.assertIn("bench: boom", stderr)
        del self.live.handlers["/abl/bench/rewind"]
        self.live.handlers["/abl/bench/load-device"] = lambda arguments: [("/abl/bench/load-device", [arguments[1], "missing"])]
        path = write_scenario(self.directory.name, scenario(
            name="loader", kind="diagnostic",
            setup=[{"op": "load_device", "kind": "instruments", "name": "Nope"}],
        ))
        code, _, stderr = self.main(["setup", "--scenario", str(path), "--timeout", "2"])
        self.assertEqual(code, 1)
        self.assertIn("load_device instruments Nope: ['missing']", stderr)
        del self.live.handlers["/abl/bench/ping"]
        code, _, stderr = self.main(["setup", "--scenario", str(path), "--timeout", "0.1"])
        self.assertEqual(code, 1)
        self.assertIn("Control Surface", stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
