#!/usr/bin/env python3
"""Deterministic tests for profiler/tracer/reduce.py (no bpftrace, no Wine needed).

Run from the repository root:  python3 -I -m unittest discover -s profiler/tracer/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRACER_DIR = HERE.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TRACER_DIR / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reduce_mod = load("wine_trace_reduce", "reduce.py")

S0 = 1_000_000_000_000  # monotonic_start_ns of the synthetic run (1000 s after boot)
PERIOD = 1_333_333  # 64 frames at 48 kHz
PID_LIVE = 4200
PID_WINESERVER = 4100
TID_MAIN = 4200
TID_CALLBACK = 4242
TID_AUDIO = 4301
TID_MIDI = 4310
TID_WINESERVER = 4100


class Fixture:
    """Builds the synthetic events.txt; every helper mirrors one printf of wine-trace.bt."""

    def __init__(self):
        self.lines = []

    def add(self, line):
        self.lines.append(line)

    def hdr(self):
        self.add("hdr mono_start_ns=%d format=1" % S0)

    def thread(self, ts, tid, pid, comm):
        self.add("T %d %d %d comm=%s" % (ts, tid, pid, comm))

    def rename(self, ts, tid, comm):
        self.add("N %d %d comm=%s" % (ts, tid, comm))

    def sc_entry(self, ts, tid, sid, frame, seq, rsp=0x7FFE1000, rip=0x7FF00014):
        self.add("E %d %d syscall %x fr=%x seq=%d rsp=%x rip=%x" % (ts, tid, sid, frame, seq, rsp, rip))

    def sc_exit(self, ts, tid, sid, frame, status=0, rflags=0):
        self.add("X %d %d syscall %x fr=%x st=%x rf=%x" % (ts, tid, sid, frame, status, rflags))

    def uc_entry(self, ts, tid, handle, code, frame, seq, rip):
        self.add("E %d %d unixcall %x:%d fr=%x seq=%d rip=%x" % (ts, tid, handle, code, frame, seq, rip))

    def uc_exit(self, ts, tid, frame, status=0):
        self.add("X %d %d unixcall fr=%x st=%x" % (ts, tid, frame, status))

    def server_req(self, ts_end, tid, req, dur, seq, status=0):
        self.add("S %d %d req %d dur=%d st=%x seq=%d" % (ts_end, tid, req, dur, status, seq))

    def server_wait(self, ts_end, tid, flags, dur, seq, status=0):
        self.add("S %d %d wait %x dur=%d st=%x seq=%d" % (ts_end, tid, flags, dur, status, seq))

    def block(self, seq, start, clk, dl, before, after, end, fl, missed, n=64, rate=48000):
        self.add("B %d %d start seq=%d n=%d rate=%d clk=%d dl=%d" % (start, TID_CALLBACK, seq, n, rate, clk, dl))
        if before is not None:
            self.add("B %d %d before seq=%d" % (before, TID_CALLBACK, seq))
        if after is not None:
            self.add("B %d %d after seq=%d" % (after, TID_CALLBACK, seq))
        if end is not None:
            self.add("B %d %d end seq=%d fl=%x missed=%d" % (end, TID_CALLBACK, seq, fl, missed))

    def cycle(self, start, end, clk, nxt, missed=0, delivered=1):
        self.add("C %d %d start clk=%d next=%d dur=64 pos=0 fl=0" % (start, TID_CALLBACK, clk, nxt))
        self.add("C %d %d end missed=%d delivered=%d" % (end, TID_CALLBACK, missed, delivered))

    def nt_wait(self, ts, tid, cmd, seq, count=1, alert=0, owner=0):
        self.add("W %d %d cmd=%x count=%d alert=%d owner=%d seq=%d" % (ts, tid, cmd, count, alert, owner, seq))

    def nt_wait_exit(self, ts, tid, ret=0, idx=0):
        self.add("w %d %d ret=%d idx=%d" % (ts, tid, ret, idx))

    def nt_wake(self, ts, tid, pid, cmd, seq):
        self.add("K %d %d %d cmd=%x seq=%d" % (ts, tid, pid, cmd, seq))

    def waking(self, ts, waker_tid, waker_pid, wakee):
        self.add("U %d %d %d wakee=%d" % (ts, waker_tid, waker_pid, wakee))

    def offcpu(self, ts_on, tid, ts_off, ts_wake, state=1):
        self.add("O %d %d off=%d wake=%d st=%d" % (ts_on, tid, ts_off, ts_wake, state))

    def end(self, ts):
        self.add("end mono_end_ns=%d" % ts)


def build_fixture():
    f = Fixture()
    f.hdr()
    f.thread(S0 + 100, TID_MAIN, PID_LIVE, "Ableton Live 12")
    f.thread(S0 + 200, TID_CALLBACK, PID_LIVE, "pw-data-loop")
    f.thread(S0 + 300, TID_AUDIO, PID_LIVE, "AudioCalc")
    f.thread(S0 + 400, TID_MIDI, PID_LIVE, "wine-thread")
    f.rename(S0 + 500, TID_MIDI, "MIDI")
    f.thread(S0 + 600, TID_WINESERVER, PID_WINESERVER, "wineserver")

    # Thread start of the MIDI thread: an exit with no entry.
    f.sc_exit(S0 + 1_000, TID_MIDI, 0, 0xD1)

    # Main thread: a message wait entered before block 1 (seq 0 -> window bucket) that nests a
    # user-mode callback syscall during block 1 (seq 1) which never exits (NtCallbackReturn).
    f.sc_entry(S0 + 5_000_000, TID_MAIN, 0x14BB, 0xC1, 0)
    f.sc_entry(S0 + 10_200_000, TID_MAIN, 0x1234, 0xC0, 1)
    f.sc_exit(S0 + 30_000_000, TID_MAIN, 0x14BB, 0xC1)

    # Block 1: on time.
    b1_start = S0 + 10_000_000
    b1_clk = b1_start - 41_000
    b1_before = b1_start + 12_000
    b1_after = b1_before + 480_000
    b1_end = b1_after + 9_000
    f.cycle(b1_start - 5_000, b1_end + 3_000, b1_clk, b1_clk + PERIOD)
    f.block(1, b1_start, b1_clk, b1_clk + PERIOD, b1_before, b1_after, b1_end, 0x1, 0)
    f.sc_entry(b1_start + 100_000, TID_AUDIO, 0x000A, 0xA1, 1)
    f.sc_exit(b1_start + 100_700, TID_AUDIO, 0x000A, 0xA1)

    # Between blocks: the callback thread itself crosses (seq 0 -> flagged between_blocks).
    f.sc_entry(S0 + 10_800_000, TID_CALLBACK, 0x0046, 0xE1, 0)
    f.sc_exit(S0 + 10_802_000, TID_CALLBACK, 0x0046, 0xE1)

    # Block 2: late (slack -126667 ns), one missed cycle.
    b2_start = S0 + 11_333_333
    b2_clk = b2_start - 40_000
    b2_before = b2_start + 10_000
    b2_after = b2_before + 1_400_000
    b2_end = b2_after + 10_000
    f.block(2, b2_start, b2_clk, b2_clk + PERIOD, b2_before, b2_after, b2_end, 0x3, 1)
    # AudioCalc waits on an NTSync object inside NtWaitForSingleObject, woken by the callback thread.
    f.sc_entry(b2_start + 50_000, TID_AUDIO, 0x0004, 0xA1, 2)
    f.nt_wait(b2_start + 51_000, TID_AUDIO, 0xC0284E82, 2, count=1, owner=TID_AUDIO)
    f.offcpu(b2_start + 301_500, TID_AUDIO, b2_start + 52_000, b2_start + 300_000)
    f.waking(b2_start + 300_000, TID_CALLBACK, PID_LIVE, TID_AUDIO)
    f.nt_wait_exit(b2_start + 351_000, TID_AUDIO, ret=0, idx=0)
    f.sc_exit(b2_start + 352_000, TID_AUDIO, 0x0004, 0xA1)
    # MIDI thread creates an event: NtCreateEvent enclosing one create_event server request.
    f.sc_entry(b2_start + 20_000, TID_MIDI, 0x0048, 0xB1, 2)
    f.server_req(b2_start + 30_000, TID_MIDI, 30, 8_000, 2)
    f.sc_exit(b2_start + 31_000, TID_MIDI, 0x0048, 0xB1)
    # wineserver sets an event during block 2.
    f.nt_wake(b2_start + 200_000, TID_WINESERVER, PID_WINESERVER, 0x80044E88, 2)

    # Block 3: near-late (slack 173333 ns < 15 % of the period), no crossings.
    b3_start = S0 + 12_666_666
    b3_clk = b3_start - 40_000
    b3_before = b3_start + 10_000
    b3_after = b3_before + 1_100_000
    b3_end = b3_after + 10_000
    f.block(3, b3_start, b3_clk, b3_clk + PERIOD, b3_before, b3_after, b3_end, 0x1, 0)

    # Block 4 never ends (trace stopped mid-block): dropped and counted.
    f.block(4, S0 + 14_000_000, S0 + 13_960_000, S0 + 13_960_000 + PERIOD, None, None, None, 0, 0)

    # MIDI thread outside any block: a unix call into winscard.so, then an alertable sleep.
    f.uc_entry(S0 + 40_000_000, TID_MIDI, 0x7F0000001000, 0, 0xB2, 0, 0x140001234)
    f.uc_exit(S0 + 40_120_000, TID_MIDI, 0xB2)
    f.sc_entry(S0 + 50_000_000, TID_MIDI, 0x0034, 0xB3, 0)
    f.server_wait(S0 + 51_000_000, TID_MIDI, 0x3, 1_000_000, 0)
    f.sc_exit(S0 + 51_001_000, TID_MIDI, 0x0034, 0xB3)
    # Second window.
    f.sc_entry(S0 + 150_000_000, TID_MIDI, 0x0046, 0xB4, 0)
    f.sc_exit(S0 + 150_003_000, TID_MIDI, 0x0046, 0xB4)

    f.add("Lost 3 events")
    f.add("Attaching 20 probes...")
    f.add("@seq: 0")
    f.end(S0 + 200_000_000)
    return f.lines


TRACER_JSON = {
    "version": "proto-bpftrace/1",
    "backend": "bpftrace",
    "mode": "summary",
    "sample_rate": 1,
    "attach": ["usdt:ntdll.so:wine:syscall_entry"],
    "wine_version": "11.13",
    "started_monotonic_ns": S0,
    "pids": [
        {"pid": PID_LIVE, "comm": "Ableton Live 12", "image": "Ableton Live 12 Trial.exe"},
        {"pid": PID_WINESERVER, "comm": "wineserver", "image": "wineserver"},
    ],
}

MAPS_4200 = (
    "7f0000000000-7f0000100000 r-xp 00000000 08:01 1 /opt/wine/lib/wine/x86_64-unix/winscard.so\n"
    "7f0001000000-7f0001400000 r-xp 00000000 08:01 2 /opt/wine/lib/wine/x86_64-unix/ntdll.so\n"
    "140000000-141000000 r-xp 00000000 08:01 3 /prefix/drive_c/Live/Ableton Live 12 Trial.exe\n"
)


def write_run(directory, lines, mode="summary"):
    with open(os.path.join(directory, "events.txt"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    with open(os.path.join(directory, "tracer.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(dict(TRACER_JSON, mode=mode), handle)
    with open(os.path.join(directory, "maps-%d.txt" % PID_LIVE), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(MAPS_4200)


def run_reduce(directory, mode="summary", extra=()):
    argv = ["--in", directory, "--mode", mode, "--quiet", "--stopped-monotonic-ns", str(S0 + 999)] + list(extra)
    rc = reduce_mod.main(argv)
    assert rc == 0, "reduce exited with %d" % rc
    return read_outputs(directory)


def read_jsonl(path):
    with open(path, "r", encoding="utf-8") as handle:
        records = [json.loads(line) for line in handle if line.strip()]
    assert records and records[0]["type"] == "header", path
    return records[0], records[1:]


def read_outputs(directory):
    out = {"dir": directory}
    out["blocks_header"], out["blocks"] = read_jsonl(os.path.join(directory, "blocks.jsonl"))
    out["threads_header"], out["threads"] = read_jsonl(os.path.join(directory, "threads.jsonl"))
    with open(os.path.join(directory, "summary.json"), "r", encoding="utf-8") as handle:
        out["summary"] = json.load(handle)
    with open(os.path.join(directory, "tracer.json"), "r", encoding="utf-8") as handle:
        out["tracer"] = json.load(handle)
    events_path = os.path.join(directory, "events.jsonl")
    if os.path.exists(events_path):
        out["events_header"], out["events"] = read_jsonl(events_path)
    return out


class ReduceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.run_dir = os.path.join(cls.tmp.name, "ordered")
        os.makedirs(cls.run_dir)
        write_run(cls.run_dir, build_fixture(), mode="drilldown")
        cls.out = run_reduce(cls.run_dir, mode="drilldown")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def block(self, seq):
        for record in self.out["blocks"]:
            if record["seq"] == seq:
                return record
        self.fail("block %d missing" % seq)

    def crossing(self, block, kind, ident):
        for item in block["crossings"]:
            if item["kind"] == kind and item["id"] == ident:
                return item
        self.fail("block %d has no %s %s crossing: %r" % (block["seq"], kind, ident, block["crossings"]))

    def test_headers(self):
        header = self.out["blocks_header"]
        self.assertEqual(header["monotonic_start_ns"], S0)
        self.assertEqual(header["monotonic_end_ns"], S0 + 200_000_000)
        self.assertEqual(header["wine_version"], "11.13")
        self.assertEqual(header["tables"], "wine-11.13.json")
        self.assertEqual(header["pids"], [PID_LIVE, PID_WINESERVER])
        self.assertEqual(header["mode"], "drilldown")
        self.assertEqual(self.out["threads_header"]["file"], "threads")

    def test_block_timing_fields(self):
        b1 = self.block(1)
        self.assertAlmostEqual(b1["t_start"], 0.01, places=6)
        self.assertEqual(b1["pre_ns"], 12_000)
        self.assertEqual(b1["live_ns"], 480_000)
        self.assertEqual(b1["post_ns"], 9_000)
        self.assertEqual(b1["elapsed_ns"], 501_000)
        self.assertEqual(b1["period_ns"], PERIOD)
        self.assertEqual(b1["wake_latency_ns"], 41_000)
        self.assertEqual(b1["slack_ns"], 791_333)
        self.assertEqual(b1["nframes"], 64)
        self.assertEqual(b1["rate"], 48000)
        self.assertEqual(b1["callback_tid"], TID_CALLBACK)
        self.assertFalse(b1["late"])
        self.assertFalse(b1["near_late"])
        self.assertEqual(b1["flags"], ["admitted"])
        self.assertEqual(b1["missed_cycles"], 0)
        self.assertEqual(b1["stacks"], [])
        self.assertEqual(b1["cycle"]["pre_ns"], 5_000)
        self.assertEqual(b1["cycle"]["post_ns"], 3_000)
        self.assertEqual(b1["cycle"]["delivered"], 1)

    def test_late_and_near_late_classification(self):
        b2, b3 = self.block(2), self.block(3)
        self.assertEqual(b2["slack_ns"], -126_667)
        self.assertTrue(b2["late"])
        self.assertFalse(b2["near_late"])
        self.assertEqual(b2["flags"], ["admitted", "time_info"])
        self.assertEqual(b2["missed_cycles"], 1)
        self.assertEqual(b3["slack_ns"], 173_333)
        self.assertFalse(b3["late"])
        self.assertTrue(b3["near_late"])
        self.assertEqual([record["seq"] for record in self.out["blocks"]], [1, 2, 3])
        self.assertEqual(self.out["summary"]["counters"]["all"]["incomplete_blocks"], 1)

    def test_block_association_rule(self):
        b1 = self.block(1)
        self.assertEqual(len(b1["crossings"]), 1)
        sem = self.crossing(b1, "syscall", "NtReleaseSemaphore")
        self.assertEqual(sem["tid"], TID_AUDIO)
        self.assertEqual(sem["role"], "audio_worker")
        self.assertEqual(sem["n"], 1)
        self.assertEqual(sem["total_ns"], 700)
        self.assertEqual(sem["max_ns"], 700)
        self.assertEqual(sem["caller"], "ntdll.dll!NtReleaseSemaphore+0x14")
        # The main thread's message wait spans blocks 1 and 2 but was entered with seq 0: window bucket.
        main_windows = [record for record in self.out["threads"] if record["tid"] == TID_MAIN]
        self.assertEqual(len(main_windows), 1)
        self.assertEqual(main_windows[0]["t"], 0.0)
        self.assertEqual(main_windows[0]["role"], "main")
        self.assertEqual(main_windows[0]["crossings"], {"syscall": {"n": 1, "total_ns": 25_000_000}})
        self.assertEqual(main_windows[0]["top_ids"], [["NtUserMsgWaitForMultipleObjectsEx", 1, 25_000_000]])
        # The callback thread's own crossing between blocks is flagged.
        cb_windows = [record for record in self.out["threads"] if record["tid"] == TID_CALLBACK]
        self.assertEqual(len(cb_windows), 1)
        self.assertEqual(cb_windows[0]["role"], "pipeasio_callback")
        self.assertEqual(cb_windows[0]["between_blocks"], {"n": 1, "total_ns": 2_000})
        self.assertEqual(self.out["summary"]["counters"]["all"]["between_blocks_events"], 1)

    def test_nesting_inheritance_and_wakers(self):
        b2 = self.block(2)
        wait = self.crossing(b2, "syscall", "NtWaitForSingleObject")
        self.assertEqual(wait["total_ns"], 302_000)
        nt = self.crossing(b2, "ntsync_wait", "WAIT_ANY")
        self.assertEqual(nt["total_ns"], 300_000)
        self.assertEqual(nt["caller"], "ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(nt["woken_by"], {"tid": TID_CALLBACK, "role": "pipeasio_callback", "count": 1})
        req = self.crossing(b2, "server_req", "create_event")
        self.assertEqual(req["tid"], TID_MIDI)
        self.assertEqual(req["role"], "live:MIDI")
        self.assertEqual(req["total_ns"], 8_000)
        self.assertEqual(req["caller"], "ntdll.dll!NtCreateEvent+0x14")
        wake = self.crossing(b2, "ntsync_wake", "EVENT_SET")
        self.assertEqual(wake["role"], "wineserver")
        self.assertEqual(wake["n"], 1)
        self.assertEqual(b2["offcpu"], [{"tid": TID_AUDIO, "role": "audio_worker", "ns": 249_500, "intervals": 1,
                                         "max_run_delay_ns": 1_500}])

    def test_pairing_counters(self):
        counters = self.out["summary"]["counters"]
        self.assertEqual(counters["unmatched_exits"], 1)
        self.assertEqual(counters["unmatched_exits_first_on_tid"], 1)
        self.assertEqual(counters["abandoned_entries"], 1)
        self.assertEqual(counters["lost_events"], 3)
        self.assertEqual(counters["events"], 12)
        self.assertEqual(counters["probe_hits"]["B"], 13)
        self.assertEqual(counters["probe_hits"]["E"], 9)
        self.assertEqual(counters["probe_hits"]["X"], 9)
        self.assertEqual(counters["probe_hits"]["S"], 2)
        self.assertEqual(counters["all"]["ignored_lines"], 1)
        self.assertEqual(counters["all"].get("open_entries_at_end", 0), 0)

    def test_unixcall_and_server_wait_ids(self):
        midi_window0 = [record for record in self.out["threads"] if record["tid"] == TID_MIDI and record["t"] == 0.0][0]
        self.assertEqual(midi_window0["pid"], PID_LIVE)
        self.assertEqual(midi_window0["comm"], "MIDI")
        self.assertEqual(midi_window0["crossings"]["unixcall"], {"n": 1, "total_ns": 120_000})
        self.assertEqual(midi_window0["crossings"]["server_wait"], {"n": 1, "total_ns": 1_000_000})
        # NtCreateEvent was entered with seq 2, so it belongs to block 2, not to this window.
        self.assertEqual(midi_window0["crossings"]["syscall"], {"n": 1, "total_ns": 1_001_000})
        names = [entry[0] for entry in midi_window0["top_ids"]]
        self.assertIn("winscard.so:scard_establish_context", names)
        self.assertIn("interruptible|alertable", names)
        self.assertIn("NtDelayExecution", names)
        midi_window1 = [record for record in self.out["threads"] if record["tid"] == TID_MIDI and record["t"] == 0.1]
        self.assertEqual(len(midi_window1), 1)
        self.assertEqual(midi_window1[0]["top_ids"], [["NtYieldExecution", 1, 3_000]])

    def test_summary_lost_slack_and_call_sites(self):
        summary = self.out["summary"]
        self.assertEqual(summary["schema"], "ableton-linux-tracer-summary/v1")
        self.assertEqual(summary["thresholds"], {"near_late_fraction": 0.15, "deadline_ns_mode": PERIOD,
                                                 "near_late_slack_ns": 200_000})
        blocks = summary["blocks"]
        self.assertEqual((blocks["count"], blocks["late"], blocks["near_late"]), (3, 1, 1))
        self.assertEqual(blocks["slack_ns"]["min"], -126_667)
        self.assertEqual(blocks["slack_ns"]["p50"], 173_333)
        self.assertEqual(blocks["elapsed_ns"]["max"], 1_420_000)
        self.assertEqual(blocks["deadline_ns"], {"min": PERIOD, "max": PERIOD})
        self.assertEqual(blocks["missed_cycles"], 1)
        lost = summary["lost_slack"]
        self.assertEqual(lost["total_ns"], 326_667 + 26_667)
        self.assertEqual(lost["attributed_ns"], 326_667)
        self.assertEqual(lost["unattributed_ns"], 26_667)
        sites = summary["call_sites"]
        self.assertEqual(sites[0]["rank"], 1)
        self.assertEqual(sites[0]["key"], "syscall|NtWaitForSingleObject|ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(sites[0]["late_blocks"], 1)
        self.assertEqual(sites[0]["near_late_blocks"], 0)
        self.assertEqual(sites[0]["n_in_late_blocks"], 1)
        self.assertEqual(sites[0]["per_late_block"], 1.0)
        self.assertEqual(sites[0]["total_ns_in_late_blocks"], 302_000)
        self.assertEqual(sites[0]["max_ns"], 302_000)
        self.assertEqual(sites[0]["n_all_blocks"], 1)
        self.assertEqual(sites[1]["kind"], "ntsync_wait")
        self.assertEqual(sites[1]["woken_by"], [{"tid": TID_CALLBACK, "role": "pipeasio_callback", "count": 1}])
        shares = sum(site["share_of_lost_slack"] for site in sites)
        self.assertLessEqual(shares, 1.0)
        self.assertAlmostEqual(shares, 326_667 / (326_667 + 26_667), places=3)
        keys = set(site["key"] for site in sites)
        self.assertNotIn("syscall|NtReleaseSemaphore|ntdll.dll!NtReleaseSemaphore+0x14", keys)
        self.assertEqual(summary["kinds"]["syscall"]["n"], 7)
        self.assertEqual(summary["kinds"]["server_req"], {"n": 1, "total_ns": 8_000})
        self.assertIn("main", summary["roles"])
        self.assertIn("live:MIDI", summary["roles"])
        self.assertEqual(summary["roles"]["main"]["bins"], 1)
        self.assertEqual(summary["roles"]["main"]["crossings_per_100ms"]["p50"], 1)
        hot = summary["hotspots_non_audio"][0]
        self.assertEqual((hot["role"], hot["kind"], hot["name"], hot["n"], hot["total_ns"]),
                         ("main", "syscall", "NtUserMsgWaitForMultipleObjectsEx", 1, 25_000_000))
        tracer = summary["tracer"]
        self.assertEqual(tracer["lost_events"], 3)
        self.assertEqual(tracer["stopped_monotonic_ns"], S0 + 200_000_000)
        self.assertEqual(tracer["started_monotonic_ns"], S0)
        self.assertGreater(tracer["overhead_estimate_ns_per_block"], 0)

    def test_tracer_json_updated(self):
        tracer = self.out["tracer"]
        self.assertEqual(tracer["stopped_monotonic_ns"], S0 + 200_000_000)
        self.assertEqual(tracer["lost_events"], 3)
        self.assertEqual(tracer["probe_hits"]["S"], 2)
        self.assertEqual(tracer["blocks"], {"count": 3, "late": 1, "near_late": 1})
        self.assertEqual(tracer["counters"]["abandoned_entries"], 1)
        self.assertEqual(tracer["reduce"]["tables"], "wine-11.13.json")

    def test_drilldown_events(self):
        events = self.out["events"]
        self.assertEqual(len(events), 12)
        self.assertEqual([event["t"] for event in events], sorted(event["t"] for event in events))
        waits = [event for event in events if event["kind"] == "ntsync_wait"]
        self.assertEqual(len(waits), 1)
        self.assertEqual(waits[0]["status"], 0)
        self.assertEqual(waits[0]["count"], 1)
        self.assertEqual(waits[0]["woken_by"], {"tid": TID_CALLBACK, "role": "pipeasio_callback"})
        unix = [event for event in events if event["kind"] == "unixcall"][0]
        self.assertEqual(unix["id"], "winscard.so:scard_establish_context")
        self.assertEqual(unix["caller"], "pe!0x140001234")
        self.assertEqual(unix["status"], "0x0")

    def test_shuffled_input_gives_identical_results(self):
        lines = build_fixture()
        body = lines[1:]
        random.Random(1234).shuffle(body)
        shuffled_dir = os.path.join(self.tmp.name, "shuffled")
        os.makedirs(shuffled_dir)
        write_run(shuffled_dir, [lines[0]] + body, mode="drilldown")
        out = run_reduce(shuffled_dir, mode="drilldown")
        self.assertEqual(out["blocks"], self.out["blocks"])
        self.assertEqual(out["threads"], self.out["threads"])
        self.assertEqual(out["summary"]["call_sites"], self.out["summary"]["call_sites"])
        self.assertEqual(out["summary"]["counters"], self.out["summary"]["counters"])
        self.assertEqual(out["events"], self.out["events"])

    def test_summary_mode_writes_no_events(self):
        summary_dir = os.path.join(self.tmp.name, "summary")
        os.makedirs(summary_dir)
        write_run(summary_dir, build_fixture(), mode="summary")
        out = run_reduce(summary_dir, mode="summary")
        self.assertNotIn("events", out)
        self.assertEqual(out["blocks"], self.out["blocks"])
        self.assertEqual(out["blocks_header"]["mode"], "summary")

    def test_builtin_roles_match_shared_classifier(self):
        # With --no-roles the reducer uses its built-in copy of the roles.toml rules; the fixture
        # must classify identically either way (and record which classifier it used).
        builtin_dir = os.path.join(self.tmp.name, "builtin")
        os.makedirs(builtin_dir)
        write_run(builtin_dir, build_fixture(), mode="summary")
        out = run_reduce(builtin_dir, mode="summary", extra=["--no-roles"])
        self.assertEqual(out["blocks_header"]["roles"], "builtin")
        roles = {record["tid"]: record["role"] for record in out["threads"]}
        self.assertEqual(roles[TID_MAIN], "main")
        self.assertEqual(roles[TID_CALLBACK], "pipeasio_callback")
        self.assertEqual(roles[TID_MIDI], "live:MIDI")
        self.assertEqual(self.block(2)["crossings"][0]["role"], "audio_worker")
        shared = {record["tid"]: record["role"] for record in self.out["threads"]}
        self.assertEqual(roles, shared)
        if (TRACER_DIR / "symbolize.py").is_file() and (TRACER_DIR / "roles.toml").is_file():
            self.assertEqual(self.out["blocks_header"]["roles"], "roles.toml")
            self.assertEqual(self.out["summary"]["roles"].keys(), out["summary"]["roles"].keys())

    def test_missing_header_and_empty_input(self):
        empty_dir = os.path.join(self.tmp.name, "empty")
        os.makedirs(empty_dir)
        with open(os.path.join(empty_dir, "events.txt"), "w", encoding="utf-8") as handle:
            handle.write("Attaching 1 probe...\n")
        self.assertEqual(reduce_mod.main(["--in", empty_dir, "--quiet"]), 1)
        self.assertEqual(reduce_mod.main(["--in", os.path.join(self.tmp.name, "nope"), "--quiet"]), 1)
        headerless = os.path.join(self.tmp.name, "headerless")
        os.makedirs(headerless)
        lines = [line for line in build_fixture() if not line.startswith("hdr ")]
        write_run(headerless, lines)
        out = run_reduce(headerless)
        self.assertEqual(out["blocks_header"]["monotonic_start_ns"], S0 + 100)
        self.assertEqual(len(out["blocks"]), 3)


class ParserTest(unittest.TestCase):
    def test_parse_line_shapes(self):
        parse = reduce_mod.parse_line
        self.assertEqual(parse("E 10 5 syscall 46 fr=ab seq=7 rsp=10 rip=20", 0),
                         ("E", 10, 5, "syscall", 0x46, 0, 0xAB, 7, 0x10, 0x20))
        self.assertEqual(parse("E 10 5 unixcall 7f00:3 fr=ab seq=0 rip=20", 0),
                         ("E", 10, 5, "unixcall", 0x7F00, 3, 0xAB, 0, 0, 0x20))
        self.assertEqual(parse("X 11 5 syscall 46 fr=ab st=c0000001 rf=20000", 0),
                         ("X", 11, 5, "syscall", 0x46, 0xAB, 0xC0000001, 0x20000))
        self.assertEqual(parse("X 11 5 unixcall fr=ab st=0", 0), ("X", 11, 5, "unixcall", 0, 0xAB, 0, 0))
        self.assertEqual(parse("S 12 5 req 30 dur=100 st=0 seq=2", 0), ("S", 12, 5, "req", 30, 100, 0, 2))
        self.assertEqual(parse("S 12 5 wait 3 dur=100 st=0 seq=2", 0), ("S", 12, 5, "wait", 3, 100, 0, 2))
        self.assertEqual(parse("T 1 2 3 comm=Ableton Live 12", 0), ("T", 1, 2, 3, "Ableton Live 12"))
        self.assertEqual(parse("N 1 2 comm=pipeasio-rt", 0), ("N", 1, 2, "pipeasio-rt"))
        self.assertEqual(parse("P 1 2 parent=3 comm=Max.exe", 0), ("P", 1, 2, 3, "Max.exe"))
        self.assertEqual(parse("K 1 2 3 cmd=80044e88 seq=4", 0), ("K", 1, 2, 3, 0x80044E88, 4))
        self.assertEqual(parse("O 50 2 off=10 wake=40 st=1", 0), ("O", 50, 2, 10, 40, 1))
        self.assertIsNone(parse("Attaching 3 probes...", 0))
        with self.assertRaises((ValueError, KeyError, IndexError)):
            parse("E 10 5 syscall", 0)

    def test_percentile(self):
        pct = reduce_mod.percentile
        self.assertIsNone(pct([], 50))
        self.assertEqual(pct([5], 1), 5)
        self.assertEqual(pct([1, 2, 3, 4], 50), 2)
        self.assertEqual(pct([1, 2, 3, 4], 99), 4)
        self.assertEqual(pct([1, 2, 3, 4], 1), 1)

    def test_module_map_lookup(self):
        modules = reduce_mod.ModuleMap()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "maps-1.txt")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(MAPS_4200)
            modules.load(path)
        self.assertEqual(modules.lookup(0x7F0000001000), "winscard.so")
        self.assertEqual(modules.lookup(0x7F00010FFFFF), "ntdll.so")
        self.assertIsNone(modules.lookup(0x7F0000100000))
        self.assertIsNone(modules.lookup(0x140000010))  # PE image, not an ELF module

    def test_tables_fallbacks(self):
        tables = reduce_mod.Tables()
        self.assertEqual(tables.syscall_name(0x46), "syscall_0x0046")
        self.assertEqual(tables.request_name(29), "request_29")
        self.assertEqual(tables.unixcall_name(None, 3), "unixcall#3")
        self.assertEqual(tables.unixcall_name("foo.so", 3), "foo.so#3")
        tables = reduce_mod.Tables({"syscalls": {"0x0046": "NtYieldExecution"}, "requests": {"29": "select"},
                                    "unixcalls": {"winscard": {"0": "scard_establish_context"}}})
        self.assertEqual(tables.syscall_name(0x46), "NtYieldExecution")
        self.assertEqual(tables.request_name(29), "select")
        self.assertEqual(tables.unixcall_name("winscard.so", 0), "winscard.so:scard_establish_context")
        self.assertEqual(tables.unixcall_name("winscard.so", 99), "winscard.so#99")


if __name__ == "__main__":
    unittest.main()
