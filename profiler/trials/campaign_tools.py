"""Headroom campaign (T0021-) and kernel-plan trial tools (run on the laptop from the checkout root).

usage:
  campaign_tools.py affinity BENCH_DIR        per Set: CPU masks of pipeasio-rt and the AudioCalc threads at window end
  campaign_tools.py audiocpu BENCH_DIR        per Set: M, the audio-thread CPU (% of one core), and Live's CPU
  campaign_tools.py rule-h TRIAL              score TRIAL against rule H (profiler/plans/resume-plan.md); JSON last line
  campaign_tools.py rule-d TRIAL [G4_POINTS]  score TRIAL against rule D (profiler/plans/kernel-plan.md); JSON last line.
                                              G4_POINTS: spin items' CPU limit in points of one core (else +5 %)
  campaign_tools.py breakdown INTERFACE_DIR   audio-thread cycles by activity, from d0003-capture's perf-live.data
"""
import collections
import glob
import json
import math
import os
import re
import statistics
import subprocess
import sys

RUNS = os.path.expanduser("~/.local/share/profiler/runs")
SETS = ["Benchmark_Inbuilts", "Benchmark_Max4Live", "Benchmark_VSTs"]


def set_of(path):
    return path.split("/sets/")[1].split("/")[0].split("-", 1)[1]


def live_process(d):
    return max((p for p in d["processes"] if p.get("comm") == "MainThread"),
               key=lambda p: p.get("cpu_percent_of_one_core") or 0)


def is_audio(t):
    c = t.get("comm") or ""
    return c.startswith("AudioCalc") or c == "pipeasio-rt"


def per_set(bench_dir):
    out = {}
    for f in sorted(glob.glob(f"{bench_dir}/sets/*/raw/proc-delta.json")):
        d = json.load(open(f))
        live = live_process(d)
        th = live.get("threads") or []
        audio = [t for t in th if is_audio(t)]
        out[set_of(f)] = {
            "m": round(sum(t.get("cpu_percent_of_one_core") or 0 for t in audio), 2),
            "live": round(live.get("cpu_percent_of_one_core") or 0, 2),
            "rt": sorted({t.get("cpus_allowed_list") for t in audio if t.get("comm") == "pipeasio-rt"}),
            "workers": sorted((t.get("cpus_allowed_list") or "?" for t in audio if (t.get("comm") or "").startswith("AudioCalc")),
                              key=lambda x: (len(x), x)),
            "worker_wait_ms": round(sum((t.get("schedstat") or {}).get("run_delay_ns", 0) for t in audio
                                        if (t.get("comm") or "").startswith("AudioCalc")) / 1e6, 1),
        }
    return out


def cmd_affinity(bench_dir):
    for s, v in per_set(bench_dir).items():
        print(f"{s.replace('Benchmark_', '')}: rt={','.join(v['rt'])} workers={len(v['workers'])}:{','.join(v['workers'])}", end="  ")
    print()


def cmd_audiocpu(bench_dir):
    for s, v in per_set(bench_dir).items():
        print(f"{s.replace('Benchmark_', '')}: M={v['m']} live={v['live']}", end="  ")
    print()


def cmd_rule_h(trial):
    score(trial, "H")


def cmd_rule_d(trial, g4_points=None):
    """Rule D (profiler/plans/kernel-plan.md): Live's DSP average is the primary metric; G4 bounds the audio-thread CPU,
    as a median change of at most +5 %, or, for spin items, at most G4_POINTS points of one core."""
    score(trial, "D", float(g4_points) if g4_points else None)


