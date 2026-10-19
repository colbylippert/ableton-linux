#!/usr/bin/env python3
"""Tests for profiler/bin/ledger-report: validation, rendering, exit codes; no Live needed."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "ledger-report"
MACHINE = "0123456789abcdef0123456789abcdef"
CALL_SITE = "ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1"
OTHER_SITE = "server_req|NtSetEvent|ntdll+0x1234"


def load(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


ledger = load("ledger_report", SCRIPT)


def trial(**overrides):
    value = {
        "schema": ledger.SCHEMA, "trial": "T0007", "date": "2026-10-17T10:00:00Z", "host": "bare-metal",
        "branch": "trial/T0007-ntsync-wait-coalesce",
        "hypothesis": "Coalescing NtWaitForSingleObject wake-ups removes late blocks on Benchmark_VSTs",
        "evidence": [{"run": "20261016T120000Z-baseline", "set": "Benchmark_VSTs", "call_site": CALL_SITE, "share_of_lost_slack": 0.62}],
        "change": {
            "kind": "wine-patch", "patch": "patches/0108-ntdll-coalesce-waits.patch", "switch": "WINE_WAIT_COALESCE=1",
            "probe": "tools/waitprobe.c", "note": "notes/ABLETON-WINE-WAIT-COALESCE.md",
        },
        "probe_result": {"pass": 5, "fail": 0, "skip": 1, "log": "~/.local/state/profiler/logs/20261017T100000Z-probe.log"},
        "runs": {
            "aa": [["20261017T100000Z-T0007-AA1", "20261017T101000Z-T0007-AA2"]],
            "abab": [
                {"a": "20261017T102000Z-T0007-A1", "b": "20261017T103000Z-T0007-B1"},
                {"a": "20261017T104000Z-T0007-A2", "b": "20261017T105000Z-T0007-B2"},
                {"a": "20261017T110000Z-T0007-A3", "b": "20261017T111000Z-T0007-B3"},
            ],
            "traced": {"a": "20261017T112000Z-T0007-traced-A", "b": "20261017T113000Z-T0007-traced-B"},
        },
        "metrics": {
            "primary": "live_cpu_pct_per_core",
            "per_set": {"Benchmark_VSTs": {"a_median": 41.2, "b_median": 39.9, "aa_spread": 0.5, "delta": -1.3, "ratio_to_spread": 2.6}},
            "xruns": {"a": 0, "b": 0}, "cpu_live_pct": {"a": 41.2, "b": 39.9},
        },
        "traced_confirmation": {"call_site_share_before": 0.62, "after": 0.11},
        "verdict": "keep",
        "rationale": "Median Live CPU fell 1.3 points, 2.6x the A/A spread; no Set regressed; traced share 0.62 -> 0.11.",
        "commit": "abc1234def56", "minutes": 95,
    }
    value.update(overrides)
    return value


def history_run(run_id, **overrides):
    value = {
        "schema": "ableton-linux-profiler-history/v1", "run_id": run_id, "tag": run_id,
        "started_at": "2026-10-16T12:00:00Z", "machine_id": MACHINE, "hostname": "bench", "virtualization": "none",
        "structure": "benchmark", "scenario": None, "trace_mode": "off", "duration_s": 30,
        "runtime": {"dist_version": "2026.08.28.1", "source_tree_sha": None, "dev_info": None}, "switches": {},
        "harness_sha": "harness-a", "commit": None, "trial": None, "arm": None,
        "source_dir": f"~/.local/share/profiler/runs/{run_id}/bench", "sets": {"Benchmark_VSTs": {"call_sites_top": None}},
    }
    value.update(overrides)
    return value


def write_history(directory: Path, runs, baselines=None):
    (directory / "runs").mkdir(parents=True, exist_ok=True)
    for run in runs:
        (directory / "runs" / f"{run['run_id']}.json").write_text(json.dumps(run))
    (directory / "baselines.json").write_text(json.dumps(baselines or {}))


def with_sites(run_id, sites, **overrides):
    return history_run(run_id, sets={"Benchmark_VSTs": {"call_sites_top": [
        {"key": key, "share": share, "total_ns_in_late_blocks": 1000} for key, share in sites
    ]}}, **overrides)


def problems(**overrides):
    return ledger.validate_trial(trial(**overrides))


def render(trials, history_dir=None, line_problems=()):
    history = ledger.load_history(history_dir) if history_dir else {"runs": {}, "baselines": {}}
    return ledger.render(trials, list(line_problems), history, Path("ledger.jsonl"), history_dir or Path("history"))


class ValidationTests(unittest.TestCase):
    def test_valid_line_has_no_problems(self):
        self.assertEqual(problems(), [])
        for verdict in ledger.VERDICTS:
            self.assertEqual(problems(verdict=verdict), [], verdict)

    def test_missing_and_unknown_keys(self):
        value = trial()
        del value["minutes"]
        value["extra"] = 1
        found = ledger.validate_trial(value)
        self.assertEqual(found, ["line is missing minutes", "line has unknown key extra"])
        self.assertEqual(ledger.validate_trial([]), ["line must be an object"])

    def test_identity_fields(self):
        self.assertEqual(problems(schema="x"), [f"schema must be {ledger.SCHEMA}"])
        self.assertEqual(problems(trial="7"), ["trial must look like T0007"])
        self.assertEqual(problems(date="2026-10-17"), ["date must be UTC ISO 8601 like 2026-10-17T10:00:00Z"])
        self.assertEqual(problems(host="laptop"), ["host must be bare-metal or vm:<name>"])
        self.assertEqual(problems(branch="feature/x"), ["branch must be trial/T0007-<slug> or the work branch profiler"])
        self.assertEqual(problems(branch="profiler"), [])
        self.assertEqual(problems(hypothesis=" "), ["hypothesis must be a non-empty string"])
        self.assertEqual(problems(verdict="maybe"), ["verdict must be one of " + ", ".join(ledger.VERDICTS)])
        self.assertEqual(problems(commit="xyz"), ["commit must be null or 7-40 hex characters"])
        self.assertEqual(problems(minutes=-1), ["minutes must be null or a number >= 0"])
        self.assertEqual(problems(commit=None, minutes=None, verdict="inconclusive"), [])

    def test_nested_shapes(self):
        self.assertEqual(problems(evidence={}), ["evidence must be a list"])
        self.assertEqual(problems(evidence=[{"run": "r", "set": "s", "call_site": "c", "share_of_lost_slack": 1.5}]),
                         ["evidence[0].share_of_lost_slack must be a number between 0 and 1"])
        self.assertEqual(problems(change={**trial()["change"], "kind": "magic"}), ["change.kind must be one of " + ", ".join(ledger.CHANGE_KINDS)])
        self.assertEqual(problems(change={**trial()["change"], "switch": " "}),
                         ["change.switch must be null or one line (NAME=value for an environment switch)"])
        self.assertEqual(problems(change={**trial()["change"], "switch": "a\nb"}),
                         ["change.switch must be null or one line (NAME=value for an environment switch)"])
        self.assertEqual(problems(change={**trial()["change"], "switch": "chrt -a -r -p 10 wineserver"}), [])
        self.assertEqual(problems(probe_result={"pass": 1, "fail": -1, "skip": 0, "log": None}), ["probe_result.fail must be a count"])
        self.assertEqual(problems(probe_result={"pass": True, "fail": 0, "skip": 0, "log": None}), ["probe_result.pass must be a count"])
        runs = trial()["runs"]
        self.assertEqual(problems(runs={**runs, "abab": [{"a": "x"}]}), ["runs.abab[0] is missing b"])
        self.assertEqual(problems(runs={**runs, "aa": [["only-one"]]}), ["runs.aa[0] must be [run, run]"])
        self.assertEqual(problems(runs={**runs, "traced": {"a": "x", "b": ""}}), ["runs.traced.b must be a run id or a list of run ids"])
        self.assertEqual(problems(runs={**runs, "traced": {"a": ["x-Inbuilts", "x-VSTs"], "b": ["y"]}}), [])
        self.assertEqual(problems(runs={**runs, "traced": {"a": [], "b": ["y"]}}), ["runs.traced.a must be a run id or a list of run ids"])
        metrics = trial()["metrics"]
        self.assertEqual(problems(metrics={**metrics, "per_set": {"S": {"a_median": "1"}}}),
                         ["metrics.per_set[S] is missing b_median", "metrics.per_set[S] is missing aa_spread",
                          "metrics.per_set[S] is missing delta", "metrics.per_set[S] is missing ratio_to_spread"])
        self.assertEqual(problems(metrics={**metrics, "xruns": {"a": "0", "b": 0}}), ["metrics.xruns.a must be null or a number"])
        # dropout trials: error totals with sign-test figures, secondary metrics, per-Set run values
        per_set = {"S": {"a_median": 3, "b_median": 1, "aa_spread": 2, "delta": -2, "ratio_to_spread": 1.0,
                         "aa_spread_from": "range of the three A runs", "a_runs": [3, 1, 3], "b_runs": [0, 1, None]}}
        dropouts = {**metrics, "per_set": per_set,
                    "pipewire_errors": {"a": 20, "b": 10, "drop": 0.5, "fewer_pairs": 6, "n_pairs": 9, "p_b_fewer": 0.049},
                    "secondary": {"dsp_avg": {"S": {"a_median": 10.5, "b_median": 9.9}}}}
        self.assertEqual(problems(metrics=dropouts), [])
        self.assertEqual(problems(metrics={**dropouts, "pipewire_errors": {"a": "20", "b": 10}}),
                         ["metrics.pipewire_errors.a must be null or a number"])
        self.assertEqual(problems(metrics={**dropouts, "pipewire_errors": {"a": 20}}),
                         ["metrics.pipewire_errors must be an object with a and b"])
        self.assertEqual(problems(metrics={**dropouts, "secondary": []}), ["metrics.secondary must be an object"])
        self.assertEqual(problems(metrics={**dropouts, "per_set": {"S": {**per_set["S"], "a_runs": ["3"]}}}),
                         ["metrics.per_set[S].a_runs must be a list of numbers"])
        self.assertEqual(problems(metrics={**dropouts, "per_set": {"S": {**per_set["S"], "extra": 1}}}),
                         ["metrics.per_set[S] has unknown key extra"])
        self.assertEqual(problems(traced_confirmation={"call_site_share_before": 0.6}), ["traced_confirmation is missing after"])
        # the headroom campaign (T0019 on): per-pair values, measured confirmations, a diagnostic's other measure
        self.assertEqual(problems(metrics={**dropouts, "per_set": {"S": {**per_set["S"], "pairs_a_b": [[34.5, 23.9], [34.7, 27.4]]}}}), [])
        self.assertEqual(problems(metrics={**dropouts, "per_set": {"S": {**per_set["S"], "pairs_a_b": [[1]]}}}),
                         ["metrics.per_set[S].pairs_a_b must be a list of [a, b] number pairs"])
        self.assertEqual(problems(traced_confirmation={"before": {"share": 0.086}, "after": {"share": 0.019}}), [])
        self.assertEqual(problems(traced_confirmation={"before": {"share": 0.086}, "after": 0.019}),
                         ["traced_confirmation.after must be an object"])
        self.assertEqual(problems(evidence=[{"run": "d0003", "set": "s", "call_site": "c", "share_of_lost_slack": None,
                                             "faults_per_late_block": "1140-1561"}]), [])
        self.assertEqual(problems(evidence=[{"run": "d0003", "set": "s", "call_site": "c", "share_of_lost_slack": None}]),
                         ["evidence[0].share_of_lost_slack must be a number between 0 and 1"])

    def test_keep_gate(self):
        virtual = ["verdicts on a virtualised host are limited to tooling or mechanism-confirmed"]
        self.assertEqual(problems(host="vm:vmware"), virtual)
        self.assertEqual(problems(host="vm:kvm", verdict="inconclusive"), virtual)
        self.assertEqual(problems(host="vm:vmware", verdict="mechanism-confirmed"), [])
        self.assertEqual(problems(host="vm:vmware", verdict="tooling", runs={"aa": [], "abab": [], "traced": None}, metrics=None), [])
        runs = trial()["runs"]
        self.assertEqual(problems(runs={**runs, "abab": runs["abab"][:2]}), ["verdict keep needs at least 3 untraced A/B pairs in runs.abab"])
        self.assertEqual(problems(runs={**runs, "aa": []}), ["verdict keep needs an A/A pair in runs.aa"])
        self.assertEqual(problems(runs={**runs, "traced": None}), ["verdict keep needs one traced run per arm in runs.traced"])
        self.assertEqual(problems(runs={**runs, "traced": None}, verdict="inconclusive"), [])
        metrics = trial()["metrics"]
        self.assertEqual(problems(metrics={**metrics, "xruns": {"a": 0, "b": 1}}), ["verdict keep needs metrics.xruns with 0 on the kept arm (b)"])
        self.assertEqual(problems(metrics={**metrics, "xruns": None}), ["verdict keep needs metrics.xruns with 0 on the kept arm (b)"])
        self.assertEqual(problems(metrics={**metrics, "xruns": {"a": 2, "b": 0}}), [])
        # a configuration change is kept on its untraced A/B rule: no probe or traced runs needed
        config = {"kind": "config", "patch": None, "switch": "ABLETON_MAX_AUDIO_THREADS=9", "probe": None, "note": "profiler/plans/resume-plan.md"}
        self.assertEqual(problems(change=config, probe_result=None, runs={**runs, "traced": None}, traced_confirmation=None), [])
        self.assertEqual(problems(change={**config, "note": None}, probe_result=None, runs={**runs, "traced": None}),
                         ["verdict keep needs change.note"])
        self.assertEqual(problems(metrics=None), ["verdict keep needs metrics"])
        self.assertEqual(problems(probe_result={"pass": 4, "fail": 1, "skip": 0, "log": None}), ["verdict keep needs probe_result with fail 0"])
        self.assertEqual(problems(change={**trial()["change"], "note": None}), ["verdict keep needs change.note"])
        self.assertEqual(problems(runs={**runs, "traced": None}, verdict="mechanism-confirmed"), ["verdict mechanism-confirmed needs runs.traced"])
        self.assertEqual(problems(traced_confirmation=None, verdict="mechanism-confirmed"), ["verdict mechanism-confirmed needs traced_confirmation"])

    def test_ledger_file_reports_line_numbers_duplicates_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "ledger.jsonl"
            lines = [json.dumps(trial()), "", "{not json", json.dumps(trial(trial="T0008", branch="trial/T0008-x", verdict="revert")),
                     json.dumps(trial(verdict="tooling"))]
            path.write_text("\n".join(lines) + "\n")
            trials, found = ledger.load_ledger(path)
            self.assertEqual([item["trial"] for item in trials], ["T0007", "T0008"])
            self.assertEqual(found[0][0], 3)
            self.assertIn("invalid JSON", found[0][1])
            self.assertEqual(found[1], (5, "duplicate trial T0007 (first on line 1)"))
            path.write_text("")
            self.assertEqual(ledger.load_ledger(path), ([], []))


class RenderTests(unittest.TestCase):
    def test_summary_counts_table_and_next_id(self):
        trials = [trial(), trial(trial="T0009", branch="trial/T0009-y", verdict="revert", metrics=None, commit=None, minutes=None)]
        rendered = render(trials)
        self.assertIn("| keep | 1 |", rendered)
        self.assertIn("| revert | 1 |", rendered)
        self.assertIn("| inconclusive | 0 |", rendered)
        self.assertIn("| total | 2 |", rendered)
        self.assertIn("Next trial id: `T0010`", rendered)
        self.assertIn("Minutes recorded: 95.", rendered)
        self.assertIn("| T0007 | 2026-10-17 | bare-metal | Coalescing NtWaitForSingleObject", rendered)
        self.assertIn("| `WINE_WAIT_COALESCE=1` | live_cpu_pct_per_core: Benchmark_VSTs -1.3 (2.6x spread) | keep | `abc1234def56` |", rendered)
        self.assertIn("| T0009 | 2026-10-17 | bare-metal |", rendered)
        self.assertIn("| - | revert | - |", rendered)
        self.assertNotIn("NO TIMING CLAIMS", rendered)
        self.assertEqual(render([]).count("No trials yet."), 1)

    def test_banner_for_vm_host_and_for_cited_virtualised_runs(self):
        rendered = render([trial(host="vm:vmware", verdict="mechanism-confirmed")])
        self.assertIn("> NO TIMING CLAIMS: 1 trial(s) ran on or cite a virtualised host: T0007 (vmware).", rendered)
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            write_history(history, [history_run("20261017T102000Z-T0007-A1", virtualization="kvm", trial="T0007", arm="A")])
            rendered = render([trial()], history)
            self.assertIn("T0007 (kvm)", rendered)
            write_history(history, [history_run("20261017T102000Z-T0007-A1", trial="T0007", arm="A")])
            self.assertNotIn("NO TIMING CLAIMS", render([trial()], history))

    def test_open_hotspots_from_baseline_or_newest_traced_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            runs = [
                history_run("20261016T120000Z-baseline"),
                with_sites("20261016T130000Z-traced-old", [(CALL_SITE, 0.7), ("old|only|x", 0.1)], trace_mode="interface", started_at="2026-10-16T13:00:00Z"),
                with_sites("20261016T140000Z-traced", [(CALL_SITE, 0.62), (OTHER_SITE, 0.2)], trace_mode="interface", started_at="2026-10-16T14:00:00Z"),
                with_sites("20261016T150000Z-switched", [("switched|x|y", 0.9)], trace_mode="interface", switches={"WINE_X": "1"}),
                with_sites("20261016T160000Z-trialled", [("trialled|x|y", 0.9)], trace_mode="interface", trial="T0001"),
            ]
            write_history(history, runs, {MACHINE: {"benchmark/-": "20261016T120000Z-baseline"}})
            rendered = render([trial()], history)
            self.assertIn("| 0123456789ab | benchmark/- | [20261016T140000Z-traced](", rendered)
            self.assertIn(f"| Benchmark_VSTs | {ledger.cell(OTHER_SITE)} | 0.20 |", rendered)
            self.assertNotIn("old|only", rendered)
            self.assertNotIn("switched", rendered.split("## Open hotspots")[1])
            self.assertNotIn("trialled", rendered.split("## Open hotspots")[1])
            self.assertNotIn(f"| {ledger.cell(CALL_SITE)} |", rendered)
            self.assertIn(f"Targeted call sites: {ledger.cell(CALL_SITE)} (T0007).", rendered)
            # An explicit traced baseline wins over newer traced runs.
            write_history(history, runs, {MACHINE: {"benchmark/-": "20261016T130000Z-traced-old"}})
            rendered = render([trial()], history)
            self.assertIn("old\\|only\\|x", rendered)
            self.assertNotIn(ledger.cell(OTHER_SITE), rendered.split("## Open hotspots")[1])
            self.assertIn("5 run(s), 1 baseline(s)", rendered)
            # history-add keys a traced baseline "...@<trace mode>" beside the untraced one; the identity stays "benchmark/-".
            write_history(history, runs, {MACHINE: {
                "benchmark/-": "20261016T120000Z-baseline", "benchmark/-@interface": "20261016T130000Z-traced-old",
            }})
            rendered = render([trial()], history)
            self.assertIn("| 0123456789ab | benchmark/- | [20261016T130000Z-traced-old](", rendered)
            self.assertNotIn("benchmark/-@interface", rendered.split("## Open hotspots")[1])
            self.assertNotIn("20261016T140000Z-traced", rendered.split("## Open hotspots")[1])
            self.assertIn("5 run(s), 2 baseline(s)", rendered)
        rendered = render([trial()])
        self.assertIn("No baseline call sites recorded", rendered)

    def test_kept_block_links_history_and_compare_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            write_history(history, [
                history_run("20261017T112000Z-T0007-traced-A", trace_mode="interface", trial="T0007", arm="A"),
                history_run("20261017T113000Z-T0007-traced-B", trace_mode="interface", trial="T0007", arm="B"),
            ])
            rendered = render([trial()], history)
            self.assertIn("### T0007 - Coalescing", rendered)
            self.assertIn("- Probe: 5 pass / 0 fail / 1 skip", rendered)
            self.assertIn("[20261017T112000Z-T0007-traced-A](", rendered)
            self.assertIn("`20261017T102000Z-T0007-A1` -> `20261017T103000Z-T0007-B1`", rendered)
            self.assertIn("call-site share 0.62 -> 0.11", rendered)
            self.assertIn(
                "compare --before ~/.local/share/profiler/runs/20261017T112000Z-T0007-traced-A/bench "
                "--after ~/.local/share/profiler/runs/20261017T113000Z-T0007-traced-B/bench", rendered,
            )
        self.assertIn("## Kept trials\n\nNone.", render([trial(verdict="revert")]))

    def test_cells_escape_pipes_and_invalid_lines_section(self):
        rendered = render([trial(hypothesis="a | b\nc", verdict="inconclusive")], line_problems=[(4, "x | y")])
        self.assertIn("| a \\| b c |", rendered)
        self.assertIn("## Invalid lines\n\n- line 4: x \\| y", rendered)
        self.assertEqual(ledger.cell("x" * 120, 10), "xxxxxxx...")
        self.assertEqual(ledger.cell(None), "-")
        self.assertTrue(rendered.isascii())


class CliTests(unittest.TestCase):
    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *arguments], capture_output=True, text=True, check=False)

    def test_exit_codes_and_output_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "ledger.jsonl"
            path.write_text(json.dumps(trial()) + "\n")
            completed = self.run_cli("--ledger", str(path), "--history-dir", str(root / "history"))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("# Profiler ledger report", completed.stdout)
            self.assertEqual(completed.stderr, "")
            output = root / "report.md"
            completed = self.run_cli("--ledger", str(path), "--history-dir", str(root / "history"), "--output", str(output))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("| keep | 1 |", output.read_text(encoding="utf-8"))
            self.assertNotIn(b"\r", output.read_bytes())
            path.write_text(json.dumps(trial()) + "\n" + json.dumps(trial(host="vm:kvm")) + "\n")
            completed = self.run_cli("--ledger", str(path), "--history-dir", str(root / "history"))
            self.assertEqual(completed.returncode, 2)
            self.assertIn("## Invalid lines", completed.stdout)
            self.assertIn(":2: verdicts on a virtualised host are limited to", completed.stderr)
            self.assertEqual(self.run_cli("--ledger", str(root / "missing.jsonl")).returncode, 2)
            path.write_text("")
            self.assertEqual(self.run_cli("--ledger", str(path), "--history-dir", str(root / "history")).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
