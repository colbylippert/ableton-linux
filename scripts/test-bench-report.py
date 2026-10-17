#!/usr/bin/env python3
"""Deterministic parser and report tests; no Live or PipeWire session needed."""

from __future__ import annotations

import argparse
import importlib.util
import csv
import json
import os
from pathlib import Path
import signal
import stat
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_osc():
    if hasattr(signal, "SIGPIPE"):
        return load("bench_osc", "bench-osc.py")
    # Windows has no SIGPIPE; bench-osc.py installs the Unix default at import.
    with mock.patch.object(signal, "SIGPIPE", signal.SIGTERM, create=True), mock.patch.object(signal, "signal"):
        return load("bench_osc", "bench-osc.py")


report = load("bench_report", "bench-report.py")
osc = load_osc()
FIXTURE_MACHINE_ID = "0123456789abcdef0123456789abcdef"
FIXTURE_CREATED_AT = "2026-08-26T12:34:56.123456Z"
# The tracer starts 0.6 s before the fixture window (1.0 s to 31.0 s on the monotonic clock).
FIXTURE_TRACER_START_NS = 400_000_000
FIXTURE_PERIOD_NS = 1_333_333
FIXTURE_FRAMES = [
    "ntdll.dll!NtWaitForSingleObject+0x14", "kernelbase.dll!WaitForSingleObjectEx+0xe3",
    "Ableton Live 12 Trial.exe+0x1a2b3c", "Ableton Live 12 Trial.exe+0x9999",
]
FIXTURE_CALLER = " <- ".join(FIXTURE_FRAMES[:3])
SITE_A_KEY = f"ntsync_wait|NtWaitForSingleObject|{FIXTURE_CALLER}"
SITE_B_KEY = "syscall|NtReleaseSemaphore|unsampled"


def benchmark_profile(gates=None):
    return {
        "schema": report.SCHEMA, "kind": "system-profile",
        "machine": {
            "id": FIXTURE_MACHINE_ID,
            "scope": "stable per-user benchmark ID",
            "source": "persistent-random-v1",
        },
        "system": {
            "uname": "Linux fixture 1", "os_release": {"ID": "fixture"},
            "cpu": {"Architecture": "x86_64", "CPU(s)": "8", "Model name": "Fixture CPU"},
            "memory": {"MemTotal": 16 * 1024**3},
            "report_filesystem": {"total_bytes": 100 * 1024**3, "available_bytes": 60 * 1024**3},
            "cpu_topology": [{"CPU": "0", "CORE": "0", "MHZ": "1234"}],
            "cpu_sysfs": {"cpus": [{"cpu": 0, "cpufreq.scaling_governor": "performance"}]},
            "gpu_lines": ["Fixture GPU"], "gpu_renderer_lines": ["Fixture renderer"],
            "audio_devices": {"alsa_cards": "Fixture audio", "playback": "P", "capture": "C"},
            "audio_kernel": {"available": True, "parameters": {"lowlatency": {"available": True, "value": "Y"}}},
            "power_profile": "performance",
        },
        "pipewire": {
            "versions": {"pipewire": "1.4", "wireplumber": "0.5", "pw_cli": "1.4"},
            "settings": {"values": {"clock.rate": "48000", "clock.quantum": "64"}},
            "active_profile_lines": ["profile = pro-audio"],
            "capture_scope": {"phase": "fixture"},
            "availability": {"pw-dump": {"successful": True}},
        },
        "runtime": {"root": "/runtime", "identity_hash": "runtime-a", "wine_version": "wine-11", "build_info": "build-a"},
        "prefix": {"path": "/prefix", "identity_hash": "prefix-a"},
        "configuration": {
            "identity_hash": "config-a", "benchmark_gates": gates or {},
            "pipeasio_effective_config": {"path": "/config/pipeasio/config.ini", "resolution": "XDG_CONFIG_HOME", "exists": True, "sha256": "asio-a"},
        },
        "live": {
            "executables": [{"product_version": "12.4.3", "sha256": "live-a"}],
            "preferences": [{"version": "12.4.3", "options": ["-MaxAudioThreads=4"], "options_hash": {"sha256": "options-a"}, "max_audio_threads": 4}],
        },
        "fixture_plugins": [
            {"name": "Dexed.vst3", "path": "/prefix/Dexed.vst3", "exists": True, "identity_hash": "dexed-a"},
            {"name": "K1v_x64.vst3", "path": "/prefix/K1v_x64.vst3", "exists": True, "identity_hash": "k1v-a"},
        ],
    }


def benchmark_resource_sample(index=1):
    return {
        "index": index,
        "captured_at": "2026-08-26T12:35:01Z",
        "scheduled_elapsed_seconds": float(index),
        "elapsed_seconds": float(index) + 0.001,
        "schedule_lateness_seconds": 0.001,
        "interval_seconds": 1.0,
        "collection_seconds": 0.0005,
        "availability": {
            "cpu": True, "memory": True, "load": True,
            "pressure_cpu": True, "pressure_memory": True, "pressure_io": True,
        },
        "cpu": {"busy_percent": 25.0, "idle_percent": 70.0, "iowait_percent": 5.0, "steal_percent": 0.0},
        "memory": {
            "total_bytes": 16 * 1024**3, "available_bytes": 12 * 1024**3,
            "swap_total_bytes": 4 * 1024**3, "swap_free_bytes": 3 * 1024**3,
        },
        "load": {"load_1m": 1.0, "load_5m": 0.8, "load_15m": 0.6, "runnable_tasks": 2, "total_tasks": 200},
        "pressure": {
            "cpu": {"some_percent": 2.0, "full_percent": 0.0},
            "memory": {"some_percent": 0.1, "full_percent": 0.0},
            "io": {"some_percent": 0.2, "full_percent": 0.1},
        },
    }


def benchmark_measurement(name, live_cpu=10.0, missing=False, zero=False, mode=None):
    value = 0 if zero else live_cpu
    timing = {
        "supervision_interval_seconds": 30.0, "output_span_seconds": 29.5, "output_line_count": 30,
        "first_output_offset_seconds": 0.1, "last_output_offset_seconds": 29.9,
    }
    summary = {
        group: {
            "cpu_percent_of_one_core": (value if group == "live" else 20.0),
            "context_switches": 100,
            "schedstat": {"runtime_ns": 1_000, "run_delay_ns": 20, "timeslices": 30},
            **({"audio_worker_count": 4} if group == "live" else {}),
        }
        for group in ("live", "wine_prefix", "pipewire")
    }
    measurement = {
        "schema": report.SCHEMA, "kind": "set-measurement",
        "set": name, "mode": mode or report.CANONICAL_MODES.get(name, "playback"), "duration_seconds": 30,
        "window": {
            "requested_duration_seconds": 30,
            "monotonic_start_ns": 1_000_000_000,
            "monotonic_deadline_ns": 31_000_000_000,
            "cpu_before_collection_offsets_seconds": [-0.02, -0.01],
            "cpu_after_collection_offsets_seconds": [30.0, 30.02],
        },
        "process": {
            "summary": summary,
            "details": {
                "elapsed_seconds": 30.0, "host_cpu_percent": {"cpu": 25.0},
                "accounting": {
                    "confounded_by_task_churn": False,
                    "processes": {"born": [], "exited": []}, "threads": {"born": [], "exited": []},
                },
            },
        },
        "pipewire": {
            "pw_top": {"instrumented": True, "identity_confounded": False, "err_delta": 0, "quantum_transitions": []},
            "settings": {"transitions": []},
        },
        "osc_dsp": {"sample_count": 30, "average_percent": 12.0, "peak_percent": 18.0},
        "kernel_counters": {
            name: {"available": True, "complete": True, "total_rate_per_second": rate, "labels": {}}
            for name, rate in (("interrupts", 100.0), ("softirqs", 200.0))
        },
        "endpoint_identity": {
            "cpu_policy": {
                "changed_within_window": False,
                "before": {"available": True, "policies": [{"policy": "policy0", "scaling_governor": "performance"}]},
                "after": {"available": True, "policies": [{"policy": "policy0", "scaling_governor": "performance"}]},
            },
            "power": {
                "changed_within_window": False,
                "before": {"available": True, "profile": "performance", "holds_available": True, "holds": "bench"},
                "after": {"available": True, "profile": "performance", "holds_available": True, "holds": "bench"},
            },
            "audio": {
                "changed_within_window": False,
                "before": {
                    "available": True, "component_availability": {"sink": True, "source": True, "links": True, "settings": True},
                    "default_sink": ["device.name = fixture"], "default_source": ["device.name = fixture"],
                    "links": ["PipeASIO:output_1 -> fixture:playback_FL"],
                    "graph_settings": {"clock.rate": "48000", "clock.quantum": "64"},
                },
                "after": {
                    "available": True, "component_availability": {"sink": True, "source": True, "links": True, "settings": True},
                    "default_sink": ["device.name = fixture"], "default_source": ["device.name = fixture"],
                    "links": ["PipeASIO:output_1 -> fixture:playback_FL"],
                    "graph_settings": {"clock.rate": "48000", "clock.quantum": "64"},
                },
            },
        },
        "capture_commands": {
            collector: {"available": True, "timing": timing}
            for collector in ("pw-top", "pw-metadata", "osc")
        },
        "live": {"version": "12.4.3", "build": "fixture", "sample_rate": 48000, "output_buffer_frames": 64},
        "system_resources": {
            "collector": "in-process-procfs-v1", "requested_interval_seconds": 1,
            "expected_sample_count": 30, "sample_count": 1, "missed_sample_count": 29,
            "coverage_complete": False, "maximum_schedule_lateness_seconds": 0.001,
            "samples": [benchmark_resource_sample()],
        },
        "crackle": {"status": "no-instrumented-evidence"}, "confounders": [],
    }
    if missing:
        measurement["process"]["summary"]["live"]["cpu_percent_of_one_core"] = None
    return measurement


def write_benchmark_run(
    root, *, status="complete", duration=30, profile=None, live_cpu=10.0, missing=False, zero=False,
    sets=None, structure=None, scenario=None, trace_mode=None, tracer=None, modes=None,
):
    (root / "profile").mkdir(parents=True)
    (root / "sets").mkdir()
    names = list(sets or report.CANONICAL_SETS)
    run = {
        "schema": report.SCHEMA, "kind": "benchmark-run", "harness": {"identity_hash": "harness-a"},
        "status": status, "tag": root.name, "duration_seconds_per_set": duration,
        "set_order": names, "created_at": FIXTURE_CREATED_AT,
        "machine": {
            "id": FIXTURE_MACHINE_ID, "scope": "stable per-user benchmark ID", "source": "persistent-random-v1",
        },
        "csv": {
            "schema": report.CSV_SCHEMA,
            "filename": report.cpu_benchmark_csv_filename(FIXTURE_MACHINE_ID, FIXTURE_CREATED_AT),
            "timestamp": report.filename_timestamp(FIXTURE_CREATED_AT),
        },
    }
    if structure:
        run["structure"] = structure
    if scenario:
        run["scenario"] = scenario
    if trace_mode:
        run["trace"] = {"mode": trace_mode, "tracer": tracer, "privilege": "sudo"}
    (root / "run.json").write_text(json.dumps(run))
    (root / "profile/profile.json").write_text(json.dumps(profile or benchmark_profile()))
    for index, name in enumerate(names, 1):
        directory = root / "sets" / f"{index:02d}-{name}"
        directory.mkdir()
        measurement = benchmark_measurement(name, live_cpu, missing, zero, (modes or {}).get(name))
        measurement["duration_seconds"] = duration
        if trace_mode:
            measurement["trace"] = {"mode": trace_mode, "directory": report.INTERFACE_DIRECTORY}
        (directory / "measurement.json").write_text(json.dumps(measurement))


def interface_tracer(stopped_ns=31_400_000_000, lost_events=0, version="wine-trace/1"):
    return {
        "version": version, "mode": "summary", "sample_rate": 64,
        "attach": ["ntdll.so:wine:*", "pipeasio64.dll.so:pipeasio:*"],
        "started_monotonic_ns": FIXTURE_TRACER_START_NS, "stopped_monotonic_ns": stopped_ns,
        "lost_events": lost_events, "probe_hits": {"syscall_entry": 1000},
        "overhead_estimate_ns_per_block": 500,
    }


def interface_crossing(tid, role, kind, identifier, n, total_ns, max_ns, woken_by=None, caller=None):
    crossing = {"tid": tid, "role": role, "kind": kind, "id": identifier, "n": n, "total_ns": total_ns, "max_ns": max_ns}
    if caller:
        crossing["caller"] = caller
    if woken_by:
        crossing["woken_by"] = woken_by
    return crossing


