"""bench-win.py: the Linux bench's measurement of one Set, on native Windows (the Windows baseline for
profiler/plans/kernel-plan.md). Run on the laptop's Windows side, over SSH, as the logged-on user:

    python bench-win.py --set Benchmark_Inbuilts --duration 120 --out C:\\Users\\colby\\AbletonBench\\runs\\TAG

It follows scripts/bench-suite.sh: Live is launched with the Set (through a scheduled task, so it runs in the
desktop session with its audio device; a program started directly over SSH would run in the hidden service session),
the bench handler inside AbletonOSC must answer /abl/bench/ping, Live's log must be quiet for SETTLE seconds,
then /abl/bench/rewind and /abl/bench/play, SETTLE seconds and a quiet log again, then the measured window. During
the window it keeps the handler's /abl/bench/cpu reports (Live's average and peak process usage, percent of the audio
buffer period, every 500 ms) and, at both ends, every thread's CPU time (psutil) and name (GetThreadDescription).
Afterwards /abl/bench/stop, Live is ended, and Live's crash-recovery files are removed so the next start has no
dialog. It writes result.json and cpu.tsv into --out.
"""
import argparse
import ctypes
import json
import os
import platform
import re
import socket
import statistics
import subprocess
import sys
import time
from ctypes import wintypes

import psutil
from pythonosc.osc_message import OscMessage
from pythonosc.osc_message_builder import OscMessageBuilder

LIVE_EXE = r"C:\ProgramData\Ableton\Live 12 Trial\Program\Ableton Live 12 Trial.exe"
SETS_DIR = r"C:\Users\colby\AbletonBench\BenchmarkSets Project"
PREFS_DIR = os.path.expandvars(r"%APPDATA%\Ableton\Live 12.4.6\Preferences")
TASK = "ProfilerBenchLive"
OSC_IN, OSC_OUT = 11000, 11001     # AbletonOSC listens on 11000 and reports to 11001
SETTLE = 5
LAUNCH_TIMEOUT = 240


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ---------------------------------------------------------------- Live's process
def live_procs():
    return [p for p in psutil.process_iter(["name"]) if (p.info["name"] or "").lower().startswith("ableton live")]


def end_live():
    for p in live_procs():
        try:
            p.kill()
        except psutil.Error:
            pass
    deadline = time.time() + 30
    while live_procs() and time.time() < deadline:
        time.sleep(0.5)


def clean_crash_files():
    for name in ("CrashDetection.cfg", "CrashRecoveryInfo.cfg"):
        try:
            os.remove(os.path.join(PREFS_DIR, name))
        except OSError:
            pass
    crash = os.path.join(PREFS_DIR, "Crash")
    if os.path.isdir(crash):
        subprocess.run(["cmd", "/c", "rmdir", "/s", "/q", crash], capture_output=True)


def set_workers(workers):
    """Live's audio worker count, as the Linux launcher sets it: -MaxAudioThreads=N in Options.txt ('default' removes it)."""
    path = os.path.join(PREFS_DIR, "Options.txt")
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = [l.rstrip("\r\n") for l in f if not l.strip().startswith("-MaxAudioThreads=")]
    if workers != "default":
        lines.append(f"-MaxAudioThreads={int(workers)}")
    if lines:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\r\n".join(lines) + "\r\n")
    elif os.path.exists(path):
        os.remove(path)


def run_task(name, action):
    """Run action in the logged-on user's desktop session (a scheduled task with /it)."""
    subprocess.run(["schtasks", "/create", "/f", "/tn", name, "/tr", action, "/sc", "once", "/st", "00:00",
                    "/it"], check=True, capture_output=True)
    subprocess.run(["schtasks", "/run", "/tn", name], check=True, capture_output=True)


def launch_live(set_path):
    """Start Live with the Set in the desktop session, and the trial-dialog answer beside it (as the Linux bench's
    live-trial-dialog watcher does)."""
    run_task(TASK, f'"{LIVE_EXE}" "{set_path}"')
    pythonw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    run_task(TASK + "Dialog", f'"{pythonw}" "{os.path.abspath(__file__)}" --dismiss-dialog {LAUNCH_TIMEOUT}')


