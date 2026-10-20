"""clock_summary.py LABEL=BENCH_DIR ...: the clock checks' per-Set comparison (D0008 on), each run against the first.

Per Set and run: the AudioCalc threads' clock while executing (cycles / reference cycles x the TSC rate), the share of
their on-CPU time they execute, IPC and CPU; pipeasio-rt's clock; Live's DSP average, peak median, worst peak and
peaks over 100 %; PipeWire errors; Live's CPU; package power and temperatures; thermal throttling; the audio CPUs'
(0, 2, 4, 6, 8, 10) idle-state entries per second and residency; the P-cores' scaling_min_freq and disabled states.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "trials"))
import campaign_tools as ct  # noqa: E402

AUDIO_CPUS = (0, 2, 4, 6, 8, 10)
TSC_FALLBACK_MHZ = 2900.0      # the laptop's boot log, for captures that predate the tsc_mhz line


def per_set(bench):
    res = {}
    for m in sorted(glob.glob(os.path.join(bench, "sets", "*", "measurement.json"))):
        set_dir = os.path.dirname(m)
        name = os.path.basename(set_dir).split("-", 1)[1].replace("Benchmark_", "")
        d = json.load(open(m))
        osc = d.get("osc_dsp") or {}
        live = ct.live_process(json.load(open(os.path.join(set_dir, "raw", "proc-delta.json"))))
        try:
            cap = json.load(open(os.path.join(set_dir, "raw", "interface", "summary.json")))
        except (OSError, ValueError):
            cap = {}
        res[name] = {"dsp": osc.get("average_percent"), "pk_med": osc.get("peak_median_percent"),
                     "pk_max": osc.get("peak_percent"), "over100": osc.get("peak_over_100_count"),
                     "pw_err": ((d.get("pipewire") or {}).get("pw_top") or {}).get("err_delta"),
                     "live_cpu": live.get("cpu_percent_of_one_core"), "cap": cap}
    return res


def clock(agg, cap):
    if agg.get("clock_unhalted_ghz"):
        return agg["clock_unhalted_ghz"]
    if agg.get("busy_ghz") and agg.get("ref_ghz"):
        return agg["busy_ghz"] / agg["ref_ghz"] * (cap.get("tsc_mhz") or TSC_FALLBACK_MHZ) / 1000
    return None


def idle(cap):
    """{state name: (entries per second per audio CPU, mean residency %)} over the audio CPUs"""
    dur = cap.get("duration_s") or 0
    acc = {}
    for key, v in (cap.get("cpuidle") or {}).items():
        cpu = int(key.split(".")[0])
        if cpu not in AUDIO_CPUS:
            continue
        e, r = acc.setdefault(v["name"], [0, 0.0])
        acc[v["name"]] = [e + v["entries"], r + (v["residency_pct"] or 0)]
    n = len(AUDIO_CPUS)
    return {k: (round(e / n / dur) if dur else None, round(r / n, 1)) for k, (e, r) in acc.items()}


def f(v, nd=2):
    return "-" if v is None else (f"{v:.{nd}f}" if isinstance(v, float) else str(v))


def main():
    runs = [(a.split("=", 1)[0], per_set(a.split("=", 1)[1])) for a in sys.argv[1:]]
    base_label, base = runs[0]
    for s in base:
        print(f"== {s}")
        for label, r in runs:
            if s not in r:
                continue
            x = r[s]
            c = x["cap"]
            ac, rt = c.get("audiocalc") or {}, c.get("pipeasio_rt") or {}
            th = c.get("throttle") or {}
            mins = sorted({v["min"] for v in (c.get("cpufreq_at_start") or {}).values()})
            disabled = sorted({v["name"] for v in (c.get("cpuidle") or {}).values() if v.get("disabled")})
            print(f"  {label}: AudioCalc {f(clock(ac, c), 2)} GHz executing {f(ac.get('unhalted_pct'), 1)} % IPC {f(ac.get('ipc'), 3)}"
                  f" CPU {f(ac.get('cpu_percent_of_one_core'))} % | pipeasio-rt {f(clock(rt, c), 2)} GHz"
                  f" | DSP {f(x['dsp'], 3)} pk_med {f(x['pk_med'])} pk_max {f(x['pk_max'], 1)} >100 {x['over100']}"
                  f" PW err {x['pw_err']} | Live CPU {f(x['live_cpu'])} %")
            print(f"     package {f(c.get('package_w'))} W, temp {c.get('package_temp_c')}, throttle {th.get('package_ms')} ms pkg"
                  f" | audio CPUs' idle (entries/s, residency %): {idle(c)} | min_freq {mins} disabled {disabled}"
                  f" C1E {c.get('c1e_at_start', '-')}")
        b = base.get(s)
        for label, r in runs[1:]:
            x = r.get(s)
            if not (b and x):
                continue
            g0 = clock(b["cap"].get("audiocalc") or {}, b["cap"])
            g1 = clock(x["cap"].get("audiocalc") or {}, x["cap"])
            if g0 and g1 and b["dsp"] and x["dsp"]:
                print(f"  {label} vs {base_label}: AudioCalc clock {100 * (g1 - g0) / g0:+.1f} %,"
                      f" DSP {100 * (x['dsp'] - b['dsp']) / b['dsp']:+.1f} %")


if __name__ == "__main__":
    main()
