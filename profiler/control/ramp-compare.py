#!/usr/bin/env python3
"""ramp-compare.py --a A.json... --b B.json... [--json]: two configurations' load ramps, paired run by run.

Reads profiler/control/ramp-report.py --json output (profiler/trials/ramp-run.sh keeps it as $R/ramp-TAG.report.json)
and pairs the i-th A run with the i-th B run. Per Set: every run's headroom and each pair's B - A; the glitches (Live's
PipeWire errors plus peaks over 100 %) over all loads; and per load the DSP average, the peak median and the glitches,
B against A (the DSP change is the median over the pairs). Then the reading pre-stated for D0011
(profiler/plans/kernel-plan.md, "Load ramp"): B raises the headroom when it is higher in at least half of the
Set-pairs, lower in none, and higher on average by more than the A runs differ from each other (the mean |Ai - Aj|
over the Sets); it lowers it by the mirror rule; otherwise no difference in headroom is shown.

A Set whose first step failed has headroom 0; one that never failed has its last load (shown with a "+").
"""
import argparse
import itertools
import json
import statistics


def load(path):
    return {r["set"]: r for r in json.load(open(path))}


def headroom(report):
    return report["headroom"] or 0


def shown(report):
    h = headroom(report)
    last = report["steps"][-1]["load"] if report["steps"] else 0
    return f"{h}+" if report["first_failure"] is None and h == last else f"{h}"


def glitches(step):
    return (step["pipewire_errors"] or 0) + step["peaks_over_100"]


def steps_by_load(report):
    return {s["load"]: s for s in report["steps"]}


def compare(a_runs, b_runs):
    pairs = list(zip(a_runs, b_runs))
    sets = [name for name in a_runs[0] if all(name in run for run in a_runs + b_runs)]
    result = {"pairs": len(pairs), "a_runs": len(a_runs), "b_runs": len(b_runs), "sets": {}}
    diffs, aa = [], []
    for name in sets:
        ha = [headroom(run[name]) for run in a_runs]
        hb = [headroom(run[name]) for run in b_runs]
        d = [headroom(b[name]) - headroom(a[name]) for a, b in pairs]
        diffs += d
        aa += [abs(x - y) for x, y in itertools.combinations(ha, 2)]
        ga = [sum(glitches(s) for s in run[name]["steps"]) for run in a_runs]
        gb = [sum(glitches(s) for s in run[name]["steps"]) for run in b_runs]
        a_steps = [steps_by_load(run[name]) for run in a_runs]
        b_steps = [steps_by_load(run[name]) for run in b_runs]
        loads = sorted(set.intersection(*(set(s) for s in a_steps + b_steps)))
        per_load = []
        for k in loads:
            row = {"load": k}
            for key in ("dsp_average", "peak_median"):
                va = [s[k][key] for s in a_steps if s[k][key] is not None]
                vb = [s[k][key] for s in b_steps if s[k][key] is not None]
                row[key + "_a"] = round(statistics.mean(va), 2) if va else None
                row[key + "_b"] = round(statistics.mean(vb), 2) if vb else None
            change = [(sb[k]["dsp_average"] - sa[k]["dsp_average"]) / sa[k]["dsp_average"] * 100
                      for sa, sb in zip(a_steps, b_steps) if sa[k]["dsp_average"] and sb[k]["dsp_average"] is not None]
            row["dsp_change_pct"] = round(statistics.median(change), 1) if change else None
            row["glitches_a"] = sum(glitches(s[k]) for s in a_steps)
            row["glitches_b"] = sum(glitches(s[k]) for s in b_steps)
            per_load.append(row)
        result["sets"][name] = {
            "headroom_a": ha, "headroom_b": hb, "shown_a": [shown(run[name]) for run in a_runs],
            "shown_b": [shown(run[name]) for run in b_runs], "headroom_b_minus_a": d,
            "glitches_a": ga, "glitches_b": gb, "per_load": per_load}
    higher, lower = sum(x > 0 for x in diffs), sum(x < 0 for x in diffs)
    mean_diff = statistics.mean(diffs) if diffs else 0.0
    spread = statistics.mean(aa) if aa else None
    beyond = spread is None or abs(mean_diff) > spread
    if diffs and 2 * higher >= len(diffs) and lower == 0 and mean_diff > 0 and beyond:
        reading = "B raises the headroom"
    elif diffs and 2 * lower >= len(diffs) and higher == 0 and mean_diff < 0 and beyond:
        reading = "B lowers the headroom"
    else:
        reading = "no difference in headroom shown"
    fewer = sum(sum(glitches(s) for s in b[n]["steps"]) < sum(glitches(s) for s in a[n]["steps"])
                for a, b in pairs for n in sets)
    result.update({"set_pairs": len(diffs), "higher": higher, "lower": lower, "mean_b_minus_a": round(mean_diff, 2),
                   "aa_spread": None if spread is None else round(spread, 2), "reading": reading,
                   "glitches_fewer_in_b": fewer})
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--a", nargs="+", required=True, help="the A runs' report JSON, in run order")
    ap.add_argument("--b", nargs="+", required=True, help="the B runs' report JSON, in run order")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    result = compare([load(p) for p in args.a], [load(p) for p in args.b])
    if args.json:
        print(json.dumps(result))
        return
    for name, s in result["sets"].items():
        print(f"== {name}: headroom A {' '.join(s['shown_a'])} | B {' '.join(s['shown_b'])} | B-A "
              f"{' '.join('%+d' % x for x in s['headroom_b_minus_a'])}; glitches over all loads "
              f"A {' '.join(map(str, s['glitches_a']))} | B {' '.join(map(str, s['glitches_b']))}")
        print(f"   {'load':>4} {'DSP A':>6} {'DSP B':>6} {'chg %':>6} {'pk A':>6} {'pk B':>6} {'gl A':>5} {'gl B':>5}")
        for r in s["per_load"]:
            print(f"   {r['load']:>3}x {r['dsp_average_a']:>6} {r['dsp_average_b']:>6} "
                  f"{'-' if r['dsp_change_pct'] is None else '%+.1f' % r['dsp_change_pct']:>6} "
                  f"{r['peak_median_a']:>6} {r['peak_median_b']:>6} {r['glitches_a']:>5} {r['glitches_b']:>5}")
    print(f"Reading: B higher in {result['higher']} of {result['set_pairs']} Set-pairs, lower in {result['lower']}; "
          f"mean B-A {result['mean_b_minus_a']:+.2f} against an A/A spread of {result['aa_spread']}: "
          f"{result['reading']}. Fewer glitches in B in {result['glitches_fewer_in_b']} of {result['set_pairs']}.")


if __name__ == "__main__":
    main()