def dismiss_dialog(timeout):
    """Click "Save/Export Disabled" on Live's demo-mode dialog: the top-level window titled exactly
    "Ableton Live 12 Trial"; the button sits at 23 % of its width and 93.5 % of its height (profiler/bin/live-trial-dialog).
    Runs in the desktop session. Returns 0 when the dialog was answered, 1 when it never appeared or stayed."""
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.SetProcessDPIAware()
    user32.FindWindowW.restype = wintypes.HWND
    title = "Ableton Live 12 Trial"
    deadline = time.time() + timeout
    while time.time() < deadline:
        hwnd = user32.FindWindowW(None, title)
        if hwnd:
            time.sleep(1.0)                       # let it finish drawing
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            x = rect.left + int((rect.right - rect.left) * 0.23)
            y = rect.top + int((rect.bottom - rect.top) * 0.935)
            user32.SetForegroundWindow(hwnd)
            time.sleep(0.3)
            user32.SetCursorPos(x, y)
            user32.mouse_event(0x0002, 0, 0, 0, 0)    # left down
            user32.mouse_event(0x0004, 0, 0, 0, 0)    # left up
            time.sleep(1.5)
            if not user32.FindWindowW(None, title):
                return 0
        time.sleep(0.5)
    return 1


# ---------------------------------------------------------------- OSC
class Osc:
    """One UDP socket bound to the report port, so the handler's reports and answers come back to it."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", OSC_OUT))
        self.sock.settimeout(0.2)

    def send(self, address, *args):
        b = OscMessageBuilder(address=address)
        for a in args:
            b.add_arg(a)
        self.sock.sendto(b.build().dgram, ("127.0.0.1", OSC_IN))

    def recv(self):
        try:
            data, _ = self.sock.recvfrom(65536)
        except (socket.timeout, ConnectionResetError):
            return None
        try:
            m = OscMessage(data)
            return m.address, list(m.params)
        except Exception:
            return ("undecodable", [])


# ---------------------------------------------------------------- threads
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
THREAD_QUERY_LIMITED_INFORMATION = 0x0800
kernel32.OpenThread.restype = wintypes.HANDLE
kernel32.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.GetThreadDescription.argtypes = [wintypes.HANDLE, ctypes.POINTER(ctypes.c_wchar_p)]
kernel32.LocalFree.argtypes = [ctypes.c_void_p]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def thread_name(tid):
    h = kernel32.OpenThread(THREAD_QUERY_LIMITED_INFORMATION, False, tid)
    if not h:
        return ""
    try:
        p = ctypes.c_wchar_p()
        if kernel32.GetThreadDescription(h, ctypes.byref(p)) >= 0 and p.value is not None:
            name = p.value
            kernel32.LocalFree(ctypes.cast(p, ctypes.c_void_p))
            return name
        return ""
    finally:
        kernel32.CloseHandle(h)


def thread_times(proc):
    """{tid: (user + system seconds, name)} for every thread of proc."""
    out = {}
    for t in proc.threads():
        out[t.id] = (t.user_time + t.system_time, thread_name(t.id))
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
                     ("sample_rate", r"Sample Rate: ([^\r\n]+)"), ("gpu_renderer", r"GPU Renderer: ([^\r\n]+)"),
                     ("overall_latency", r"Overall Latency: ([^\r\n]+)")):
        found = re.findall(pat, text)
        if found:
            facts[key] = found[-1].strip()
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


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--dismiss-dialog":
        sys.exit(dismiss_dialog(int(sys.argv[2]) if len(sys.argv) > 2 else LAUNCH_TIMEOUT))
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--duration", type=int, default=120)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", default="default", help="Live's audio workers (-MaxAudioThreads) or 'default'")
    a = ap.parse_args()
    set_path = os.path.join(SETS_DIR, a.set + ".als")
    if not os.path.exists(set_path):
        sys.exit(f"no such Set: {set_path}")
    os.makedirs(a.out, exist_ok=True)
    result = {"set": a.set, "duration_s": a.duration, "host": platform.node(), "windows": platform.version(),
              "power_plan": subprocess.run(["powercfg", "/getactivescheme"], capture_output=True, text=True).stdout.strip()}

    end_live()
    clean_crash_files()
    set_workers(a.workers)
    result["workers_option"] = a.workers
    log_path = os.path.join(PREFS_DIR, "Log.txt")
    log_offset = os.path.getsize(log_path) if os.path.exists(log_path) else 0
    osc = Osc()
    log(f"launching Live with {a.set}")
    launch_live(set_path)
    t0 = time.time()
    while time.time() - t0 < LAUNCH_TIMEOUT:            # the bench handler answers once the script is up
        osc.send("/abl/bench/ping", 1)
        m = osc.recv()
        if m and m[0] == "/abl/bench/pong":
            break
    else:
        end_live()
        sys.exit("no /abl/bench/pong: Live or AbletonOSC did not come up")
    log(f"handler up after {time.time() - t0:.0f} s")
    if not log_quiet(log_path, SETTLE, LAUNCH_TIMEOUT):
        log("warning: Live's log did not settle")
    procs = live_procs()
    proc = max(procs, key=lambda p: p.memory_info().rss)
    result["live_pid"] = proc.pid
    osc.send("/abl/bench/rewind")
    osc.send("/abl/bench/play")
    time.sleep(SETTLE)
    log_quiet(log_path, SETTLE, LAUNCH_TIMEOUT)

    log(f"window {a.duration} s")
    averages, peaks, playing = [], [], []
    cpu_rows = []
    before = thread_times(proc)
    p_before = proc.cpu_times()
    w0 = time.time()
    while time.time() - w0 < a.duration:
        m = osc.recv()
        if not m:
            continue
        address, params = m
        if address == "/abl/bench/cpu" and len(params) >= 2:
            avg, peak = float(params[0]), float(params[1])
            cpu_rows.append((round(time.time() - w0, 3), avg, peak))
            if avg >= 0:
                averages.append(avg)
            if peak >= 0:
                peaks.append(peak)
        elif address == "/abl/bench/playing" and params:
            playing.append((round(time.time() - w0, 3), int(params[0])))
    elapsed = time.time() - w0
    after = thread_times(proc)
    p_after = proc.cpu_times()
    osc.send("/abl/bench/stop")

    threads = []
    for tid, (t1, name) in after.items():
        t_0 = before.get(tid, (0.0, ""))[0]
        threads.append({"tid": tid, "name": name or before.get(tid, (0, ""))[1],
                        "cpu_percent_of_one_core": round((t1 - t_0) / elapsed * 100, 2)})
    threads.sort(key=lambda t: -t["cpu_percent_of_one_core"])
    audio = [t for t in threads if t["name"].startswith("AudioCalc")]
    result.update({
        "window_s": round(elapsed, 2),
        "dsp": dsp_summary(averages, peaks),
        "live_cpu_percent_of_one_core": round(((p_after.user + p_after.system) - (p_before.user + p_before.system)) / elapsed * 100, 2),
        "audiocalc_threads": len(audio),
        "audiocalc_cpu_percent_of_one_core": round(sum(t["cpu_percent_of_one_core"] for t in audio), 2),
        "threads_top": threads[:15],
        "thread_count": len(threads),
        "playing_events": playing,
        "log": log_facts(log_path, log_offset),
    })
    end_live()
    clean_crash_files()
    with open(os.path.join(a.out, "cpu.tsv"), "w") as f:
        f.write("t\taverage\tpeak\n" + "".join(f"{t}\t{x}\t{y}\n" for t, x, y in cpu_rows))
    with open(os.path.join(a.out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)
    d = result["dsp"]
    log(f"done: DSP average {d['average_percent']} %, peak median {d['peak_median_percent']} %, peaks > 100 %: "
        f"{d['peak_over_100_count']}; Live CPU {result['live_cpu_percent_of_one_core']} %, "
        f"{len(audio)} AudioCalc threads {result['audiocalc_cpu_percent_of_one_core']} %")


if __name__ == "__main__":
    main()
