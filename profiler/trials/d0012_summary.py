#!/usr/bin/env python3
"""d0012_summary.py [--runs DIR] [--json]: the D0012 smoke test of 8 to 12 audio workers
(profiler/plans/kernel-plan.md, D0012).

Reads the smoke runs ($R/d0012-r1-wN/bench): per Set Live's DSP average, peak median, worst peak and peaks over 100 %
(measurement.json's osc_dsp), Live's PipeWire errors (pipewire.pw_top.err_delta), xrun log lines, the audio-thread CPU M
and Live's CPU, and the AudioCalc threads' count (campaign_tools.per_set). Each count's score is the mean over the three
Sets of its DSP average divided by the five counts' mean for that Set (below 1 is better). For reference, today's T0032
A runs (the kept 5 workers, physcore, on the same boot and configuration; three runs, medians) are shown alongside: not
the same session, so context, not part of the ranking. One run per count: a smoke test, not a verdict.
"""
import argparse
import glob
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import campaign_tools  # noqa: E402

CONFIGS = [f"w{n}" for n in range(8, 13)]
SETS = campaign_tools.SETS
REFERENCE = ["trial-T0032-A1", "trial-T0032-A2", "trial-T0032-A3"]


def measurements(bench):
    out = {}
    try:
        threads = campaign_tools.per_set(bench)
    except Exception:
        threads = {}
    for f in glob.glob(os.path.join(bench, "sets", "*", "measurement.json")):
        d = json.load(open(f))
        name = os.path.basename(os.path.dirname(f)).split("-", 1)[1]
        dsp = d.get("osc_dsp") or {}
        pw = (d.get("pipewire") or {}).get("pw_top") or {}
        t = threads.get(name, {})
        out[name] = {"dsp": dsp.get("average_percent"), "peak_median": dsp.get("peak_median_percent"),
                     "worst": dsp.get("peak_percent"), "over100": dsp.get("peak_over_100_count") or 0,
                     "pw_err": pw.get("err_delta") or 0, "xruns": int((d.get("logs") or {}).get("xrun_line_count") or 0),
                     "m": t.get("m"), "live": t.get("live"), "workers": len(t.get("workers") or [])}
    return out


def reading(runs):
    data = {c: measurements(os.path.join(runs, f"d0012-r1-{c}", "bench")) for c in CONFIGS
            if os.path.isdir(os.path.join(runs, f"d0012-r1-{c}", "bench"))}
    ref_runs = [measurements(os.path.join(runs, r, "bench")) for r in REFERENCE if os.path.isdir(os.path.join(runs, r, "bench"))]
    mean = {s: statistics.mean(data[c][s]["dsp"] for c in data if s in data[c]) for s in SETS
            if any(s in data[c] for c in data)}
    rows = []
    for c, sets in data.items():
        ratios = [sets[s]["dsp"] / mean[s] for s in SETS if s in sets and s in mean]
        rows.append({"config": c, "score": round(statistics.mean(ratios), 4) if len(ratios) == len(SETS) else None,
                     "sets": sets, "pw_err": sum(v["pw_err"] for v in sets.values()),
                     "over100": sum(v["over100"] for v in sets.values()), "xruns": sum(v["xruns"] for v in sets.values()),
                     "workers_seen": sorted({v["workers"] for v in sets.values()})})
    rows.sort(key=lambda r: (r["score"] is None, r["score"] or 0))
    reference = {s: {k: round(statistics.median(r[s][k] for r in ref_runs if s in r and r[s][k] is not None), 2)
                     for k in ("dsp", "peak_median", "worst", "m", "live")}
                 for s in SETS if ref_runs and all(s in r for r in ref_runs)}
    ref_errors = sum(r[s]["pw_err"] for r in ref_runs for s in r) if ref_runs else None
    return {"rows": rows, "best": rows[0]["config"] if rows and rows[0]["score"] is not None else None,
            "reference_w5": reference, "reference_runs": len(ref_runs), "reference_pw_err": ref_errors}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--runs", default=campaign_tools.RUNS)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    result = reading(a.runs)
    if a.json:
        print(json.dumps(result))
        return
    short = [s.replace("Benchmark_", "") for s in SETS]
    print(f"{'count':>5} {'score':>6} | DSP average {' / '.join(short)} | peak median | worst peak | M (audio CPU) | "
          f"Live CPU | PW err  >100  xruns  workers")
    fmt = lambda sets, key: " / ".join(f"{sets[s][key]}" if s in sets and sets[s][key] is not None else "-" for s in SETS)
    for r in result["rows"]:
        s = r["sets"]
        live = statistics.median(v["live"] for v in s.values() if v["live"] is not None) if s else None
        print(f"{r['config'][1:]:>5} {r['score'] if r['score'] is not None else '-':>6} | {fmt(s, 'dsp')} | "
              f"{fmt(s, 'peak_median')} | {fmt(s, 'worst')} | {fmt(s, 'm')} | {live} | {r['pw_err']:>3} {r['over100']:>5} "
              f"{r['xruns']:>5}  {r['workers_seen']}")
    ref = result["reference_w5"]
    if ref:
        print(f"  ref 5 (T0032 A, {result['reference_runs']} runs, medians) | {' / '.join(str(ref[s]['dsp']) for s in SETS)} | "
              f"{' / '.join(str(ref[s]['peak_median']) for s in SETS)} | {' / '.join(str(ref[s]['worst']) for s in SETS)} | "
              f"{' / '.join(str(ref[s]['m']) for s in SETS)} | {statistics.median(ref[s]['live'] for s in SETS)} | "
              f"PW err {result['reference_pw_err']} over {result['reference_runs']} runs")
    print(f"Smoke reading: lowest DSP among 8-12: {result['best']} (one run per count; a full run decides)")


if __name__ == "__main__":
    main()
