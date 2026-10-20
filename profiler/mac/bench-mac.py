#!/usr/bin/env python3
"""bench-mac.py: the Linux bench's measurement of Live's Sets, on macOS. Run on the Mac over SSH as the logged-in user,
from the tree profiler/mac/push.sh sends (~/AbletonBench/src):

    python3 ~/AbletonBench/src/profiler/mac/bench-mac.py --out ~/AbletonBench/runs/TAG [--sets Inbuilts,Max4Live,VSTs]
        [--duration 120] [--workers N|default] [--ramp PASSES] [--dialog-helper CMD]

Per Set, as profiler/windows/bench-win.py does on Windows: Live is opened with the Set through LaunchServices
(`open -a`, so it runs in the logged-in user's GUI session with its audio device), the bench handler inside AbletonOSC
must answer /abl/bench/ping, Live's log must be quiet for SETTLE seconds, then /abl/bench/rewind and /abl/bench/play,
SETTLE seconds and a quiet log again, then the measured window. During the window it keeps the handler's
/abl/bench/cpu reports (Live's average and peak, percent of the audio buffer period, every 500 ms) and, at both ends,
every thread's CPU time and name and the process's (libproc's proc_pidinfo, no root needed for one's own processes).
Reports queued before the window are discarded. Afterwards /abl/bench/stop, Live is ended and its crash-recovery files
are removed, so the next start has no recovery dialog.

--ramp PASSES runs the load ramp instead of a plain window (profiler/scenarios/ramp-duplicate-all.json): a scenario
marker every 5 s, /abl/bench/duplicate-all 51.3 s into every 51.4286 s period, PASSES periods in all. Every message
received is written to raw/osc.tsv in the layout profiler/control/ramp-report.py and ramp-beats.py read ("t epoch
address arguments", t from the window start); there is no PipeWire on macOS, so a ramp step fails on peaks only.

Output: OUT/sets/NN-Benchmark_SET/{result.json,cpu.tsv,raw/osc.tsv} and OUT/run.json.

The Trial's start-up dialog (demo mode: "Save/Export Disabled", as on Linux and Windows) must be answered before the
bench handler starts: --dialog-helper names a program run in the GUI session that does it (clicking needs Accessibility
permission there), or Live is authorized so the dialog does not appear.
"""
import argparse
import ctypes
import ctypes.util
import importlib.util
import json
import os
import platform
import re
import signal
import socket
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LIVE_APP = "/Applications/Ableton Live 12 Trial.app"
LIVE_PROCESS = "Live"
SETS_DIR = os.path.expanduser("~/AbletonBench/bench/BenchmarkSets Project")
PREFS_DIR = os.path.expanduser("~/Library/Preferences/Ableton/Live 12.4.6")
OSC_IN, OSC_OUT = 11000, 11001     # AbletonOSC listens on 11000 and reports to 11001
SETTLE = 5
LAUNCH_TIMEOUT = 240
RAMP_PERIOD_S = 51.4286            # 96 beats at 112 BPM, profiler/scenarios/ramp-duplicate-all.json
RAMP_AT_S = 51.3
MARKER_EVERY_S = 5.0


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# scripts/bench-osc.py: the suite's dependency-free OSC codec (push.sh sends it along)
osc_codec = load("bench_osc", os.path.join(HERE, "..", "..", "scripts", "bench-osc.py"))


