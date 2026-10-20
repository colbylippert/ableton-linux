"""rescore-d0005.py: D0005's DSP figures from the per-reading logs (profiler/plans/findings/d0005-dsp-readings.tsv).

usage: python3 rescore-d0005.py [READINGS_TSV] [SPAN_S]

The data file holds every DSP report of D0005's 18 Set-runs (os, run, set, t in seconds from the window's start, Live's
average and peak process usage in percent of the buffer period, in_window). The Linux rows are the bench's raw/osc.tsv,
all inside the window. The Windows rows are bench-win.py's cpu.tsv: its first versions counted the reports that had
queued on its socket since the handler's pong, read in one burst at t = 0 (in_window = 0 here), as window readings.
The first scoring used those figures; this rescore uses the window only on both systems.

It also aligns the two systems on the song: each Linux window began a few seconds before the Sets' heavy section,
each Windows window as it began. The aligned figures cover SPAN_S seconds (default 100) from each window's first
reading of at least 6 %.
"""
import csv
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TSV = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "plans", "findings", "d0005-dsp-readings.tsv")
SPAN = float(sys.argv[2]) if len(sys.argv) > 2 else 100.0
SETS = ("Inbuilts", "Max4Live", "VSTs")
RUNS = (1, 2, 3)
HEAVY = 6.0


def load():
    runs = {}
    with open(TSV, newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            runs.setdefault((row["os"], int(row["run"]), row["set"]), []).append(
                (float(row["t"]), float(row["average"]), float(row["peak"]), row["in_window"] == "1"))
    return runs


def summary(rows):
    """As scripts/bench-report.py: mean of the averages, median of the peaks, peaks over 100 % (missed deadlines)."""
    av = [a for _, a, _ in rows if a >= 0]
    pk = [p for _, _, p in rows if p >= 0]
    return {"n": len(av), "avg": sum(av) / len(av), "pk_med": statistics.median(pk), "over100": sum(p > 100 for p in pk)}


def sign_test(d, metric, label):
    ch = []
    for s in SETS:
        for r in RUNS:
            lin, win = d[("linux", r, s)][metric], d[("windows", r, s)][metric]
            ch.append((s, lin, win, (win - lin) / lin * 100))
    k = sum(c[3] < 0 for c in ch)
    p = sum(math.comb(9, i) for i in range(k, 10)) / 2 ** 9
    print(f"{label}: Windows lower in {k} of 9 pairs (one-sided p {p:.4f}), median change {statistics.median(c[3] for c in ch):+.1f} %")
    for s in SETS:
        print(f"  {s:9} " + "  ".join(f"L {lin:6.2f} W {win:6.2f} ({c:+5.1f} %)" for s2, lin, win, c in ch if s2 == s))


def main():
    runs = load()
    as_run = {k: summary([x[:3] for x in v]) for k, v in runs.items()}
    window = {k: summary([x[:3] for x in v if x[3]]) for k, v in runs.items()}
    aligned = {}
    for k, v in runs.items():
        w = [x[:3] for x in v if x[3]]
        t0 = next(t for t, a, _ in w if a >= HEAVY)
        aligned[k] = summary([x for x in w if t0 <= x[0] < t0 + SPAN])

    print("Windows, as first scored (queued reports included) and window only:")
    for r in RUNS:
        for s in SETS:
            k = ("windows", r, s)
            q = [x for x in runs[k] if not x[3]]
            print(f"  B{r} {s:9} as scored {as_run[k]['avg']:6.3f} (n={as_run[k]['n']}, over 100 %: {as_run[k]['over100']})"
                  f"  window {window[k]['avg']:6.3f} (n={window[k]['n']}, over 100 %: {window[k]['over100']})"
                  f"  queued {len(q)}, average {sum(x[1] for x in q) / len(q):.2f}")
    print()
    for name, d in (("window only", window), (f"aligned, {SPAN:.0f} s from the heavy section", aligned)):
        for metric, label in (("avg", "DSP average"), ("pk_med", "peak median")):
            sign_test(d, metric, f"{label}, {name}")
        print()
    print("medians of the window-only DSP average (Linux, Windows):",
          {s: tuple(round(statistics.median(window[(o, r, s)]["avg"] for r in RUNS), 2) for o in ("linux", "windows")) for s in SETS})
    for o in ("linux", "windows"):
        late = [(f"{s} run {r}", f"t {x[0]:.0f} s", x[2]) for (o2, r, s), v in sorted(runs.items()) if o2 == o
                for x in v if x[3] and x[2] > 100]
        print(f"missed deadlines in the window, {o}: {len(late)} {late}")


if __name__ == "__main__":
    main()
