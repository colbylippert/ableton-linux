"""d0007_summary.py A_BENCH B_BENCH: D0007's per-Set comparison, A (as is) against B (clock floor on the P-cores).

Per Set: the audio threads' clock while running (cycles / task clock), IPC and CPU from clock-capture; Live's DSP
average, peak median and peaks over 100 % (the bench's osc_dsp); PipeWire errors; Live's CPU; package power and
temperatures; thermal throttling; the P-cores' scaling_min_freq during the capture (the mechanism).
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "trials"))
import campaign_tools as ct  # noqa: E402


def per_set(bench):
    res = {}
    for m in sorted(glob.glob(os.path.join(bench, "sets", "*", "measurement.json"))):
        set_dir = os.path.dirname(m)
        name = os.path.basename(set_dir).split("-", 1)[1].replace("Benchmark_", "")
        d = json.load(open(m))
        osc = d.get("osc_dsp") or {}
        raw = json.load(open(os.path.join(set_dir, "raw", "proc-delta.json")))
        live = ct.live_process(raw)
        try:
            cap = json.load(open(os.path.join(set_dir, "raw", "interface", "summary.json")))
        except (OSError, ValueError):
            cap = {}
        res[name] = {
            "dsp": osc.get("average_percent"), "pk_med": osc.get("peak_median_percent"),
            "over100": osc.get("peak_over_100_count"), "pk_max": osc.get("peak_percent"),
            "pw_err": ((d.get("pipewire") or {}).get("pw_top") or {}).get("err_delta"),
            "live_cpu": live.get("cpu_percent_of_one_core"), "cap": cap,
        }
    return res


def fmt(v, nd=2):
    return "-" if v is None else f"{v:.{nd}f}" if isinstance(v, float) else str(v)


def main():
    a, b = per_set(sys.argv[1]), per_set(sys.argv[2])
    for s in a:
        if s not in b:
            continue
        print(f"== {s}")
        for label, ra in (("A", a[s]), ("B", b[s])):
            c = ra["cap"]
            ac, rt = c.get("audiocalc") or {}, c.get("pipeasio_rt") or {}
            th = c.get("throttle") or {}
            mins = sorted({v["min"] for v in (c.get("cpufreq_at_start") or {}).values()})
            epps = sorted({v["epp"] for v in (c.get("cpufreq_at_start") or {}).values()})
            print(f"  {label}: AudioCalc {fmt(ac.get('busy_ghz'), 3)} GHz IPC {fmt(ac.get('ipc'), 3)} CPU {fmt(ac.get('cpu_percent_of_one_core'))} %"
                  f" | pipeasio-rt {fmt(rt.get('busy_ghz'), 3)} GHz CPU {fmt(rt.get('cpu_percent_of_one_core'))} %"
                  f" | DSP {fmt(ra['dsp'], 3)} pk_med {fmt(ra['pk_med'], 2)} pk_max {fmt(ra['pk_max'], 1)} >100 {ra['over100']} PW err {ra['pw_err']}"
                  f" | Live CPU {fmt(ra['live_cpu'])} %")
            print(f"     package {fmt(c.get('package_w'))} W (p95 {fmt(c.get('package_w_p95'), 1)}), temp {c.get('package_temp_c')},"
                  f" hottest core {c.get('hottest_core_temp_c')}, throttle pkg {th.get('package_events')} ev / {th.get('package_ms')} ms,"
                  f" cores ms {th.get('core_ms')} | min_freq {mins} EPP {epps}")
        ga = (a[s]["cap"].get("audiocalc") or {}).get("busy_ghz")
        gb = (b[s]["cap"].get("audiocalc") or {}).get("busy_ghz")
        if ga and gb and a[s]["dsp"] and b[s]["dsp"]:
            print(f"  B vs A: clock {100 * (gb - ga) / ga:+.1f} %, DSP {100 * (b[s]['dsp'] - a[s]['dsp']) / a[s]['dsp']:+.1f} %")


if __name__ == "__main__":
    main()