def interface_block(seq, t_start, slack_ns, crossings=(), stacks=(), elapsed=0.00043):
    return {
        "seq": seq, "t_start": t_start, "t_end": round(t_start + elapsed, 6),
        "period_ns": FIXTURE_PERIOD_NS, "slack_ns": slack_ns, "late": slack_ns < 0,
        "near_late": 0 <= slack_ns < 200_000, "missed_cycles": int(slack_ns < 0),
        "crossings": list(crossings), "stacks": list(stacks),
    }


def interface_blocks():
    """Twelve blocks: two late, three near-late, five on time, two outside the window."""
    site_a = lambda n, total, peak, woken_by=None: interface_crossing(  # noqa: E731
        4242, "pipeasio_callback", "ntsync_wait", "NtWaitForSingleObject", n, total, peak, woken_by,
    )
    site_b = lambda n, total, peak: interface_crossing(  # noqa: E731
        4301, "audio_worker", "syscall", "NtReleaseSemaphore", n, total, peak,
    )
    site_c = interface_crossing(4301, "audio_worker", "syscall", "NtYieldExecution", 10, 50_000, 9_000)
    site_main = interface_crossing(4200, "main", "server_req", "select", 5, 90_000, 40_000)
    stack_a = {"tid": 4242, "kind": "ntsync_wait", "id": "NtWaitForSingleObject", "frames": FIXTURE_FRAMES, "stop": "max_frames"}
    waker = {"tid": 4301, "role": "audio_worker"}
    return [
        {"type": "header", "monotonic_start_ns": FIXTURE_TRACER_START_NS, "mode": "summary"},
        interface_block(1, 0.1, -999_999, [site_a(100, 9_000_000, 9_000_000)]),
        interface_block(2, 1.0, -210_000, [site_a(4, 300_000, 210_000, waker), site_b(3, 2_100, 900)], [stack_a], 0.00154),
        interface_block(3, 2.0, -50_000, [site_a(8, 400_000, 150_000), site_b(2, 1_000, 600)], [stack_a]),
        interface_block(4, 3.0, 50_000, [site_a(2, 100_000, 80_000)], [stack_a]),
        interface_block(5, 4.0, 150_000, [site_b(1, 60_000, 60_000)]),
        interface_block(6, 5.0, 199_000),
        interface_block(7, 6.0, 900_000, [site_c, site_a(1, 20_000, 20_000)], [stack_a]),
        interface_block(8, 7.0, 950_000, [site_c, site_main]),
        interface_block(9, 8.0, 1_000_000, [site_c]),
        interface_block(10, 9.0, 1_100_000, [site_c]),
        interface_block(11, 10.0, 850_000, [site_c]),
        interface_block(12, 31.0, -5_000, [site_a(1, 5_000, 5_000)]),
    ]


def interface_threads():
    bin_ = lambda t, tid, role, crossings: {  # noqa: E731
        "t": t, "window_ms": 100, "tid": tid, "role": role, "oncpu_ns": 1_000, "offcpu_ns": 99_000_000,
        "crossings": crossings, "top_ids": [],
    }
    return [
        {"type": "header", "monotonic_start_ns": FIXTURE_TRACER_START_NS},
        bin_(0.1, 4301, "audio_worker", {"syscall": {"n": 999, "total_ns": 999}}),
        bin_(1.0, 4301, "audio_worker", {"syscall": {"n": 40, "total_ns": 950_000}}),
        bin_(1.1, 4301, "audio_worker", {"syscall": {"n": 60, "total_ns": 1_050_000}}),
        bin_(1.0, 4200, "main", {"server_req": {"n": 2, "total_ns": 80_000}, "syscall": {"n": 10, "total_ns": 20_000}}),
    ]


def write_interface_files(set_dir, tracer=None, blocks=None, threads=None):
    directory = set_dir / "raw/interface"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "tracer.json").write_text(json.dumps(tracer or interface_tracer()))
    (directory / "blocks.jsonl").write_text("".join(json.dumps(item) + "\n" for item in blocks or interface_blocks()))
    (directory / "threads.jsonl").write_text("".join(json.dumps(item) + "\n" for item in threads or interface_threads()))
    return directory


def fixture_interface_section(**options):
    measurement = benchmark_measurement("Benchmark_Empty")
    measurement["trace"] = {"mode": "interface", "directory": report.INTERFACE_DIRECTORY}
    blocks = options.pop("blocks", None) or [item for item in interface_blocks() if item.get("type") != "header"]
    threads = [item for item in interface_threads() if item.get("type") != "header"]
    return report.interface_section(
        measurement, options.pop("tracer", interface_tracer()), options.pop("summary", {}), blocks,
        FIXTURE_TRACER_START_NS, threads, FIXTURE_TRACER_START_NS, **options,
    )


def load_reduce_fixture():
    """profiler/tracer/tests/test_reduce.py: the reducer's synthetic trace and runner."""
    return load("tracer_test_reduce", "../profiler/tracer/tests/test_reduce.py")


