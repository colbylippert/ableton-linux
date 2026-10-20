"""Live CPU, audio worker CPU and dropouts for the three setups, as one SVG for GitHub.

Reads the raw results in profiler/plans/findings: D0006 (Linux, upstream setup), D0005 (its Windows runs) and D0018
(Linux with the current fixes). CPU values are the median of each setup's three runs per Set. Dropouts are totals over
its nine Set-runs; Windows' missed deadlines count only readings inside the measured window (D0005's correction).
Usage: python3 profiler/trials/fix_levels_svg.py profiler/plans/findings profiler/plans/findings/fix-levels.svg
"""
import json
import statistics
import sys
from decimal import ROUND_HALF_UP, Decimal
from xml.sax.saxutils import escape

FIND, OUT = sys.argv[1], sys.argv[2]
SETS = [("Inbuilts", "Live's own devices"), ("Max4Live", "Max for Live devices"), ("VSTs", "third-party plugins")]


def load(name, keep):
    rows = [json.loads(line) for line in open(f"{FIND}/{name}", encoding="utf-8") if line.strip()]
    rows = [r for r in rows if keep(r)]
    for r in rows:
        r["set"] = r["set"].replace("Benchmark_", "")
    return rows


SETUPS = []
for key, name, keep, bar, label, color, buffer in (
    ("upstream", "d0006-results.jsonl", lambda r: True, "Linux upstream", "Linux, upstream setup", "#8c959f", 64),
    ("windows", "d0005-results.jsonl", lambda r: r["os"] == "windows", "Windows 11", "Windows 11, Focusrite ASIO", "#0969da", 64),
    ("current", "d0018-results.jsonl", lambda r: True, "Linux + fixes", "Linux with the current fixes", "#1a7f37", 72),
):
    rows = load(name, keep)
    assert len(rows) == 9 and all(sum(r["set"] == s for r in rows) == 3 for s, _ in SETS), (key, len(rows))
    workers = {int(r.get("workers") or r["audiocalc_threads"]) for r in rows}
    assert len(workers) == 1, (key, workers)
    if key == "current":
        assert {r["switches"].get("PIPEASIO_PREFERRED_BUFFERSIZE") for r in rows} == {str(buffer)}
    if key == "windows":
        missed = 0
        for line in open(f"{FIND}/d0005-dsp-readings.tsv", encoding="utf-8"):
            f = line.rstrip("\n").split("\t")
            if f[0] == "windows" and float(f[5]) > 100 and f[6] == "1":
                missed += 1
        pw_errors = None
    else:
        missed = sum(int(r["peaks_over_100"]) for r in rows)
        pw_errors = sum(int(r["pipewire_errors"]) for r in rows)
    med = {(s, k): statistics.median(float(r[k]) for r in rows if r["set"] == s)
           for s, _ in SETS for k in ("live_cpu", "audio_total")}
    SETUPS.append(dict(key=key, bar=bar, label=label, color=color, buffer=buffer, workers=workers.pop(),
                       missed=missed, pw=pw_errors, med=med))


def one(x):
    return str(Decimal(str(x)).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))


W, PAD = 920, 28
TEXT, MUTED, GRID, BORDER = "#1f2328", "#59636e", "#e6eaef", "#d0d7de"
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
body = []


def text(x, y, s, size=12, weight=None, fill=TEXT, anchor=None):
    a = f'x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}"'
    if weight:
        a += f' font-weight="{weight}"'
    if anchor:
        a += f' text-anchor="{anchor}"'
    body.append(f"<text {a}>{escape(s)}</text>")


def rect(x, y, w, h, fill, rx=0):
    body.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rx}" fill="{fill}"/>')


def line(x1, y1, x2, y2, stroke):
    body.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{stroke}" stroke-width="1"/>')


text(PAD, 42, "Ableton Live 12: Linux (Wine) against Windows 11 on the same laptop", 20, 600)
text(PAD, 66, "i7-13620H laptop, Focusrite Scarlett 2i4 at 48 kHz. Each bar is the median of 3 runs, "
              "2 minutes of playback per Set.", 12.5, fill=MUTED)
for x, s in zip((PAD, 200, 392), SETUPS):
    rect(x, 87, 11, 11, s["color"], 2)
    text(x + 17, 97, s["label"], 12)

