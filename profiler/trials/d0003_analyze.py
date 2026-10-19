"""D0003: analyse late audio blocks (run on the laptop from the checkout root; needs sudo -n for perf script).

usage: python3 d0003_analyze.py RUN_DIR [--json OUT]

RUN_DIR is a d0003 run (…/runs/d0003/capture or …/light). Per Set (sets/*/raw/interface, written by d0003-capture):
  - every block longer than 700 us (blocks.txt), placed on the song: 112 BPM, played from beat 0, loop 16-112, so
    pass 1 covers beats 16-112 and every later pass replays them;
  - when perf data is present, per slow block and audio thread (pipeasio-rt and the AudioCalc workers): on-CPU time,
    preemptions and run-queue waits (scheduler events), CPU samples (clock speed, IPC, hottest kernel functions and
    Windows code), page faults, syscalls and IRQs; and the same figures over the whole window for comparison.
"""
import bisect
import collections
import glob
import json
import os
import re
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "profiler", "tracer"))
import symbolize  # noqa: E402  (profiler/tracer/symbolize.py: PE module + offset)

BEAT_NS = 60e9 / 112          # the heavy Sets play at 112 BPM
TSC_GHZ = 2.9184              # ref-cycles tick at the TSC rate (dmesg: 2918.400 MHz TSC)
PLAY_LAG_NS = 150_000_000     # d0003-capture starts about 0.15 s after the bench's play command
SYSCALLS = {0: "read", 1: "write", 7: "poll", 9: "mmap", 10: "mprotect", 11: "munmap", 13: "rt_sigaction",
            14: "rt_sigprocmask", 15: "rt_sigreturn", 24: "sched_yield", 28: "madvise", 35: "nanosleep",
            39: "getpid", 186: "gettid", 202: "futex", 228: "clock_gettime", 230: "clock_nanosleep",
            232: "epoll_wait", 270: "pselect6", 271: "ppoll", 281: "epoll_pwait", 435: "clone3", 56: "clone",
            200: "tkill", 234: "tgkill", 72: "fcntl", 257: "openat", 3: "close", 17: "pread64", 8: "lseek"}


def ns_of(text):
    sec, _, frac = text.partition(".")
    return int(sec) * 1_000_000_000 + int((frac + "000000000")[:9])


def song(t_ns, t_play):
    beat = (t_ns - t_play) / BEAT_NS
    if beat < 16:
        return beat, 0, beat
    pass_no = 1 + int((beat - 16) // 96)
    return beat, pass_no, 16 + (beat - 16) % 96


def perf_lines(data, fields, extra=()):
    cmd = ["sudo", "-n", "perf", "script", "-f", "-i", data, "-F", fields, "--ns", *extra]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace",
                            bufsize=1 << 20)
    yield from proc.stdout
    proc.wait()


class Window:
    """One slow block: [t0, t1] on the callback thread."""

    def __init__(self, seq, t0, elapsed, slack):
        self.seq, self.t0, self.t1, self.elapsed, self.slack = seq, t0, t0 + elapsed, elapsed, slack
        self.thr = collections.defaultdict(lambda: {
            "oncpu": 0, "preempted": 0, "preempted_by": collections.Counter(), "rq_wait": 0, "rq_max": 0,
            "samples": 0, "cyc": 0, "ins": 0, "ref": 0, "kernel": collections.Counter(), "user": collections.Counter(),
            "kfrac": 0, "faults": collections.Counter(), "sys": collections.Counter(), "irq_ns": 0, "irqs": collections.Counter(),
            "softirq_ns": 0})


def find_window(windows, starts, t):
    i = bisect.bisect_right(starts, t) - 1
    if i >= 0 and windows[i].t0 <= t <= windows[i].t1:
        return windows[i]
    return None