class ParserTests(unittest.TestCase):
    def test_pw_top_xruns_reset_and_quantum_transition(self):
        fixture = """\
0.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
0.100000\tR 42 256 48000 0.1 0.2 0.0 0.0 2 S16LE Ableton Live
1.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
1.100000\tR 42 256 48000 0.1 0.2 0.0 0.0 4 S16LE Ableton Live
2.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
2.100000\tR 42 128 48000 0.1 0.2 0.0 0.0 5 S16LE Ableton Live
2.100000\tR 99 128 48000 0.1 0.2 0.0 0.0 99 S16LE Firefox
"""
        parsed = report.parse_pw_top(fixture)
        self.assertTrue(parsed["instrumented"])
        self.assertEqual(parsed["err_delta"], 3)
        self.assertEqual(parsed["nodes"][0]["quantums"], [256, 128])
        self.assertEqual(parsed["quantum_transitions"][0]["to"], 128)

    def test_pw_top_splits_node_generations_on_reset_gap_and_name_change(self):
        fixture = """\
0.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
0.1\tR 42 256 48000 0.1 0.2 0.0 0.0 5 S16LE Ableton Live
1.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
1.1\tR 42 256 48000 0.1 0.2 0.0 0.0 1 S16LE Ableton Live
2.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
2.1\tR 99 256 48000 0.1 0.2 0.0 0.0 0 S16LE Firefox
3.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
3.1\tR 42 128 48000 0.1 0.2 0.0 0.0 2 S16LE Ableton Live
4.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
4.1\tR 42 128 48000 0.1 0.2 0.0 0.0 2 S16LE PipeASIO
"""
        parsed = report.parse_pw_top(fixture)
        self.assertEqual([node["generation"] for node in parsed["nodes"]], [1, 2, 3, 4])
        self.assertEqual([event["reason"] for event in parsed["node_lifecycle_events"]], [
            "error-counter-reset-or-id-reuse",
            "disappeared-and-reappeared",
            "name-change-or-id-reuse",
        ])
        self.assertTrue(parsed["identity_confounded"])
        self.assertEqual(parsed["err_delta"], 1)

    def test_pw_top_effective_quantum_follows_the_driver(self):
        # B4 on the laptop: the settings metadata said 256, the graph ran at 64.
        # Live is a follower ("+ " prefix, empty FORMAT) of the driving source.
        fixture = """\
0.004987\tS   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
0.005108\tC   97      0      0    ---     ---   ---   ---     0                  Ableton Live 12 Trial
0.247468\tS   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
0.247560\tI   29      0      0   0.0us   0.0us  ???   ???     0                  Dummy-Driver
0.247759\tR   66     64  48000   4.1ms  41.1us  3.10  0.03  23522    S32LE 2 48000 alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source
0.247780\tR   64      0      0    +++   36.6us  +++   0.03  720299    S32LE 2 48000  + alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink
0.247800\tR   97     64  48000  36.2us 538.1us  0.03  0.40   19                   + Ableton Live 12 Trial
0.247814\tS   67      0      0    ---     ---   ---   ---     0                  bluez_midi.server
1.004847\tS   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
1.005759\tR   66     64  48000   4.1ms  41.1us  3.10  0.03  23530    S32LE 2 48000 alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source
1.005800\tR   97     64  48000  36.2us 538.1us  0.03  0.40   21                   + Ableton Live 12 Trial
"""
        parsed = report.parse_pw_top(fixture)
        self.assertEqual((parsed["effective_rate"], parsed["effective_quantum"]), (48000, 64))
        self.assertEqual(parsed["effective_quantums"], [64])
        self.assertEqual(parsed["driver_names"], ["alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source"])
        self.assertEqual(parsed["err_delta"], 2)
        self.assertEqual([node["name"] for node in parsed["nodes"]], ["Ableton Live 12 Trial"])
        self.assertEqual(report.pw_top_row_tail("R 97 64 48000 1us 2us 0.0 0.0 19 + Ableton Live 12 Trial"),
                         (True, "Ableton Live 12 Trial"))
        self.assertEqual(report.pw_top_row_tail("R 66 64 48000 1us 2us 0.0 0.0 1 S32LE 2 48000 alsa_input.x"),
                         (False, "alsa_input.x"))
        settings = {"clock.rate": "48000", "clock.quantum": "256"}
        self.assertEqual(report.sample_rate_buffer_label(parsed, settings, settings), "48000/64 (graph default 256)")
        self.assertEqual(
            report.sample_rate_buffer_label(parsed, settings, {"clock.rate": "48000", "clock.quantum": "128"}),
            "48000/64 (graph default 48000/256 → 48000/128)",
        )
        self.assertEqual(report.sample_rate_buffer_label({}, settings, settings), "pending (graph default 48000/256)")
        # A driver that changes its quantum inside the window shows every value.
        changed = dict(parsed, effective_quantums=[64, 128, 64])
        self.assertEqual(report.sample_rate_buffer_label(changed, settings, settings), "48000/64→128→64 (graph default 256)")

    def test_pw_top_driver_is_the_node_itself_when_it_drives(self):
        fixture = """\
0.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
0.1\tR 42 128 48000 0.1 0.2 0.0 0.0 2 S16LE Ableton Live
0.2\tR 43 0 0 0.1 0.2 0.0 0.0 0 + Ableton Live helper
"""
        parsed = report.parse_pw_top(fixture)
        self.assertEqual((parsed["effective_rate"], parsed["effective_quantum"]), (48000, 128))
        self.assertEqual(parsed["driver_names"], ["Ableton Live"])

    def test_osc_peak_is_the_worst_buffer_per_report(self):
        # B4 Inbuilts: average 30-88%, peaks around 50% and up to 715% where the
        # PipeWire ERR counter rose; the median keeps one overrun from owning the cell.
        fixture = "".join(
            f"{index * 0.5:.1f}\t1700000000.000 /abl/bench/cpu {average} {peak}\n"
            for index, (average, peak) in enumerate([(30, 47.475), (32, 53.7), (31, 132.15), (80, 715.125), (75, 50.0)])
        )
        parsed = report.parse_osc(fixture)
        self.assertEqual(parsed["peak_percent"], 715.125)
        self.assertEqual(parsed["peak_median_percent"], 53.7)
        self.assertEqual(parsed["peak_over_100_count"], 2)
        self.assertEqual(report.dsp_label(parsed), "49.60 / 53.70 (max 715.12, 2 over 100%)")
        self.assertEqual(report.dsp_label({"average_percent": 12.0, "peak_percent": 18.0}), "12.00 / 18.00")
        self.assertEqual(report.dsp_label({}), "pending / pending")
        even = report.parse_osc("0.1\t1.0 /abl/bench/cpu 10 20\n0.2\t1.5 /abl/bench/cpu 10 30\n")
        self.assertEqual(even["peak_median_percent"], 25.0)
        self.assertEqual(even["peak_over_100_count"], 0)

    def test_osc_average_and_peak_are_distinct(self):
        fixture = """\
0.1\t1700000000.000 /abl/bench/cpu 10 14
0.2\t1700000000.250 /abl/bench/playing 0
0.2\t1700000000.500 /abl/bench/cpu -1 -1
0.3\t1700000001.000 /abl/bench/cpu 20 31
"""
        parsed = report.parse_osc(fixture)
        self.assertEqual(parsed["sample_count"], 2)
        self.assertEqual(parsed["average_percent"], 15.0)
        self.assertEqual(parsed["peak_percent"], 31.0)
        self.assertEqual(parsed["addresses"]["/abl/bench/playing"], 1)
        self.assertEqual(report.playback_state_confounder("playback", parsed)["kind"], "playback-state-changed")
        self.assertIsNone(report.playback_state_confounder("idle-no-controller", parsed))

    def test_metadata_transition_parser(self):
        fixture = """\
0.0\tupdate: id:0 key:'clock.quantum' value:'256' type:''
1.0\tremove: id:0 key:'clock.quantum'
2.0\tupdate: id:0 key:'clock.quantum' value:'128' type:''
3.0\tupdate: id:0 key:'clock.rate' value:'48000' type:''
4.0\tremove: id:0 all keys
"""
        parsed = report.parse_metadata(fixture)
        self.assertEqual(parsed["values"], {})
        self.assertEqual(
            [(item["key"], item["from"], item["to"]) for item in parsed["transitions"]],
            [
                ("clock.quantum", "256", None),
                ("clock.quantum", None, "128"),
                ("clock.quantum", "128", None),
                ("clock.rate", "48000", None),
            ],
        )
        self.assertEqual([item["operation"] for item in parsed["events"]], [
            "update", "remove", "update", "update", "remove-all",
        ])

    def test_metadata_literal_null_is_a_delete_readd_transition(self):
        fixture = """\
0.0\tupdate: id:0 key:'clock.force-rate' value:'48000' type:''
1.0\tupdate: id:0 key:'clock.force-rate' value:(null) type:''
2.0\tupdate: id:0 key:'clock.force-rate' value:'44100' type:''
"""
        parsed = report.parse_metadata(fixture)
        self.assertEqual(parsed["values"]["clock.force-rate"], "44100")
        self.assertEqual(
            [(item["from"], item["to"]) for item in parsed["transitions"]],
            [("48000", None), (None, "44100")],
        )

    def test_endpoint_task_lifecycle_is_explicitly_confounded(self):
        def task(pid, start, comm, cpu, threads=()):
            return {
                "pid": pid, "starttime_ticks": start, "comm": comm,
                "utime_ticks": cpu, "stime_ticks": 0, "status": {
                    "voluntary_ctxt_switches": cpu, "nonvoluntary_ctxt_switches": 0,
                },
                "schedstat": {"runtime_ns": cpu, "run_delay_ns": 0, "timeslices": cpu},
                "threads": list(threads), "cmdline": [comm], "exe": f"/runtime/{comm}",
            }

        before = {
            "monotonic_ns": 1_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [
                task(10, 100, "Live", 10, [task(10, 100, "Main", 5), task(11, 101, "Old", 1)]),
                task(20, 200, "Helper", 3, [task(20, 200, "Helper", 3)]),
            ],
        }
        after = {
            "monotonic_ns": 31_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [
                task(10, 100, "Live", 40, [task(10, 100, "Main", 20), task(12, 102, "New", 2)]),
                task(30, 300, "Born", 2, [task(30, 300, "Born", 2)]),
            ],
        }
        parsed = report.snapshots_delta(before, after)
        accounting = parsed["accounting"]
        self.assertEqual([item["pid"] for item in parsed["processes"]], [10])
        self.assertTrue(accounting["confounded_by_task_churn"])
        self.assertEqual(accounting["confounder"], "task-churn-detected")
        self.assertEqual([item["pid"] for item in accounting["processes"]["born"]], [30])
        self.assertEqual([item["pid"] for item in accounting["processes"]["exited"]], [20])
        self.assertEqual([item["pid"] for item in accounting["threads"]["born"]], [12, 30])
        self.assertEqual([item["pid"] for item in accounting["threads"]["exited"]], [11, 20])
        self.assertEqual(parsed["elapsed_seconds"], 30.0)
        self.assertEqual(parsed["elapsed_lower_bound_seconds"], 30.0)
        self.assertEqual(parsed["elapsed_upper_bound_seconds"], 30.0)

    def test_small_thread_only_churn_is_counted_but_not_confounded(self):
        def task(pid, start, cpu, threads=()):
            return {
                "pid": pid, "starttime_ticks": start, "comm": "AudioCalc",
                "utime_ticks": cpu, "stime_ticks": 0,
                "status": {"voluntary_ctxt_switches": cpu, "nonvoluntary_ctxt_switches": 0},
                "schedstat": {"runtime_ns": cpu, "run_delay_ns": 0, "timeslices": cpu},
                "threads": list(threads), "cmdline": ["AudioCalc"], "exe": "/runtime/wine64",
            }

        before_threads = [task(pid, pid, 1) for pid in range(1000, 1180)]
        after_threads = [task(pid, pid, 2) for pid in range(1000, 1178)]
        after_threads.extend([task(2000, 2000, 1), task(2001, 2001, 1)])
        before = {
            "monotonic_ns": 1_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [task(10, 10, 1, before_threads)],
        }
        after = {
            "monotonic_ns": 31_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [task(10, 10, 2, after_threads)],
        }
        accounting = report.snapshots_delta(before, after)["accounting"]
        self.assertFalse(accounting["confounded_by_task_churn"])
        self.assertEqual(accounting["confounder"], "task-churn-below-threshold")
        self.assertEqual(accounting["counts"]["thread_events"], 4)
        self.assertEqual(accounting["thresholds"]["thread_events"], 9)
        after["processes"][0]["threads"] = [task(pid, pid, 2) for pid in range(1000, 1170)]
        after["processes"][0]["threads"].extend(task(pid, pid, 1) for pid in range(2000, 2010))
        material = report.snapshots_delta(before, after)["accounting"]
        self.assertTrue(material["confounded_by_task_churn"])
        self.assertEqual(material["counts"]["thread_events"], 20)
        self.assertEqual(material["thresholds"]["thread_events"], 9)

    def test_timed_command_reports_observed_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            command = report.TimedCommand(
                "fixture", [sys.executable, "-c", "print('one'); print('two')"],
                Path(temporary), time.monotonic_ns(),
            )
            command.start()
            assert command.process is not None
            command.process.wait(timeout=2)
            time.sleep(0.05)
            command.terminate_at_deadline()
            result = command.stop()
            timing = result["timing"]
            self.assertEqual(timing["output_line_count"], 2)
            self.assertIsNotNone(timing["spawned_offset_seconds"])
            self.assertIsNotNone(timing["deadline_observed_offset_seconds"])
            self.assertGreaterEqual(timing["output_span_seconds"], 0)
            self.assertTrue(timing["exited_before_deadline"])
            self.assertLess(timing["supervision_interval_seconds"], timing["deadline_observed_offset_seconds"])
            self.assertFalse(report.collector_command_usable(result, 30))

    def test_periodic_collector_with_silent_tail_is_unusable_but_metadata_monitor_is_valid(self):
        command = {
            "available": True,
            "timing": {
                "supervision_interval_seconds": 30.0,
                "output_line_count": 2,
                "first_output_offset_seconds": 0.1,
                "last_output_offset_seconds": 1.1,
                "reader_alive_after_join": False,
            },
        }
        self.assertFalse(report.collector_command_usable(command, 30, "pw-top"))
        self.assertFalse(report.collector_command_usable(command, 30, "osc"))
        self.assertTrue(report.collector_command_usable(command, 30, "pw-metadata"))

    def test_osc_collector_allows_control_device_report_edges(self):
        command = {
            "available": True,
            "timing": {
                "supervision_interval_seconds": 30.0,
                "output_line_count": 56,
                "first_output_offset_seconds": 1.8825,
                "last_output_offset_seconds": 28.118,
                "reader_alive_after_join": False,
            },
        }
        self.assertTrue(report.collector_command_usable(command, 30, "osc"))
        self.assertFalse(report.collector_command_usable(command, 30, "pw-top"))

    def test_duration_floor_keeps_one_second_collectors_instrumented(self):
        self.assertEqual(report.positive_duration("10"), 10)
        with self.assertRaisesRegex(argparse.ArgumentTypeError, "between 10 and 3600"):
            report.positive_duration("9")

    def test_udp_preflight_reports_socket_creation_failure(self):
        args = type("Args", (), {"port": 19002})()
        with mock.patch.object(report.socket, "socket", side_effect=OSError("denied")), mock.patch("builtins.print"):
            self.assertEqual(report.udp_available(args), 1)

    def test_effective_pipeasio_config_follows_xdg_then_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            xdg_path = root / "xdg/pipeasio/config.ini"
            xdg_path.parent.mkdir(parents=True)
            xdg_path.write_text("[pipeasio]\n")
            xdg = report.effective_pipeasio_config({"XDG_CONFIG_HOME": str(root / "xdg"), "HOME": "/ignored"})
            self.assertEqual(xdg["path"], str(xdg_path))
            self.assertEqual(xdg["resolution"], "XDG_CONFIG_HOME")
            home = report.effective_pipeasio_config({"HOME": str(root / "home")})
            self.assertEqual(home["path"], str(root / "home/.config/pipeasio/config.ini"))
            self.assertEqual(report.effective_pipeasio_config({})["path"], None)

    def test_benchmark_machine_id_is_private_stable_and_filename_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "config/cpu-benchmark-machine-id-v1"
            first = report.load_benchmark_machine_id(path=path, token=FIXTURE_MACHINE_ID)
            second = report.load_benchmark_machine_id(path=path, token="f" * 32)
            self.assertEqual(first, FIXTURE_MACHINE_ID)
            self.assertEqual(second, FIXTURE_MACHINE_ID)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(
                report.cpu_benchmark_csv_filename(first, FIXTURE_CREATED_AT),
                f"{FIXTURE_MACHINE_ID}-20260826T123456123456Z_cpu-benchmark.csv",
            )
            self.assertNotEqual(
                report.cpu_benchmark_csv_filename(first, "2026-08-26T12:34:56.123457Z"),
                report.cpu_benchmark_csv_filename(first, FIXTURE_CREATED_AT),
            )
            with self.assertRaisesRegex(ValueError, "must contain 32 lowercase hexadecimal characters"):
                report.cpu_benchmark_csv_filename("../machine", FIXTURE_CREATED_AT)
            self.assertFalse(any(item.name.startswith(".cpu-benchmark-machine-id-v1.") for item in path.parent.iterdir()))

    def test_benchmark_machine_id_refuses_malformed_or_indirect_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            invalid = root / "invalid"
            invalid.write_text("machine/name\n")
            invalid.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "must contain 32 lowercase hexadecimal characters"):
                report.load_benchmark_machine_id(path=invalid)
            permissive = root / "permissive"
            permissive.write_text(FIXTURE_MACHINE_ID + "\n")
            permissive.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "mode 0600"):
                report.load_benchmark_machine_id(path=permissive)
            link = root / "link"
            link.symlink_to(permissive)
            with self.assertRaisesRegex(ValueError, "check access|regular file"):
                report.load_benchmark_machine_id(path=link)

    def test_benchmark_machine_id_creation_failure_is_a_clean_refusal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent = root / "config-as-file"
            parent.write_text("fixture")
            with self.assertRaisesRegex(ValueError, "check access.*report source ID location"):
                report.load_benchmark_machine_id(path=parent / report.MACHINE_ID_FILENAME)
            args = type("Args", (), {
                "output": str(root / "run.json"), "tag": "fixture", "duration": 30,
                "set": list(report.CANONICAL_SETS),
            })()
            with mock.patch.dict(os.environ, {"ABLETON_CONFIG_HOME": str(parent)}, clear=False), \
                 mock.patch("builtins.print"):
                self.assertEqual(report.init_run(args), 2)
            self.assertFalse((root / "run.json").exists())

    def test_init_run_stores_one_machine_timestamp_and_csv_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            report.load_benchmark_machine_id(path=config / report.MACHINE_ID_FILENAME, token=FIXTURE_MACHINE_ID)
            args = type("Args", (), {
                "output": str(root / "run.json"), "tag": "fixture", "duration": 30,
                "set": list(report.CANONICAL_SETS),
            })()
            with mock.patch.dict(os.environ, {"ABLETON_CONFIG_HOME": str(config)}, clear=False), \
                 mock.patch.object(report, "utc_now", return_value=FIXTURE_CREATED_AT):
                self.assertEqual(report.init_run(args), 0)
            run = json.loads((root / "run.json").read_text())
            self.assertEqual(run["machine"]["id"], FIXTURE_MACHINE_ID)
            self.assertEqual(
                run["csv"]["filename"],
                f"{FIXTURE_MACHINE_ID}-20260826T123456123456Z_cpu-benchmark.csv",
            )

    def test_resource_parsers_and_interval_report_available_capacity(self):
        memory = report.parse_meminfo(
            "MemTotal: 1000 kB\nMemAvailable: 750 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\n"
        )
        self.assertEqual(memory["MemAvailable"], 750 * 1024)
        self.assertEqual(report.parse_loadavg("1.25 0.75 0.50 3/200 1234")["runnable_tasks"], 3)
        pressure = report.parse_pressure("some avg10=1.00 avg60=0.5 avg300=0.1 total=100000\n")
        self.assertEqual(pressure["some"]["total"], 100000)
        before = {
            "captured_at": "before", "monotonic_ns": 1_000_000_000, "collection_seconds": 0.001,
            "cpu": {"cpu": [100, 0, 50, 1000, 10, 5, 5, 0]},
            "memory": memory, "load": report.parse_loadavg("1 1 1 2/100 1"),
            "pressure": {name: {"some": {"total": 1000}, "full": {"total": 500}} for name in ("cpu", "memory", "io")},
        }
        after = {
            **before, "captured_at": "after", "monotonic_ns": 2_000_000_000,
            "cpu": {"cpu": [120, 0, 60, 1060, 15, 7, 8, 0]},
            "pressure": {name: {"some": {"total": 11000}, "full": {"total": 5500}} for name in ("cpu", "memory", "io")},
        }
        sample = report.system_resource_interval(
            before, after, start_ns=1_000_000_000, scheduled_ns=2_000_000_000, index=1,
        )
        self.assertEqual(sample["cpu"]["busy_percent"], 35.0)
        self.assertEqual(sample["cpu"]["idle_percent"], 60.0)
        self.assertEqual(sample["pressure"]["cpu"]["some_percent"], 1.0)
        self.assertTrue(all(sample["availability"].values()))
        incomplete = report.system_resource_report([sample], 30)
        self.assertEqual(incomplete["missed_sample_count"], 29)
        self.assertFalse(incomplete["coverage_complete"])
        self.assertTrue(report.system_resource_report([sample], 1)["coverage_complete"])
        complete_samples = [{**sample, "scheduled_elapsed_seconds": float(index)} for index in range(1, 8)]
        complete = report.system_resource_report(complete_samples, 7)
        self.assertEqual((complete["expected_sample_count"], complete["sample_count"]), (7, 7))
        self.assertTrue(complete["coverage_complete"])
        self.assertEqual(report.advance_resource_deadline(1_000, 2_200, 1_000), 3_000)

    def test_resource_snapshot_keeps_missing_proc_fields_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proc = root / "proc"
            (proc / "pressure").mkdir(parents=True)
            (proc / "stat").write_text("cpu 10 0 2 20 0 0 0 0 0 0\n")
            (proc / "meminfo").write_text("MemTotal: 100 kB\n")
            (proc / "loadavg").write_text("")
            snapshot = report.system_resource_snapshot(proc)
            self.assertEqual(snapshot["memory"], {"MemTotal": 100 * 1024})
            self.assertEqual(snapshot["load"], {})
            self.assertEqual(snapshot["pressure"], {"cpu": {}, "memory": {}, "io": {}})

    def test_kernel_counter_parser_and_delta_preserve_labels_and_cpus(self):
        before_text = """\
           CPU0       CPU1
  8:         10         20  IR-IO-APIC  8-edge rtc0
NMI:          1          2  Non-maskable interrupts
ERR:          4
"""
        after_text = """\
           CPU0       CPU1
  8:         13         25  IR-IO-APIC  8-edge rtc0
NMI:          2          4  Non-maskable interrupts
ERR:          5
"""
        before, after = report.parse_kernel_counters(before_text), report.parse_kernel_counters(after_text)
        before.update(monotonic_ns=1_000_000_000, monotonic_begin_ns=900_000_000, monotonic_end_ns=1_100_000_000)
        after.update(monotonic_ns=31_000_000_000, monotonic_begin_ns=30_900_000_000, monotonic_end_ns=31_100_000_000)
        parsed = report.kernel_counter_delta(before, after)
        self.assertTrue(parsed["available"])
        self.assertTrue(parsed["complete"])
        self.assertEqual(parsed["labels"]["8"]["per_cpu_delta"], {"CPU0": 3, "CPU1": 5})
        self.assertEqual(parsed["labels"]["ERR"]["delta"], 1)
        self.assertEqual(parsed["per_cpu_delta"], {"CPU0": 4, "CPU1": 7})
        self.assertEqual(parsed["total_delta"], 12)
        self.assertEqual(parsed["total_rate_per_second"], 0.4)

    def test_kernel_counter_unavailable_and_reset_are_explicit(self):
        self.assertFalse(report.parse_kernel_counters("")["available"])
        before = report.parse_kernel_counters("CPU0\nTIMER: 9\n")
        after = report.parse_kernel_counters("CPU0\nTIMER: 2\n")
        before.update(monotonic_ns=0)
        after.update(monotonic_ns=1_000_000_000)
        parsed = report.kernel_counter_delta(before, after)
        self.assertFalse(parsed["complete"])
        self.assertEqual(parsed["labels"]["TIMER"]["status"], "counter-reset")
        self.assertIsNone(parsed["total_rate_per_second"])

    def test_profile_environment_keeps_exact_cpu_gates_without_all_wine_values(self):
        environment = {
            "WINE_APC_FASTPATH": "1", "WINEFSYNC": "1", "STAGING_RT_PRIORITY_SERVER": "90",
            "WINE_UNRELATED_SECRET": "omit", "PIPEASIO_REALTIME": "1", "ABLETON_RT": "1",
            "ABLETON_DCOMP": "off", "ABLETON_POWER": "performance",
        }
        selected = report.benchmark_environment(environment)
        self.assertEqual(selected["WINE_APC_FASTPATH"], "1")
        self.assertNotIn("WINE_UNRELATED_SECRET", selected)
        self.assertEqual(report.benchmark_gate_environment(environment)["PIPEASIO_REALTIME"], "1")
        self.assertEqual(report.benchmark_gate_environment(environment)["ABLETON_POWER"], "performance")

    def test_audio_kernel_and_cpu_policy_snapshots_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parameters = root / "parameters"
            parameters.mkdir()
            (parameters / "lowlatency").write_text("Y\n")
            audio = report.audio_kernel_parameters(parameters)
            self.assertEqual(audio["parameters"]["lowlatency"]["value"], "Y")
            self.assertFalse(audio["parameters"]["autoclock"]["available"])
            policy = root / "cpufreq/policy0"
            policy.mkdir(parents=True)
            (policy / "scaling_governor").write_text("performance\n")
            (policy / "scaling_min_freq").write_text("1000\n")
            snapshot = report.cpu_policy_snapshot(root / "cpufreq")
            self.assertTrue(snapshot["available"])
            self.assertEqual(snapshot["policies"][0]["scaling_governor"], "performance")

    def test_audio_endpoint_snapshot_keeps_stable_profile_links_and_graph_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary)
            payloads = {
                "sink": 'device.name = "usb-interface"\ndevice.profile.name = "pro-audio"\nobject.serial = 77\n',
                "source": 'node.name = "alsa_input.usb-interface"\napi.alsa.path = "hw:2"\n',
                "links": "PipeASIO:output_1\n  |-> alsa_output.usb-interface:playback_FL\n",
                "settings": (
                    "update: id:0 key:'clock.rate' value:'48000' type:''\n"
                    "update: id:0 key:'clock.quantum' value:'64' type:''\n"
                ),
            }
            seen = {}

            def fake_capture(name, argv, raw_dir, timeout=15):
                component = name.rsplit("-", 1)[1]
                seen[component] = argv
                (raw_dir / f"{name}.stdout.txt").write_text(payloads[component])
                (raw_dir / f"{name}.stderr.txt").write_text("")
                return {"argv": argv, "available": True, "returncode": 0}

            with mock.patch.object(report, "command_capture", side_effect=fake_capture):
                value = report.audio_endpoint_snapshot(raw, "before")
            self.assertTrue(value["available"])
            self.assertEqual(value["graph_settings"]["clock.quantum"], "64")
            self.assertIn('device.profile.name = "pro-audio"', value["default_sink"])
            self.assertNotIn("object.serial = 77", value["default_sink"])
            self.assertIn("PipeASIO:output_1", value["links"])
            self.assertEqual(seen["links"], ["pw-link", "-l"])

    def test_fixture_plugin_inventory_hashes_file_and_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            root = prefix / "drive_c/Program Files/Common Files/VST3"
            bundle = root / "Dexed.vst3/Contents/x86_64-win"
            bundle.mkdir(parents=True)
            (bundle / "Dexed.vst3").write_bytes(b"MZdexed")
            root.mkdir(parents=True, exist_ok=True)
            (root / "K1v_x64.vst3").write_bytes(b"MZk1v")
            with mock.patch.object(report, "embedded_product_version", return_value="1.2.3"):
                values = report.fixture_plugin_inventory(prefix)
            self.assertEqual([item["kind"] for item in values], ["bundle", "file"])
            self.assertTrue(all(item.get("identity_hash") for item in values))
            self.assertEqual(values[0]["files"][0]["product_version"], "1.2.3")

    def test_live_log_identity_includes_runtime_visible_core_topology(self):
        fixture = """\
2026-08-20: info: Started: Live 12.4.3 Build: test-build
2026-08-20: info: Options: -MaxAudioThreads=16
2026-08-20: info: Init: CPU Count: 32
2026-08-20: info: Init: Logical High-Performance Core Count: 24
2026-08-20: info: Init: Logical Power-Efficient Core Count: 8
2026-08-20: info: Init: CPU Count For Real-Time Threads: 24
2026-08-20: info: Audio In Out: Sample Rate: 48000
2026-08-20: info: Audio In Out: Output Buffer Size: 64 Samples
"""
        parsed = report.parse_live_log_identity(fixture)
        self.assertEqual(parsed["version"], "12.4.3")
        self.assertEqual(parsed["max_audio_threads_option"], 16)
        self.assertEqual(parsed["reported_performance_cpus"], 24)
        self.assertEqual(parsed["reported_efficiency_cpus"], 8)
        self.assertEqual(parsed["output_buffer_frames"], 64)

    def test_proc_stat_handles_spaces_and_parentheses(self):
        # Fields 3 onward from proc_pid_stat(5); pad through policy (field 41).
        fields = ["S", "1"] + ["0"] * 9 + ["100", "50"] + ["0"] * 4 + ["7", "0", "999"] + ["0"] * 16 + ["3", "10", "2"]
        parsed = report.parse_proc_stat("123 (Audio Worker (7)) " + " ".join(fields))
        self.assertIsNotNone(parsed)
        assert parsed
        self.assertEqual(parsed["comm"], "Audio Worker (7)")
        self.assertEqual(parsed["utime_ticks"], 100)
        self.assertEqual(parsed["stime_ticks"], 50)

    def test_crackle_status_precedence_and_semantics(self):
        self.assertEqual(report.crackle_status(True, 1, 0, "heard")["status"], "detected")
        self.assertEqual(report.crackle_status(True, 0, 0, "heard")["status"], "manual")
        self.assertEqual(report.crackle_status(True, 0, 0, "not-provided")["status"], "no-instrumented-evidence")
        self.assertEqual(report.crackle_status(False, 0, 0, "not-heard")["status"], "unknown")

    def test_live_worker_count_uses_observed_audiocalc_threads(self):
        delta = {"processes": [{
            "pid": 12,
            "comm": "Ableton Live 12",
            "cmdline": [r"C:\\ProgramData\\Ableton Live 12 Suite.exe"],
            "exe": "/runtime/bin/wine64",
            "cpu_percent_of_one_core": 25.0,
            "context_switches": 4,
            "threads": [
                {"pid": 13, "comm": "AudioCalc"},
                {"pid": 14, "comm": "AudioCalc"},
                {"pid": 15, "comm": "MainThread"},
            ],
        }]}
        groups = report.process_groups(delta, Path("/prefix"), Path("/runtime"))
        self.assertEqual(groups["live"]["audio_worker_count"], 2)
        self.assertEqual(groups["live"]["thread_count"], 3)

    def test_osc_string_padding_round_trip(self):
        # Four-character strings are the edge case: OSC still needs four NULs.
        packet = osc.encode("/abc", ["test", "7", "1.5"])
        address, arguments = osc.decode(packet)
        self.assertEqual(address, "/abc")
        self.assertEqual(arguments, ["test", 7, 1.5])

    def test_probe_nonce_is_always_an_osc_string(self):
        with mock.patch.object(osc.secrets, "token_hex", return_value="1234567890123456"):
            nonce = osc.probe_nonce()
        self.assertEqual(nonce, "n1234567890123456")
        _, arguments = osc.decode(osc.encode("/abl/bench/ping", [nonce]))
        self.assertEqual(arguments, [nonce])

    def test_live_inventory_reports_options_and_worker_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            prefs = prefix / "drive_c/users/bench/AppData/Roaming/Ableton/Live 12.4.3/Preferences"
            prefs.mkdir(parents=True)
            (prefs / "Options.txt").write_text("-DisablePythonOptimize\n-MaxAudioThreads=6\n")
            inventory = report.live_inventory(prefix)
            self.assertEqual(inventory["preferences"][0]["version"], "12.4.3")
            self.assertEqual(inventory["preferences"][0]["user"], "bench")
            self.assertEqual(inventory["preferences"][0]["max_audio_threads"], 6)
            self.assertIn("-DisablePythonOptimize", inventory["preferences"][0]["options"])
            profile_path = prefix / "profile.json"
            profile_path.write_text(json.dumps({"live": {"preferences": []}, "keep": "value"}))
            (prefs / "Options.txt").write_text("-MaxAudioThreads=10\n")
            args = type("Args", (), {"profile": str(profile_path), "prefix": str(prefix)})()
            self.assertEqual(report.refresh_live(args), 0)
            refreshed = json.loads(profile_path.read_text())
            self.assertEqual(refreshed["live"]["preferences"][0]["max_audio_threads"], 10)
            self.assertEqual(refreshed["keep"], "value")
            self.assertIn("first runner-owned Live", refreshed["live_capture_scope"]["phase"])

    def test_optional_missing_identity_values_match_between_runs(self):
        first = benchmark_profile()
        first["system"]["gpu_lines"] = []
        first["system"]["gpu_renderer_lines"] = []
        first["system"]["power_profile"] = ""
        first["pipewire"]["active_profile_lines"] = []
        first["pipewire"]["settings"]["values"].pop("clock.rate")
        first["pipewire"]["settings"]["values"].pop("clock.quantum")
        second = json.loads(json.dumps(first))
        checks = report.profile_identity_checks({"profile": first}, {"profile": second})
        optional = {"gpu", "gpu_renderer", "audio_profile", "sample_rate", "quantum", "power_profile"}
        selected = [item for item in checks if item["id"] in optional]
        self.assertEqual({item["id"] for item in selected}, optional)
        self.assertTrue(all(item["status"] == "match" and not item["confounder"] for item in selected))

    def test_compare_completed_compatible_runs_and_writes_both_formats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after, output = root / "before", root / "after", root / "comparison"
            write_benchmark_run(before, live_cpu=10.0)
            write_benchmark_run(after, live_cpu=8.0)
            args = type("Args", (), {"before": str(before), "after": str(after), "output": str(output)})()
            self.assertEqual(report.compare(args), 0)
            result = json.loads((output / "comparison.json").read_text())
            metric = result["sets"][1]["metrics"]["live_cpu_percent"]
            self.assertEqual((metric["delta"], metric["percent_change"]), (-2.0, -20.0))
            self.assertFalse(metric["confounded"])
            self.assertIn("interrupts", result["sets"][1]["kernel_counters"]["before"])
            self.assertIn("Repeat pairs to measure normal variation", (output / "comparison.md").read_text())

    def test_compare_reports_identity_and_exact_gate_confounders(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_profile = benchmark_profile({"WINE_APC_FASTPATH": "0"})
            last_profile = benchmark_profile({"WINE_APC_FASTPATH": "1"})
            last_profile["runtime"]["identity_hash"] = "runtime-b"
            before, after = root / "before", root / "after"
            write_benchmark_run(before, profile=first_profile)
            write_benchmark_run(after, profile=last_profile)
            after_run = json.loads((after / "run.json").read_text())
            after_run["harness"]["identity_hash"] = "harness-b"
            (after / "run.json").write_text(json.dumps(after_run))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            statuses = {item["id"]: item["status"] for item in result["identity"]}
            self.assertEqual(statuses["runtime_identity"], "different")
            self.assertEqual(statuses["benchmark_gates"], "different")
            self.assertEqual(statuses["harness"], "different")
            self.assertTrue(result["sets"][0]["metrics"]["host_cpu_percent"]["confounded"])

    def test_compare_treats_different_benchmark_machine_ids_as_a_confounder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after)
            different_id = "fedcba9876543210fedcba9876543210"
            profile_value = json.loads((after / "profile/profile.json").read_text())
            profile_value["machine"]["id"] = different_id
            (after / "profile/profile.json").write_text(json.dumps(profile_value))
            run = json.loads((after / "run.json").read_text())
            run["machine"]["id"] = different_id
            run["csv"]["filename"] = report.cpu_benchmark_csv_filename(different_id, run["created_at"])
            (after / "run.json").write_text(json.dumps(run))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            identity = next(item for item in result["identity"] if item["id"] == "benchmark_machine")
            self.assertEqual(identity["status"], "different")
            self.assertTrue(result["sets"][0]["metrics"]["host_cpu_percent"]["confounded"])

    def test_compare_uses_normalized_harness_hash_not_worktree_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after)
            for directory, path in ((before, "/worktree/a/bench-report.py"), (after, "/worktree/b/bench-report.py")):
                run = json.loads((directory / "run.json").read_text())
                run["harness"]["files"] = [{"path": path, "sha256": "same", "size": 1}]
                (directory / "run.json").write_text(json.dumps(run))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            harness = next(item for item in result["identity"] if item["id"] == "harness")
            self.assertEqual(harness["status"], "match")

    def test_compare_marks_missing_metrics_without_inventing_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after, missing=True)
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            metric = result["sets"][0]["metrics"]["live_cpu_percent"]
            self.assertEqual(metric["comparison_status"], "missing-after")
            self.assertIsNone(metric["delta"])
            self.assertIsNone(metric["percent_change"])

    def test_compare_zero_baseline_has_delta_but_undefined_percent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before, zero=True)
            write_benchmark_run(after, live_cpu=5.0)
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            metric = result["sets"][0]["metrics"]["live_cpu_percent"]
            self.assertEqual(metric["delta"], 5.0)
            self.assertEqual(metric["percent_status"], "zero-baseline")
            self.assertIsNone(metric["percent_change"])

    def test_compare_refuses_incomplete_or_different_duration_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incomplete, complete = root / "incomplete", root / "complete"
            write_benchmark_run(incomplete, status="failed")
            write_benchmark_run(complete)
            with self.assertRaisesRegex(ValueError, "expected 'complete'"):
                report.load_completed_run(incomplete)
            different = root / "different"
            write_benchmark_run(different, duration=31)
            with self.assertRaisesRegex(ValueError, "30-second protocol"):
                report.load_completed_run(different)
            bad_schema = root / "bad-schema"
            write_benchmark_run(bad_schema)
            value = json.loads((bad_schema / "run.json").read_text())
            value["schema"] = "fixture/v0"
            (bad_schema / "run.json").write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "schema/kind"):
                report.load_completed_run(bad_schema)
            bad_window = root / "bad-window"
            write_benchmark_run(bad_window)
            path = next((bad_window / "sets").glob("*-Benchmark_Empty/measurement.json"))
            value = json.loads(path.read_text())
            value.pop("window")
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "monotonic window evidence"):
                report.load_completed_run(bad_window)

    def test_compare_confounders_cover_audio_power_holds_and_fixture_plugins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            first_profile, last_profile = benchmark_profile(), benchmark_profile()
            last_profile["fixture_plugins"][0]["identity_hash"] = "dexed-b"
            write_benchmark_run(before, profile=first_profile)
            write_benchmark_run(after, profile=last_profile)
            path = next((after / "sets").glob("*-Benchmark_Empty/measurement.json"))
            measurement = json.loads(path.read_text())
            measurement["endpoint_identity"]["power"]["before"]["holds_available"] = False
            measurement["endpoint_identity"]["audio"]["before"]["graph_settings"]["clock.quantum"] = "128"
            path.write_text(json.dumps(measurement))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            self.assertIn("identity:vst_fixtures:different", result["sets"][1]["confounders"])
            self.assertIn("after:power-holds-before-unavailable", result["sets"][1]["confounders"])
            self.assertIn("set-identity:audio defaults/profile/graph-before", result["sets"][1]["confounders"])
            self.assertEqual(result["sets"][1]["metrics"]["graph_quantum_before"]["after"], 128)

    def test_annotate_preserves_unusable_node_identity_as_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir)
            path = next((run_dir / "sets").glob("*-Benchmark_Empty/measurement.json"))
            measurement = json.loads(path.read_text())
            measurement["pipewire"]["pw_top"]["identity_confounded"] = True
            measurement["logs"] = {"xrun_line_count": 0}
            path.write_text(json.dumps(measurement))
            args = type("Args", (), {
                "run_dir": str(run_dir), "set_name": "Benchmark_Empty", "manual_crackle": "not-heard",
            })()
            self.assertEqual(report.annotate(args), 0)
            updated = json.loads(path.read_text())
            self.assertEqual(updated["crackle"]["status"], "unknown")

    def test_renderer_keeps_canonical_set_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            order = ["Benchmark_Zero", "Benchmark_Empty"]
            (run_dir / "sets").mkdir()
            (run_dir / "profile").mkdir()
            (run_dir / "run.json").write_text(json.dumps({
                "tag": "fixture", "status": "complete", "duration_seconds_per_set": 30,
                "set_order": order,
            }))
            (run_dir / "profile/profile.json").write_text("{}")
            for index, name in enumerate(reversed(order), 1):
                directory = run_dir / "sets" / f"{index:02d}-{name}"
                directory.mkdir()
                (directory / "measurement.json").write_text(json.dumps({"set": name, "mode": "playback"}))
            args = type("Args", (), {"run_dir": str(run_dir)})()
            self.assertEqual(report.render(args), 0)
            rendered = json.loads((run_dir / "report.json").read_text())
            self.assertEqual([item["set"] for item in rendered["sets"]], order)
            self.assertIn("Crackle evidence", (run_dir / "report.md").read_text())
            self.assertEqual(list(run_dir.glob("*_cpu-benchmark.csv")), [])
            annotate_args = type("Args", (), {
                "run_dir": str(run_dir), "set_name": "Benchmark_Zero", "manual_crackle": "heard",
            })()
            self.assertEqual(report.annotate(annotate_args), 0)
            updated = json.loads(next((run_dir / "sets").glob("*-Benchmark_Zero/measurement.json")).read_text())
            self.assertEqual(updated["crackle"]["status"], "manual")

    def test_renderer_writes_one_stable_timestamped_csv_with_resources_and_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir)
            run = json.loads((run_dir / "run.json").read_text())
            run["tag"] = "=SUM(1,1)"
            (run_dir / "run.json").write_text(json.dumps(run))
            args = type("Args", (), {"run_dir": str(run_dir)})()
            with mock.patch.object(report, "utc_now", return_value="2026-08-26T13:00:00Z"):
                self.assertEqual(report.render(args), 0)
            expected = run_dir / report.cpu_benchmark_csv_filename(FIXTURE_MACHINE_ID, FIXTURE_CREATED_AT)
            self.assertTrue(expected.is_file())
            with expected.open(newline="") as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), len(report.CANONICAL_SETS))
            self.assertEqual(rows[0]["machine_id"], FIXTURE_MACHINE_ID)
            self.assertEqual(rows[0]["tag"], "'=SUM(1,1)")
            self.assertEqual(rows[0]["row_kind"], "resource-sample")
            self.assertEqual(rows[0]["resource_expected_sample_count"], "30")
            self.assertEqual(rows[0]["resource_missed_sample_count"], "29")
            self.assertEqual(rows[0]["resource_coverage_complete"], "False")
            self.assertEqual(rows[0]["memory_available_bytes"], str(12 * 1024**3))
            self.assertEqual(rows[0]["filesystem_available_bytes"], str(60 * 1024**3))
            self.assertEqual(rows[0]["cpu_model"], "Fixture CPU")
            self.assertNotIn("audio_devices", rows[0])
            self.assertEqual(rows[0]["crackle_status"], "no-instrumented-evidence")
            rendered = json.loads((run_dir / "report.json").read_text())
            self.assertEqual(rendered["csv"]["row_count"], len(report.CANONICAL_SETS))
            self.assertEqual(rendered["csv"]["resource_sample_count"], len(report.CANONICAL_SETS))
            with mock.patch.object(report, "utc_now", return_value="2026-08-26T14:00:00Z"):
                self.assertEqual(report.render(args), 0)
            self.assertEqual(list(run_dir.glob("*_cpu-benchmark.csv")), [expected])

    def test_csv_writer_uses_unique_temporary_files_for_symlinks_and_concurrent_renders(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / f"{FIXTURE_MACHINE_ID}-20260826T123456123456Z_cpu-benchmark.csv"
            victim = root / "victim"
            victim.write_text("keep\n")
            predictable = root / f".{path.name}.tmp"
            predictable.symlink_to(victim)
            rows = [{"csv_schema": report.CSV_SCHEMA, "machine_id": FIXTURE_MACHINE_ID, "row_kind": "profile"}]
            errors = []

            def write():
                try:
                    report.write_benchmark_csv(path, rows)
                except Exception as error:  # pragma: no cover - failure detail belongs in the assertion
                    errors.append(error)

            threads = [threading.Thread(target=write) for _ in range(8)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(errors, [])
            self.assertEqual(victim.read_text(), "keep\n")
            self.assertFalse(path.is_symlink())
            with path.open(newline="") as source:
                written = list(csv.DictReader(source))
            self.assertEqual(len(written), 1)
            self.assertEqual(written[0]["machine_id"], FIXTURE_MACHINE_ID)

    def test_renderer_writes_profile_row_for_a_failed_run_without_set_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir, status="failed")
            for measurement in (run_dir / "sets").glob("*/measurement.json"):
                measurement.unlink()
            args = type("Args", (), {"run_dir": str(run_dir)})()
            self.assertEqual(report.render(args), 0)
            path = next(run_dir.glob("*_cpu-benchmark.csv"))
            with path.open(newline="") as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["row_kind"], "profile")
            self.assertEqual(rows[0]["run_status"], "failed")
            self.assertEqual(rows[0]["memory_total_bytes"], str(16 * 1024**3))

    def test_renderer_refuses_a_changed_csv_name_or_machine_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changed_name = root / "changed-name"
            write_benchmark_run(changed_name)
            run = json.loads((changed_name / "run.json").read_text())
            run["csv"]["filename"] = "../outside.csv"
            (changed_name / "run.json").write_text(json.dumps(run))
            args = type("Args", (), {"run_dir": str(changed_name)})()
            with mock.patch("builtins.print"):
                self.assertEqual(report.render(args), 2)
            self.assertFalse((root / "outside.csv").exists())

            changed_machine = root / "changed-machine"
            write_benchmark_run(changed_machine)
            profile_value = json.loads((changed_machine / "profile/profile.json").read_text())
            profile_value["machine"]["id"] = "f" * 32
            (changed_machine / "profile/profile.json").write_text(json.dumps(profile_value))
            args = type("Args", (), {"run_dir": str(changed_machine)})()
            with mock.patch("builtins.print"):
                self.assertEqual(report.render(args), 2)
            self.assertEqual(list(changed_machine.glob("*_cpu-benchmark.csv")), [])

    def test_renderer_marks_unavailable_endpoint_evidence_for_review(self):
        measurement = benchmark_measurement("Benchmark_Zero")
        measurement["endpoint_identity"]["audio"]["before"]["available"] = False
        measurement["endpoint_identity"]["audio"]["after"]["available"] = False
        measurement["endpoint_identity"]["cpu_policy"]["before"]["available"] = False
        measurement["endpoint_identity"]["cpu_policy"]["after"]["available"] = False
        rendered = report.markdown_report({
            "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
            "profile": benchmark_profile(), "sets": [measurement], "generated_at": "fixture",
        })
        header = next(line for line in rendered.splitlines() if line.startswith("| Set | Mode |"))
        separator = rendered.splitlines()[rendered.splitlines().index(header) + 1]
        row = next(line for line in rendered.splitlines() if line.startswith("| Benchmark_Zero |"))
        self.assertEqual((header.count("|"), separator.count("|"), row.count("|")), (18, 18, 18))
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        self.assertEqual(cells[10:12], ["review", "review"])

    def test_markdown_distinguishes_uninstalled_absent_and_duplicate_live_versions(self):
        profile = benchmark_profile()
        profile["system"]["power_profile"] = ""
        profile["commands"] = {"power-profile": {"available": False}}
        profile["live"]["preferences"] = [
            {
                "version": "12.4.3", "user": "lgillingham", "max_audio_threads": 10,
                "options_hash": {"exists": True, "sha256": "options-user"},
            },
            {
                "version": "12.4.3", "max_audio_threads": None,
                "directory": "/prefix/drive_c/users/Public/AppData/Roaming/Ableton/Live 12.4.3/Preferences",
                "options_hash": {"exists": False},
            },
        ]
        rendered = report.markdown_report({
            "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
            "profile": profile, "sets": [], "generated_at": "fixture",
        })
        self.assertIn("Power profile before Live starts: `not installed`", rendered)
        self.assertIn("Live 12.4.3 (users/lgillingham): MaxAudioThreads=10", rendered)
        self.assertIn("Live 12.4.3 (users/Public): MaxAudioThreads=Live default", rendered)
        self.assertIn("Options.txt SHA-256 `absent`", rendered)


