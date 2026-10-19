"""summarise.py: one line per bench-win.py run (result.json), for comparing with the Linux bench.

usage: python summarise.py [--json] RUN_DIR [RUN_DIR ...]   (--json: one line per run, as linux-run.sh prints)
Per run: Set, worker option, sample rate and buffer from Live's log, DSP average and peak median (percent of the
buffer period), peaks over 100 % (missed deadlines), Live's CPU, the AudioCalc threads' CPU (count), the busiest
other thread (on Windows the ASIO driver's callback thread, the counterpart of PipeASIO's pipeasio-rt), and the
audio total (AudioCalc + that thread, comparable with the Linux bench's M), all in percent of one core.
"""
import json
import os
import sys


def as_json(d):
    """One JSON line in profiler/windows/linux-run.sh's format (os, set, dsp_average, ...)."""
    r = json.load(open(os.path.join(d, "result.json")))
    threads = r.get("threads_top", [])
    other = next((t for t in threads if not t["name"].startswith("AudioCalc")), {"cpu_percent_of_one_core": 0})
    audio = r.get("audiocalc_cpu_percent_of_one_core", 0)
    dsp = r.get("dsp", {})
    return json.dumps({"os": "windows", "set": r["set"].replace("Benchmark_", ""), "dsp_average": dsp.get("average_percent"),
                       "dsp_peak_median": dsp.get("peak_median_percent"), "peaks_over_100": dsp.get("peak_over_100_count"),
                       "live_cpu": r.get("live_cpu_percent_of_one_core"), "audiocalc_cpu": audio,
                       "audiocalc_threads": r.get("audiocalc_threads"), "callback_cpu": other["cpu_percent_of_one_core"],
                       "audio_total": round(audio + other["cpu_percent_of_one_core"], 2),
                       "sample_rate": r.get("log", {}).get("sample_rate"), "workers": r.get("workers_option")})


def main():
    if sys.argv[1:2] == ["--json"]:
        for d in sys.argv[2:]:
            print(as_json(d))
        return
    print(f"{'set':10} {'workers':7} {'rate':>6} {'dsp':>6} {'pk_med':>7} {'>100%':>5} {'live':>6} {'audioc':>12} "
          f"{'callback':>22} {'M':>6}")
    for d in sys.argv[1:]:
        try:
            r = json.load(open(os.path.join(d, "result.json")))
        except OSError:
            print(f"{d}: no result.json")
            continue
        threads = r.get("threads_top", [])
        other = next((t for t in threads if not t["name"].startswith("AudioCalc")), {"name": "?", "cpu_percent_of_one_core": 0})
        audio = r.get("audiocalc_cpu_percent_of_one_core", 0)
        dsp = r.get("dsp", {})
        log = r.get("log", {})
        print(f"{r['set'].replace('Benchmark_', ''):10} {r.get('workers_option', '?'):7} {log.get('sample_rate', '?'):>6} "
              f"{dsp.get('average_percent', 0):6.2f} {dsp.get('peak_median_percent', 0):7.2f} {dsp.get('peak_over_100_count', 0):5} "
              f"{r.get('live_cpu_percent_of_one_core', 0):6.2f} {audio:6.2f} ({r.get('audiocalc_threads', 0):2}) "
              f"{other['cpu_percent_of_one_core']:6.2f} {other['name'][:14]:>14} {audio + other['cpu_percent_of_one_core']:6.2f}")


if __name__ == "__main__":
    main()