# ---------------------------------------------------------------- Live's process
def live_pids():
    out = subprocess.run(["pgrep", "-x", LIVE_PROCESS], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def end_live():
    for sig, wait in ((signal.SIGTERM, 20), (signal.SIGKILL, 10)):
        for pid in live_pids():
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.time() + wait
        while live_pids() and time.time() < deadline:
            time.sleep(0.5)
        if not live_pids():
            return


def clean_crash_files():
    for name in ("CrashDetection.cfg", "CrashRecoveryInfo.cfg"):
        try:
            os.remove(os.path.join(PREFS_DIR, name))
        except OSError:
            pass
    subprocess.run(["rm", "-rf", os.path.join(PREFS_DIR, "Crash")], capture_output=True)


def set_workers(workers):
    """Live's audio worker count, as the Linux launcher sets it: -MaxAudioThreads=N in Options.txt ('default' removes it)."""
    path = os.path.join(PREFS_DIR, "Options.txt")
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = [l.rstrip("\r\n") for l in f if not l.strip().startswith("-MaxAudioThreads=")]
    if workers != "default":
        lines.append("-MaxAudioThreads=%d" % int(workers))
    if lines:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    elif os.path.exists(path):
        os.remove(path)


def launch_live(set_path, dialog_helper):
    subprocess.run(["open", "-a", LIVE_APP, set_path], check=True)
    if dialog_helper:
        subprocess.Popen(dialog_helper, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------- OSC
class Osc:
    """One UDP socket bound to the report port, so the handler's reports and answers come back to it."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", OSC_OUT))
        self.sock.settimeout(0.2)

    def send(self, address, *args):
        words = [repr(a) if isinstance(a, float) else str(int(a)) if isinstance(a, bool) else str(a) for a in args]
        self.sock.sendto(osc_codec.encode(address, words), ("127.0.0.1", OSC_IN))

    def recv(self, timeout=0.2):
        self.sock.settimeout(timeout)
        try:
            data, _ = self.sock.recvfrom(65536)
        except (socket.timeout, ConnectionResetError):
            return None
        return self.decode(data)

    @staticmethod
    def decode(data):
        try:
            address, args = osc_codec.decode(data)
            return address, list(args)
        except Exception:
            return ("undecodable", [])

    def drain(self):
        """Read everything already queued: the reports sent before the window, which must not count as readings."""
        msgs = []
        self.sock.setblocking(False)
        try:
            while True:
                try:
                    data, _ = self.sock.recvfrom(65536)
                except BlockingIOError:
                    break
                except ConnectionResetError:
                    continue
                msgs.append(self.decode(data))
        finally:
            self.sock.settimeout(0.2)
        return msgs


# ---------------------------------------------------------------- threads (libproc)
libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
PROC_PIDTASKINFO, PROC_PIDTHREADINFO, PROC_PIDLISTTHREADS = 4, 5, 6


class ProcTaskInfo(ctypes.Structure):
    _fields_ = [("pti_virtual_size", ctypes.c_uint64), ("pti_resident_size", ctypes.c_uint64),
                ("pti_total_user", ctypes.c_uint64), ("pti_total_system", ctypes.c_uint64),
                ("pti_threads_user", ctypes.c_uint64), ("pti_threads_system", ctypes.c_uint64),
                ("pti_policy", ctypes.c_int32), ("pti_faults", ctypes.c_int32), ("pti_pageins", ctypes.c_int32),
                ("pti_cow_faults", ctypes.c_int32), ("pti_messages_sent", ctypes.c_int32),
                ("pti_messages_received", ctypes.c_int32), ("pti_syscalls_mach", ctypes.c_int32),
                ("pti_syscalls_unix", ctypes.c_int32), ("pti_csw", ctypes.c_int32), ("pti_threadnum", ctypes.c_int32),
                ("pti_numrunning", ctypes.c_int32), ("pti_priority", ctypes.c_int32)]


class ProcThreadInfo(ctypes.Structure):
    _fields_ = [("pth_user_time", ctypes.c_uint64), ("pth_system_time", ctypes.c_uint64),
                ("pth_cpu_usage", ctypes.c_int32), ("pth_policy", ctypes.c_int32), ("pth_run_state", ctypes.c_int32),
                ("pth_flags", ctypes.c_int32), ("pth_sleep_time", ctypes.c_int32), ("pth_curpri", ctypes.c_int32),
                ("pth_priority", ctypes.c_int32), ("pth_maxpriority", ctypes.c_int32), ("pth_name", ctypes.c_char * 64)]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = MachTimebase()
ctypes.CDLL(None).mach_timebase_info(ctypes.byref(_timebase))


def task_cpu_seconds(pid):
    """The process's user + system CPU seconds (task info counts in Mach absolute time units), or None."""
    info = ProcTaskInfo()
    if libproc.proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return (info.pti_total_user + info.pti_total_system) * _timebase.numer / _timebase.denom / 1e9


def thread_times(pid):
    """{thread id: (user + system seconds, name, priority)} for every thread of pid (thread times are nanoseconds)."""
    ids = (ctypes.c_uint64 * 4096)()
    n = libproc.proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, ids, ctypes.sizeof(ids))
    out = {}
    for i in range(max(n, 0) // 8):
        info = ProcThreadInfo()
        if libproc.proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[i], ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info):
            out[ids[i]] = ((info.pth_user_time + info.pth_system_time) / 1e9, info.pth_name.decode("utf-8", "replace"),
                           info.pth_curpri)
    return out


# ---------------------------------------------------------------- log
def log_quiet(path, quiet_s, timeout_s):
    """Wait until the file has not grown for quiet_s seconds."""
    last_size, since, deadline = -1, time.time(), time.time() + timeout_s
    while time.time() < deadline:
        size = os.path.getsize(path) if os.path.exists(path) else 0
        if size != last_size:
            last_size, since = size, time.time()
        elif time.time() - since >= quiet_s:
            return True
        time.sleep(0.5)
    return False


def log_facts(path, start_offset):
    """Live's audio setup lines written since this run's launch."""
    facts = {}
    try:
        with open(path, "rb") as f:
            f.seek(start_offset)
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return facts
    for key, pat in (("live_version", r"Live Version: ([^\r\n]+)"), ("driver_type", r"Driver Type: ([^\r\n]+)"),
                     ("output_device", r"Output Device: ([^\r\n]+)"), ("buffer", r"Input Buffer Size: ([^\r\n]+)"),
                     ("output_buffer", r"Output Buffer Size: ([^\r\n]+)"), ("sample_rate", r"Sample Rate: ([^\r\n]+)"),
                     ("gpu_renderer", r"GPU Renderer: ([^\r\n]+)"), ("overall_latency", r"Overall Latency: ([^\r\n]+)"),
                     ("licensing", r"Licensing: ([^\r\n]+)")):
        found = re.findall(pat, text)
        if found:
            facts[key] = found[-1].strip()
    facts["errors"] = len(re.findall(r": error: ", text))
    return facts


def dsp_summary(averages, peaks):
    """As scripts/bench-report.py: average of the averages, window maximum and median of the peaks, peaks > 100 %."""
    ordered = sorted(peaks)
    return {
        "sample_count": len(averages),
        "average_percent": round(sum(averages) / len(averages), 3) if averages else None,
        "peak_percent": max(peaks) if peaks else None,
        "peak_median_percent": round(statistics.median(ordered), 3) if ordered else None,
        "peak_over_100_count": sum(v > 100.0 for v in peaks) if peaks else None,
    }


def machine():
    def sysctl(name):
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
    therm = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True).stdout.strip()
    return {"host": platform.node(), "macos": platform.mac_ver()[0], "arch": platform.machine(),
            "cpu": sysctl("machdep.cpu.brand_string"), "model": sysctl("hw.model"),
            "physical_cpus": sysctl("hw.physicalcpu"), "logical_cpus": sysctl("hw.ncpu"),
            "perf_levels": {sysctl("hw.perflevel%d.name" % i): sysctl("hw.perflevel%d.logicalcpu" % i)
                            for i in (0, 1) if sysctl("hw.perflevel%d.name" % i)},
            "memory_gb": round(int(sysctl("hw.memsize") or 0) / 2 ** 30), "thermal": therm,
            "live": subprocess.run(["defaults", "read", LIVE_APP + "/Contents/Info", "CFBundleShortVersionString"],
                                   capture_output=True, text=True).stdout.strip()}


