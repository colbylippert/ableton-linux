"""Print a headroom-campaign ledger line (run on the laptop from the checkout root; nothing is written).

usage: ledger_campaign.py SPEC_JSON RULE_JSON
RULE_JSON: the last line of `campaign_tools.py rule-h TRIAL` (rule-d for rule D). SPEC_JSON (per trial):
  {"trial", "rule": "H", "D" or "noninferiority", "hypothesis", "change": {kind, patch, switch, probe, note},
   "probe_result": {...} or null, "mechanism_holds": bool, "mechanism": {...}, "mechanism_summary": text,
   "traced": {"a": [...], "b": [...]} or null, "traced_confirmation": {...} or null,
   "keep_note", "not_kept_note"}
Verdicts as pre-registered (resume-plan.md, headroom campaign; kernel-plan.md, trial rules):
  rule H: keep = PASS and mechanism; mechanism-confirmed = guards G1-G3 and mechanism but H1 or H2 fails; else revert.
  rule D: keep = PASS and mechanism; mechanism-confirmed = guards G1, G2, G4 and mechanism but D1 or D2 fails; else revert.
  non-inferiority (T0023): keep = G1, G2, G3 and mechanism; else revert.
"""
import datetime
import json
import os
import sys

spec = json.load(open(sys.argv[1]))
rule = json.loads(open(sys.argv[2]).read())
trial = spec["trial"]
SETS = ["Benchmark_Inbuilts", "Benchmark_Max4Live", "Benchmark_VSTs"]
pairs = [{"a": f"trial-{trial}-A{i}", "b": f"trial-{trial}-B{i}"} for i in (1, 2, 3)]
OUT = os.path.expanduser(f"~/.local/state/profiler/trial-{trial}.out")
c = rule["criteria"]
guards = c["G1"] and c["G2"] and (c["G4"] if spec["rule"] == "D" else c["G3"])
mech = spec["mechanism_holds"]
if spec["rule"] in ("H", "D"):
    if rule["verdict_rule"] == "PASS" and mech:
        v = "keep"
    elif guards and mech:
        v = "mechanism-confirmed"
    else:
        v = "revert"
    if spec["rule"] == "H":
        rule_text = (f"Pre-registered rule H {rule['verdict_rule']}: [H1] {'yes' if c['H1'] else 'no'} (B's audio-thread CPU lower in "
                     f"{rule['lower_pairs']} of 9 Set-pairs, sign test p = {rule['p_sign']:.4f}), [H2] {'yes' if c['H2'] else 'no'} "
                     f"(median paired change {rule['median_change']:+.1%}); ")
    else:
        rule_text = (f"Pre-registered rule D {rule['verdict_rule']}: [D1] {'yes' if c['D1'] else 'no'} (B's DSP average lower in "
                     f"{rule['lower_pairs']} of 9 Set-pairs, sign test p = {rule['p_sign']:.4f}), [D2] {'yes' if c['D2'] else 'no'} "
                     f"(median paired change {rule['median_change']:+.1%}); [G4] {'ok' if c['G4'] else 'FAIL'} (audio-thread CPU "
                     f"median paired change {rule['m_median_change']:+.1%}, {rule['m_median_points']:+.2f} points of one core; "
                     f"limit {rule['g4_limit']}); ")
else:
    v = "keep" if guards and mech else "revert"
    rule_text = "Pre-registered non-inferiority rule " + ("PASS" if guards else "FAIL") + "; "
pe, dsp = rule["pipewire_errors"], rule["dsp_avg"]
rationale = (
    rule_text +
    f"guards: xruns {rule['xruns']['a']} -> {rule['xruns']['b']} ({'ok' if c['G1'] else 'FAIL'}), PipeWire errors "
    f"{pe['a']} -> {pe['b']} (p that B's share is this high = {pe['p_b_more']:.3f}, {'ok' if c['G2'] else 'FAIL'}), "
    f"DSP average {'/'.join(str(dsp[s]['a_median']) for s in SETS)} -> {'/'.join(str(dsp[s]['b_median']) for s in SETS)} "
    + (f"({'ok' if c['G3'] else 'FAIL'})" if "G3" in c else "") +
    f". Audio-thread CPU medians (% of one core) {rule['m_median']['a']} -> {rule['m_median']['b']}; "
    f"Live CPU {rule['live_cpu']['a']} -> {rule['live_cpu']['b']} %; worst DSP peak medians {rule['dsp_peak_median']['a']} -> "
    f"{rule['dsp_peak_median']['b']} %. Mechanism {'holds' if mech else 'does not hold'}: {spec['mechanism_summary']} "
    + (spec["keep_note"] if v == "keep" else spec["not_kept_note"])
)
rec = lambda r: json.load(open(f"profiler/history/runs/{r}.json"))
a1 = rec(pairs[0]["a"])
started = datetime.datetime.fromisoformat(a1["started_at"].replace("Z", "+00:00"))
ended = datetime.datetime.fromtimestamp(os.path.getmtime(OUT), datetime.timezone.utc)
if spec["rule"] == "D":  # the DSP average has T0002's A/A spread
    per_set = {s: {"a_median": d["a_median"], "b_median": d["b_median"], "aa_spread": d["aa_spread"], "delta": d["delta"],
                   "ratio_to_spread": d["ratio_to_spread"], "pairs_a_b": rule["dsp_pairs"][s]}
               for s, d in ((s, rule["dsp_avg"][s]) for s in SETS)}
else:  # the audio-thread CPU has no A/A spread
    per_set = {s: {"a_median": rule["m_median"]["a"][i], "b_median": rule["m_median"]["b"][i], "aa_spread": None,
                   "delta": round(rule["m_median"]["b"][i] - rule["m_median"]["a"][i], 2), "ratio_to_spread": None,
                   "pairs_a_b": rule["m_pairs"][s]} for i, s in enumerate(SETS)}
entry = {
    "schema": "ableton-linux-profiler-ledger/v1",
    "trial": trial,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    "host": "bare-metal",
    "branch": "profiler",
    "hypothesis": spec["hypothesis"],
    "evidence": spec.get("evidence", []),
    "change": spec["change"],
    "probe_result": spec.get("probe_result"),
    "runs": {"aa": [["aa-focusrite-1", "aa-focusrite-2"], ["aa-focusrite-2", "aa-focusrite-3"]], "abab": pairs,
             "traced": spec.get("traced")},
    "metrics": {
        "primary": {"H": "audio_thread_cpu_pct", "D": "dsp_avg"}.get(spec["rule"], "pipewire_errors"),
        "per_set": per_set,
        "pipewire_errors": pe,
        "secondary": {"dsp_avg": dsp, "dsp_peak_median": rule["dsp_peak_median"], "worker_wait_ms": rule["worker_wait_ms"],
                      "rule": rule["criteria"], "lower_pairs": rule["lower_pairs"], "p_sign": rule["p_sign"],
                      "median_change": rule["median_change"], "mechanism": spec["mechanism"]},
        "xruns": rule["xruns"],
        "cpu_live_pct": rule["live_cpu"],
    },
    "traced_confirmation": spec.get("traced_confirmation"),
    "verdict": v,
    "rationale": rationale,
    "commit": (a1.get("commit") or "")[:7],
    "minutes": round((ended - started).total_seconds() / 60),
}
print(json.dumps(entry))
