#!/usr/bin/env python3
"""pwerr_analyze.py BENCH_DIR [--node REGEX] [--json FILE]: what made Live's node miss PipeWire's cycle, per error.

For a bench run traced with profiler/trials/pwerr-capture (profiler/trials/pwerr-run.sh); run on the laptop from the
checkout root. Per Set (BENCH_DIR/sets/*/raw/interface):
1. The error cycles: every graph cycle in profiler.json where the xrun count of Live's node (NODE_RE) or of the driver
   rose, with the cycle's start and period, and when the driver and Live's node were signalled, woke and finished.
2. A cause class from those times:
     driver late   PipeWire's driver (its data loop) woke more than LATE of a period after the cycle's start
     woke late     Live's node was signalled in time but woke more than LATE of a period later
     ran long      Live's node woke in time and finished after the deadline (the next cycle's start)
     unseen        none of these: the times look in time (an SMI, or a node other than Live's)
3. The evidence in that cycle from perf-sched.data (and blocks.txt): for a late wake, the task the woken thread's CPU
   ran before it, the IRQs and softirqs there, and the idle state the CPU left; for a long run, the PipeASIO block and
   where pipeasio-rt and the AudioCalc threads spent the cycle (running, preempted, asleep and who woke them).
4. A summary: errors per class, the most common blockers, IRQs and idle states, and the SMI and throttle counts.
"""
import argparse
import bisect
import collections
import glob
import json
import os
import re
import subprocess
import sys

NODE_RE = re.compile(r"Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]")   # scripts/bench-report.py DEFAULT_NODE_RE
LATE = 0.30          # of a period: a wake later than this after its signal (or the cycle start) is late
PERF_LINE = re.compile(r"^\s*(?P<comm>.+?)\s+(?P<pid>-?\d+)/(?P<tid>-?\d+)\s+\[(?P<cpu>\d+)\]\s+(?P<sec>\d+)\.(?P<nsec>\d+):"
                       r"\s+(?P<event>[\w:]+):\s*(?P<trace>.*)$")
IDLE_EXIT = 4294967295


# ---------------------------------------------------------------- pw-profiler
def profiler_cycles(path):
    """[{t0, period, deadline, driver: {...}, nodes: [{name, signal, awake, finish, xruns, status}]}] from pw-profiler -J.

    Each JSON object is one profiler sample: the clock of the cycle (its start in ns, its duration in samples at its
    rate, the next cycle's start) and a block per node with its signal, awake and finish times and xrun count."""
    cycles = []
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return cycles
    decoder, i = json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i] in " \t\r\n,[]":
            i += 1
        if i >= len(text):
            break
        try:
            obj, i = decoder.raw_decode(text, i)
        except ValueError:
            break
        for sample in (obj if isinstance(obj, list) else [obj]):
            cycle = cycle_of(sample)
            if cycle:
                cycles.append(cycle)
    return cycles