# ---------------------------------------------------------------- one Set
def run_set(set_name, out, duration, workers, ramp, dialog_helper):
    set_path = os.path.join(SETS_DIR, set_name + ".als")
    if not os.path.exists(set_path):
        sys.exit("no such Set: %s" % set_path)
    os.makedirs(os.path.join(out, "raw"), exist_ok=True)
    result = {"set": set_name, "duration_s": duration, "ramp_passes": ramp, "machine": machine()}
    end_live()
    clean_crash_files()
    set_workers(workers)
    result["workers_option"] = workers
    log_path = os.path.join(PREFS_DIR, "Log.txt")
    log_offset = os.path.getsize(log_path) if os.path.exists(log_path) else 0
    osc = Osc()
    log("launching Live with %s" % set_name)
    launch_live(set_path, dialog_helper)
    t0 = time.time()
    while time.time() - t0 < LAUNCH_TIMEOUT:            # the bench handler answers once the script is up
        osc.send("/abl/bench/ping", 1)
        m = osc.recv()
        if m and m[0] == "/abl/bench/pong":
            break
    else:
        end_live()
        sys.exit("no /abl/bench/pong: Live or AbletonOSC did not come up (Trial dialog unanswered? AbletonOSC not "
                 "selected as a Control Surface?)")
    log("handler up after %.0f s" % (time.time() - t0))
    if not log_quiet(log_path, SETTLE, LAUNCH_TIMEOUT):
        log("warning: Live's log did not settle")
    pids = live_pids()
    if not pids:
        sys.exit("Live is not running")
    pid = pids[0]
    result["live_pid"] = pid
    osc.send("/abl/bench/stop")
    osc.send("/abl/bench/rewind")
    osc.send("/abl/bench/play")
    time.sleep(SETTLE)
    log_quiet(log_path, SETTLE, LAUNCH_TIMEOUT)

    window = ramp * RAMP_PERIOD_S + 1 if ramp else duration
    log("window %.0f s%s" % (window, " (load ramp, %d passes)" % ramp if ramp else ""))
    averages, peaks, playing, cpu_rows, raw = [], [], [], [], []
    before = thread_times(pid)
    p_before = task_cpu_seconds(pid)
    queued = osc.drain()
    w0 = time.time()
    states = [int(p[0]) for addr, p in queued if addr == "/abl/bench/playing" and p]
    result["queued_before_window"] = {"messages": len(queued), "cpu_reports": sum(addr == "/abl/bench/cpu" for addr, _ in queued),
                                      "playing": states[-1] if states else None}
    next_marker, next_dup, dups = 0.0, RAMP_AT_S, 0
    while time.time() - w0 < window:
        now = time.time() - w0
        if ramp:
            if now >= next_marker:
                osc.send("/abl/bench/scenario-marker", "start" if next_marker == 0 else "at-%gs" % next_marker)
                next_marker += MARKER_EVERY_S
            if now >= next_dup and dups < ramp - 1:
                osc.send("/abl/bench/duplicate-all")
                dups += 1
                next_dup += RAMP_PERIOD_S
        m = osc.recv(0.05 if ramp else 0.2)
        if not m:
            continue
        t, address, params = round(time.time() - w0, 6), m[0], m[1]
        raw.append("%.6f\t%.3f %s %s" % (t, time.time(), address, " ".join(str(p) for p in params)))
        if address == "/abl/bench/cpu" and len(params) >= 2:
            avg, peak = float(params[0]), float(params[1])
            cpu_rows.append((round(t, 3), avg, peak))
            if avg >= 0:
                averages.append(avg)
            if peak >= 0:
                peaks.append(peak)
        elif address == "/abl/bench/playing" and params:
            playing.append((round(t, 3), int(params[0])))
    elapsed = time.time() - w0
    after = thread_times(pid)
    p_after = task_cpu_seconds(pid)
    osc.send("/abl/bench/stop")

    threads = []
    for tid, (t1, name, pri) in after.items():
        t_0 = before.get(tid, (0.0, "", 0))[0]
        threads.append({"tid": tid, "name": name or before.get(tid, (0, "", 0))[1], "priority": pri,
                        "cpu_percent_of_one_core": round((t1 - t_0) / elapsed * 100, 2)})
    threads.sort(key=lambda t: -t["cpu_percent_of_one_core"])
    audio = [t for t in threads if t["name"].startswith("AudioCalc")]
    result.update({
        "window_s": round(elapsed, 2),
        "dsp": dsp_summary(averages, peaks),
        "live_cpu_percent_of_one_core": round((p_after - p_before) / elapsed * 100, 2)
        if p_before is not None and p_after is not None else None,
        "audiocalc_threads": len(audio),
        "audiocalc_cpu_percent_of_one_core": round(sum(t["cpu_percent_of_one_core"] for t in audio), 2),
        "threads_top": threads[:20],
        "thread_count": len(threads),
        "thread_names": sorted({t["name"] for t in threads if t["name"]}),
        "playing_events": playing,
        "duplications": dups,
        "log": log_facts(log_path, log_offset),
    })
    end_live()
    clean_crash_files()
    with open(os.path.join(out, "cpu.tsv"), "w") as f:
        f.write("t\taverage\tpeak\n" + "".join("%s\t%s\t%s\n" % row for row in cpu_rows))
    with open(os.path.join(out, "raw", "osc.tsv"), "w") as f:
        f.write("".join(line + "\n" for line in raw))
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)
    d = result["dsp"]
    log("done: DSP average %s %%, peak median %s %%, peaks > 100 %%: %s; Live CPU %s %%, %d AudioCalc threads %s %%"
        % (d["average_percent"], d["peak_median_percent"], d["peak_over_100_count"], result["live_cpu_percent_of_one_core"],
           len(audio), result["audiocalc_cpu_percent_of_one_core"]))
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--sets", default="Inbuilts,Max4Live,VSTs")
    ap.add_argument("--duration", type=int, default=120)
    ap.add_argument("--workers", default="default", help="Live's audio workers (-MaxAudioThreads) or 'default'")
    ap.add_argument("--ramp", type=int, default=0, help="run the load ramp for PASSES periods instead of a plain window")
    ap.add_argument("--dialog-helper", default=os.environ.get("ABLETON_BENCH_DIALOG_HELPER", ""),
                    help="a command, run after each launch, that answers the Trial's start-up dialog")
    a = ap.parse_args()
    out = os.path.expanduser(a.out)
    os.makedirs(out, exist_ok=True)
    names = ["Benchmark_" + s.replace("Benchmark_", "") for s in a.sets.split(",") if s]
    run = {"created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "sets": names, "duration_s": a.duration,
           "workers_option": a.workers, "ramp_passes": a.ramp, "machine": machine(), "results": []}
    for i, name in enumerate(names):
        r = run_set(name, os.path.join(out, "sets", "%02d-%s" % (i + 1, name)), a.duration, a.workers, a.ramp,
                    a.dialog_helper)
        run["results"].append({"set": name, "dsp": r["dsp"], "live_cpu": r["live_cpu_percent_of_one_core"],
                               "audiocalc_threads": r["audiocalc_threads"]})
    run["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with open(os.path.join(out, "run.json"), "w") as f:
        json.dump(run, f, indent=1)


if __name__ == "__main__":
    main()
