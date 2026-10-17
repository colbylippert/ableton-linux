#!/usr/bin/env python3
"""Tests for profiler/bin/history-add on the bench-report fixtures; no Live or history run needed."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
SCRIPT = HERE.parent / "history-add"


def load(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


history_add = load("history_add", SCRIPT)
bench_tests = load("bench_report_tests", REPOSITORY / "scripts/test-bench-report.py")
report = bench_tests.report

TOP_LEVEL_KEYS = (
    "schema", "run_id", "tag", "started_at", "machine_id", "hostname", "virtualization", "structure",
    "scenario", "trace_mode", "duration_s", "runtime", "switches", "harness_sha", "commit", "trial", "arm",
    "source_dir", "sets",
)
SET_KEYS = (
    "mode", "host_cpu_pct", "live_cpu_pct_per_core", "wine_cpu_pct_per_core", "pipewire_cpu_pct", "irq_per_s",
    "softirq_per_s", "pipewire_errors", "xruns", "dsp_avg", "dsp_peak", "audio_workers",
    "voluntary_switches_per_s", "late_blocks", "near_late_blocks", "slack_p01_ns", "slack_p50_ns",
    "lost_slack_total_ns", "call_sites_top", "hotspots_non_audio_top",
)
INTERFACE_KEYS = ("late_blocks", "near_late_blocks", "slack_p01_ns", "slack_p50_ns", "lost_slack_total_ns")
BUILD_INFO = "dist-version: 2026.08.28.1\nwine:         wine-11.13\nsource-tree:  0123abcd\n"


def interface_block(sites=12):
    return {
        "schema": "ableton-linux-interface/v1", "mode": "interface",
        "blocks": {"count": 14062, "late": 3, "near_late": 41, "slack_ns": {"min": -210000, "p01": 150000, "p50": 900000, "p99": 1100000}},
        "lost_slack": {"total_ns": 2100000, "attributed_ns": 1900000, "unattributed_ns": 200000},
        "call_sites": [
            {
                "rank": index, "key": f"ntsync_wait|NtWaitForSingleObject|ntdll+0x{index:x}", "kind": "ntsync_wait",
                "share_of_lost_slack": round(0.5 / index, 4), "total_ns_in_late_blocks": 540000 // index, "max_ns": 210000,
            }
            for index in range(1, sites + 1)
        ],
        "hotspots_non_audio": [
            {"role": "main", "kind": "server_req", "caller": "ntdll+0x1", "n": 1800, "total_ns": 90000000, "extra": {"ignored": True}},
            {"role": "loader", "kind": "syscall", "caller": "ntdll+0x2", "n": 20, "total_ns": 500},
        ],
        "confounders": [],
    }


def run_cli(*arguments):
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), *arguments], capture_output=True, text=True, check=False,
    )


class RecordTests(unittest.TestCase):
    def test_record_shape_from_a_rendered_fixture_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "20261016T120000Z-fixture"
            history = Path(temporary) / "history"
            bench_tests.write_benchmark_run(root)
            # The real renderer writes report.json; -X utf8 keeps its Markdown arrows portable.
            rendered = subprocess.run(
                [sys.executable, "-I", "-X", "utf8", str(REPOSITORY / "scripts/bench-report.py"), "render", "--run-dir", str(root)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertTrue((root / "report.json").is_file())
            completed = run_cli(str(root), "--history-dir", str(history))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("wrote", completed.stdout)
            target = history / "runs" / "20261016T120000Z-fixture.json"
            record = json.loads(target.read_text())
            self.assertEqual(tuple(record), TOP_LEVEL_KEYS)
            self.assertEqual(record["schema"], "ableton-linux-profiler-history/v1")
            self.assertEqual(record["run_id"], "20261016T120000Z-fixture")
            self.assertEqual(record["tag"], "20261016T120000Z-fixture")
            self.assertEqual(record["started_at"], bench_tests.FIXTURE_CREATED_AT)
            self.assertEqual(record["machine_id"], bench_tests.FIXTURE_MACHINE_ID)
            self.assertEqual(record["hostname"], "fixture")
            self.assertIsNone(record["virtualization"])
            self.assertEqual(record["structure"], "benchmark")
            self.assertIsNone(record["scenario"])
            self.assertEqual(record["trace_mode"], "off")
            self.assertEqual(record["duration_s"], 30)
            self.assertEqual(record["runtime"], {"dist_version": None, "source_tree_sha": None, "dev_info": None})
            self.assertEqual(record["switches"], {})
            self.assertEqual(record["harness_sha"], "harness-a")
            self.assertTrue(record["commit"] is None or re.fullmatch(r"[0-9a-f]{40}", record["commit"]))
            self.assertIsNone(record["trial"])
            self.assertIsNone(record["arm"])
            self.assertTrue(record["source_dir"].endswith("20261016T120000Z-fixture"))
            self.assertEqual(tuple(record["sets"]), report.CANONICAL_SETS)
            for name, values in record["sets"].items():
                self.assertEqual(tuple(values), SET_KEYS, name)
                self.assertEqual(values["mode"], report.CANONICAL_MODES[name])
                self.assertEqual(values["host_cpu_pct"], 25.0)
                self.assertEqual(values["live_cpu_pct_per_core"], 10.0)
                self.assertEqual(values["wine_cpu_pct_per_core"], 20.0)
                self.assertEqual(values["pipewire_cpu_pct"], 20.0)
                self.assertEqual(values["irq_per_s"], 100.0)
                self.assertEqual(values["softirq_per_s"], 200.0)
                self.assertEqual(values["pipewire_errors"], 0)
                self.assertIsNone(values["xruns"])
                self.assertEqual(values["dsp_avg"], 12.0)
                self.assertEqual(values["dsp_peak"], 18.0)
                self.assertEqual(values["audio_workers"], 4)
                self.assertIsNone(values["voluntary_switches_per_s"])
                for key in INTERFACE_KEYS:
                    self.assertIsNone(values[key], key)
                self.assertIsNone(values["call_sites_top"])
                self.assertIsNone(values["hotspots_non_audio_top"])

    def test_maps_run_profile_and_interface_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "run"
            history = Path(temporary) / "history"
            profile = bench_tests.benchmark_profile(gates={"WINE_APC_FASTPATH": "1", "PIPEASIO_TELEMETRY": "on"})
            profile["system"]["virtualization"] = {
                "detector": "systemd-detect-virt", "value": "vmware", "dmi_product": "VMware", "timing_claims_allowed": False,
            }
            profile["runtime"]["build_info"] = BUILD_INFO
            profile["runtime"]["dev_info"] = "HEAD 0123abcd dirty=no"
            bench_tests.write_benchmark_run(root, profile=profile)
            run = json.loads((root / "run.json").read_text())
            run.update({
                "id": "20261016T130000Z-traced", "structure": "diagnostic", "scenario": {"name": "clip-launch-storm"},
                "trace": {"mode": "interface", "tracer": "wine-trace", "privilege": "sudo"},
            })
            (root / "run.json").write_text(json.dumps(run))
            path = root / "sets/05-Benchmark_VSTs/measurement.json"
            measurement = json.loads(path.read_text())
            measurement["interface"] = interface_block()
            measurement["logs"] = {"files": [], "xrun_line_count": 2}
            measurement["process"]["summary"]["live"]["pids"] = [100, 101]
            measurement["process"]["details"]["processes"] = [
                {"pid": 100, "voluntary_context_switches": 3000},
                {"pid": 101, "voluntary_context_switches": 1500},
                {"pid": 7, "voluntary_context_switches": 99},
            ]
            path.write_text(json.dumps(measurement))
            self.assertEqual(history_add.main([str(root), "--history-dir", str(history), "--trial", "T0007", "--arm", "B"]), 0)
            record = json.loads((history / "runs/20261016T130000Z-traced.json").read_text())
            self.assertEqual(record["run_id"], "20261016T130000Z-traced")
            self.assertEqual(record["virtualization"], "vmware")
            self.assertEqual(record["structure"], "diagnostic")
            self.assertEqual(record["scenario"], "clip-launch-storm")
            self.assertEqual(record["trace_mode"], "interface")
            self.assertEqual(record["runtime"], {"dist_version": "2026.08.28.1", "source_tree_sha": "0123abcd", "dev_info": "HEAD 0123abcd dirty=no"})
            self.assertEqual(record["switches"], {"PIPEASIO_TELEMETRY": "on", "WINE_APC_FASTPATH": "1"})
            self.assertEqual(record["trial"], "T0007")
            self.assertEqual(record["arm"], "B")
            values = record["sets"]["Benchmark_VSTs"]
            self.assertEqual(values["xruns"], 2)
            self.assertEqual(values["voluntary_switches_per_s"], 150.0)
            self.assertEqual(values["late_blocks"], 3)
            self.assertEqual(values["near_late_blocks"], 41)
            self.assertEqual(values["slack_p01_ns"], 150000)
            self.assertEqual(values["slack_p50_ns"], 900000)
            self.assertEqual(values["lost_slack_total_ns"], 2100000)
            self.assertEqual(len(values["call_sites_top"]), 10)
            self.assertEqual(values["call_sites_top"][0], {
                "key": "ntsync_wait|NtWaitForSingleObject|ntdll+0x1", "share": 0.5, "total_ns_in_late_blocks": 540000,
            })
            self.assertEqual(values["hotspots_non_audio_top"], [
                {"role": "main", "kind": "server_req", "caller": "ntdll+0x1", "n": 1800, "total_ns": 90000000},
                {"role": "loader", "kind": "syscall", "caller": "ntdll+0x2", "n": 20, "total_ns": 500},
            ])
            self.assertIsNone(record["sets"]["Benchmark_Zero"]["late_blocks"])

    def test_run_id_from_bench_subdirectory(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "20261016T140000Z-nested"
            history = Path(temporary) / "history"
            bench_tests.write_benchmark_run(run_dir / "bench")
            for argument in (run_dir, run_dir / "bench"):
                self.assertEqual(history_add.main([str(argument), "--history-dir", str(history)]), 0)
                record = json.loads((history / "runs/20261016T140000Z-nested.json").read_text())
                self.assertEqual(record["run_id"], "20261016T140000Z-nested")
                self.assertTrue(record["source_dir"].endswith("20261016T140000Z-nested/bench"))

    def test_baseline_and_idempotence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "20261016T150000Z-baseline"
            history = Path(temporary) / "history"
            bench_tests.write_benchmark_run(root)
            first = run_cli(str(root), "--history-dir", str(history), "--baseline")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertNotIn("warning", first.stderr)
            baselines = history / "baselines.json"
            self.assertEqual(json.loads(baselines.read_text()), {
                bench_tests.FIXTURE_MACHINE_ID: {"benchmark/-": "20261016T150000Z-baseline"},
            })
            record_bytes = (history / "runs/20261016T150000Z-baseline.json").read_bytes()
            baseline_bytes = baselines.read_bytes()
            self.assertNotIn(b"\r", record_bytes + baseline_bytes)
            second = run_cli(str(root), "--history-dir", str(history), "--baseline")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("unchanged", second.stdout)
            self.assertEqual((history / "runs/20261016T150000Z-baseline.json").read_bytes(), record_bytes)
            self.assertEqual(baselines.read_bytes(), baseline_bytes)
            # A baseline with a switch recorded is suspicious: warn, still record.
            gated = bench_tests.benchmark_profile(gates={"WINE_APC_FASTPATH": "1"})
            (root / "profile/profile.json").write_text(json.dumps(gated))
            third = run_cli(str(root), "--history-dir", str(history), "--baseline", "--trial", "T0001", "--arm", "AA")
            self.assertEqual(third.returncode, 0, third.stderr)
            self.assertIn("warning", third.stderr)
            record = json.loads((history / "runs/20261016T150000Z-baseline.json").read_text())
            self.assertEqual((record["trial"], record["arm"], record["switches"]), ("T0001", "AA", {"WINE_APC_FASTPATH": "1"}))
            # A traced baseline gets its own key, so it never replaces the untraced one.
            traced = Path(temporary) / "20261016T151000Z-baseline-traced"
            bench_tests.write_benchmark_run(traced, trace_mode="interface", tracer="wine-trace")
            self.assertEqual(history_add.main([str(traced), "--history-dir", str(history), "--baseline"]), 0)
            self.assertEqual(json.loads(baselines.read_text())[bench_tests.FIXTURE_MACHINE_ID], {
                "benchmark/-": "20261016T150000Z-baseline", "benchmark/-@interface": "20261016T151000Z-baseline-traced",
            })

    def test_plain_baseline_with_launcher_configuration_does_not_warn(self):
        # B4's baseline: the suite recorded the installer's Link settings and the
        # wrapper's ABLETON_POWER; none of them is a switch.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "20261017T034259Z-b4-baseline-untraced"
            history = Path(temporary) / "history"
            profile = bench_tests.benchmark_profile(gates={
                "ABLETON_LINKD": "/home/user/.local/share/ableton-wine/ableton-linkd",
                "ABLETON_LINK_MODE": "off", "ABLETON_POWER": "performance", "ABLETON_RT": "auto",
                "WINE_APC_FASTPATH": "", "PIPEASIO_TELEMETRY": " ",
            })
            bench_tests.write_benchmark_run(root, profile=profile)
            completed = run_cli(str(root), "--history-dir", str(history), "--baseline")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("warning", completed.stderr)
            record = json.loads((history / "runs/20261017T034259Z-b4-baseline-untraced.json").read_text())
            self.assertEqual(record["switches"], {})

    def test_rejects_bad_arguments_and_incomplete_baselines(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "running"
            history = Path(temporary) / "history"
            self.assertEqual(run_cli(str(root), "--history-dir", str(history)).returncode, 2)
            bench_tests.write_benchmark_run(root, status="running")
            self.assertEqual(run_cli(str(root), "--history-dir", str(history), "--arm", "C").returncode, 2)
            self.assertEqual(run_cli(str(root), "--history-dir", str(history), "--trial", "7").returncode, 2)
            completed = run_cli(str(root), "--history-dir", str(history))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("not 'complete'", completed.stderr)
            refused = run_cli(str(root), "--history-dir", str(history), "--baseline")
            self.assertEqual(refused.returncode, 2)
            self.assertFalse((history / "baselines.json").exists())

    def test_sparse_inputs_never_crash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "sparse"
            history = Path(temporary) / "history"
            root.mkdir()
            (root / "run.json").write_text("{}")
            (root / "report.json").write_text("not json")
            completed = run_cli(str(root), "--history-dir", str(history))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            record = json.loads((history / "runs/sparse.json").read_text())
            self.assertEqual(tuple(record), TOP_LEVEL_KEYS)
            self.assertEqual(record["sets"], {})
            self.assertIsNone(record["structure"])
            self.assertEqual(record["trace_mode"], "off")
            self.assertEqual(record["switches"], {})
            self.assertEqual(run_cli(str(root), "--history-dir", str(history), "--baseline").returncode, 2)


class HelperTests(unittest.TestCase):
    def test_voluntary_switch_rate_needs_every_live_process(self):
        measurement = bench_tests.benchmark_measurement("Benchmark_Empty")
        self.assertIsNone(history_add.voluntary_switch_rate(measurement))
        measurement["process"]["summary"]["live"]["pids"] = [1, 2]
        measurement["process"]["details"]["processes"] = [
            {"pid": 1, "voluntary_context_switches": 600}, {"pid": 2, "voluntary_context_switches": None},
        ]
        self.assertIsNone(history_add.voluntary_switch_rate(measurement))
        measurement["process"]["details"]["processes"][1]["voluntary_context_switches"] = 300
        self.assertEqual(history_add.voluntary_switch_rate(measurement), 30.0)

    def test_build_info_fields_and_structure_inference(self):
        self.assertEqual(history_add.build_info_fields(BUILD_INFO), {
            "dist-version": "2026.08.28.1", "wine": "wine-11.13", "source-tree": "0123abcd",
        })
        self.assertEqual(history_add.build_info_fields("build-a"), {})
        canonical = {"set_order": list(report.CANONICAL_SETS)}
        self.assertEqual(history_add.run_structure(canonical, None), "benchmark")
        self.assertEqual(history_add.run_structure(canonical, "idle-playing"), "diagnostic")
        self.assertEqual(history_add.run_structure({"set_order": ["Benchmark_Zero"]}, None), "diagnostic")
        self.assertEqual(history_add.run_structure({"structure": "benchmark", "set_order": ["x"]}, None), "benchmark")
        self.assertIsNone(history_add.run_structure({}, None))

    def test_switch_classification(self):
        profile = {"configuration": {"benchmark_gates": {
            "ABLETON_LINKD": "/opt/linkd", "ABLETON_LINKD_LINGER": "0", "ABLETON_LINK_MODE": "session",
            "ABLETON_MAX_AUDIO_THREADS": "4", "ABLETON_POWER": "balanced", "ABLETON_RT": "off",
            "ABLETON_DCOMP": "on", "ABLETON_THEME_MODE": "auto",
            "PIPEASIO_PREFERRED_BUFFERSIZE": "64", "WINE_APC_FASTPATH": "0", "WINE_MSG_FASTPATH": "",
        }}}
        self.assertEqual(history_add.switch_record(profile), {
            "ABLETON_LINK_MODE": "session", "ABLETON_MAX_AUDIO_THREADS": "4", "ABLETON_POWER": "balanced",
            "ABLETON_RT": "off", "PIPEASIO_PREFERRED_BUFFERSIZE": "64", "WINE_APC_FASTPATH": "0",
        })
        self.assertEqual(history_add.switch_record({"configuration": {"benchmark_gates": None}}), {})
        self.assertFalse(history_add.is_switch("ABLETON_POWER", "Performance"))
        self.assertTrue(history_add.is_switch("WINE_APC_FASTPATH", "1"))

    def test_numbers_reject_booleans_and_strings(self):
        self.assertIsNone(history_add.number(True))
        self.assertIsNone(history_add.number("3"))
        self.assertEqual(history_add.number(3.5), 3.5)
        self.assertEqual(history_add.run_identifier({"id": "a b/c"}, Path("/tmp/x")), "a-b-c")

    def test_baseline_key_adds_the_trace_mode_of_traced_runs(self):
        self.assertEqual(history_add.baseline_key({"structure": "benchmark", "scenario": None, "trace_mode": "off"}), "benchmark/-")
        self.assertEqual(history_add.baseline_key({"structure": None, "scenario": None, "trace_mode": "off"}), "-/-")
        self.assertEqual(
            history_add.baseline_key({"structure": "diagnostic", "scenario": "view-flip", "trace_mode": "drilldown"}),
            "diagnostic/view-flip@drilldown",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