def first(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and k in d:
            return d[k]
    return default


def node_of(block):
    return {"id": first(block, "id"), "name": str(first(block, "name", default="")),
            "signal": int(first(block, "signal", "signal-time", default=0) or 0),
            "awake": int(first(block, "awake", "awake-time", default=0) or 0),
            "finish": int(first(block, "finish", "finish-time", default=0) or 0),
            "status": first(block, "status"), "xruns": int(first(block, "xrun-count", "xrun_count", "xruns", default=0) or 0)}


def cycle_of(sample):
    """One cycle from a sample, or None (the exact key names are checked against a real capture)."""
    clock = first(sample, "clock")
    driver = first(sample, "driver")
    followers = first(sample, "followers", default=[])
    if not isinstance(clock, dict) or not isinstance(driver, dict):
        return None
    t0 = int(first(clock, "nsec", default=0) or 0)
    rate = first(clock, "rate")
    duration = int(first(clock, "duration", default=0) or 0)
    if isinstance(rate, str) and "/" in rate:
        num, den = rate.split("/")
        period = int(duration * int(num) * 1e9 / int(den)) if int(den) else 0
    elif isinstance(rate, dict):
        period = int(duration * int(rate.get("num", 1)) * 1e9 / int(rate.get("denom", 1) or 1))
    else:
        period = 0
    nxt = int(first(clock, "next-nsec", "next_nsec", default=0) or 0)
    if not period and nxt > t0:
        period = nxt - t0
    info = first(sample, "info", default={})
    return {"t0": t0, "period": period, "deadline": nxt or (t0 + period),
            "xruns": int(first(info, "xrun-count", "xrun_count", default=0) or 0),
            "driver": node_of(driver), "nodes": [node_of(f) for f in followers if isinstance(f, dict)]}


def error_cycles(cycles, node_re):
    """[(cycle, live node, what rose)]: the cycles where Live's node's or the driver's xrun count rose."""
    out, last = [], {}
    for c in cycles:
        live = next((n for n in c["nodes"] if node_re.search(n["name"])), None)
        rose = []
        for key, n in (("live", live), ("driver", c["driver"])):
            if n is None:
                continue
            ident = (key, n["id"])
            if ident in last and n["xruns"] > last[ident]:
                rose.append(key)
            last[ident] = n["xruns"]
        if rose:
            out.append((c, live, rose))
    return out


def classify(c, live):
    p = c["period"] or 1
    d = c["driver"]
    if d["awake"] and d["awake"] - c["t0"] > LATE * p:
        return "driver late"
    if live is None or not live["signal"]:
        return "unseen"
    if not live["awake"] or live["awake"] - live["signal"] > LATE * p:
        return "woke late"
    if not live["finish"] or live["finish"] > c["deadline"]:
        return "ran long"
    return "unseen"


# ---------------------------------------------------------------- perf and blocks
def perf_events(data):
    """[(ns, cpu, comm, pid, tid, event, fields)] from perf-sched.data, by time."""
    cmd = ["perf", "script", "-i", data, "-F", "comm,pid,tid,cpu,time,event,trace", "--ns"]
    run = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if run.returncode != 0:
        run = subprocess.run(["sudo", "-n"] + cmd, capture_output=True, text=True, errors="replace")
    events = []
    for line in run.stdout.splitlines():
        m = PERF_LINE.match(line)
        if not m:
            continue
        ns = int(m["sec"]) * 1000000000 + int(m["nsec"].ljust(9, "0")[:9])
        fields = dict(re.findall(r"(\w+)=(\S+)", m["trace"]))
        events.append((ns, int(m["cpu"]), m["comm"].strip(), int(m["pid"]), int(m["tid"]), m["event"], fields))
    events.sort(key=lambda e: e[0])
    return events


def blocks(path):
    """[(start ns, elapsed ns, slack ns)] of PipeASIO's blocks, by start."""
    out = []
    try:
        for line in open(path, errors="replace"):
            p = line.split()
            if len(p) == 5 and p[0] == "B":
                out.append((int(p[2]), int(p[3]), int(p[4])))
    except OSError:
        pass
    out.sort()
    return out


def counters(path):
    out = {"smi_count": None, "throttle": {}}
    try:
        for line in open(path):
            p = line.split()
            if p[:1] == ["smi_count"] and len(p) > 1 and p[1].isdigit():
                out["smi_count"] = int(p[1])
            elif p[:1] == ["throttle"] and len(p) == 4:
                out["throttle"][p[1]] = (int(p[2]), int(p[3]))
    except OSError:
        pass
    return out


class Trace:
    def __init__(self, events):
        self.events = events
        self.times = [e[0] for e in events]

    def between(self, a, b):
        return self.events[bisect.bisect_left(self.times, a):bisect.bisect_right(self.times, b)]

    def before(self, t, pred, span):
        for e in reversed(self.between(t - span, t)):
            if pred(e):
                return e
        return None


def wake_evidence(trace, comm, signal, awake, period):
    """What stood between COMM's signal and its running: its waking (by whom, to which CPU), the switch that ran it
    (the task before it on that CPU), the IRQs and softirqs there, and the idle state that CPU left."""
    ev = {}
    switch_in = next((e for e in trace.between(signal - period, awake + period)
                      if e[5] == "sched:sched_switch" and e[6].get("next_comm", "").startswith(comm) and e[0] >= signal - period // 4), None)
    if switch_in is None:
        return ev
    cpu = switch_in[1]
    ev["cpu"] = cpu
    ev["ran_after_ns"] = switch_in[0] - signal
    ev["before"] = "%s (prio %s, %s)" % (switch_in[6].get("prev_comm"), switch_in[6].get("prev_prio"), switch_in[6].get("prev_state"))
    waking = trace.before(switch_in[0], lambda e: e[5] == "sched:sched_waking" and e[6].get("comm", "").startswith(comm), 2 * period)
    if waking:
        ev["woken_by"] = "%s on CPU %d, %d us before running" % (waking[2], waking[1], (switch_in[0] - waking[0]) // 1000)
    irqs = collections.Counter()
    for e in trace.between(signal - period // 2, switch_in[0]):
        if e[1] == cpu and e[5] in ("irq:irq_handler_entry", "irq:softirq_entry"):
            irqs[e[6].get("name") or e[6].get("action") or e[6].get("vec")] += 1
    if irqs:
        ev["irqs_on_cpu"] = dict(irqs)
    idle = trace.before(switch_in[0], lambda e: e[1] == cpu and e[5] == "power:cpu_idle", 4 * period)
    if idle and int(idle[6].get("state", "0")) == IDLE_EXIT:
        entry = trace.before(idle[0], lambda e: e[1] == cpu and e[5] == "power:cpu_idle" and int(e[6].get("state", "0")) != IDLE_EXIT, 50 * period)
        ev["cpu_was_idle"] = "state %s until %d us before running" % (entry[6].get("state") if entry else "?", (switch_in[0] - idle[0]) // 1000)
    return ev


def run_evidence(trace, blks, awake, finish, deadline):
    """Where pipeasio-rt and the AudioCalc threads spent [awake, max(finish, deadline)]: the PipeASIO block, pipeasio-rt's
    switches out (preempted by whom, or asleep until who woke it), each worker's time on CPU."""
    end = max(finish, deadline)
    ev = {}
    i = bisect.bisect_left(blks, (awake - (deadline - awake),))
    block = next((b for b in blks[i:i + 4] if b[0] <= end), None)
    if block:
        ev["block"] = "elapsed %d us, slack %d us" % (block[1] // 1000, block[2] // 1000)
    outs = []
    oncpu = collections.defaultdict(int)
    since = {}
    for e in trace.between(awake, end):
        if e[5] != "sched:sched_switch":
            continue
        prev, nxt = e[6].get("prev_comm", ""), e[6].get("next_comm", "")
        if prev == "pipeasio-rt":
            outs.append("%s at +%d us (%s)" % ("preempted by " + nxt if e[6].get("prev_state", "").startswith("R") else "slept",
                                              (e[0] - awake) // 1000, nxt))
        if nxt.startswith("AudioCalc"):
            since[e[6].get("next_pid")] = e[0]
        if prev.startswith("AudioCalc") and e[6].get("prev_pid") in since:
            oncpu[prev + ":" + e[6].get("prev_pid")] += e[0] - since.pop(e[6].get("prev_pid"))
    if outs:
        ev["pipeasio_rt_switched_out"] = outs[:6]
    if oncpu:
        ev["worker_us_on_cpu"] = {k: v // 1000 for k, v in sorted(oncpu.items())}
    return ev


# ---------------------------------------------------------------- per Set
def analyse(interface, node_re):
    name = interface.split("/sets/")[1].split("/")[0].split("-", 1)[-1].replace("Benchmark_", "")
    cycles = profiler_cycles(os.path.join(interface, "profiler.json"))
    errs = error_cycles(cycles, node_re)
    trace = Trace(perf_events(os.path.join(interface, "perf-sched.data"))) if errs else Trace([])
    blks = blocks(os.path.join(interface, "blocks.txt"))
    c0, c1 = counters(os.path.join(interface, "counters-start.txt")), counters(os.path.join(interface, "counters-stop.txt"))
    smi = (c1["smi_count"] - c0["smi_count"]) if c0["smi_count"] is not None and c1["smi_count"] is not None else None
    throttle = sum(c1["throttle"].get(k, (0, 0))[0] - v[0] for k, v in c0["throttle"].items())
    out = []
    for c, live, rose in errs:
        cls = classify(c, live)
        p = c["period"]
        rec = {"t0": c["t0"], "rose": rose, "class": cls, "period_us": p // 1000,
               "driver_awake_us": (c["driver"]["awake"] - c["t0"]) // 1000 if c["driver"]["awake"] else None}
        if live:
            rec.update({"live_wake_us": (live["awake"] - live["signal"]) // 1000 if live["awake"] and live["signal"] else None,
                        "live_run_us": (live["finish"] - live["awake"]) // 1000 if live["finish"] and live["awake"] else None,
                        "live_finish_after_deadline_us": (live["finish"] - c["deadline"]) // 1000 if live["finish"] else None})
        if cls == "woke late" and live:
            rec["evidence"] = wake_evidence(trace, "pipeasio-rt", live["signal"], live["awake"] or live["signal"] + p, p)
        elif cls == "driver late":
            rec["evidence"] = wake_evidence(trace, "data-loop", c["t0"], c["driver"]["awake"], p)
        elif cls == "ran long" and live:
            rec["evidence"] = run_evidence(trace, blks, live["awake"], live["finish"] or c["deadline"], c["deadline"])
        out.append(rec)
    return {"set": name, "cycles": len(cycles), "errors": out, "smi_count_delta": smi, "core_throttle_delta": throttle,
            "blocks": len(blks), "live_node": next((n["name"] for c in cycles[:50] for n in c["nodes"] if node_re.search(n["name"])), None)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bench_dir")
    ap.add_argument("--node", default=NODE_RE.pattern, help="regex for Live's node name")
    ap.add_argument("--json")
    a = ap.parse_args()
    node_re = re.compile(a.node)
    reports = [analyse(d, node_re) for d in sorted(glob.glob(os.path.join(a.bench_dir, "sets", "*", "raw", "interface")))]
    if a.json:
        json.dump(reports, open(a.json, "w"), indent=1)
    classes = collections.Counter()
    for r in reports:
        print(f"== {r['set']}: {r['cycles']} cycles profiled, {len(r['errors'])} error cycles; Live's node {r['live_node']!r}; "
              f"{r['blocks']} PipeASIO blocks; SMIs {r['smi_count_delta']}; core throttle events {r['core_throttle_delta']}")
        for e in r["errors"]:
            classes[e["class"]] += 1
            times = ", ".join(f"{k} {e[k]}" for k in ("driver_awake_us", "live_wake_us", "live_run_us", "live_finish_after_deadline_us")
                              if e.get(k) is not None)
            print(f"   {e['class']:<11} ({'+'.join(e['rose'])}) period {e['period_us']} us: {times}")
            for k, v in (e.get("evidence") or {}).items():
                print(f"      {k}: {v}")
    if classes:
        print("Errors by class: " + ", ".join(f"{k} {v}" for k, v in classes.most_common()))


if __name__ == "__main__":
    main()
