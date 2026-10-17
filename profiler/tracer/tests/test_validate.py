#!/usr/bin/env python3
"""Unit tests for profiler/tracer/validate.py.

Run from the repository root:  python3 -I -m unittest discover -s profiler/tracer/tests -v
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import validate as V  # noqa: E402

PID = 100
MAIN = 100
HELPER = 101
OTHER_PID = 200


def ev(tid, kind, id_, t, dur_ns, status=0, **extra):
    rec = {"t": t, "tid": tid, "pid": PID if tid in (MAIN, HELPER) else OTHER_PID, "kind": kind, "id": id_,
           "dur_ns": dur_ns, "status": status}
    rec.update(extra)
    return rec


def probe_events():
    """A synthetic traceprobe run: the seven phases of design B section 7."""
    recs = [{"type": "header", "threads": {str(MAIN): {"comm": "traceprobe.exe", "pid": PID},
                                           str(HELPER): {"comm": "traceprobe-help", "pid": PID},
                                           "300": {"comm": "traceprobe.exe", "pid": OTHER_PID}}}]
    t = 1.0
    for i in range(100):                                             # phase 1
        recs.append(ev(MAIN, "syscall", "NtYieldExecution", t, 500, 0 if i % 2 else 0x40000024))
        t += 1e-5
    for _ in range(200):                                             # phase 2 (numeric id too)
        recs.append(ev(MAIN, "syscall", "NtQueryPerformanceCounter", t, 300, 0, id_num=0x31))
        t += 1e-5
    for _ in range(50):                                              # phase 3
        recs.append(ev(MAIN, "syscall", "NtCreateEvent", t, 40000))
        recs.append(ev(MAIN, "server_req", "create_event", t + 5e-6, 20000))
        t += 1e-4
        recs.append(ev(MAIN, "syscall", "NtClose", t, 30000))
        recs.append(ev(MAIN, "server_req", "close_handle", t + 5e-6, 15000))
        t += 1e-4
    for _ in range(20):                                              # phase 4
        recs.append(ev(MAIN, "syscall", "NtWaitForSingleObject", t, 10_300_000, 0x102))
        recs.append(ev(MAIN, "ntsync_wait", "WAIT_ANY", t + 2e-6, 10_250_000, -110, count=1))
        t += 0.0105
    for _ in range(20):                                              # phase 5
        recs.append(ev(MAIN, "syscall", "NtWaitForSingleObject", t, 200_000, 0))
        recs.append(ev(MAIN, "ntsync_wait", "WAIT_ANY", t + 2e-6, 190_000, 0, count=1, woken_by={"tid": HELPER}))
        recs.append(ev(HELPER, "syscall", "NtSetEvent", t + 1e-4, 3000, 0))
        recs.append(ev(HELPER, "ntsync_wake", "EVENT_SET", t + 1.1e-4, 500, 0))
        t += 3e-4
    for _ in range(10):                                              # phase 6
        recs.append(ev(MAIN, "unixcall", "winscard.so:scard_establish_context", t, 5000))
        t += 1e-5
    for _ in range(20):
        recs.append(ev(MAIN, "unixcall", "dwrite.so:get_glyph_indices", t, 2000))
        t += 1e-5
    for _ in range(10):                                              # phase 7
        recs.append(ev(MAIN, "syscall", "NtDelayExecution", t, 1_100_000, 0))
        recs.append(ev(MAIN, "server_wait", "select", t + 3e-6, 1_050_000, 0x102))
        t += 0.0012
    recs.append(ev(300, "syscall", "NtYieldExecution", t, 100))      # another process' probe thread
    return recs


class ParsingTests(unittest.TestCase):
    def test_parse_expect_lines(self):
        lines = ["PASS phase1", "EXPECT syscall NtYieldExecution == 100",
                 "EXPECT ntsync_wait WAIT_ANY >= 20 status=ETIMEDOUT dur_ms=10+-1",
                 "  EXPECT unixcall winscard.so:* ~ 10 ", "EXPECT bad", "EXPECT syscall X ?? 3",
                 "EXPECT ntsync_wake EVENT_SET == 20 thread=traceprobe-help"]
        exps = V.parse_expect_lines(lines)
        self.assertEqual(len(exps), 4)
        self.assertEqual((exps[0].kind, exps[0].id, exps[0].op, exps[0].n, exps[0].filters), ("syscall", "NtYieldExecution", "==", 100, {}))
        self.assertEqual(exps[1].filters, {"status": "ETIMEDOUT", "dur_ms": "10+-1"})
        self.assertEqual((exps[2].op, exps[2].id), ("~", "winscard.so:*"))
        self.assertEqual(exps[3].filters["thread"], "traceprobe-help")
        self.assertEqual(exps[1].label(), "EXPECT ntsync_wait WAIT_ANY >= 20 status=ETIMEDOUT dur_ms=10+-1")

    def test_compare_and_numbers(self):
        self.assertTrue(V.compare("==", 5, 5))
        self.assertFalse(V.compare("==", 4, 5))
        self.assertTrue(V.compare("~", 104, 100))
        self.assertFalse(V.compare("~", 106, 100))
        self.assertTrue(V.compare("~", 1, 2))
        self.assertTrue(V.compare(">=", 7, 7) and V.compare("<=", 7, 7) and V.compare(">", 8, 7) and V.compare("<", 6, 7) and V.compare("!=", 1, 2))
        self.assertEqual(V.parse_number("0x102"), 0x102)
        self.assertEqual(V.parse_number("STATUS_TIMEOUT"), 0x102)
        self.assertEqual(V.parse_number("etimedout"), -110)
        self.assertEqual(V.norm_status(-1073741816), 0xC0000008)
        self.assertEqual(V.norm_status("-110"), -110)
        self.assertEqual(V.norm_status("STATUS_NO_YIELD_PERFORMED"), 0x40000024)
        self.assertEqual(V.parse_range("10+-1", 1000000), (9000000, 11000000))
        self.assertEqual(V.parse_range("9..11"), (9, 11))
        self.assertEqual(V.parse_range("5"), (5, 5))
        self.assertIsNone(V.parse_range("x"))
        self.assertEqual(V.percentile_index(750, 50), 374)
        self.assertEqual(V.percentile_index(750, 99), 742)
        self.assertEqual(V.percentile_index(1, 99), 0)
        self.assertEqual(V.percentile_index(0, 50), 0)

    def test_id_matching(self):
        self.assertTrue(V.id_matches("NtClose", "NtClose"))
        self.assertTrue(V.id_matches("ntclose", "NtClose"))
        self.assertTrue(V.id_matches("winscard.so:*", "winscard.so:scard_establish_context"))
        self.assertFalse(V.id_matches("winscard.so:*", "dwrite.so:x"))
        self.assertTrue(V.id_matches("0x31", "NtQueryPerformanceCounter", 0x31))
        self.assertTrue(V.id_matches("49", "0x31"))
        self.assertFalse(V.id_matches("0x31", "NtClose", 0x0F))
        self.assertTrue(V.id_matches("*", None))


class ExpectEventsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.events = os.path.join(self.tmp.name, "events.jsonl")
        with open(self.events, "w", encoding="utf-8") as fh:
            for rec in probe_events():
                fh.write(json.dumps(rec) + "\n")
        self.obs = V.Observations()
        self.obs.load_events(self.events)

    def tearDown(self):
        self.tmp.cleanup()

    def run_lines(self, lines, tid=MAIN, tables=None):
        report = V.Report()
        for exp in V.parse_expect_lines(lines):
            V.evaluate_expectation(exp, self.obs, tid, tables or {}, report)
        return report

    def statuses(self, lines, **kw):
        return [r.status for r in self.run_lines(lines, **kw).results]

    def test_thread_resolution(self):
        tid, note = self.obs.resolve_tid("traceprobe.exe")
        self.assertEqual(tid, MAIN)
        self.assertIn("main thread", note)
        self.assertEqual(self.obs.resolve_tid("traceprobe.exe", OTHER_PID)[0], 300)
        self.assertEqual(self.obs.resolve_tid("nothing")[0], None)
        self.assertEqual(self.obs.tids_with_comm("traceprobe-helper", PID), [HELPER])   # 15-char comm prefix

    def test_phase_counts(self):
        self.assertEqual(self.statuses([
            "EXPECT syscall NtYieldExecution == 100",
            "EXPECT syscall NtYieldExecution == 100 status=0|STATUS_NO_YIELD_PERFORMED",
            "EXPECT syscall NtYieldExecution == 50 status=0x40000024",
            "EXPECT syscall 0x31 == 200",
            "EXPECT syscall NtQueryPerformanceCounter == 200",
            "EXPECT server_req create_event == 50",
            "EXPECT server_req create_event == 50 within=NtCreateEvent",
            "EXPECT server_req close_handle == 50 within=NtClose",
            "EXPECT ntsync_wait WAIT_ANY == 20 status=ETIMEDOUT dur_ms=10+-1",
            "EXPECT ntsync_wait WAIT_ANY == 20 status=0 woken_by=comm:traceprobe-help",
            "EXPECT ntsync_wait WAIT_ANY == 20 status=0 woken_by=%d" % HELPER,
            "EXPECT ntsync_wake EVENT_SET == 20 thread=traceprobe-help",
            "EXPECT unixcall winscard.so:* == 10",
            "EXPECT unixcall dwrite.so:* ~ 20",
            "EXPECT syscall NtDelayExecution == 10",
            "EXPECT server_wait select == 10 within=NtDelayExecution",
            "EXPECT ntsync_wait WAIT_ANY == 40 count=1",
        ]), ["PASS"] * 17)

    def test_failures_and_skips(self):
        report = self.run_lines([
            "EXPECT syscall NtYieldExecution == 99",
            "EXPECT ntsync_wait WAIT_ANY == 20 status=0 woken_by=comm:nobody",
            "EXPECT ntsync_wake EVENT_SET == 20",                     # on the main thread: 0
            "EXPECT ntsync_wake EVENT_SET == 20 thread=nobody",
            "EXPECT server_req create_event == 50 within=NtClose",
            "EXPECT bogus x == 1",
            "EXPECT ntsync_wait WAIT_ANY == 20 dur_ms=zzz",
        ])
        self.assertEqual([r.status for r in report.results], ["FAIL", "SKIP", "FAIL", "SKIP", "FAIL", "SKIP", "SKIP"])
        self.assertIn("observed 100", report.results[0].detail)
        self.assertEqual(report.failures, 3)
        self.assertEqual(report.summary(), "SUMMARY pass=0 fail=3 skip=4")

    def test_tables_translate_numeric_ids(self):
        tables = {0x46: "NtYieldExecution"}
        # events carry names already; a numeric expectation needs id_num or a table hit on id_num
        self.assertEqual(self.statuses(["EXPECT syscall 0x46 == 100"], tables=tables), ["FAIL"])
        self.obs.events[0].id_num = 0x46
        self.assertEqual(self.statuses(["EXPECT syscall 0x46 == 1"], tables=tables), ["PASS"])

    def test_pairing_checks(self):
        report = V.Report()
        self.obs.tracer = {"counters": {"unmatched_exits": {str(MAIN): 1, str(HELPER): 1, "total": 2}, "abandoned_entries": 0}}
        V.pairing_checks(self.obs, MAIN, report)
        self.assertEqual([(r.check, r.status) for r in report.results],
                         [("pairing-enclosure", "PASS"), ("pairing-unmatched_exits", "PASS"), ("pairing-abandoned_entries", "PASS")])
        # an orphan server request and too many unmatched exits
        self.obs.events.append(V.Event(ev(MAIN, "server_req", "select", 999.0, 100)))
        self.obs.tracer = {"unmatched_exits": 7, "per_tid": {str(MAIN): {"abandoned_entries": 2}}}
        report = V.Report()
        V.pairing_checks(self.obs, MAIN, report)
        self.assertEqual([(r.check, r.status) for r in report.results],
                         [("pairing-enclosure", "FAIL"), ("pairing-unmatched_exits", "INFO"), ("pairing-abandoned_entries", "FAIL")])
        report = V.Report()
        V.pairing_checks(V.Observations(), MAIN, report)
        self.assertEqual([r.status for r in report.results], ["SKIP", "SKIP", "SKIP"])


class ExpectAggregateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.blocks = os.path.join(self.tmp.name, "blocks.jsonl")
        with open(self.blocks, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "header"}) + "\n")
            for seq in (1, 2):
                fh.write(json.dumps({"seq": seq, "crossings": [
                    {"tid": MAIN, "role": "main", "kind": "syscall", "id": "NtYieldExecution", "n": 50, "total_ns": 1000, "max_ns": 50},
                    {"tid": MAIN, "role": "main", "kind": "server_req", "id": "create_event", "n": 25, "total_ns": 1000, "max_ns": 50},
                    {"tid": HELPER, "role": "live:x", "kind": "ntsync_wake", "id": "EVENT_SET", "n": 10, "total_ns": 1, "max_ns": 1}]}) + "\n")
        self.threads = os.path.join(self.tmp.name, "threads.jsonl")
        with open(self.threads, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"t": 0.0, "window_ms": 100, "pid": PID, "tid": MAIN, "comm": "traceprobe.exe",
                                 "crossings": {"syscall": {"n": 300, "total_ns": 5}, "unixcall": {"n": 30, "total_ns": 5}},
                                 "top_ids": [["NtQueryPerformanceCounter", 200, 4], ["winscard.so:scard_establish_context", 10, 1]]}) + "\n")
            fh.write(json.dumps({"t": 0.0, "window_ms": 100, "pid": PID, "tid": HELPER, "comm": "traceprobe-help",
                                 "crossings": {"syscall": {"n": 20, "total_ns": 5}}, "top_ids": [["NtSetEvent", 20, 4]]}) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_blocks_and_threads(self):
        obs = V.Observations()
        obs.load_blocks(self.blocks)
        obs.load_threads(self.threads)
        self.assertFalse(obs.has_events)
        self.assertEqual(obs.resolve_tid("traceprobe.exe")[0], MAIN)
        report = V.Report()
        for exp in V.parse_expect_lines([
                "EXPECT syscall NtYieldExecution == 100",
                "EXPECT server_req create_event == 50",
                "EXPECT ntsync_wake EVENT_SET == 20 thread=traceprobe-help",
                "EXPECT syscall NtQueryPerformanceCounter == 200",      # from top_ids: approximate but matching
                "EXPECT syscall NtClose == 50",                          # not in blocks nor top_ids: inconclusive
                "EXPECT unixcall * == 30",                               # kind total from threads.jsonl
                "EXPECT syscall * == 300",                               # kind total preferred over blocks (100)
                "EXPECT syscall NtYieldExecution == 100 status=0",       # needs events
                "EXPECT syscall NtYieldExecution == 99",                 # aggregates never FAIL
                "EXPECT ntsync_wake EVENT_SET == 20"]):                  # main thread: nothing anywhere
            V.evaluate_expectation(exp, obs, MAIN, {}, report)
        self.assertEqual([r.status for r in report.results],
                         ["PASS", "PASS", "PASS", "PASS", "SKIP", "PASS", "PASS", "SKIP", "SKIP", "SKIP"])
        self.assertIn("observed 100", report.results[8].detail)
        # blocks only: still PASS/SKIP, never FAIL
        obs2 = V.Observations()
        obs2.load_blocks(self.blocks)
        report = V.Report()
        for exp in V.parse_expect_lines(["EXPECT syscall NtYieldExecution == 100", "EXPECT syscall * == 100",
                                         "EXPECT syscall NtYieldExecution == 1"]):
            V.evaluate_expectation(exp, obs2, MAIN, {}, report)
        self.assertEqual([r.status for r in report.results], ["PASS", "PASS", "SKIP"])


class TelemetryTests(unittest.TestCase):
    LOG = """[2026-10-16 12:00:00] launcher: starting