# CPU panels: a shared scale, so bars compare across panels
SCALE_MAX, SCALE_PX = 70, 280
k = SCALE_PX / SCALE_MAX
for px, metric, title, sub in (
    (PAD, "live_cpu", "Live CPU", "whole Live process, % of one core"),
    (W / 2 + 8, "audio_total", "Audio worker CPU", "Live's audio workers + the driver's callback thread, % of one core"),
):
    bx = px + 96
    text(px, 146, title, 15, 600)
    text(px, 164, sub, 11.5, fill=MUTED)
    for v in (0, 20, 40, 60):
        line(bx + v * k, 186, bx + v * k, 440, GRID)
        text(bx + v * k, 455, str(v), 10.5, fill=MUTED, anchor="middle")
    for gi, (set_name, what) in enumerate(SETS):
        yg = 200 + gi * 84
        body.append(f'<text x="{px:.1f}" y="{yg:.1f}" font-size="12" fill="{TEXT}">'
                    f'<tspan font-weight="600">{escape(set_name)}</tspan>'
                    f'<tspan fill="{MUTED}"> ({escape(what)})</tspan></text>')
        for i, s in enumerate(SETUPS):
            y = yg + 8 + i * 20
            v = s["med"][(set_name, metric)]
            text(px + 88, y + 11.5, s["bar"], 11, fill=MUTED, anchor="end")
            rect(bx, y, v * k, 15, s["color"], 2)
            text(bx + v * k + 6, y + 11.5, one(v), 11, 600 if s["key"] == "current" else None)

# dropouts table
y0 = 500
text(PAD, y0, "Dropouts", 15, 600)
text(PAD + 76, y0, "totals over each setup's 9 Set-runs (18 minutes of playback)", 12, fill=MUTED)
cols = [("Audio workers", 470), ("Buffer", 590), ("Missed deadlines", 740), ("PipeWire errors", W - PAD)]
text(PAD + 17, y0 + 28, "Setup", 11.5, 600, MUTED)
for name, x in cols:
    text(x, y0 + 28, name, 11.5, 600, MUTED, "end")
line(PAD, y0 + 36, W - PAD, y0 + 36, BORDER)
for i, s in enumerate(SETUPS):
    y = y0 + 58 + i * 26
    if i:
        line(PAD, y - 18, W - PAD, y - 18, GRID)
    w = 600 if s["key"] == "current" else None
    rect(PAD, y - 10, 11, 11, s["color"], 2)
    text(PAD + 17, y, s["label"], 12.5, w)
    values = (str(s["workers"]), f'{s["buffer"]} samples', str(s["missed"]), "n/a" if s["pw"] is None else str(s["pw"]))
    for (_, x), v in zip(cols, values):
        text(x, y, v, 12.5, w, anchor="end")

notes = [
    "Missed deadline: an audio block that took Live longer than its buffer period to compute (its DSP meter over 100 % "
    "during playback).",
    "PipeWire error: a cycle in which Live's audio reached the interface late. Windows has no PipeWire, so there are none "
    "to count there.",
    "Current fixes: posix_spawn for new processes, a realtime driver callback thread, one audio thread per physical "
    "P-core, a new display path,",
    "shallow CPU idle (C1E off; C2/C3 off on the P-cores) and a buffer aligned to the interface's 0.5 ms USB transfers.",
    "Each setup ran with the worker count in the table. Measured 2026-10-19 (upstream, Windows) and 2026-10-20 "
    "(current fixes).",
    "Data: profiler/plans/findings in github.com/colbylippert/ableton-linux, runs D0006 (upstream), D0005 (Windows) and "
    "D0018 (current fixes).",
]
ny = y0 + 58 + 3 * 26 + 18
for i, n in enumerate(notes):
    text(PAD, ny + i * 16, n, 11, fill=MUTED)
H = int(ny + (len(notes) - 1) * 16 + 22)

summary = "; ".join(
    f'{s["label"]}: Live CPU {"/".join(one(s["med"][(n, "live_cpu")]) for n, _ in SETS)} %, audio worker CPU '
    f'{"/".join(one(s["med"][(n, "audio_total")]) for n, _ in SETS)} % (Inbuilts/Max4Live/VSTs), {s["workers"]} workers, '
    f'{s["missed"]} missed deadlines' + ("" if s["pw"] is None else f', {s["pw"]} PipeWire errors')
    for s in SETUPS)
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
       f'aria-labelledby="t d" font-family="{FONT}">\n'
       f'<title id="t">Ableton Live 12: Live CPU, audio worker CPU and dropouts, Linux (Wine) against Windows 11</title>\n'
       f'<desc id="d">{escape(summary)}.</desc>\n'
       f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="10" fill="#ffffff" stroke="{BORDER}"/>\n'
       + "\n".join(body) + "\n</svg>\n")
with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(svg)
print(summary)
print(f"wrote {OUT} ({W}x{H})")