def score(trial, rule, g4_points=None):
    root = os.path.join(os.getcwd(), "profiler")
    ledger = [json.loads(l) for l in open(f"{root}/ledger.jsonl") if l.strip()]
    spread = {s: v["aa_spread"] for s, v in next(e for e in ledger if e["trial"] == "T0002")["metrics"]["per_set"].items()}
    pairs = [(f"trial-{trial}-A{i}", f"trial-{trial}-B{i}") for i in (1, 2, 3)]
    rec = {r: json.load(open(f"{root}/history/runs/{r}.json")) for p in pairs for r in p}
    data = {r: per_set(os.path.expanduser(rec[r]["source_dir"])) for r in rec}
    print(f"== {trial} (rule {rule}): identity")
    for r in rec:
        print(f"  {r:16} {rec[r]['started_at'][:19]} switches={rec[r]['switches']} harness={rec[r]['harness_sha'][:8]}")
    for key in ("harness_sha", "audio_device", "machine_id", "duration_s", "trace_mode"):
        vals = {str(v[key]) for v in rec.values()}
        print(f"  {key}: {'same' if len(vals) == 1 else 'DIFFERS ' + str(vals)}")
    if rule == "H":
        primary = lambda r, s: data[r][s]["m"]
    else:
        primary = lambda r, s: rec[r]["sets"][s]["dsp_avg"]
    lower, changes, m_changes, m_points, rows = 0, [], [], [], []
    for s in SETS:
        for a, b in pairs:
            pa, pb = primary(a, s), primary(b, s)
            ma, mb = data[a][s]["m"], data[b][s]["m"]
            lower += pb < pa
            changes.append((pb - pa) / pa)
            m_changes.append((mb - ma) / ma)
            m_points.append(mb - ma)
            rows.append(f"  {s.replace('Benchmark_', ''):9} {a[-2:]}->{b[-2:]}: M {ma:6.2f} -> {mb:6.2f} ({(mb - ma) / ma:+.1%})"
                        + ("" if rule == "H" else f"  DSP avg {pa:5.2f} -> {pb:5.2f} ({(pb - pa) / pa:+.1%})"))
    print("\n== M, audio-thread CPU (% of one core)" + ("" if rule == "H" else ", and Live's DSP average") + ", per Set-pair")
    print("\n".join(rows))
    p_sign = sum(math.comb(9, k) for k in range(lower, 10)) / 512
    med = statistics.median(changes)
    h1, h2 = lower >= 8, med <= -0.03
    m_med, m_pts = statistics.median(m_changes), statistics.median(m_points)
    g4 = m_pts <= g4_points if g4_points is not None else m_med <= 0.05
    xr_b = sum(rec[b]["sets"][s]["xruns"] for _, b in pairs for s in SETS)
    xr_a = sum(rec[a]["sets"][s]["xruns"] for a, _ in pairs for s in SETS)
    ea = sum(rec[a]["sets"][s]["pipewire_errors"] for a, _ in pairs for s in SETS)
    eb = sum(rec[b]["sets"][s]["pipewire_errors"] for _, b in pairs for s in SETS)
    n = ea + eb
    p_more = sum(math.comb(n, k) for k in range(eb, n + 1)) / 2 ** n if n else 1.0
    dsp, worse = {}, []
    for s in SETS:
        am = statistics.median(rec[a]["sets"][s]["dsp_avg"] for a, _ in pairs)
        bm = statistics.median(rec[b]["sets"][s]["dsp_avg"] for _, b in pairs)
        dsp[s] = {"a_median": round(am, 2), "b_median": round(bm, 2), "aa_spread": spread[s], "delta": round(bm - am, 2),
                  "ratio_to_spread": round(abs(bm - am) / spread[s], 2)}
        if bm - am > 2 * spread[s]:
            worse.append(s)
    g1, g2, g3 = xr_b == 0, p_more >= 0.05, not worse
    if rule == "H":
        crit = {"H1": h1, "H2": h2, "G1": g1, "G2": g2, "G3": g3}
    else:
        crit = {"D1": h1, "D2": h2, "G1": g1, "G2": g2, "G4": g4}
    verdict = "PASS" if all(crit.values()) else "FAIL"
    peak = {arm: [round(statistics.median(rec[p[i]]["sets"][s]["dsp_peak"] for p in pairs), 1) for s in SETS]
            for i, arm in ((0, "a"), (1, "b"))}
    live = {arm: round(statistics.median(data[p[i]][s]["live"] for p in pairs for s in SETS), 1) for i, arm in ((0, "a"), (1, "b"))}
    mmed = {arm: [round(statistics.median(data[p[i]][s]["m"] for p in pairs), 2) for s in SETS] for i, arm in ((0, "a"), (1, "b"))}
    wait = {arm: [round(statistics.median(data[p[i]][s]["worker_wait_ms"] for p in pairs), 1) for s in SETS] for i, arm in ((0, "a"), (1, "b"))}
    print(f"\n  B lower in {lower} of 9 Set-pairs (one-sided sign p = {p_sign:.4f}); median change {med:+.1%}")
    print(f"  M medians per Set A {mmed['a']} B {mmed['b']}; Live CPU median {live['a']} -> {live['b']}")
    print(f"  PipeWire errors {ea} -> {eb} (p B more = {p_more:.3f}); xruns {xr_a} -> {xr_b}")
    for s, v in dsp.items():
        print(f"  {s:20} DSP avg A {v['a_median']:5.2f} B {v['b_median']:5.2f} delta {v['delta']:+5.2f} ({v['ratio_to_spread']}x spread)")
    print(f"  worst DSP peak medians A {peak['a']} B {peak['b']}; worker run-queue wait medians (ms per window) A {wait['a']} B {wait['b']}")
    g4_limit = f"+{g4_points:g} points" if g4_points is not None else "+5 %"
    print(f"  M median paired change {m_med:+.1%} ({m_pts:+.2f} points of one core); G4 limit {g4_limit}")
    print(f"\n== {trial} rule {rule}: {verdict} {crit}")
    print(json.dumps({"rule": rule, "verdict_rule": verdict, "criteria": crit, "lower_pairs": lower, "p_sign": round(p_sign, 4),
                      "median_change": round(med, 4), "m_median": mmed, "live_cpu": live,
                      "m_median_change": round(m_med, 4), "m_median_points": round(m_pts, 2), "g4_limit": g4_limit,
                      "pipewire_errors": {"a": ea, "b": eb, "p_b_more": round(p_more, 4)}, "xruns": {"a": xr_a, "b": xr_b},
                      "dsp_avg": dsp, "dsp_peak_median": peak, "worker_wait_ms": wait,
                      "m_pairs": {s: [[data[a][s]["m"], data[b][s]["m"]] for a, b in pairs] for s in SETS},
                      "dsp_pairs": {s: [[rec[a]["sets"][s]["dsp_avg"], rec[b]["sets"][s]["dsp_avg"]] for a, b in pairs]
                                    for s in SETS}}))