[pipeasio telemetry] enabled for 64-bit host; capacity=8192, interval_ms=1000
[pipeasio telemetry] cycles=750 time_info=750 legacy=0 muted=0 dropped=0 block_range=1000-1749 late=2
[pipeasio telemetry] monotonic_wall_ns phase=entry_to_live p50=12000 p95=13000 p99=14000 max=20000
[pipeasio telemetry] monotonic_wall_ns phase=live_callback p50=480000 p95=600000 p99=700500 max=900000
[pipeasio telemetry] monotonic_wall_ns phase=live_to_outputs p50=9000 p95=9500 p99=9900 max=12000
[pipeasio telemetry] thread_cpu_ns phase=entry_to_live p50=1 p95=1 p99=1 max=1
[pipeasio telemetry] cycles=750 time_info=750 legacy=0 muted=0 dropped=0 block_range=1750-2499 late=0
[pipeasio telemetry] monotonic_wall_ns phase=live_callback p50=480000 p95=600000 p99=700000 max=900000
[pipeasio telemetry] cycles=748 time_info=740 legacy=0 muted=8 dropped=3 block_range=2500-3239 late=1
[pipeasio telemetry] monotonic_wall_ns phase=live_callback p50=480000 p95=600000 p99=700000 max=900000
[pipeasio telemetry] cycles=750 time_info=750 legacy=0 muted=0 dropped=0 block_range=9000-9749 late=0
[pipeasio telemetry] cycles=0 time_info=0 legacy=0 muted=5 dropped=0
"""

    @staticmethod
    def blocks(first=1000, count=3000):
        blocks = []
        for i in range(count):
            seq = first + i
            # live time: 480000 for most, 600000 at every 10th, 700000 at i%100 in (98, 99):
            # per 750-block interval that is 667/68/15 samples (p50 480000, p95 600000, p99 700000
            # with pipeasio_telemetry_percentile_index)
            live = 480000
            if i % 100 in (98, 99):
                live = 700000
            elif i % 10 == 9:
                live = 600000
            late = seq in (1003, 1500, 2600)
            flags = ["admitted", "time_info"]
            if 2500 <= seq < 2508:
                flags.append("muted")
            blocks.append({"seq": seq, "t_start": 1.0 + i / 750.0, "t_before_live": 1.0 + i / 750.0 + 1e-5,
                           "t_after_live": 1.0 + i / 750.0 + 1e-5 + live / 1e9, "late": late, "flags": flags})
        return [V.Block(b) for b in blocks]

    def test_parse_telemetry(self):
        intervals = V.parse_telemetry(self.LOG.splitlines())
        self.assertEqual(len(intervals), 5)
        self.assertEqual(intervals[0].block_range, (1000, 1749))
        self.assertEqual(intervals[0].get("late"), 2)
        self.assertEqual(intervals[0].phases[("monotonic_wall", "live_callback")]["p99"], 700500)
        self.assertEqual(len(intervals[0].phases), 4)
        self.assertEqual(intervals[2].get("muted"), 8)
        self.assertIsNone(intervals[4].block_range)
        self.assertEqual(intervals[4].get("cycles"), 0)

    def test_check_telemetry(self):
        intervals = V.parse_telemetry(self.LOG.splitlines())
        report = V.Report()
        V.check_telemetry(intervals, self.blocks(), report, tolerance_ns=2000, tolerance_blocks=1)
        by_check = {r.check: r for r in report.results}
        self.assertEqual(by_check["telemetry[0@line3]-cycles"].status, "PASS")
        self.assertEqual(by_check["telemetry[0@line3]-late"].status, "PASS")          # 1003 and 1500 late
        self.assertEqual(by_check["telemetry[0@line3]-live_callback"].status, "PASS")  # p99 off by 500 ns
        self.assertEqual(by_check["telemetry[1@line8]-cycles"].status, "PASS")
        self.assertEqual(by_check["telemetry[1@line8]-late"].status, "PASS")
        self.assertEqual(by_check["telemetry[1@line8]-live_callback"].status, "PASS")
        self.assertEqual(by_check["telemetry[2@line10]-cycles"].status, "PASS")        # 740 blocks vs 748 within muted+dropped
        self.assertEqual(by_check["telemetry[2@line10]-late"].status, "PASS")
        self.assertEqual(by_check["telemetry[2@line10]-live_callback"].status, "SKIP")  # dropped samples
        self.assertEqual(by_check["telemetry[3@line12]"].status, "SKIP")               # outside the tracer window
        self.assertEqual(by_check["telemetry[4@line13]"].status, "SKIP")               # no block_range
        self.assertEqual(report.failures, 0)

    def test_check_telemetry_failures(self):
        log = self.LOG.replace("block_range=1750-2499 late=0", "block_range=1750-2499 late=3") \
                      .replace("p99=700500", "p99=710000")
        intervals = V.parse_telemetry(log.splitlines())
        report = V.Report()
        V.check_telemetry(intervals, self.blocks(), report)
        by_check = {r.check: r for r in report.results}
        self.assertEqual(by_check["telemetry[1@line8]-late"].status, "FAIL")
        self.assertEqual(by_check["telemetry[0@line3]-live_callback"].status, "FAIL")
        self.assertEqual(report.failures, 2)
        # missing blocks inside a range
        blocks = [b for b in self.blocks() if not (1100 <= b.seq < 1110)]
        report = V.Report()
        V.check_telemetry(intervals, blocks, report)
        self.assertEqual({r.check: r for r in report.results}["telemetry[0@line3]-cycles"].status, "FAIL")
        report = V.Report()
        V.check_telemetry([], blocks, report)
        self.assertEqual(report.results[0].status, "FAIL")
        report = V.Report()
        V.check_telemetry(intervals, [], report)
        self.assertEqual(report.results[0].status, "FAIL")
        report = V.Report()
        V.check_telemetry(intervals, self.blocks(first=50000, count=10), report)
        self.assertEqual(report.results[-1].check, "telemetry-coverage")
        self.assertEqual(report.results[-1].status, "FAIL")

    def test_block_live_ns_field(self):
        blk = V.Block({"seq": 5, "live_ns": 123, "late": True, "flags": ["muted"]})
        self.assertEqual((blk.live_ns, blk.late, blk.muted), (123, True, True))
        blk = V.Block({"seq": 6, "t_before_live": 1.0, "t_after_live": 1.0005})
        self.assertEqual(blk.live_ns, 500000)
        self.assertFalse(blk.muted)


class ProbeConventionTests(unittest.TestCase):
    """B5: what tools/traceprobe.exe really prints, against what reduce.py really writes."""

    PROBE_OUTPUT = [
        "traceprobe: wine interface tracer validation probe [fastpath=off]",
        "info ids 32 pid=31 helper=0 linux_pid=100 linux_tid=100 linux_helper_tid=? comm=traceprobe-main helper_comm=traceprobe-help",
        "EXPECT syscall NtDelayExecution eq 10",
        "EXPECT server_wait NtDelayExecution ge 10",
        "EXPECT server_req create_event eq 2",
        "EXPECT unixcall winscard.so eq 3",
        "EXPECT ntsync_wake EVENT_SET eq 2 thread=helper",
        "EXPECT syscall NtYieldExecution ge 1",
        "SUMMARY pass=10 fail=0 skip=0",
        "TID 32 pid=31 helper=36 linux_pid=100 linux_tid=100 linux_helper_tid=? comm=traceprobe-main helper_comm=traceprobe-help",
    ]

    @staticmethod
    def reducer_events():
        """events.jsonl records shaped like reduce.py's public_events (callers, flag-named waits)."""
        recs = [{"type": "header", "file": "events"}]
        t = 1.0
        for _ in range(10):
            recs.append({"t": t, "tid": MAIN, "role": "main", "kind": "syscall", "id": "NtDelayExecution",
                         "caller": "ntdll.dll!NtDelayExecution+0x14", "dur_ns": 1_100_000, "status": "0x0", "seq": 0})
            recs.append({"t": t + 2e-6, "tid": MAIN, "role": "main", "kind": "server_wait",
                         "id": "interruptible|alertable", "caller": "ntdll.dll!NtDelayExecution+0x14",
                         "dur_ns": 1_000_000, "status": "0x102", "seq": 0})
            t += 0.002
        for _ in range(2):
            recs.append({"t": t, "tid": MAIN, "kind": "syscall", "id": "NtCreateEvent",
                         "caller": "ntdll.dll!NtCreateEvent+0x14", "dur_ns": 30_000, "status": "0x0"})
            recs.append({"t": t + 2e-6, "tid": MAIN, "kind": "server_req", "id": "create_event",
                         "caller": "ntdll.dll!NtCreateEvent+0x14", "dur_ns": 10_000, "status": "0x0"})
            t += 0.001
        for code in ("scard_establish_context", "scard_release_context", "scard_establish_context"):
            recs.append({"t": t, "tid": MAIN, "kind": "unixcall", "id": "winscard.so:" + code,
                         "caller": "pe!0x140001234", "dur_ns": 5000, "status": "0x0"})
            t += 0.001
        recs.append({"t": t, "tid": MAIN, "kind": "unixcall", "id": "winscardx.so#1", "caller": "pe!0x1",
                     "dur_ns": 5000, "status": "0x0"})
        for _ in range(2):
            recs.append({"t": t, "tid": HELPER, "kind": "syscall", "id": "NtSetEvent",
                         "caller": "ntdll.dll!NtSetEvent+0x14", "dur_ns": 3000, "status": "0x0"})
            recs.append({"t": t + 1e-6, "tid": HELPER, "kind": "ntsync_wake", "id": "EVENT_SET",
                         "caller": "ntdll.dll!NtSetEvent+0x14", "dur_ns": 0, "status": 0})
            t += 0.001
        recs.append({"t": t, "tid": MAIN, "kind": "syscall", "id": "NtYieldExecution",
                     "caller": "ntdll.dll!NtYieldExecution+0x14", "dur_ns": 900, "status": "0x0"})
        return recs

    def run_main(self, extra=()):
        import io
        from contextlib import redirect_stdout
        with tempfile.TemporaryDirectory() as tmp:
            events = os.path.join(tmp, "events.jsonl")
            with open(events, "w", encoding="utf-8") as fh:
                for rec in self.reducer_events():
                    fh.write(json.dumps(rec) + "\n")
            threads = os.path.join(tmp, "threads.jsonl")
            with open(threads, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "header", "file": "threads"}) + "\n")
                fh.write(json.dumps({"t": 0.0, "pid": PID, "tid": HELPER, "comm": "traceprobe-help",
                                     "crossings": {}, "top_ids": []}) + "\n")
                fh.write(json.dumps({"t": 0.0, "pid": PID, "tid": MAIN, "comm": "traceprobe-main",
                                     "crossings": {}, "top_ids": []}) + "\n")
            expect = os.path.join(tmp, "traceprobe.txt")
            with open(expect, "w", encoding="utf-8") as fh:
                fh.write("\n".join(self.PROBE_OUTPUT) + "\n")
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = V.main(["--expect", expect, "--events", events, "--threads", threads] + list(extra))
        return rc, buf.getvalue().splitlines()

    def test_word_ops_parse(self):
        exps = V.parse_expect_lines(self.PROBE_OUTPUT)
        self.assertEqual([e.op for e in exps], ["==", ">=", "==", "==", "==", ">="])

    def test_probe_ids_line(self):
        ids = V.parse_probe_ids(self.PROBE_OUTPUT)
        self.assertEqual(ids["helper"], "36")
        self.assertEqual(V.probe_number(ids, "linux_tid"), MAIN)
        self.assertIsNone(V.probe_number(ids, "linux_helper_tid"))

    def test_probe_output_passes_against_reducer_events(self):
        rc, out = self.run_main()
        self.assertEqual(rc, 0, "\n".join(out))
        self.assertIn("INFO expect-thread: tid 100 (the probe's TID line (linux_tid)); observations from events+threads", out)
        self.assertIn("PASS EXPECT server_wait NtDelayExecution >= 10: observed 10 on tid 100", out)
        self.assertIn("PASS EXPECT unixcall winscard.so == 3: observed 3 on tid 100", out)
        self.assertIn("PASS EXPECT ntsync_wake EVENT_SET == 2 thread=helper: observed 2 on tid 101", out)
        self.assertIn("PASS EXPECT server_req create_event == 2: observed 2 on tid 100", out)

    def test_event_inside_never_exiting_entry_is_not_an_orphan(self):
        # The probe's last syscall, NtTerminateProcess(-1), never exits: its terminate_process
        # request has no completed enclosing event but keeps the caller the reducer gave it.
        obs = V.Observations()
        obs.events = [V.Event({"t": 1.0, "tid": MAIN, "kind": "server_req", "id": "terminate_process",
                               "caller": "ntdll.dll!NtTerminateProcess+0x14", "dur_ns": 13000}),
                      V.Event({"t": 2.0, "tid": MAIN, "kind": "server_req", "id": "init_thread",
                               "caller": "none", "dur_ns": 1000})]
        report = V.Report()
        V.pairing_checks(obs, MAIN, report)
        lines = [r.line() for r in report.results]
        self.assertIn("INFO pairing-open-enclosure: 1 server/ntsync events inside an entry that never exited "
                      "(caller kept) on tid 100", lines)
        self.assertIn("FAIL pairing-enclosure: 1 of 2 server/ntsync events without an enclosing syscall/unixcall "
                      "on tid 100", lines)

    def test_bare_module_does_not_match_other_libraries(self):
        exp = V.parse_expect_lines(["EXPECT unixcall winscard.so eq 1"])[0]
        event = V.Event({"tid": 1, "kind": "unixcall", "id": "winscardx.so#1"})
        self.assertFalse(V.expect_id_matches(exp, event, event.id))
        event = V.Event({"tid": 1, "kind": "unixcall", "id": "winscard.so#7"})
        self.assertTrue(V.expect_id_matches(exp, event, event.id))

    def test_enclosing_syscall_id_only_for_nested_kinds(self):
        exp = V.parse_expect_lines(["EXPECT syscall NtDelayExecution eq 1"])[0]
        event = V.Event({"tid": 1, "kind": "syscall", "id": "NtYieldExecution",
                         "caller": "ntdll.dll!NtDelayExecution+0x14"})
        self.assertFalse(V.expect_id_matches(exp, event, event.id))


