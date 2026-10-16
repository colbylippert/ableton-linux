#!/usr/bin/env python3
"""Loopback tests for the AbletonOSC client; no Live or PipeWire session needed."""

from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import signal
import socket
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


def load_liveosc():
    if hasattr(signal, "SIGPIPE"):
        return load("liveosc", HERE.parent / "liveosc.py")
    # Windows has no SIGPIPE; bench-osc.py installs the Unix default at import.
    with mock.patch.object(signal, "SIGPIPE", signal.SIGTERM, create=True), mock.patch.object(signal, "signal"):
        return load("liveosc", HERE.parent / "liveosc.py")


liveosc = load_liveosc()
osc = liveosc.osc


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
        self.handlers: dict = {}
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
                self.send(reply_address, reply_arguments)

    def send(self, address: str, arguments: list) -> None:
        packet = osc.encode(address, liveosc.wire_arguments(arguments))
        self.socket.sendto(packet, ("127.0.0.1", self.reply_port))

    def send_later(self, delay: float, address: str, arguments: list) -> None:
        threading.Timer(delay, self.send, (address, arguments)).start()

    def wait_received(self, count: int, timeout: float = 2.0) -> list:
        deadline = time.monotonic() + timeout
        while len(self.received) < count and time.monotonic() < deadline:
            time.sleep(0.005)
        return list(self.received)

    def close(self) -> None:
        self.stopping.set()
        self.thread.join(timeout=1)
        self.socket.close()


def pong(arguments: list) -> list:
    return [("/abl/bench/pong", arguments)]


