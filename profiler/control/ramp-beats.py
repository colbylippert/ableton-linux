#!/usr/bin/env python3
"""ramp-beats.py BENCH_DIR... [--loop START END] [--bpm BPM] [--from-load K] [--settle S]: where in the Set's loop a
load ramp's misses fall.

For bench runs with the ramp-duplicate-all scenario (profiler/trials/ramp-run.sh keeps each as $R/ramp-TAG/bench).
The scenario markers in raw/osc.tsv carry Live's song position; the beat at window time t is the first marker's beat
plus the tempo times the time since, wrapped into the arrangement loop (the bench Sets loop beats 16-112 at 112 BPM).
Counts, per 4-beat bar of the loop and over every run and Set given, the PipeWire error events of Live's nodes and
the peaks over 100 % inside profiler/control/ramp-report.py's steps (from SETTLE seconds after a duplication finished
to the next one's start) at loads K and up (default 4). pw-top prints once a second, so its errors land up to about
two beats after the block that missed. Also how many markers sit on the tempo line (the others arrived late, while
Live was busy duplicating).
"""
import argparse
import importlib.util
import os
from collections import Counter, defaultdict

spec = importlib.util.spec_from_file_location("ramp_report", os.path.join(os.path.dirname(__file__), "ramp-report.py"))
ramp_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ramp_report)


def markers(path):
    """[(t, beat)] of the scenario markers"""
    out = []
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 5 and p[2] == "/abl/bench/scenario-marker":
            try:
                out.append((float(p[0]), float(p[4])))
            except ValueError:
                pass
    return out


def beat_line(marks, loop0, loop1, bps):
    """(beat(t), markers on the line): the song position from the first marker at a constant tempo"""
    t0, b0 = marks[0]

    def beat(t):
        b = b0 + bps * (t - t0)
        return loop0 + (b - loop0) % (loop1 - loop0) if b >= loop1 else b
    on_line = sum(min(abs(beat(t) - b), abs(abs(beat(t) - b) - (loop1 - loop0))) < 0.5 for t, b in marks)
    return beat, on_line


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bench_dirs", nargs="+")
    ap.add_argument("--loop", nargs=2, type=float, default=(16.0, 112.0), metavar=("START", "END"))
    ap.add_argument("--bpm", type=float, default=112.0)
    ap.add_argument("--from-load", type=int, default=4)
    ap.add_argument("--settle", type=float, default=10.0)
    a = ap.parse_args()
    loop0, loop1 = a.loop
    bars = int((loop1 - loop0) // 4)
    per_set = defaultdict(lambda: (Counter(), Counter()))
    for bench in a.bench_dirs:
        sets_dir = os.path.join(bench, "sets")
        for name in sorted(os.listdir(sets_dir)):
            raw = os.path.join(sets_dir, name, "raw")
            if not os.path.isfile(os.path.join(raw, "osc.tsv")):
                continue
            cpu, dup, end, _ = ramp_report.osc_rows(os.path.join(raw, "osc.tsv"))
            errors = ramp_report.pw_error_events(os.path.join(raw, "pw-top.tsv")) or []
            marks = markers(os.path.join(raw, "osc.tsv"))
            if not marks:
                continue
            beat, on_line = beat_line(marks, loop0, loop1, a.bpm / 60.0)
            label = name.split("-", 1)[-1].replace("Benchmark_", "")
            pw_bars, pk_bars = per_set[label]
            starts = [0.0] + [d[0] for d in dup]
            stops = [d[0] - d[3] / 1000.0 for d in dup] + [end]
            for k, (s0, s1) in enumerate(zip(starts, stops)):
                if k + 1 < a.from_load:
                    continue
                for t, count in errors:
                    if s0 + a.settle <= t < s1:
                        pw_bars[int((beat(t) - loop0) // 4)] += count
                for t, average, peak in cpu:
                    if s0 + a.settle <= t < s1 and peak > 100:
                        pk_bars[int((beat(t) - loop0) // 4)] += 1
            print(f"{os.path.basename(os.path.dirname(bench.rstrip('/')))} {label}: markers on the tempo line "
                  f"{on_line}/{len(marks)}")
    for label, (pw_bars, pk_bars) in per_set.items():
        total = sum(pw_bars.values()) + sum(pk_bars.values())
        print(f"== {label}: misses by bar of the loop (bar 1 = beats {loop0:g}-{loop0 + 4:g}), loads {a.from_load}x and up")
        for bar in range(bars):
            n_pw, n_pk = pw_bars[bar], pk_bars[bar]
            if n_pw or n_pk:
                print(f"   bar {bar + 1:>2} (beat {loop0 + 4 * bar:>5g}): PW err {n_pw:>3}  >100 % {n_pk:>3}  "
                      + "#" * ((n_pw + n_pk + 1) // 2))
        top = sorted(range(bars), key=lambda b: -(pw_bars[b] + pk_bars[b]))[:4]
        share = sum(pw_bars[b] + pk_bars[b] for b in top) / total * 100 if total else 0.0
        print(f"   the 4 worst of {bars} bars hold {share:.0f} % of {total} misses")


if __name__ == "__main__":
    main()