class CLITests(unittest.TestCase):
    def test_main_exit_code_and_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = os.path.join(tmp, "events.jsonl")
            with open(events, "w", encoding="utf-8") as fh:
                for rec in probe_events():
                    fh.write(json.dumps(rec) + "\n")
            expect = os.path.join(tmp, "traceprobe.txt")
            with open(expect, "w", encoding="utf-8") as fh:
                fh.write("PASS phase1-yield\nEXPECT syscall NtYieldExecution == 100\nEXPECT syscall NtClose == 49\n"
                         "EXPECT unixcall winscard.so:* == 10\nSUMMARY pass=1 fail=0 skip=0\n")
            blocks = os.path.join(tmp, "blocks.jsonl")
            with open(blocks, "w", encoding="utf-8") as fh:
                for b in TelemetryTests.blocks():
                    fh.write(json.dumps({"seq": b.seq, "live_ns": b.live_ns, "late": b.late,
                                         "flags": ["muted"] if b.muted else []}) + "\n")
            log = os.path.join(tmp, "live.log")
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(TelemetryTests.LOG)
            import io
            from contextlib import redirect_stdout
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = V.main(["--expect", expect, "--events", events, "--telemetry", log, "--blocks", blocks])
            out = buf.getvalue().splitlines()
            self.assertEqual(rc, 1)
            self.assertIn("FAIL EXPECT syscall NtClose == 49: observed 50 on tid 100", out)
            self.assertTrue(out[-1].startswith("SUMMARY pass="))
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = V.main(["--expect", expect, "--events", events, "--tid", str(MAIN), "--json"])
            doc = json.loads(buf.getvalue())
            self.assertEqual(rc, 1)
            self.assertEqual(doc["fail"], 1)
            self.assertTrue(any(r["check"] == "expect-thread" for r in doc["results"]))
            with self.assertRaises(SystemExit):
                V.main([])
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = V.main(["--expect", expect, "--events", events, "--comm", "nobody"])
            self.assertEqual(rc, 1)
            self.assertIn("FAIL expect-thread", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
