#!/usr/bin/env python3
"""BenchHandler and overlay manager tests against tests/fake_live.py; no Live,
no socket. Runs with `python3 -I -m unittest discover -s profiler/control/tests`
or directly as a script."""

import ast
import difflib
import importlib.util
import io
import os
import sys
import unittest
from pathlib import Path

# Keep vendor/ and overlay/ free of __pycache__: vendor.sh --check ignores it,
# but build.sh snapshots the tree.
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
CONTROL = HERE.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fake_live = load("fake_live", "fake_live.py")
package = fake_live.load_overlay()
bench = package.abletonosc.bench
Manager = package.manager.Manager

ADDRESSES = {
    "/abl/bench/" + name for name in (
        "ping", "play", "stop", "rewind", "poll", "cpu-period", "scenario-marker", "info",
        "views", "show-view", "focus-view", "load-device", "subscribe", "unsubscribe",
    )
}


class HandlerCase(unittest.TestCase):
    def setUp(self):
        self.song = fake_live.FakeSong()
        self.application = fake_live.install()
        self.manager = fake_live.FakeManager(self.song)
        self.server = self.manager.osc_server

    def make_handler(self):
        with self.manager.component_guard():
            return bench.BenchHandler(self.manager)

    def reports(self, address):
        return self.server.messages(address)

    def test_registers_every_bench_address(self):
        self.make_handler()
        self.assertEqual(set(self.server.handlers), ADDRESSES)

    def test_ready_and_default_cpu_period_at_init(self):
        handler = self.make_handler()
        self.assertEqual(self.reports("/abl/bench/ready"), [((1,), None)])
        self.assertTrue(handler.cpu_attribute_ok)
        self.assertEqual(handler.period_ticks, 5)
        self.assertEqual([entry[0] for entry in self.manager.scheduled], [5])
        self.assertEqual(len(self.song.listeners["is_playing"]), 1)

    def test_ready_0_and_minus_one_when_cpu_attribute_raises(self):
        self.application.usage_error = AttributeError("no average_process_usage")
        with self.assertLogs("abletonosc", "ERROR") as logged:
            handler = self.make_handler()
        self.assertEqual(self.reports("/abl/bench/ready"), [((0,), None)])
        self.assertFalse(handler.cpu_attribute_ok)
        self.assertTrue(any("bench: average_process_usage is unavailable" in line for line in logged.output))
        self.server.dispatch("/abl/bench/poll")
        self.assertEqual(self.reports("/abl/bench/cpu"), [((-1.0, -1.0), None)])
        # The attribute coming back later is picked up without a restart.
        self.application.usage_error = None
        self.server.dispatch("/abl/bench/poll")
        self.assertEqual(self.reports("/abl/bench/cpu")[-1][0], (0.25 * bench.CPU_SCALE, 0.5 * bench.CPU_SCALE))

    def test_pong_echoes_the_arguments(self):
        self.make_handler()
        self.assertIsNone(self.server.dispatch("/abl/bench/ping", "n0123abcd", 7, 2.5))
        self.assertEqual(self.reports("/abl/bench/pong"), [(("n0123abcd", 7, 2.5), None)])
        self.assertEqual(self.reports("/abl/bench/ping"), [])
        self.server.dispatch("/abl/bench/ping")
        self.assertEqual(self.reports("/abl/bench/pong")[-1], ((), None))

    def test_play_stop_rewind(self):
        self.make_handler()
        self.song.current_song_time = 7.5
        self.server.dispatch("/abl/bench/play")
        self.server.dispatch("/abl/bench/stop")
        self.assertEqual(self.song.calls, ["start_playing", "stop_playing"])
        self.server.dispatch("/abl/bench/rewind")
        self.assertEqual(self.song.current_song_time, 0.0)
        self.assertIsInstance(self.song.current_song_time, float)

    def test_playing_listener_reports_transitions(self):
        self.make_handler()
        self.song.start_playing()
        self.song.start_playing()
        self.song.stop_playing()
        self.assertEqual(self.reports("/abl/bench/playing"), [((1,), None), ((0,), None)])

    def test_poll_reports_scaled_cpu_as_floats(self):
        self.make_handler()
        self.application.average_process_usage = 0.125
        self.application.peak_process_usage = 0.75
        self.server.dispatch("/abl/bench/poll")
        (values, remote), = self.reports("/abl/bench/cpu")
        self.assertEqual(values, (0.125 * bench.CPU_SCALE, 0.75 * bench.CPU_SCALE))
        self.assertTrue(all(type(value) is float for value in values))
        self.assertIsNone(remote)

    def test_cpu_period_rearms_at_tick_resolution(self):
        handler = self.make_handler()
        self.manager.advance(4)
        self.assertEqual(self.reports("/abl/bench/cpu"), [])
        self.manager.advance(1)
        self.assertEqual(len(self.reports("/abl/bench/cpu")), 1)
        self.assertEqual([entry[0] for entry in self.manager.scheduled], [5])
        # A new period starts its own chain; the queued tick of the old one dies.
        self.server.dispatch("/abl/bench/cpu-period", 1000)
        self.assertEqual(handler.period_ticks, 10)
        self.assertEqual(sorted(entry[0] for entry in self.manager.scheduled), [5, 10])
        self.manager.advance(5)
        self.assertEqual(len(self.reports("/abl/bench/cpu")), 1)
        self.assertEqual([entry[0] for entry in self.manager.scheduled], [5])
        self.manager.advance(5)
        self.assertEqual(len(self.reports("/abl/bench/cpu")), 2)
        self.assertEqual([entry[0] for entry in self.manager.scheduled], [10])
        # 100 ms resolution with a one-tick floor; no argument means the default.
        self.server.dispatch("/abl/bench/cpu-period", 50)
        self.assertEqual(handler.period_ticks, 1)
        self.server.dispatch("/abl/bench/cpu-period", 250.0)
        self.assertEqual(handler.period_ticks, 2)
        self.server.dispatch("/abl/bench/cpu-period")
        self.assertEqual(handler.period_ticks, 5)

    def test_cpu_period_zero_cancels(self):
        handler = self.make_handler()
        self.server.dispatch("/abl/bench/cpu-period", 0)
        self.assertEqual(handler.period_ticks, 0)
        self.manager.advance(20)
        self.assertEqual(self.reports("/abl/bench/cpu"), [])
        self.assertEqual(self.manager.scheduled, [])

    def test_cpu_tick_survives_a_send_failure(self):
        self.make_handler()
        original = self.server.send
        failures = []

        def flaky_send(address, params=(), remote_addr=None):
            if address == "/abl/bench/cpu" and not failures:
                failures.append(address)
                raise OSError("network is unreachable")
            original(address, params, remote_addr)
        self.server.send = flaky_send
        with self.assertLogs("abletonosc", "ERROR") as logged:
            self.manager.advance(5)
        self.assertTrue(any("bench: cpu report failed" in line for line in logged.output))
        self.assertEqual([entry[0] for entry in self.manager.scheduled], [5])
        self.manager.advance(5)
        self.assertEqual(len(self.reports("/abl/bench/cpu")), 1)

    def test_marker_echoes_name_song_time_and_playing(self):
        self.make_handler()
        self.song.current_song_time = 4.0
        self.song.is_playing = True
        self.server.dispatch("/abl/bench/scenario-marker", "setup-done")
        self.assertEqual(self.reports("/abl/bench/scenario-marker"), [(("setup-done", 4.0, 1), None)])

    def test_info_fields(self):
        self.make_handler()
        self.server.dispatch("/abl/bench/info")
        (fields, _), = self.reports("/abl/bench/info")
        self.assertEqual(fields[:3], ("12.4.3", "%d.%d.%d" % sys.version_info[:3], 1))
        self.assertEqual(os.path.basename(fields[3]), "AbletonOSC")
        self.assertTrue(os.path.isfile(os.path.join(fields[3], "manager.py")))

    def test_views_show_view_focus_view(self):
        self.make_handler()
        self.server.dispatch("/abl/bench/views")
        self.assertEqual(self.reports("/abl/bench/views"), [(fake_live.MAIN_VIEWS, None)])
        self.server.dispatch("/abl/bench/show-view", "Arranger")
        self.server.dispatch("/abl/bench/focus-view", "Detail/Clip")
        self.assertEqual(self.application.view.shown, ["Arranger"])
        self.assertEqual(self.application.view.focused, ["Detail/Clip"])
        self.assertEqual(self.reports("/abl/bench/view"), [(("Arranger", 1), None), (("Detail/Clip", 1), None)])

    def test_load_device_selects_track_and_searches_depth_first(self):
        handler = self.make_handler()
        browser = self.application.browser
        self.server.dispatch("/abl/bench/load-device", "instruments", "Drum Rack", 1)
        self.assertIs(self.song.view.selected_track, self.song.tracks[1])
        self.assertEqual([item.name for item in browser.loaded], ["Drum Rack"])
        self.server.dispatch("/abl/bench/load-device", "plugins", "Dexed")
        self.assertEqual([item.name for item in browser.loaded], ["Drum Rack", "Dexed"])
        self.server.dispatch("/abl/bench/load-device", "instruments", "No Such Device")
        self.assertEqual(self.reports("/abl/bench/load-device"),
                         [(("Drum Rack", "ok"), None), (("Dexed", "ok"), None), (("No Such Device", "missing"), None)])
        self.assertEqual(set(handler.browser_index), {"instruments", "plugins"})
        self.assertFalse(any(item.name == "Drums" for item in handler.browser_index["instruments"].values()))
        with self.assertLogs("abletonosc", "ERROR") as logged:
            self.server.dispatch("/abl/bench/load-device", "sounds", "Kick")
        self.assertTrue(any("unknown browser root" in line for line in logged.output))
        self.assertEqual(len(self.reports("/abl/bench/load-device")), 3)

    def test_load_device_failure_drops_the_cached_index(self):
        handler = self.make_handler()
        self.server.dispatch("/abl/bench/load-device", "instruments", "Operator")
        self.assertIn("instruments", handler.browser_index)
        self.application.browser.load_error = RuntimeError("stale browser item")
        with self.assertLogs("abletonosc", "ERROR") as logged:
            self.server.dispatch("/abl/bench/load-device", "instruments", "Operator")
        self.assertTrue(any("bench: load-device failed: stale browser item" in line for line in logged.output))
        self.assertNotIn("instruments", handler.browser_index)

    def test_subscribe_fans_out_every_report(self):
        handler = self.make_handler()
        self.server.dispatch("/abl/bench/subscribe", 9001)
        self.server.dispatch("/abl/bench/subscribe", 9001)
        self.assertEqual(handler.subscribers, {("127.0.0.1", 9001)})
        self.server.dispatch("/abl/bench/poll")
        self.server.dispatch("/abl/bench/ping", "x")
        self.song.start_playing()
        for address in ("/abl/bench/cpu", "/abl/bench/pong", "/abl/bench/playing"):
            self.assertEqual([remote for _, remote in self.reports(address)], [None, ("127.0.0.1", 9001)])
        self.server.dispatch("/abl/bench/unsubscribe", 9001)
        self.server.dispatch("/abl/bench/poll")
        self.assertEqual([remote for _, remote in self.reports("/abl/bench/cpu")][2:], [None])

    def test_unreachable_subscriber_does_not_lose_the_default_report(self):
        self.make_handler()
        self.server.dispatch("/abl/bench/subscribe", 9002)
        original = self.server.send

        def send(address, params=(), remote_addr=None):
            if remote_addr == ("127.0.0.1", 9002):
                raise OSError("connection refused")
            original(address, params, remote_addr)
        self.server.send = send
        with self.assertLogs("abletonosc", "WARNING") as logged:
            self.server.dispatch("/abl/bench/poll")
        self.assertEqual(len(self.reports("/abl/bench/cpu")), 1)
        self.assertTrue(any("subscriber 127.0.0.1:9002 missed /abl/bench/cpu" in line for line in logged.output))

    def test_handler_errors_are_logged_not_raised(self):
        self.make_handler()

        def broken():
            raise RuntimeError("boom")
        self.song.start_playing = broken
        with self.assertLogs("abletonosc", "ERROR") as logged:
            self.assertIsNone(self.server.dispatch("/abl/bench/play"))
        self.assertEqual(logged.output[0], "ERROR:abletonosc:bench: play failed: boom")
        with self.assertLogs("abletonosc", "ERROR") as logged:
            self.server.dispatch("/abl/bench/show-view")
        self.assertIn("bench: show-view failed:", logged.output[0])
        self.assertEqual(self.reports("/abl/bench/view"), [])

    def test_clear_api_removes_listener_and_cancels_period(self):
        handler = self.make_handler()
        handler.clear_api()
        self.assertEqual(self.song.listeners["is_playing"], [])
        self.assertIsNone(handler.playing_listener)
        self.assertEqual(handler.period_ticks, 0)
        self.song.start_playing()
        self.manager.advance(10)
        self.assertEqual(self.reports("/abl/bench/playing"), [])
        self.assertEqual(self.reports("/abl/bench/cpu"), [])
        # A second clear_api (upstream calls it on every reload) is harmless.
        handler.clear_api()

    def test_reports_carry_only_int_float_str(self):
        self.make_handler()
        self.server.dispatch("/abl/bench/ping", "n1", 1, 1.5)
        self.server.dispatch("/abl/bench/poll")
        self.server.dispatch("/abl/bench/scenario-marker", "m")
        self.server.dispatch("/abl/bench/info")
        self.server.dispatch("/abl/bench/views")
        self.server.dispatch("/abl/bench/show-view", "Session")
        self.server.dispatch("/abl/bench/load-device", "audio_effects", "Reverb")
        self.song.start_playing()
        self.manager.advance(5)
        self.assertGreaterEqual(len(self.server.sent), 9)
        for address, params, _ in self.server.sent:
            self.assertTrue(address.startswith("/abl/bench/"), address)
            for value in params:
                self.assertIn(type(value), (int, float, str), (address, params))