def cmd_breakdown(interface):
    tasks = {}
    for line in open(f"{interface}/tasks-start.txt", errors="replace"):
        p = line.split(None, 1)
        if len(p) == 2:
            tasks[int(p[0])] = p[1].strip()
    audio = {t for t, c in tasks.items() if c.startswith("AudioCalc") or c == "pipeasio-rt"}
    cmd = ["sudo", "-n", "perf", "script", "-f", "-i", f"{interface}/perf-live.data", "-F", "tid,time,event,period,ip,sym", "--ns"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace", bufsize=1 << 20)
    hdr = re.compile(r"^\s*(\d+)\s+(\d+\.\d+):\s+(\d+)\s+(\S+):\s*$")
    rt_bal = {"balance_rt", "pull_rt_task", "push_rt_tasks", "push_rt_task", "double_rq_lock", "find_lowest_rq",
              "cpupri_find_fitness", "cpupri_set", "rto_push_irq_work_func"}
    cur, chain, cyc = None, [], collections.Counter()

    def flush():
        if not cur or cur[0] not in audio or cur[2] != "cpu_core/cycles/":
            return
        k = "user"
        if chain:
            if any(s in rt_bal for s in chain):
                k = "rt-balancing"
            elif any("page_fault" in s for s in chain):
                k = "page-fault"
            elif any(s.startswith(("ntsync", "__x64_sys_ioctl")) for s in chain) or "[unknown]" in chain[:3]:
                k = "ntsync/ioctl"
            elif any(s in ("__schedule", "schedule", "try_to_wake_up") for s in chain):
                k = "sched-other"
            else:
                k = "kernel-other"
        cyc[k] += cur[1]

    for line in proc.stdout:
        m = hdr.match(line)
        if m:
            key = (int(m.group(1)), m.group(2))
            if cur and (cur[0], cur[3]) == key:
                cur = (cur[0], cur[1], cur[2], cur[3], True)
                continue
            flush()
            cur, chain = (int(m.group(1)), int(m.group(3)), m.group(4), m.group(2), False), []
            continue
        s = line.split()
        if cur and not cur[4] and len(s) >= 2 and re.match(r"^[0-9a-f]+$", s[0]):
            chain.append(s[1])
    flush()
    total = sum(cyc.values()) or 1
    shares = {k: round(v / total, 4) for k, v in cyc.most_common()}
    print(json.dumps({"audio_cycles": total, "shares": shares}))


if __name__ == "__main__":
    {"affinity": cmd_affinity, "audiocpu": cmd_audiocpu, "rule-h": cmd_rule_h, "rule-d": cmd_rule_d,
     "breakdown": cmd_breakdown}[sys.argv[1]](*sys.argv[2:])
