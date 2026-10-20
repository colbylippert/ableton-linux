#!/usr/bin/env python3
"""ramp-report.py BENCH_DIR [--settle S] [--fail-errors N] [--fail-peaks N] [--json]: the load ramp, per step.

For a bench run with the ramp-duplicate-all scenario. Per Set it splits the measured window at the
/abl/bench/duplicate-all replies the bench recorded in raw/osc.tsv: step k (the Set playing k+1 times) runs from the
k-th reply (the window start for step 0) plus SETTLE seconds (default 10: the new devices and the copies' first plays)
to the next reply, or the window end. Per step: Live's DSP average and peak median (percent of the buffer period),
the worst peak, the peaks over 100 % (missed deadlines), Live's PipeWire errors in that time (raw/pw-top.tsv, Live's
nodes as scripts/bench-report.py matches them), and how long the duplication took.

A step fails with FAIL_ERRORS or more PipeWire errors (default 3) or FAIL_PEAKS or more peaks over 100 % (default 3).
The Set's headroom is the load of the last step before the first failing one ("10x+" when none failed).
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys

NODE_RE = re.compile(r"Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]")   # scripts/bench-report.py DEFAULT_NODE_RE


def osc_rows(path):
    """(cpu rows [(t, average, peak)], duplicate-all replies [(t, pass, tracks, ms)], last t) from raw/osc.tsv"""
    cpu, dup, last = [], [], 0.0
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) < 3:
            continue
        try:
            t = float(p[0])
        except ValueError:
            continue
        last = max(last, t)
        if p[2] == "/abl/bench/cpu" and len(p) >= 5:
            cpu.append((t, float(p[3]), float(p[4])))
        elif p[2] == "/abl/bench/duplicate-all" and len(p) >= 6:
            dup.append((t, int(float(p[3])), int(float(p[4])), int(float(p[5])),
                        int(float(p[6])) if len(p) > 6 else None, float(p[7]) if len(p) > 7 else None))
    return cpu, dup, last


def pw_error_events(path):
    """[(t, errors)]: each rise of a Live node's pw-top ERR counter, at the time pw-top printed it"""
    events, last = [], {}
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return None
    for raw in lines:
        if "\t" not in raw:
            continue
        head, line = raw.split("\t", 1)
        try:
            t = float(head)
        except ValueError:
            continue
        fields = line.strip().split(None, 10)
        if len(fields) < 10 or not fields[1].isdigit():
            continue
        rate, error, name = fields[3], fields[8], fields[10] if len(fields) > 10 else ""
        if not (rate.isdigit() and int(rate) > 0 and error.isdigit() and NODE_RE.search(name)):
            continue
        node, err = int(fields[1]), int(error)
        if node in last:
            rise = err - last[node] if err >= last[node] else err   # a reset or a reused id starts again
            if rise > 0:
                events.append((t, rise))
        last[node] = err
    return events


def set_report(set_dir, settle, fail_errors, fail_peaks):
    cpu, dup, end = osc_rows(os.path.join(set_dir, "raw", "osc.tsv"))
    errors = pw_error_events(os.path.join(set_dir, "raw", "pw-top.tsv"))
    bounds = [0.0] + [d[0] for d in dup] + [end]
    steps, headroom, failed = [], None, False
    for k in range(len(bounds) - 1):
        start, stop = bounds[k] + settle, bounds[k + 1]
        if stop - start < 5:                     # nothing left to measure after the settle time
            continue
        rows = [(a, p) for t, a, p in cpu if start <= t < stop]
        if not rows:
            continue
        averages = [a for a, p in rows if a >= 0]
        peaks = [p for a, p in rows if p >= 0]
        pw = sum(n for t, n in errors if start <= t < stop) if errors is not None else None
        over = sum(p > 100 for p in peaks)
        fails = (pw is not None and pw >= fail_errors) or over >= fail_peaks
        step = {"load": k + 1, "start_s": round(start, 1), "seconds": round(stop - start, 1), "readings": len(rows),
                "dsp_average": round(sum(averages) / len(averages), 2) if averages else None,
                "peak_median": round(statistics.median(peaks), 2) if peaks else None,
                "peak_max": round(max(peaks), 1) if peaks else None, "peaks_over_100": over,
                "pipewire_errors": pw, "duplicate_ms": dup[k - 1][3] if k >= 1 else None,
                "tracks": dup[k - 1][2] if k >= 1 else None, "trims": dup[k - 1][4] if k >= 1 else None,
                "trim_db": dup[k - 1][5] if k >= 1 else 0.0, "fails": fails}
        steps.append(step)
        if fails and not failed:
            failed = True
        if not failed:
            headroom = k + 1
    return {"set": os.path.basename(set_dir).split("-", 1)[-1].replace("Benchmark_", ""), "steps": steps,
            "headroom": headroom, "first_failure": next((s["load"] for s in steps if s["fails"]), None),
            "passes_seen": len(dup)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bench_dir")
    ap.add_argument("--settle", type=float, default=10.0)
    ap.add_argument("--fail-errors", type=int, default=3)
    ap.add_argument("--fail-peaks", type=int, default=3)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    sets = sorted(glob.glob(os.path.join(a.bench_dir, "sets", "*")))
    if not sets:
        sys.exit(f"ramp-report: no sets under {a.bench_dir}")
    reports = [set_report(d, a.settle, a.fail_errors, a.fail_peaks) for d in sets if os.path.isdir(d)]
    if a.json:
        print(json.dumps(reports))
        return
    for r in reports:
        last = r["steps"][-1]["load"] if r["steps"] else 0
        hr = "none (step 1 failed)" if r["headroom"] is None else f"{r['headroom']}x" + ("+" if r["first_failure"] is None and r["headroom"] == last else "")
        print(f"== {r['set']}: headroom {hr} (first failing load: {r['first_failure'] or '-'}x; {r['passes_seen']} passes)")
        print(f"   {'load':>4} {'tracks':>6} {'dup ms':>6} {'DSP avg':>7} {'pk med':>6} {'pk max':>6} {'>100':>4} {'PW err':>6}")
        for s in r["steps"]:
            print(f"   {s['load']:>3}x {s['tracks'] or '-':>6} {s['duplicate_ms'] or '-':>6} {s['dsp_average']:>7} "
                  f"{s['peak_median']:>6} {s['peak_max']:>6} {s['peaks_over_100']:>4} "
                  f"{'-' if s['pipewire_errors'] is None else s['pipewire_errors']:>6}{'  FAIL' if s['fails'] else ''}")


if __name__ == "__main__":
    main()