class LiveOSCTests(unittest.TestCase):
    def setUp(self) -> None:
        self.live = FakeLive()
        self.addCleanup(self.live.close)
        for name, value in (("SEND_PORT", self.live.port), ("RECV_PORT", self.live.reply_port), ("PING_INTERVAL", 0.02)):
            patcher = mock.patch.object(liveosc, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_ping_round_trip_uses_a_string_nonce(self):
        self.live.handlers["/abl/bench/ping"] = pong
        elapsed = liveosc.ping(timeout=2)
        self.assertGreaterEqual(elapsed, 0)
        self.assertLess(elapsed, 2)
        address, arguments = self.live.received[0]
        self.assertEqual(address, "/abl/bench/ping")
        self.assertEqual(len(arguments), 1)
        self.assertIsInstance(arguments[0], str)
        self.assertTrue(arguments[0].startswith("n"))

    def test_wait_ready_keeps_pinging_until_its_own_nonce_comes_back(self):
        pings = []

        def late_pong(arguments):
            pings.append(arguments)
            if len(pings) < 3:
                return [("/abl/bench/pong", ["nwrong"])]
            return pong(arguments)

        self.live.handlers["/abl/bench/ping"] = late_pong
        waited = liveosc.wait_ready(timeout=3)
        self.assertLess(waited, 3)
        self.assertGreaterEqual(len(pings), 3)

    def test_timeout_names_the_control_surface_step(self):
        with self.assertRaises(liveosc.LiveTimeout) as caught:
            liveosc.wait_ready(timeout=0.1)
        message = str(caught.exception)
        self.assertIsInstance(caught.exception, TimeoutError)
        self.assertIn("no /abl/bench/pong", message)
        self.assertIn("within 0.1s", message)
        self.assertIn(f"UDP 127.0.0.1:{self.live.reply_port}", message)
        self.assertIn("Control Surface", message)
        self.assertIn("Preferences > Link, Tempo & MIDI", message)
        self.assertIn("restart Live", message)

    def test_query_returns_the_reply_and_releases_the_port(self):
        self.live.handlers["/live/song/get/tempo"] = lambda arguments: [("/live/song/get/tempo", [120.0])]
        self.assertEqual(liveosc.query("/live/song/get/tempo", timeout=2), [120.0])
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", self.live.reply_port))

    def test_query_waits_for_the_reply_address_and_skips_other_reports(self):
        self.live.handlers["/abl/bench/show-view"] = lambda arguments: [
            ("/abl/bench/cpu", [1.5, 2.0]), ("/live/startup", []), ("/abl/bench/view", [arguments[0], 1]),
        ]
        reply = liveosc.query("/abl/bench/show-view", ["Session"], timeout=2, reply="/abl/bench/view")
        self.assertEqual(reply, ["Session", 1])

    def test_query_raises_on_a_relayed_live_error(self):
        self.live.handlers["/nope"] = lambda arguments: [("/live/error", ["Unknown OSC address: /nope"])]
        with self.assertRaises(liveosc.LiveError) as caught:
            liveosc.query("/nope", timeout=2)
        self.assertIn("Unknown OSC address: /nope", str(caught.exception))

    def test_query_times_out_without_a_reply(self):
        with self.assertRaises(liveosc.LiveTimeout) as caught:
            liveosc.query("/live/song/get/tempo", timeout=0.1)
        self.assertIn("reply /live/song/get/tempo to /live/song/get/tempo", str(caught.exception))

    def test_busy_reply_port_is_reported(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as holder:
            holder.bind(("127.0.0.1", self.live.reply_port))
            with self.assertRaises(liveosc.LiveError) as caught:
                liveosc.ping(timeout=0.1)
        self.assertIn("reply port", str(caught.exception))
        self.assertIn(str(self.live.reply_port), str(caught.exception))

    def test_typed_commands_keep_their_osc_types(self):
        expected = [
            (liveosc.play, (), "/abl/bench/play", []),
            (liveosc.stop, (), "/abl/bench/stop", []),
            (liveosc.rewind, (), "/abl/bench/rewind", []),
            (liveosc.set_tempo, (120,), "/live/song/set/tempo", [120.0]),
            (liveosc.set_quantization, (7,), "/live/song/set/clip_trigger_quantization", [7]),
            (liveosc.fire_clip, ("1", 2), "/live/clip/fire", [1, 2]),
            (liveosc.fire_scene, (3,), "/live/scene/fire", [3]),
            (liveosc.set_param, (0, 2, 8, 1), "/live/device/set/parameter/value", [0, 2, 8, 1.0]),
            (liveosc.create_midi_track, (-1,), "/live/song/create_midi_track", [-1]),
            (liveosc.create_audio_track, (1,), "/live/song/create_audio_track", [1]),
            (liveosc.delete_track, (1,), "/live/song/delete_track", [1]),
            (liveosc.create_clip, (1, 0, 4), "/live/clip_slot/create_clip", [1, 0, 4.0]),
            (liveosc.add_notes, (1, 0, [[60, 0, 0.5, 100, False], [62, 1, 0.25, 90, 1]]),
             "/live/clip/add/notes", [1, 0, 60, 0.0, 0.5, 100.0, 0, 62, 1.0, 0.25, 90.0, 1]),
            (liveosc.load_device, ("instruments", "Operator"), "/abl/bench/load-device", ["instruments", "Operator"]),
            (liveosc.load_device, ("audio_effects", "EQ Eight", 2), "/abl/bench/load-device", ["audio_effects", "EQ Eight", 2]),
            (liveosc.show_view, ("Detail/DeviceChain",), "/abl/bench/show-view", ["Detail/DeviceChain"]),
            (liveosc.marker, ("setup-done",), "/abl/bench/scenario-marker", ["setup-done"]),
        ]
        messages = [function(*arguments) for function, arguments, _, _ in expected]
        received = self.live.wait_received(len(expected))
        self.assertEqual(received, [(address, arguments) for _, _, address, arguments in expected])
        # Decoded values keep the wire type: floats stay float, ints stay int.
        for (_, wire), (_, _, _, want) in zip(received, expected):
            self.assertEqual([type(value) for value in wire], [type(value) for value in want])
        self.assertEqual(str(messages[3]), "/live/song/set/tempo 120.0")
        self.assertEqual(messages[12].arguments[2:7], ["60", "0.0", "0.5", "100.0", "0"])

    def test_wire_arguments_keep_bench_osc_types(self):
        self.assertEqual(
            liveosc.wire_arguments([True, False, 3, -1, 2.0, 1e16, 0.1, "x", "Detail/Clip"]),
            ["1", "0", "3", "-1", "2.0", "1e+16", "0.1", "x", "Detail/Clip"],
        )
        # 1e8 is exact in float32, so the round trip keeps the value as well as the type.
        _, decoded = osc.decode(osc.encode("/a", liveosc.wire_arguments([2.0, 7, 1e8])))
        self.assertEqual(decoded, [2.0, 7, 1e8])
        self.assertEqual([type(value) for value in decoded], [float, int, float])

    def test_listen_yields_reports_with_offsets(self):
        self.live.send_later(0.05, "/abl/bench/cpu", [1.5, 2.5])
        messages = list(liveosc.listen(0.3))
        self.assertIn(("/abl/bench/cpu", [1.5, 2.5]), [(address, arguments) for _, address, arguments in messages])
        for offset, _, _ in messages:
            self.assertGreaterEqual(offset, 0.0)
            self.assertLess(offset, 1.0)

    def test_cli_types_its_arguments(self):
        self.assertEqual(liveosc.main(["set-tempo", "128"]), 0)
        self.assertEqual(liveosc.main(["set-param", "0", "2", "8", "0.5"]), 0)
        self.assertEqual(liveosc.main(["add-notes", "1", "0", "60", "0", "0.5", "100", "0"]), 0)
        self.assertEqual(liveosc.main(["load-device", "instruments", "Operator", "1"]), 0)
        self.assertEqual(liveosc.main(["create-clip", "1", "0", "4"]), 0)
        self.assertEqual(self.live.wait_received(5), [
            ("/live/song/set/tempo", [128.0]),
            ("/live/device/set/parameter/value", [0, 2, 8, 0.5]),
            ("/live/clip/add/notes", [1, 0, 60, 0.0, 0.5, 100.0, 0]),
            ("/abl/bench/load-device", ["instruments", "Operator", 1]),
            ("/live/clip_slot/create_clip", [1, 0, 4.0]),
        ])
        self.assertIs(type(self.live.received[0][1][0]), float)
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            liveosc.main(["fire-clip", "1", "x"])
        self.assertEqual(caught.exception.code, 2)
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            liveosc.main(["load-device", "midi", "Operator"])
        self.assertEqual(caught.exception.code, 2)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(liveosc.main(["add-notes", "1", "0", "60", "0", "1"]), 2)
        self.assertIn("groups of PITCH START DURATION VELOCITY MUTE", stderr.getvalue())

    def test_cli_query_prints_the_reply_arguments(self):
        self.live.handlers["/live/device/get/parameter/name"] = (
            lambda arguments: [("/live/device/get/parameter/name", [*arguments, "Boom Amount"])]
        )
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = liveosc.main(["query", "/live/device/get/parameter/name", "0", "2", "8", "--timeout", "2"])
        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), "0 2 8 Boom Amount\n")
        self.assertEqual(self.live.received[0], ("/live/device/get/parameter/name", [0, 2, 8]))

    def test_cli_reports_timeouts_and_readiness(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(liveosc.main(["ping", "--timeout", "0.1"]), 1)
        self.assertTrue(stderr.getvalue().startswith("liveosc: no /abl/bench/pong"))
        self.assertIn("Control Surface", stderr.getvalue())
        self.live.handlers["/abl/bench/ping"] = pong
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(liveosc.main(["ping", "--timeout", "2"]), 0)
            self.assertEqual(liveosc.main(["wait-ready", "--timeout", "2"]), 0)
        lines = stdout.getvalue().splitlines()
        self.assertTrue(lines[0].startswith("pong after "))
        self.assertTrue(lines[1].startswith("ready after "))

    def test_cli_listen_prints_reports(self):
        self.live.send_later(0.05, "/abl/bench/cpu", [1.5, 2.5])
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(liveosc.main(["listen", "--duration", "0.3"]), 0)
        self.assertIn(" /abl/bench/cpu 1.5 2.5", stdout.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