class ProfilerTests(unittest.TestCase):
    def test_interface_window_filtering_and_counts(self):
        section = fixture_interface_section()
        self.assertEqual(section["schema"], report.INTERFACE_SCHEMA)
        self.assertEqual(section["mode"], "interface")
        self.assertEqual(section["window"], {"blocks_in_file": 12, "blocks_in_window": 10})
        blocks = section["blocks"]
        self.assertEqual((blocks["count"], blocks["late"], blocks["near_late"], blocks["late_per_minute"]), (10, 2, 3, 4.0))
        self.assertEqual(blocks["slack_ns"], {"min": -210_000, "p01": -210_000, "p50": 199_000, "p99": 1_100_000})
        self.assertEqual(blocks["elapsed_ns"], {"p50": 430_000, "p99": 1_540_000, "max": 1_540_000})
        self.assertEqual(blocks["deadline_ns"], {"min": FIXTURE_PERIOD_NS, "max": FIXTURE_PERIOD_NS})
        self.assertEqual(section["thresholds"], {
            "near_late_fraction": 0.15, "deadline_ns_mode": FIXTURE_PERIOD_NS, "near_late_slack_ns": 200_000,
        })
        tracer = section["tracer"]
        self.assertEqual((tracer["started_offset_seconds"], tracer["stopped_offset_seconds"]), (-0.6, 30.4))
        self.assertTrue(tracer["coverage_complete"])
        self.assertEqual(tracer["overhead"]["estimate_ns_per_block"], 500)
        self.assertEqual(section["kinds"]["ntsync_wait"], {"n": 15, "total_ns": 820_000})
        self.assertEqual(section["kinds"]["syscall"], {"n": 56, "total_ns": 313_100})
        self.assertEqual(section["kinds"]["unixcall"], {"n": 0, "total_ns": 0})
        self.assertEqual(section["roles"]["audio_worker"], {
            "bins": 2, "crossings_per_100ms": {"p50": 40, "p99": 60},
            "total_ns_per_100ms": {"p50": 950_000, "p99": 1_050_000},
        })
        self.assertEqual(section["roles"]["main"]["bins"], 1)
        self.assertEqual(section["hotspots_non_audio"], [
            {"role": "main", "kind": "server_req", "name": "select", "caller": "unsampled", "n": 5, "total_ns": 90_000},
        ])
        self.assertEqual(section["hotspots_non_audio_source"], "blocks-in-window")
        self.assertEqual(section["confounders"], [])
        self.assertEqual(section["evidence"], {
            "blocks": "raw/interface/blocks.jsonl", "threads": "raw/interface/threads.jsonl",
            "tracer": "raw/interface/tracer.json",
        })

    def test_interface_call_sites_use_the_callers_recorded_on_crossings(self):
        caller = "ntdll.dll!NtWaitForSingleObject+0x14"
        stack = {"tid": 4242, "kind": "ntsync_wait", "id": "NtWaitForSingleObject", "frames": FIXTURE_FRAMES}
        wait = lambda n, total: interface_crossing(  # noqa: E731
            4242, "pipeasio_callback", "ntsync_wait", "NtWaitForSingleObject", n, total, total, caller=caller,
        )
        blocks = [
            interface_block(1, 1.0, -100_000, [wait(2, 200_000)]),
            interface_block(2, 2.0, 50_000, [wait(1, 100_000)], [stack]),
            interface_block(3, 3.0, 900_000, [
                interface_crossing(4400, "plugin:Dexed.vst3", "syscall", "NtDelayExecution", 1, 9_000, 9_000, caller="pe!0x1"),
                interface_crossing(4302, "pipeasio_worker", "syscall", "NtYieldExecution", 1, 8_000, 8_000, caller="none"),
                interface_crossing(4310, "live:MIDI", "server_req", "select", 2, 7_000, 4_000,
                                   caller="ntdll.dll!NtWaitForMultipleObjects+0x14"),
            ]),
        ]
        section = fixture_interface_section(blocks=blocks)
        first = section["call_sites"][0]
        self.assertEqual(first["key"], f"ntsync_wait|NtWaitForSingleObject|{caller}")
        self.assertEqual((first["caller"], first["late_blocks"], first["near_late_blocks"]), (caller, 1, 1))
        self.assertEqual(first["total_ns_in_late_blocks"], 300_000)
        self.assertNotIn("unsampled", [site["caller"] for site in section["call_sites"]])
        self.assertEqual(section["hotspots_non_audio"], [{
            "role": "live:MIDI", "kind": "server_req", "name": "select",
            "caller": "ntdll.dll!NtWaitForMultipleObjects+0x14", "n": 2, "total_ns": 7_000,
        }])
        whole_trace = [{"role": "main", "kind": "syscall", "name": "NtUserMsgWaitForMultipleObjectsEx",
                        "caller": "win32u.dll!NtUserMsgWaitForMultipleObjectsEx+0x14", "n": 1, "total_ns": 25_000_000}]
        traced = fixture_interface_section(blocks=blocks, summary={"hotspots_non_audio": whole_trace})
        self.assertEqual(traced["hotspots_non_audio"], whole_trace)
        self.assertEqual(traced["hotspots_non_audio_source"], "summary-whole-trace")
        self.assertEqual(traced["evidence"]["summary"], "raw/interface/summary.json")
        self.assertTrue(report.is_audio_role("plugin:Dexed.vst3"))
        self.assertTrue(report.is_audio_role("pipeasio_worker"))
        self.assertFalse(report.is_audio_role("main"))

    def test_interface_reads_the_reducer_output(self):
        fixture = load_reduce_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir, trace_mode="drilldown")
            set_dir = next((run_dir / "sets").glob("*-Benchmark_Empty"))
            directory = set_dir / "raw/interface"
            directory.mkdir(parents=True)
            fixture.write_run(str(directory), fixture.build_fixture(), mode="drilldown")
            tracer_out = fixture.run_reduce(str(directory), mode="drilldown")
            measurement = json.loads((set_dir / "measurement.json").read_text())
            measurement["window"]["monotonic_start_ns"] = fixture.S0
            measurement["window"]["monotonic_deadline_ns"] = fixture.S0 + 10_000_000_000
            (set_dir / "measurement.json").write_text(json.dumps(measurement))
            args = type("Args", (), {"set_dir": str(set_dir), "near_late_fraction": 0.15, "top": 20})()
            self.assertEqual(report.interface(args), 0)
            section = json.loads((set_dir / "measurement.json").read_text())["interface"]
            summary = tracer_out["summary"]
            self.assertEqual(section["lost_slack"]["total_ns"], summary["lost_slack"]["total_ns"])
            ours = {site["key"]: site for site in section["call_sites"]}
            for site in summary["call_sites"]:
                self.assertIn(site["key"], ours)
                self.assertEqual(ours[site["key"]]["total_ns_in_late_blocks"], site["total_ns_in_late_blocks"])
            self.assertNotIn("unsampled", [site["caller"] for site in section["call_sites"]])
            self.assertEqual(section["hotspots_non_audio"], summary["hotspots_non_audio"])
            self.assertEqual(section["evidence"]["events"], "raw/interface/events.jsonl")
            output = Path(temporary) / "drilldown.md"
            drill = type("Args", (), {"run_dir": str(run_dir), "set": "Benchmark_Empty", "top": 3, "output": str(output)})()
            self.assertEqual(report.interface_drilldown(drill), 0)
            text = output.read_text()
            self.assertIn("Crossings in order (events.jsonl):", text)
            self.assertIn("ntdll.dll!NtWaitForSingleObject+0x14", text)
            symbolized = [json.loads(line) for line in (directory / "blocks.jsonl").read_text().splitlines()]
            for record in symbolized:
                for crossing in record.get("crossings", []):
                    crossing["caller"] = "symbolized!" + crossing["caller"]
            (directory / "blocks.symbolized.jsonl").write_text("".join(json.dumps(item) + "\n" for item in symbolized))
            self.assertEqual(report.interface(args), 0)
            measurement = json.loads((set_dir / "measurement.json").read_text())
            self.assertTrue(all(site["caller"].startswith("symbolized!") for site in measurement["interface"]["call_sites"]))
            self.assertEqual(measurement["interface"]["evidence"]["blocks"], "raw/interface/blocks.symbolized.jsonl")
            self.assertEqual(measurement["evidence"]["interface_blocks"], "raw/interface/blocks.symbolized.jsonl")

    def test_interface_ranking_and_lost_slack_shares(self):
        section = fixture_interface_section()
        lost = section["lost_slack"]
        self.assertEqual((lost["total_ns"], lost["attributed_ns"], lost["unattributed_ns"]), (861_000, 702_100, 158_900))
        sites = section["call_sites"]
        self.assertEqual([site["rank"] for site in sites], [1, 2, 3, 4])
        first = sites[0]
        self.assertEqual(first["key"], SITE_A_KEY)
        self.assertEqual((first["kind"], first["name"], first["caller"]), ("ntsync_wait", "NtWaitForSingleObject", FIXTURE_CALLER))
        self.assertEqual((first["late_blocks"], first["near_late_blocks"], first["n_in_late_blocks"]), (2, 1, 14))
        self.assertEqual(first["per_late_block"], 4.6667)
        self.assertEqual((first["total_ns_in_late_blocks"], first["max_ns"]), (800_000, 210_000))
        self.assertEqual((first["n_all_blocks"], first["total_ns_all_blocks"]), (15, 820_000))
        self.assertEqual(first["share_of_lost_slack"], 0.7542)
        self.assertEqual(first["woken_by"], [{"tid": 4301, "role": "audio_worker", "count": 4}])
        second = sites[1]
        self.assertEqual(second["key"], SITE_B_KEY)
        self.assertEqual((second["n_in_late_blocks"], second["total_ns_in_late_blocks"]), (6, 63_100))
        self.assertEqual(second["share_of_lost_slack"], 0.0612)
        self.assertTrue(all(0 <= site["share_of_lost_slack"] <= 1 for site in sites))
        self.assertAlmostEqual(sum(site["share_of_lost_slack"] for site in sites), lost["attributed_ns"] / lost["total_ns"], places=3)
        self.assertIsNone(sites[3]["per_late_block"])
        self.assertEqual(len(fixture_interface_section(top=2)["call_sites"]), 2)
        self.assertEqual(fixture_interface_section(near_late_fraction=0.0)["blocks"]["near_late"], 0)

    def test_interface_coverage_and_lost_event_confounders(self):
        early = fixture_interface_section(tracer=interface_tracer(stopped_ns=30_000_000_000))
        self.assertFalse(early["tracer"]["coverage_complete"])
        self.assertEqual(early["tracer"]["stopped_offset_seconds"], 29.0)
        self.assertEqual(early["confounders"], ["interface-tracer-coverage-incomplete"])
        lossy = fixture_interface_section(tracer=interface_tracer(lost_events=3))
        self.assertEqual(lossy["confounders"], ["interface-lost-events"])
        self.assertEqual(lossy["tracer"]["lost_events"], 3)
        self.assertTrue(lossy["tracer"]["clean_exit"])

    def test_interface_unclean_tracer_confounders(self):
        # b5-tproto-t60: bpftrace aborted 32.9 s in; reduce.py stops the trace at its last event
        # and reports lost_events null, so the coverage and the exit are both flagged
        crashed = dict(interface_tracer(stopped_ns=FIXTURE_TRACER_START_NS + 5_000_000_000, lost_events=None),
                       clean_exit=False, tracer_exit="crashed")
        section = fixture_interface_section(tracer=crashed)
        self.assertIsNone(section["tracer"]["lost_events"])
        self.assertFalse(section["tracer"]["clean_exit"])
        self.assertEqual(section["tracer"]["tracer_exit"], "crashed")
        self.assertEqual(section["confounders"], ["interface-tracer-coverage-incomplete", "interface-tracer-unclean"])
        # each signal alone is enough
        for tracer in (interface_tracer(lost_events=None), dict(interface_tracer(), clean_exit=False),
                       dict(interface_tracer(), tracer_exit="killed")):
            self.assertIn("interface-tracer-unclean", fixture_interface_section(tracer=tracer)["confounders"])
        self.assertNotIn("interface-tracer-unclean",
                         fixture_interface_section(tracer=dict(interface_tracer(), tracer_exit="clean",
                                                               clean_exit=True))["confounders"])

    def test_interface_private_stack_and_lower_bound(self):
        tracer = dict(interface_tracer(lost_events=2), private_stack_risky=["usdt_wine_syscall_entry_2"],
                      private_stack_allowed=True, loss={"lower_bound": True})
        section = fixture_interface_section(tracer=tracer)
        self.assertEqual(section["confounders"], ["interface-lost-events", "interface-tracer-private-stack"])
        self.assertEqual(section["tracer"]["private_stack_risky"], ["usdt_wine_syscall_entry_2"])
        self.assertTrue(section["tracer"]["lost_events_lower_bound"])
        for kind in section["confounders"]:
            self.assertIn(kind, report.INTERFACE_CONFOUNDERS)

    def test_interface_subcommand_rewrites_measurement(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir, trace_mode="interface")
            set_dir = next((run_dir / "sets").glob("*-Benchmark_Empty"))
            write_interface_files(set_dir)
            args = type("Args", (), {"set_dir": str(set_dir), "near_late_fraction": 0.15, "top": 20})()
            self.assertEqual(report.interface(args), 0)
            measurement = json.loads((set_dir / "measurement.json").read_text())
            self.assertEqual(measurement["interface"]["schema"], report.INTERFACE_SCHEMA)
            self.assertEqual(measurement["interface"]["blocks"]["late"], 2)
            self.assertEqual(measurement["interface"]["call_sites"][0]["key"], SITE_A_KEY)
            self.assertEqual(measurement["confounders"], [])
            self.assertEqual(measurement["evidence"]["interface_blocks"], "raw/interface/blocks.jsonl")
            write_interface_files(set_dir, tracer=interface_tracer(stopped_ns=30_000_000_000))
            self.assertEqual(report.interface(args), 0)
            self.assertEqual(report.interface(args), 0)
            measurement = json.loads((set_dir / "measurement.json").read_text())
            self.assertEqual([item["kind"] for item in measurement["confounders"]], ["interface-tracer-coverage-incomplete"])
            self.assertIn("after:interface-tracer-coverage-incomplete", report.measurement_confounders(measurement, "after"))

    def test_interface_subcommand_refuses_missing_tracer_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir, trace_mode="interface")
            set_dir = next((run_dir / "sets").glob("*-Benchmark_Empty"))
            args = type("Args", (), {"set_dir": str(set_dir), "near_late_fraction": 0.15, "top": 20})()
            with mock.patch("builtins.print"):
                self.assertEqual(report.interface(args), 2)
            measurement = json.loads((set_dir / "measurement.json").read_text())
            self.assertIsNone(measurement["interface"])
            self.assertEqual([item["kind"] for item in measurement["confounders"]], ["interface-tracer-output-missing"])
            self.assertIn("before:interface-tracer-output-missing", report.measurement_confounders(measurement, "before"))
            untraced = next((run_dir / "sets").glob("*-Benchmark_Zero"))
            measurement = json.loads((untraced / "measurement.json").read_text())
            measurement["trace"]["mode"] = "off"
            (untraced / "measurement.json").write_text(json.dumps(measurement))
            before = (untraced / "measurement.json").read_text()
            with mock.patch("builtins.print"):
                self.assertEqual(report.interface(type("Args", (), {"set_dir": str(untraced), "near_late_fraction": 0.15, "top": 20})()), 0)
            self.assertEqual((untraced / "measurement.json").read_text(), before)

    def test_render_adds_interface_crossings_section(self):
        measurement = benchmark_measurement("Benchmark_Zero")
        measurement["interface"] = fixture_interface_section()
        rendered = report.markdown_report({
            "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30,
                    "structure": "benchmark", "trace": {"mode": "interface"}, "scenario": None},
            "profile": benchmark_profile(), "sets": [measurement, benchmark_measurement("Benchmark_Empty")],
            "generated_at": "fixture",
        })
        lines = rendered.splitlines()
        self.assertIn("- Trace: `interface`", lines)
        self.assertIn("- Structure: `benchmark`", lines)
        self.assertIn("- Scenario: `none`", lines)
        self.assertLess(lines.index("## Results"), lines.index("## Interface crossings"))
        self.assertLess(lines.index("## Interface crossings"), lines.index("## Run details"))
        self.assertIn("### Benchmark_Zero", lines)
        self.assertIn("- Interface data unavailable; see the measurement confounders.", lines[lines.index("### Benchmark_Empty"):])
        table_header = next(line for line in lines if line.startswith("| Rank |"))
        self.assertEqual(table_header, "| Rank | Crossing | Caller | Per late block | Share of lost slack |")
        row = next(line for line in lines if line.startswith("| 1 |"))
        self.assertEqual(row, f"| 1 | ntsync_wait NtWaitForSingleObject | {FIXTURE_CALLER} | 4.67 | 75.4% |")
        self.assertIn("lost slack attributed 81.5%", rendered)
        header = next(line for line in lines if line.startswith("| Set | Mode |"))
        separator = lines[lines.index(header) + 1]
        set_row = next(line for line in lines if line.startswith("| Benchmark_Zero |"))
        self.assertEqual((header.count("|"), separator.count("|"), set_row.count("|")), (18, 18, 18))
        untraced = report.markdown_report({
            "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
            "profile": benchmark_profile(), "sets": [benchmark_measurement("Benchmark_Zero")], "generated_at": "fixture",
        })
        self.assertNotIn("## Interface crossings", untraced)
        self.assertIn("- Trace: `off`", untraced)

    def test_compare_refuses_trace_mode_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after, trace_mode="interface", tracer="wine-trace/1")
            with self.assertRaisesRegex(ValueError, "trace mode mismatch: before=off, after=interface"):
                report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            args = type("Args", (), {"before": str(before), "after": str(after), "output": str(root / "comparison")})()
            with mock.patch("builtins.print"):
                self.assertEqual(report.compare(args), 2)
            self.assertFalse((root / "comparison").exists())

    def test_compare_flags_tracer_identity_and_set_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before, trace_mode="interface", tracer="wine-trace/1")
            write_benchmark_run(after, trace_mode="interface", tracer="wine-trace/2")
            path = next((after / "sets").glob("*-Benchmark_VSTs/measurement.json"))
            measurement = json.loads(path.read_text())
            measurement["set_file"] = {"path": "/sets/Benchmark_VSTs.als", "sha256": "b" * 64}
            path.write_text(json.dumps(measurement))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            self.assertIn("identity:trace:different", result["identity_confounders"])
            self.assertEqual(result["structure"]["trace_mode"], "interface")
            self.assertIn("set-identity:set-file", result["sets"][4]["confounders"])
            self.assertNotIn("set-identity:set-file", result["sets"][0]["confounders"])
            self.assertIsNone(result["sets"][0]["interface"])
            untraced = report.comparison_report(*(report.load_completed_run(path) for path in (before, before)))
            self.assertNotIn("identity:trace:different", untraced["identity_confounders"])

    def test_compare_joins_interface_call_sites(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before, trace_mode="interface", tracer="wine-trace/1")
            write_benchmark_run(after, trace_mode="interface", tracer="wine-trace/1")
            improved = fixture_interface_section()
            improved["blocks"]["late"] = 1
            improved["lost_slack"]["total_ns"] = 400_000
            improved["call_sites"][0]["share_of_lost_slack"] = 0.4
            improved["call_sites"][0]["total_ns_in_late_blocks"] = 200_000
            improved["call_sites"][1]["key"] = "syscall|NtDelayExecution|unsampled"
            for directory, section in ((before, fixture_interface_section()), (after, improved)):
                path = next((directory / "sets").glob("*-Benchmark_Empty/measurement.json"))
                measurement = json.loads(path.read_text())
                measurement["interface"] = section
                path.write_text(json.dumps(measurement))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            interface = result["sets"][1]["interface"]
            late = interface["metrics"]["late_blocks"]
            self.assertEqual((late["before"], late["after"], late["delta"]), (2, 1, -1))
            self.assertEqual(interface["metrics"]["lost_slack_total_ns"]["delta"], -461_000)
            self.assertEqual(interface["metrics"]["tracer_lost_events"]["comparison_status"], "comparable")
            self.assertEqual(interface["call_sites"][0]["key"], SITE_A_KEY)
            self.assertEqual(interface["call_sites"][0]["delta_share"], -0.3542)
            self.assertEqual(interface["call_sites"][0]["delta_total_ns_in_late_blocks"], -600_000)
            self.assertEqual(interface["appeared"], ["syscall|NtDelayExecution|unsampled"])
            self.assertEqual(interface["disappeared"], [SITE_B_KEY])
            disappeared = next(item for item in interface["call_sites"] if item["key"] == SITE_B_KEY)
            self.assertIsNone(disappeared["after"])
            self.assertEqual(disappeared["delta_share"], -0.0612)
            markdown = report.comparison_markdown(result)
            self.assertIn("## Interface crossings", markdown)
            self.assertIn("### Benchmark_Empty", markdown)
            self.assertIn("| ntsync_wait NtWaitForSingleObject |", markdown)
            self.assertIn("- Late audio blocks: 2", markdown)

    def test_virtualization_identity_and_banner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "raw"
            raw.mkdir()
            (raw / "virt.stdout.txt").write_text("vmware\n")
            dmi = root / "product_name"
            dmi.write_text("VMware20,1\n")
            record = report.virtualization_record(raw, dmi)
            self.assertEqual(record, {
                "detector": "systemd-detect-virt", "value": "vmware", "dmi_product": "VMware20,1",
                "timing_claims_allowed": False,
            })
            (raw / "virt.stdout.txt").write_text("")
            self.assertEqual(report.virtualization_record(raw, root / "absent")["value"], "unknown")
            (raw / "virt.stdout.txt").write_text("none\n")
            self.assertTrue(report.virtualization_record(raw, dmi)["timing_claims_allowed"])
            virtual, metal = benchmark_profile(), benchmark_profile()
            virtual["system"]["virtualization"] = record
            metal["system"]["virtualization"] = report.virtualization_record(raw, dmi)
            before, after = root / "before", root / "after"
            write_benchmark_run(before, profile=virtual)
            write_benchmark_run(after, profile=metal)
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            self.assertIn("identity:virtualization:different", result["identity_confounders"])
            self.assertIn("> NO TIMING CLAIMS: this run executed under vmware; use it for mechanism and tooling evidence only.", report.comparison_markdown(result))
            banner = report.markdown_report({
                "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
                "profile": virtual, "sets": [], "generated_at": "fixture",
            })
            self.assertIn("> NO TIMING CLAIMS: this run executed under vmware;", banner)
            clean = report.markdown_report({
                "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
                "profile": metal, "sets": [], "generated_at": "fixture",
            })
            self.assertNotIn("NO TIMING CLAIMS", clean)
            self.assertNotIn("NO TIMING CLAIMS", report.markdown_report({
                "run": {}, "profile": benchmark_profile(), "sets": [], "generated_at": "fixture",
            }))

    def test_scenario_mode_skips_playback_state_confounder(self):
        parsed = report.parse_osc("0.2\t1700000000.250 /abl/bench/playing 0\n0.3\t1700000001.000 /abl/bench/cpu 20 31\n")
        self.assertEqual(parsed["addresses"]["/abl/bench/playing"], 1)
        self.assertEqual(report.playback_state_confounder("playback", parsed)["kind"], "playback-state-changed")
        self.assertIsNone(report.playback_state_confounder("scenario", parsed))

    def test_scenario_collector_appears_only_when_a_scenario_ran(self):
        plain = benchmark_measurement("Benchmark_Inbuilts")
        self.assertEqual(report.measurement_collectors(plain), report.COLLECTORS)
        self.assertNotIn("scenario_coverage_seconds", report.set_metric_values(plain))
        self.assertFalse(any("scenario" in item for item in report.measurement_confounders(plain, "before")))
        scenario = benchmark_measurement("Benchmark_Inbuilts", mode="scenario")
        scenario["scenario"] = {"name": "clip-launch-storm", "kind": "benchmark", "file": "/scenarios/clip-launch-storm.json",
                                "sha256": "a" * 64, "markers": [{"name": "end", "offset_seconds": 29.9}], "operations": 60}
        scenario["capture_commands"]["scenario"] = {"available": True, "timing": scenario["capture_commands"]["osc"]["timing"]}
        self.assertEqual(report.measurement_collectors(scenario), report.COLLECTORS + ("scenario",))
        self.assertEqual(report.set_metric_values(scenario)["scenario_coverage_seconds"][2], 30.0)
        self.assertNotIn("before:scenario-collector-unusable", report.measurement_confounders(scenario, "before"))
        scenario["capture_commands"]["scenario"] = {"available": True, "timing": {"supervision_interval_seconds": 3.0, "output_line_count": 2}}
        self.assertIn("before:scenario-collector-unusable", report.measurement_confounders(scenario, "before"))

    def test_scenario_log_and_set_file_parsers(self):
        parsed = report.parse_scenario(
            "0.500000\t0.4990\tmarker\tsetup-done\n"
            "1.000000\t0.9990\top\tfire_scene\t0\n"
            "junk line\n"
            "30.000000\t29.9990\tmarker\tend\n"
        )
        self.assertEqual(parsed["operations"], 1)
        self.assertEqual(parsed["markers"], [
            {"name": "setup-done", "offset_seconds": 0.5, "scenario_offset_seconds": 0.499},
            {"name": "end", "offset_seconds": 30.0, "scenario_offset_seconds": 29.999},
        ])
        self.assertEqual(report.set_file_record("ABCDEF  /sets/Benchmark_VSTs.als"), {"path": "/sets/Benchmark_VSTs.als", "sha256": "abcdef"})
        self.assertEqual(report.set_file_record("abcdef"), {"path": None, "sha256": "abcdef"})
        self.assertEqual(report.set_file_record(None), {"path": None, "sha256": None})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scenarios").mkdir()
            (root / "control").mkdir()
            (root / "scenarios/view-flip.json").write_text(json.dumps({"name": "view-flip", "kind": "diagnostic"}))
            record = report.scenario_record("view-flip", str(root / "control/scenario-run.py"), parsed)
            self.assertEqual((record["name"], record["kind"], record["operations"]), ("view-flip", "diagnostic", 1))
            self.assertEqual(len(record["sha256"]), 64)
            self.assertIsNone(report.scenario_record("absent", str(root / "control/scenario-run.py"), parsed)["sha256"])

    def test_osc_decode_handles_bool_nil_blob_and_wide_tags(self):
        packet = (
            osc.pad(b"/live/song/get/is_playing") + osc.pad(b",TFNIhdb")
            + struct.pack(">q", 2**40) + struct.pack(">d", 2.5) + struct.pack(">i", 3) + b"abc\x00"
        )
        address, arguments = osc.decode(packet)
        self.assertEqual(address, "/live/song/get/is_playing")
        self.assertEqual(arguments, [True, False, None, float("inf"), 2**40, 2.5, b"abc"])
        aligned = osc.pad(b"/x") + osc.pad(b",bis") + struct.pack(">i", 4) + b"abcd" + struct.pack(">i", 7) + osc.pad(b"ok")
        self.assertEqual(osc.decode(aligned), ("/x", [b"abcd", 7, "ok"]))
        with self.assertRaisesRegex(ValueError, "unsupported OSC type tag 'm'"):
            osc.decode(osc.pad(b"/x") + osc.pad(b",m") + b"\x00\x90\x3c\x40")
        with self.assertRaisesRegex(ValueError, "truncated OSC blob"):
            osc.decode(osc.pad(b"/x") + osc.pad(b",b") + struct.pack(">i", 9) + b"abc\x00")

    def test_compare_diagnostic_structure_accepts_two_sets_and_refuses_other_scenarios(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sets = ["Benchmark_Zero", "Benchmark_VSTs"]
            modes = {"Benchmark_VSTs": "scenario"}
            before, after, other = root / "before", root / "after", root / "other"
            for directory, scenario in ((before, "clip-launch-storm"), (after, "clip-launch-storm"), (other, "tempo-ramp")):
                write_benchmark_run(directory, sets=sets, structure="diagnostic", scenario=scenario, modes=modes)
            loaded = report.load_completed_run(before, "diagnostic")
            self.assertEqual([item["set"] for item in loaded["sets"]], sets)
            with self.assertRaisesRegex(ValueError, "diagnostic"):
                report.load_completed_run(before)
            with self.assertRaisesRegex(ValueError, "scenario mismatch"):
                report.comparison_report(loaded, report.load_completed_run(other, "diagnostic"), "diagnostic")
            canonical = root / "canonical"
            write_benchmark_run(canonical)
            with self.assertRaisesRegex(ValueError, "set order mismatch"):
                report.comparison_report(loaded, report.load_completed_run(canonical, "diagnostic"), "diagnostic")
            short = root / "short"
            write_benchmark_run(short, sets=sets, structure="diagnostic", scenario="clip-launch-storm", modes=modes, duration=5)
            with self.assertRaisesRegex(ValueError, "at least 10 seconds"):
                report.load_completed_run(short, "diagnostic")
            args = type("Args", (), {
                "before": str(before), "after": str(after), "output": str(root / "comparison"), "structure": "diagnostic",
            })()
            self.assertEqual(report.compare(args), 0)
            result = json.loads((root / "comparison/comparison.json").read_text())
            self.assertEqual(result["structure"]["name"], "diagnostic")
            self.assertEqual(result["structure"]["set_order"], sets)
            self.assertEqual([item["mode"] for item in result["sets"]], ["idle-no-controller", "scenario"])
            self.assertIn("- Structure: `diagnostic`; trace `off`; scenario `clip-launch-storm`", (root / "comparison/comparison.md").read_text(encoding="utf-8"))

    def test_init_run_records_structure_trace_and_scenario(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = type("Args", (), {
                "output": str(root / "run.json"), "tag": "fixture", "duration": 30, "set": ["Benchmark_Zero"],
                "structure": "diagnostic", "trace_mode": "interface", "scenario": "view-flip",
                "tracer": "/opt/profiler/bin/wine-trace", "privilege": "root-helper",
            })()
            with mock.patch.object(report, "load_benchmark_machine_id", return_value=FIXTURE_MACHINE_ID):
                self.assertEqual(report.init_run(args), 0)
                run = json.loads((root / "run.json").read_text())
                self.assertEqual((run["structure"], run["scenario"]), ("diagnostic", "view-flip"))
                self.assertEqual(run["trace"], {"mode": "interface", "tracer": "/opt/profiler/bin/wine-trace", "privilege": "root-helper"})
                plain = type("Args", (), {"output": str(root / "plain.json"), "tag": "fixture", "duration": 30, "set": ["Benchmark_Zero"]})()
                self.assertEqual(report.init_run(plain), 0)
            run = json.loads((root / "plain.json").read_text())
            self.assertEqual((run["structure"], run["scenario"], run["trace"]["mode"]), ("benchmark", None, "off"))

    def test_interface_drilldown_lists_blocks_with_the_least_slack(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir, trace_mode="drilldown")
            set_dir = next((run_dir / "sets").glob("*-Benchmark_Empty"))
            directory = write_interface_files(set_dir)
            event = lambda t, seq: {  # noqa: E731
                "t": t, "tid": 4301, "role": "audio_worker", "kind": "syscall", "id": "NtReleaseSemaphore",
                "caller": "ntdll.dll!NtReleaseSemaphore+0x14", "dur_ns": 500, "status": "0x0", "seq": seq,
            }
            (directory / "events.jsonl").write_text("".join(json.dumps(item) + "\n" for item in (
                {"type": "header", "monotonic_start_ns": FIXTURE_TRACER_START_NS},
                event(2.0001, 3), event(1.9999, 0),
            )))
            output = Path(temporary) / "drilldown.md"
            args = type("Args", (), {"run_dir": str(run_dir), "set": "Benchmark_Empty", "top": 3, "output": str(output)})()
            self.assertEqual(report.interface_drilldown(args), 0)
            text = output.read_text()
            lines = text.splitlines()
            self.assertEqual(lines[0], "# Interface drill-down: Benchmark_Empty")
            headings = [line for line in lines if line.startswith("## Block")]
            self.assertEqual(headings, [
                "## Block 2: slack -210000 ns (late)", "## Block 3: slack -50000 ns (late)",
                "## Block 4: slack 50000 ns (near-late)",
            ])
            self.assertIn("- Blocks in window: 10; late 2; near-late 3; showing the 3 with the least slack", lines)
            self.assertIn("| 4242 | pipeasio_callback | ntsync_wait | NtWaitForSingleObject | 4 | 300000 | 210000 |", text)
            self.assertIn(f"- tid 4242 ntsync_wait NtWaitForSingleObject: {' <- '.join(FIXTURE_FRAMES)} (stop: max_frames)", lines)
            self.assertIn("- 1.400100 s tid 4301 syscall NtReleaseSemaphore: 500 ns, caller ntdll.dll!NtReleaseSemaphore+0x14", lines)
            self.assertEqual(sum(line.startswith("- 1.399900 s") for line in lines), 0)
            self.assertLess(lines.index("## Block 2: slack -210000 ns (late)"), lines.index("- Window offset 0.400000 s; elapsed 1540000 ns; period 1333333 ns; near-late threshold 200000 ns; lost slack 410000 ns; missed cycles 1"))
            with mock.patch("builtins.print") as printed:
                args.output = None
                self.assertEqual(report.interface_drilldown(args), 0)
                self.assertTrue(printed.call_args[0][0].startswith("# Interface drill-down"))
            missing = type("Args", (), {"run_dir": str(run_dir), "set": "Benchmark_Zero", "top": 3, "output": None})()
            with mock.patch("builtins.print"):
                self.assertEqual(report.interface_drilldown(missing), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