class OverlayManagerCase(unittest.TestCase):
    """The overlay manager.py through the real Manager: registration, the
    /live/error relay and /live/api/reload."""

    def setUp(self):
        self.song = fake_live.FakeSong()
        fake_live.install()
        self.original_server = package.abletonosc.OSCServer
        package.abletonosc.OSCServer = fake_live.FakeOSCServer
        self.manager = Manager(fake_live.FakeCInstance(self.song))
        self.server = self.manager.osc_server

    def tearDown(self):
        self.manager.disconnect()
        self.manager.log_file_handler.close()
        package.abletonosc.OSCServer = self.original_server

    def bench_handlers(self):
        return [handler for handler in self.manager.handlers if handler.class_identifier == "bench"]

    def test_manager_registers_the_bench_handler(self):
        self.assertEqual(len(self.bench_handlers()), 1)
        self.assertIsInstance(self.bench_handlers()[0], bench.BenchHandler)
        self.assertTrue(ADDRESSES <= set(self.server.handlers))
        self.assertIn("/live/test", self.server.handlers)
        self.assertEqual(self.server.messages("/abl/bench/ready"), [((1,), None)])
        self.assertEqual(self.manager.scheduled[0][:1], [0])
        self.assertTrue(os.path.isfile(os.path.join(os.path.dirname(package.manager.__file__), "logs", "abletonosc.log")))

    def test_handler_error_reaches_live_error(self):
        def broken():
            raise RuntimeError("boom")
        self.song.start_playing = broken
        self.server.dispatch("/abl/bench/play")
        self.assertEqual(self.server.messages("/live/error"), [(("play failed: boom",), None)])

    def test_reload_replaces_the_bench_handler(self):
        old = self.bench_handlers()[0]
        old_class = type(old)
        self.manager.reload_imports()
        new = self.bench_handlers()[0]
        self.assertIsNot(new, old)
        self.assertIsNot(type(new), old_class)
        self.assertEqual(type(new).__name__, "BenchHandler")
        self.assertEqual(old.period_ticks, 0)
        self.assertIsNone(old.playing_listener)
        self.assertEqual(len(self.song.listeners["is_playing"]), 1)
        self.assertEqual(new.period_ticks, 5)
        self.assertIn("/abl/bench/ping", self.server.handlers)
        self.manager.advance(5)
        self.assertEqual(len(self.server.messages("/abl/bench/cpu")), 1)


