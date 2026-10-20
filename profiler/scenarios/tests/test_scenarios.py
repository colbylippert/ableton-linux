#!/usr/bin/env python3
"""Every shipped scenario validates against SCHEMA.md and keeps its benchmark grade."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import signal
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SCENARIOS = HERE.parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_scenario_run():
    path = HERE.parents[1] / "control" / "scenario-run.py"
    if hasattr(signal, "SIGPIPE"):
        return load("scenario_run", path)
    # Windows has no SIGPIPE; bench-osc.py installs the Unix default at import.
    with mock.patch.object(signal, "SIGPIPE", signal.SIGTERM, create=True), mock.patch.object(signal, "signal"):
        return load("scenario_run", path)


scenario_run = load_scenario_run()
validate = scenario_run.validate
EXPECTED = {
    "idle-playing": "benchmark", "clip-launch-storm": "benchmark", "param-sweep": "benchmark",
    "tempo-ramp": "benchmark", "track-churn": "diagnostic", "view-flip": "diagnostic",
    "load-devices": "diagnostic", "ramp-duplicate-all": "diagnostic",
}


def shipped() -> dict[str, tuple[Path, dict]]:
    return {
        path.stem: (path, json.loads(path.read_text(encoding="utf-8")))
        for path in sorted(SCENARIOS.glob("*.json"))
    }


def ops(document: dict, phase: str) -> list[str]:
    steps = document["timeline"]["steps"] if phase == "timeline" else document[phase]
    return [step["op"] for step in steps]


class ShippedScenarioTests(unittest.TestCase):
    def test_the_expected_scenarios_exist_with_their_kinds(self):
        self.assertEqual({name: document["kind"] for name, (_, document) in shipped().items()}, EXPECTED)

    def test_every_scenario_validates(self):
        for name, (path, document) in shipped().items():
            with self.subTest(name):
                self.assertEqual(validate(document, path.stem), [])
                self.assertEqual(document["schema"], scenario_run.SCENARIO_SCHEMA)
                self.assertEqual(document["name"], name)

    def test_files_are_canonical_json_with_lf_endings(self):
        for name, (path, document) in shipped().items():
            with self.subTest(name):
                raw = path.read_bytes()
                self.assertNotIn(b"\r", raw)
                self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
                self.assertEqual(raw.decode("utf-8"), json.dumps(document, indent=2) + "\n")

    def test_timeline_steps_ascend_and_fit_the_period(self):
        for name, (_, document) in shipped().items():
            with self.subTest(name):
                timeline = document["timeline"]
                times = [step["at_s"] for step in timeline["steps"]]
                self.assertEqual(times, sorted(times))
                if timeline["repeat"]:
                    self.assertTrue(all(at < timeline["period_s"] for at in times))
                else:
                    self.assertNotIn("period_s", timeline)
                self.assertEqual(timeline["marker_every_s"], 5.0)

    def test_ops_are_known_sendable_and_documented(self):
        schema = (SCENARIOS / "SCHEMA.md").read_text(encoding="utf-8")
        for op in scenario_run.OPS:
            self.assertIn(f"| `{op}` |", schema)
            if op != "sleep":
                self.assertIn(op, scenario_run.SENDERS)
        for name, (_, document) in shipped().items():
            with self.subTest(name):
                self.assertIn(f"| `{name}` |", schema)
                for phase in ("setup", "timeline", "teardown"):
                    self.assertTrue(set(ops(document, phase)) <= scenario_run.PHASE_OPS[phase])

    def test_benchmark_scenarios_keep_their_grade(self):
        forbidden = {"load_device", "create_midi_track", "create_audio_track", "delete_track", "show_view", "duplicate_all"}
        for name, (_, document) in shipped().items():
            with self.subTest(name):
                used = {phase: set(ops(document, phase)) for phase in ("setup", "timeline", "teardown")}
                if document["kind"] == "benchmark":
                    for phase, names in used.items():
                        self.assertFalse(names & forbidden, f"{name}: {phase} uses {names & forbidden}")
                    self.assertFalse((used["timeline"] | used["teardown"]) & scenario_run.BENCHMARK_SETUP_ONLY)
                else:
                    self.assertTrue((used["setup"] | used["timeline"]) & forbidden, f"{name} exercises nothing diagnostic")

    def test_requirements_and_setup_protocol(self):
        for name, (_, document) in shipped().items():
            with self.subTest(name):
                self.assertEqual(document["requires"], {"control_surface": True, "max_for_live": False, "plugins": []})
                self.assertEqual(ops(document, "setup")[:2], ["stop", "rewind"])
                self.assertIn("play", ops(document, "setup"))
                self.assertEqual(ops(document, "setup").count("marker"), 1)
                self.assertEqual(ops(document, "teardown")[0], "stop")
                self.assertIn(document["base_set"], scenario_run.BASE_SETS)

    def test_idle_playing_is_the_canonical_protocol(self):
        _, document = shipped()["idle-playing"]
        self.assertEqual(document["base_set"], "any")
        self.assertEqual(document["timeline"], {"repeat": False, "marker_every_s": 5.0, "steps": []})
        self.assertEqual(ops(document, "setup"), ["stop", "rewind", "play", "marker"])

    def test_clip_launch_storm_creates_what_it_fires(self):
        _, document = shipped()["clip-launch-storm"]
        created = {(step["track"], step["clip"]) for step in document["setup"] if step["op"] == "create_clip"}
        noted = {(step["track"], step["clip"]) for step in document["setup"] if step["op"] == "add_notes"}
        fired = [(step["track"], step["clip"]) for step in document["timeline"]["steps"]]
        self.assertEqual(created, noted)
        self.assertEqual(set(fired), created)
        self.assertEqual([step["at_s"] for step in document["timeline"]["steps"]], [0.0, 0.5, 1.0, 1.5])
        self.assertEqual(document["timeline"]["period_s"], 2.0)
        self.assertIn({"op": "set_quantization", "quantization": 7}, document["setup"])

    def test_param_sweep_is_a_20_hz_triangle_within_range(self):
        _, document = shipped()["param-sweep"]
        steps = document["timeline"]["steps"]
        self.assertEqual(len(steps), 120)
        self.assertEqual({step["op"] for step in steps}, {"set_param"})
        self.assertEqual({(step["track"], step["device"]) for step in steps}, {(0, 2)})
        self.assertEqual({step["param"] for step in steps}, {2, 4, 8})
        self.assertEqual(sorted({step["at_s"] for step in steps}), [round(slot * 0.05, 2) for slot in range(40)])
        values = [step["value"] for step in steps if step["param"] == 2]
        self.assertEqual((min(values), max(values)), (0.0, 1.0))
        self.assertEqual(values[:3], [0.0, 0.05, 0.1])
        self.assertEqual(values[20], 1.0)
        self.assertEqual(values[-1], 0.05)

    def test_tempo_ramp_moves_one_bpm_per_step(self):
        _, document = shipped()["tempo-ramp"]
        steps = document["timeline"]["steps"]
        self.assertEqual(len(steps), 120)
        self.assertEqual(document["timeline"]["period_s"], 30.0)
        tempos = [step["bpm"] for step in steps]
        self.assertEqual((min(tempos), max(tempos)), (90.0, 150.0))
        self.assertTrue(all(abs(b - a) == 1 for a, b in zip(tempos, tempos[1:])))
        self.assertEqual([step["at_s"] for step in steps[:3]], [0.0, 0.25, 0.5])
        self.assertIn({"op": "set_tempo", "bpm": 112.0}, document["teardown"])

    def test_diagnostic_scenarios_exercise_their_subsystems(self):
        _, churn = shipped()["track-churn"]
        self.assertEqual(ops(churn, "timeline"), ["create_midi_track", "delete_track"])
        self.assertEqual({step["index"] for step in churn["timeline"]["steps"]}, {1})
        _, flip = shipped()["view-flip"]
        self.assertEqual([step["view"] for step in flip["timeline"]["steps"]], ["Session", "Arranger", "Detail/DeviceChain"])
        _, loads = shipped()["load-devices"]
        self.assertFalse(loads["timeline"]["repeat"])
        self.assertEqual(len(loads["timeline"]["steps"]), 10)
        self.assertEqual({step["kind"] for step in loads["timeline"]["steps"]}, {"instruments", "audio_effects"})
        self.assertEqual([step["at_s"] for step in loads["timeline"]["steps"]], [float(3 * n) for n in range(10)])


class ValidationTests(unittest.TestCase):
    def problems(self, mutate) -> list[str]:
        document = copy.deepcopy(shipped()["clip-launch-storm"][1])
        mutate(document)
        return validate(document, "clip-launch-storm")

    def assert_problem(self, text: str, mutate) -> None:
        problems = self.problems(mutate)
        self.assertTrue(any(text in problem for problem in problems), f"{text!r} not in {problems}")

    def test_document_shape(self):
        self.assertEqual(validate([], None), ["scenario: must be a JSON object"])
        self.assert_problem("schema: must be 'ableton-linux-scenario/v1'", lambda d: d.update(schema="v0"))
        self.assert_problem("name: 'other' does not match the file name", lambda d: d.update(name="other"))
        self.assert_problem("name: must match", lambda d: d.update(name="Clip Storm"))
        self.assert_problem("kind: must be benchmark or diagnostic", lambda d: d.update(kind="smoke"))
        self.assert_problem("base_set: must be a canonical set name or any", lambda d: d.update(base_set="Mine.als"))
        self.assert_problem("extra: unknown key", lambda d: d.update(extra=1))
        self.assert_problem("teardown: missing", lambda d: d.pop("teardown"))
        self.assert_problem("requires.plugins: must be a list", lambda d: d["requires"].update(plugins="Dexed"))
        self.assert_problem("requires.gpu: unknown key", lambda d: d["requires"].update(gpu=True))
        self.assert_problem("description: must be a string", lambda d: d.update(description=3))
        self.assertEqual(self.problems(lambda d: d.pop("description")), [])

    def test_ops_and_fields(self):
        self.assert_problem("setup[0].op: unknown op 'pause'", lambda d: d["setup"].__setitem__(0, {"op": "pause"}))
        self.assert_problem("timeline.steps[0].track: missing", lambda d: d["timeline"]["steps"][0].pop("track"))
        self.assert_problem("timeline.steps[0].scene: unknown field for fire_clip",
                            lambda d: d["timeline"]["steps"][0].update(scene=1))
        self.assert_problem("timeline.steps[0].clip: must be an integer of 0 or more",
                            lambda d: d["timeline"]["steps"][0].update(clip=-1))
        self.assert_problem("setup[2].quantization: must be an integer between 0 and 13",
                            lambda d: d["setup"][2].update(quantization=14))
        self.assert_problem("setup[4].notes: must be a non-empty list",
                            lambda d: d["setup"][4].update(notes=[[60, 0, 1, 100]]))
        self.assert_problem("setup[3].length: must be a number above 0", lambda d: d["setup"][3].update(length=0))
        self.assert_problem("op: sleep is not allowed in timeline",
                            lambda d: d["timeline"]["steps"].append({"at_s": 1.9, "op": "sleep", "seconds": 1}))
        self.assert_problem("teardown[1].op: sleep is not allowed in teardown",
                            lambda d: d["teardown"].append({"op": "sleep", "seconds": 1}))
        self.assert_problem("setup[12].name: must match", lambda d: d["setup"][12].update(name="5"))
        self.assert_problem("setup[12].name: must match", lambda d: d["setup"][12].update(name="end"))
        self.assert_problem("setup[12].name: must match", lambda d: d["setup"][12].update(name="at-5s"))

    def test_timeline_rules(self):
        self.assert_problem("timeline.steps[1].at_s: must not decrease (0.25 after 0.5)",
                            lambda d: d["timeline"].update(
                                steps=[{"at_s": 0.5, "op": "play"}, {"at_s": 0.25, "op": "play"}]))
        self.assert_problem("timeline.steps[3].at_s: must stay below period_s (2 >= 2)",
                            lambda d: d["timeline"]["steps"][3].update(at_s=2.0))
        self.assert_problem("timeline.steps[0].at_s: missing", lambda d: d["timeline"]["steps"][0].pop("at_s"))
        self.assert_problem("timeline.steps[0].at_s: must be a number of 0 or more",
                            lambda d: d["timeline"]["steps"][0].update(at_s=-1))
        self.assert_problem("timeline.period_s: must be a number above 0 when repeat is true",
                            lambda d: d["timeline"].pop("period_s"))
        self.assert_problem("timeline.period_s: only valid when repeat is true",
                            lambda d: d["timeline"].update(repeat=False))
        self.assert_problem("timeline.marker_every_s: must be a number above 0",
                            lambda d: d["timeline"].update(marker_every_s=0))
        self.assert_problem("timeline.repeat: must be true or false", lambda d: d["timeline"].update(repeat=1))
        self.assert_problem("timeline.loop: unknown key", lambda d: d["timeline"].update(loop=True))
        self.assert_problem("timeline: must be an object", lambda d: d.update(timeline=[]))

    def test_benchmark_grade_rules(self):
        self.assert_problem("timeline.steps[0].op: load_device is not allowed in a benchmark scenario",
                            lambda d: d["timeline"]["steps"].__setitem__(
                                0, {"at_s": 0.0, "op": "load_device", "kind": "instruments", "name": "Operator"}))
        self.assert_problem("setup[0].op: create_midi_track is not allowed in a benchmark scenario",
                            lambda d: d["setup"].__setitem__(0, {"op": "create_midi_track", "index": -1}))
        self.assert_problem("teardown[0].op: show_view is not allowed in a benchmark scenario",
                            lambda d: d["teardown"].__setitem__(0, {"op": "show_view", "view": "Arranger"}))
        self.assert_problem("timeline.steps[0].op: create_clip is allowed only in the setup of a benchmark scenario",
                            lambda d: d["timeline"]["steps"].__setitem__(
                                0, {"at_s": 0.0, "op": "create_clip", "track": 1, "clip": 2, "length": 4.0}))
        allowed = self.problems(lambda d: d.update(kind="diagnostic") or d["timeline"]["steps"].__setitem__(
            0, {"at_s": 0.0, "op": "load_device", "kind": "instruments", "name": "Operator"}))
        self.assertEqual(allowed, [])

    def test_text_fields_reject_numeric_looking_names(self):
        self.assert_problem("setup[0].name: must be a printable string", lambda d: d["setup"].__setitem__(
            0, {"op": "load_device", "kind": "instruments", "name": "808"}) or d.update(kind="diagnostic"))
        self.assert_problem("setup[0].view: must be a printable string", lambda d: d["setup"].__setitem__(
            0, {"op": "show_view", "view": " Session"}) or d.update(kind="diagnostic"))
        self.assert_problem("setup[0].kind: must be one of instruments", lambda d: d["setup"].__setitem__(
            0, {"op": "load_device", "kind": "midi_effects", "name": "Arpeggiator"}) or d.update(kind="diagnostic"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