def analyse_set(interface, report):
    set_name = interface.split("/sets/")[1].split("/")[0]
    out = {"set": set_name}
    t_play = int(open(f"{interface}/start-mono.txt").read()) - PLAY_LAG_NS
    stop_ns = int(open(f"{interface}/stop-mono.txt").read()) if os.path.exists(f"{interface}/stop-mono.txt") else None
    cb_tid, slow, secs, faults_long, fault_totals = None, [], [], [], None
    for line in open(f"{interface}/blocks.txt", errors="replace"):
        p = line.split()
        if not p:
            continue
        if p[0] == "T" and len(p) == 2:
            cb_tid = int(p[1])
        elif p[0] == "B" and len(p) == 5:
            slow.append(Window(int(p[1]), int(p[2]), int(p[3]), int(p[4])))
        elif p[0] == "S" and len(p) == 4:
            secs.append((int(p[1]), int(p[2]), int(p[3])))
        elif p[0] == "F" and len(p) == 5:
            faults_long.append((int(p[1]), int(p[2]), int(p[3]), int(p[4], 16)))
        elif p[0] == "FAULTS" and len(p) == 3:
            fault_totals = (int(p[1]), int(p[2]))
    slow.sort(key=lambda w: w.t0)
    starts = [w.t0 for w in slow]
    out["callback_tid"] = cb_tid
    out["blocks_counted"] = sum(s[1] for s in secs)
    out["faults_all"] = {"n": fault_totals[0], "mean_us": round(fault_totals[1] / fault_totals[0] / 1e3, 2)} if fault_totals and fault_totals[0] else None
    out["faults_over_10us"] = len(faults_long)
    long_by_window = collections.defaultdict(lambda: collections.defaultdict(list))
    for tid, t0, d, addr in faults_long:
        w = find_window(slow, starts, t0)
        if w:
            long_by_window[w.seq][tid].append(d)
    in_windows = sum(len(v) for per in long_by_window.values() for v in per.values())
    out["faults_over_10us_in_slow_blocks"] = in_windows
    durs = sorted(d for _, _, d, _ in faults_long)
    out["long_fault_us"] = {"p50": round(durs[len(durs) // 2] / 1e3, 1), "max": round(durs[-1] / 1e3, 1)} if durs else None
    out["slow"] = []
    for w in slow:
        beat, pass_no, pos = song(w.t0, t_play)
        out["slow"].append({"seq": w.seq, "t_s": round((w.t0 - t_play) / 1e9, 3), "elapsed_us": round(w.elapsed / 1e3),
                            "slack_us": round(w.slack / 1e3), "late": w.slack < 0, "beat": round(beat, 2),
                            "pass": pass_no, "loop_beat": round(pos, 2)})
    tasks = {}
    for line in open(f"{interface}/tasks-start.txt", errors="replace"):
        p = line.split(None, 1)
        if len(p) == 2:
            tasks[int(p[0])] = p[1].strip()
    audio = {t for t, c in tasks.items() if c.startswith("AudioCalc") or c == "pipeasio-rt"}
    out["audio_threads"] = len(audio)
    for w, rec in zip(slow, out["slow"]):
        per = long_by_window.get(w.seq, {})
        rec["long_faults"] = {("callback" if tid == cb_tid else tasks.get(tid, str(tid)) + f"/{tid}"):
                              {"n": len(ds), "total_us": round(sum(ds) / 1e3), "max_us": round(max(ds) / 1e3)}
                              for tid, ds in per.items()}
    live_data, sched_data = f"{interface}/perf-live.data", f"{interface}/perf-sched.data"
    if not os.path.exists(live_data):
        report.append(out)
        return
    pid = int(open(f"{interface}/live.pid").read())
    modules = symbolize.ModuleMap()
    modules.load(f"{interface}/maps-start.txt", pid=pid)

    def user_sym(ip):
        mod = modules.find(ip, pid)
        if mod is None:
            return "anon:0x%x" % (ip & ~0xfff)
        return symbolize.format_address(mod, ip, modules)

    def user_bucket(ip):
        """Windows code to 1 KiB (no symbols), Wine/unix code to the symbol, anonymous memory to the page."""
        mod = modules.find(ip, pid)
        if mod is None:
            return "anon:0x%x" % (ip & ~0xfff)
        if mod.kind in ("pe64", "pe32") and not mod.is_wine_dll:
            return "%s+0x%x" % (mod.name, (ip - mod.base) & ~0x3ff)
        return symbolize.format_address(mod, ip, modules).split("+0x")[0]

    # ---- whole-window totals per role (callback / worker), for comparison
    total = {r: {"samples": 0, "cyc": 0, "ins": 0, "ref": 0, "kernel": collections.Counter(), "faults": 0,
                 "sys": collections.Counter(), "preempted": 0, "oncpu": 0, "irq_ns": 0, "softirq_ns": 0}
             for r in ("callback", "worker")}

    def role(tid):
        return "callback" if tid == cb_tid else "worker"

    # ---- scheduler: on-CPU intervals, preemptions, run-queue waits, IRQs on audio CPUs
    running = {}          # tid -> (cpu, since)
    on_cpu = {}           # cpu -> audio tid running there
    woken = {}            # tid -> wakeup time
    irq_open = {}         # cpu -> start
    soft_open = {}

    def add_oncpu(tid, a, b):
        r = total[role(tid)]
        r["oncpu"] += b - a
        i = bisect.bisect_right(starts, b) - 1
        while i >= 0 and slow[i].t1 >= a:
            w = slow[i]
            lo, hi = max(a, w.t0), min(b, w.t1)
            if hi > lo:
                w.thr[tid]["oncpu"] += hi - lo
            i -= 1

    sw = re.compile(r"prev_comm=(.*?) prev_pid=(\d+) prev_prio=(\d+) prev_state=(\S+) ==> next_comm=(.*?) next_pid=(\d+)")
    wk = re.compile(r"comm=(.*?) pid=(\d+) prio=(\d+) target_cpu=(\d+)")
    hdr = re.compile(r"^\s*\[(\d+)\]\s+(\d+\.\d+):\s+(\S+):\s*(.*)$")
    if os.path.exists(sched_data):
        for line in perf_lines(sched_data, "cpu,time,event,trace"):
            m = hdr.match(line)
            if not m:
                continue
            cpu, t, ev, rest = int(m.group(1)), ns_of(m.group(2)), m.group(3), m.group(4)
            if ev == "sched:sched_switch":
                s = sw.search(rest)
                if not s:
                    continue
                prev, state, nxt = int(s.group(2)), s.group(4), int(s.group(6))
                if prev in audio and prev in running:
                    c0, since = running.pop(prev)
                    add_oncpu(prev, since, t)
                    on_cpu.pop(cpu, None)
                    if state.startswith("R"):
                        total[role(prev)]["preempted"] += 1
                        w = find_window(slow, starts, t)
                        if w:
                            w.thr[prev]["preempted"] += 1
                            w.thr[prev]["preempted_by"][s.group(5)] += 1
                if nxt in audio:
                    running[nxt] = (cpu, t)
                    on_cpu[cpu] = nxt
                    if nxt in woken:
                        wait = t - woken.pop(nxt)
                        w = find_window(slow, starts, t)
                        if w and wait < 5_000_000:
                            w.thr[nxt]["rq_wait"] += wait
                            w.thr[nxt]["rq_max"] = max(w.thr[nxt]["rq_max"], wait)
            elif ev == "sched:sched_wakeup":
                s = wk.search(rest)
                if s and int(s.group(2)) in audio:
                    woken[int(s.group(2))] = t
            elif ev == "irq:irq_handler_entry":
                irq_open[cpu] = (t, rest.split("name=")[-1].strip())
            elif ev == "irq:irq_handler_exit" and cpu in irq_open:
                t0, name = irq_open.pop(cpu)
                tid = on_cpu.get(cpu)
                if tid is not None:
                    total[role(tid)]["irq_ns"] += t - t0
                    w = find_window(slow, starts, t)
                    if w:
                        w.thr[tid]["irq_ns"] += t - t0
                        w.thr[tid]["irqs"][name] += 1
            elif ev == "irq:softirq_entry":
                soft_open[cpu] = t
            elif ev == "irq:softirq_exit" and cpu in soft_open:
                t0 = soft_open.pop(cpu)
                tid = on_cpu.get(cpu)
                if tid is not None:
                    total[role(tid)]["softirq_ns"] += t - t0
                    w = find_window(slow, starts, t)
                    if w:
                        w.thr[tid]["softirq_ns"] += t - t0

    # ---- CPU samples (group: cycles leader + instructions + ref-cycles) with call chains
    shdr = re.compile(r"^\s*(\d+)\s+\[(\d+)\]\s+(\d+\.\d+):\s+(\d+)\s+(\S+):\s*$")
    frame = re.compile(r"^\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$")
    cur, chain = None, []

    def flush():
        if cur is None:
            return
        tid, t, vals = cur["tid"], cur["t"], cur["vals"]
        if tid not in audio or "cpu_core/cycles/" not in vals:
            return
        kern = [f for f in chain if f[0] >= 0xffff800000000000]
        user = [f for f in chain if f[0] < 0x800000000000]
        leaf_k = kern[0][1] if kern else None
        r = total[role(tid)]
        r["samples"] += 1
        r["cyc"] += vals.get("cpu_core/cycles/", 0)
        r["ins"] += vals.get("cpu_core/instructions/", 0)
        r["ref"] += vals.get("cpu_core/ref-cycles/", 0)
        if leaf_k:
            r["kernel"][leaf_k] += 1
        w = find_window(slow, starts, t)
        if w:
            th = w.thr[tid]
            th["samples"] += 1
            th["cyc"] += vals.get("cpu_core/cycles/", 0)
            th["ins"] += vals.get("cpu_core/instructions/", 0)
            th["ref"] += vals.get("cpu_core/ref-cycles/", 0)
            if leaf_k:
                th["kfrac"] += 1
                # the kernel path: leaf plus the first frame that names a subsystem entry
                path = [f[1] for f in kern[:6]]
                th["kernel"][" <- ".join(path[:3])] += 1
            if user:
                th["user"][user_bucket(user[0][0])] += 1

    for line in perf_lines(live_data, "tid,cpu,time,event,period,ip,sym,dso", ("--max-stack", "24")):
        if not line.strip():
            continue
        m = shdr.match(line)
        if m:
            tid, t, period, ev = int(m.group(1)), ns_of(m.group(3)), int(m.group(4)), m.group(5)
            if cur is not None and (cur["tid"], cur["t"]) == (tid, t):
                cur["vals"][ev] = period      # another member of the same group sample, same call chain
                cur["chain_done"] = True
                continue
            flush()
            cur, chain = {"tid": tid, "t": t, "vals": {ev: period}}, []
            continue
        f = frame.match(line)
        if f and cur is not None and len(chain) < 40:
            if not cur.get("chain_done"):
                chain.append((int(f.group(1), 16), f.group(2)))
    flush()

    # ---- tracepoints of Live's process: page faults, syscalls, signals
    thdr = re.compile(r"^\s*(\d+)\s+\[(\d+)\]\s+(\d+\.\d+):\s+(\S+):\s*(.*)$")
    for line in perf_lines(live_data, "tid,cpu,time,event,trace", ("-G",)):
        m = thdr.match(line)
        if not m:
            continue
        tid, t, ev, rest = int(m.group(1)), ns_of(m.group(3)), m.group(4), m.group(5)
        if tid not in audio:
            continue
        r = total[role(tid)]
        w = find_window(slow, starts, t)
        if ev == "exceptions:page_fault_user":
            r["faults"] += 1
            if w:
                a = re.search(r"address=(0x[0-9a-f]+)", rest)
                ip = re.search(r"ip=(0x[0-9a-f]+)", rest)
                where = user_sym(int(a.group(1), 16)).split("+")[0] if a else "?"
                who = user_bucket(int(ip.group(1), 16)) if ip else "?"
                w.thr[tid]["faults"][f"{where} by {who}"] += 1
        elif ev == "raw_syscalls:sys_enter":
            nr = re.search(r"NR (\d+)", rest)
            name = SYSCALLS.get(int(nr.group(1)), nr.group(1)) if nr else "?"
            r["sys"][name] += 1
            if w:
                w.thr[tid]["sys"][name] += 1
        elif ev == "signal:signal_deliver" and w:
            w.thr[tid]["sys"]["signal"] += 1

    # ---- summarise
    window_s = ((stop_ns or slow[-1].t1 if slow else 0) - (t_play + PLAY_LAG_NS)) / 1e9 if (stop_ns or slow) else 0
    out["totals"] = {}
    for r, v in total.items():
        out["totals"][r] = {
            "ghz": round(v["cyc"] / v["ref"] * TSC_GHZ, 2) if v["ref"] else None,
            "ipc": round(v["ins"] / v["cyc"], 2) if v["cyc"] else None,
            "kernel_share": round(sum(v["kernel"].values()) / v["samples"], 3) if v["samples"] else None,
            "top_kernel": v["kernel"].most_common(6),
            "faults_per_s": round(v["faults"] / window_s, 1) if window_s else None,
            "preempted_per_s": round(v["preempted"] / window_s, 1) if window_s else None,
            "irq_us_per_s": round((v["irq_ns"] + v["softirq_ns"]) / 1e3 / window_s, 1) if window_s else None,
            "syscalls_per_s": {k: round(n / window_s, 1) for k, n in v["sys"].most_common(6)} if window_s else None,
        }
    for w, rec in zip(slow, out["slow"]):
        thr = []
        for tid, v in w.thr.items():
            if not v["oncpu"] and not v["samples"]:
                continue
            thr.append({
                "tid": tid, "role": "callback" if tid == cb_tid else tasks.get(tid, "?"),
                "oncpu_us": round(v["oncpu"] / 1e3), "samples": v["samples"],
                "ghz": round(v["cyc"] / v["ref"] * TSC_GHZ, 2) if v["ref"] else None,
                "ipc": round(v["ins"] / v["cyc"], 2) if v["cyc"] else None,
                "kernel_samples": v["kfrac"], "top_kernel": v["kernel"].most_common(3),
                "top_user": v["user"].most_common(6),
                "preempted": v["preempted"], "preempted_by": dict(v["preempted_by"]),
                "rq_wait_us": round(v["rq_wait"] / 1e3), "rq_max_us": round(v["rq_max"] / 1e3),
                "faults": dict(v["faults"]), "syscalls": dict(v["sys"]),
                "irq_us": round((v["irq_ns"] + v["softirq_ns"]) / 1e3), "irqs": dict(v["irqs"]),
            })
        thr.sort(key=lambda x: -x["oncpu_us"])
        rec["threads"] = thr[:4]
    report.append(out)


def main():
    run = sys.argv[1]
    report = []
    for interface in sorted(glob.glob(f"{run}/bench/sets/*/raw/interface")):
        analyse_set(interface, report)
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, default=str)
    for s in report:
        print(f"\n######## {s['set']}: {s['blocks_counted']} blocks, {len(s['slow'])} over 700 us "
              f"({sum(1 for x in s['slow'] if x['late'])} late); callback tid {s['callback_tid']}")
        print(f"  page faults in Live: {s['faults_all']}; over 10 us: {s['faults_over_10us']} "
              f"(p50 / max {s['long_fault_us']}), {s['faults_over_10us_in_slow_blocks']} of them inside slow blocks")
        by_pass = collections.Counter((x["pass"], x["late"]) for x in s["slow"])
        print("  by loop pass (pass: late/slow): " + ", ".join(
            f"{p}: {by_pass[(p, True)]}/{by_pass[(p, True)] + by_pass[(p, False)]}" for p in sorted({x['pass'] for x in s['slow']})))
        for r, v in s.get("totals", {}).items():
            print(f"  whole window, {r}: {v['ghz']} GHz, IPC {v['ipc']}, kernel {v['kernel_share']}, faults/s {v['faults_per_s']}, "
                  f"preempted/s {v['preempted_per_s']}, irq us/s {v['irq_us_per_s']}, syscalls/s {v['syscalls_per_s']}")
            print(f"     top kernel leaves: {v['top_kernel']}")
        for x in s["slow"]:
            print(f"\n  {'LATE' if x['late'] else 'slow'} seq {x['seq']} t {x['t_s']} s  beat {x['beat']} (pass {x['pass']}, "
                  f"loop beat {x['loop_beat']})  elapsed {x['elapsed_us']} us  slack {x['slack_us']} us")
            if x.get("long_faults"):
                print(f"    faults over 10 us: {x['long_faults']}")
            for th in x.get("threads", []):
                print(f"    {th['role']:12} tid {th['tid']}: on-CPU {th['oncpu_us']} us, {th['samples']} samples, {th['ghz']} GHz, "
                      f"IPC {th['ipc']}, kernel samples {th['kernel_samples']}, preempted {th['preempted']} {th['preempted_by']}, "
                      f"rq wait {th['rq_wait_us']} us (max {th['rq_max_us']}), faults {th['faults']}, syscalls {th['syscalls']}, "
                      f"irq {th['irq_us']} us {th['irqs']}")
                if th["top_kernel"]:
                    print(f"       kernel: {th['top_kernel']}")
                if th["top_user"]:
                    print(f"       user:   {th['top_user']}")


if __name__ == "__main__":
    main()