class OverlaySourceCase(unittest.TestCase):
    def read(self, path):
        with io.open(path, encoding="utf-8", newline="") as handle:
            return handle.read()

    def test_overlay_manager_is_the_vendored_file_plus_three_lines(self):
        vendored = self.read(CONTROL / "vendor" / "AbletonOSC" / "manager.py")
        overlay = self.read(CONTROL / "overlay" / "manager.py")
        added = [line[1:] for line in difflib.unified_diff(vendored.split("\n"), overlay.split("\n"), lineterm="", n=0)
                 if line.startswith("+") and not line.startswith("+++")]
        removed = [line for line in difflib.unified_diff(vendored.split("\n"), overlay.split("\n"), lineterm="", n=0)
                   if line.startswith("-") and not line.startswith("---")]
        self.assertEqual(removed, [])
        self.assertEqual(added, ["from .abletonosc import bench",
                                 "                bench.BenchHandler(self),",
                                 "            importlib.reload(bench)"])

    def test_overlay_sources_are_lf_without_bom_and_3_11_syntax(self):
        for path in (CONTROL / "overlay" / "manager.py", CONTROL / "overlay" / "abletonosc" / "bench.py"):
            source = self.read(path)
            self.assertNotIn("\r", source, path)
            self.assertFalse(source.startswith("﻿"), path)
            ast.parse(source, filename=str(path), feature_version=(3, 11))


if __name__ == "__main__":
    unittest.main()
