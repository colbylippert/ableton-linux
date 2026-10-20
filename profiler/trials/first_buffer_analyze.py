#!/usr/bin/env python3
"""first_buffer_analyze.py OUT_DIR [--json]: how PipeASIO and PipeWire started Live's audio (profiler/trials/first-buffer.sh).

From probes.txt (PipeASIO's USDT probes from before Live started; CLOCK_MONOTONIC ns):
- each driver instance (a block sequence restarting at 1: Live builds its buffers again, e.g. when a Set loads);
- the first cycle and the first block: the graph's quantum (clock.duration) against Live's block size, the block's
  flags (1 admitted, 2 time info, 4 muted), how long after the cycle's start it ran;
- the muted stretch: blocks with flag 4 before the first admitted one, and how long it lasted;
- the hand-over to one block per cycle: the first block at the graph's quantum, admitted and not muted, and from there
  on the in-sync check: cycles per block (exactly one), the block's phase in its cycle (block_start after the cycle
  start; Live's bufferSwitch call after it), Live's time in bufferSwitch, the slack at block_end against the deadline,
  frames missed (cycle_end), and blocks of a size other than the quantum;
- the play instant (the bench's /abl/bench/play, caught leaving by a sendto probe on the same clock): the blocks from
  200 ms before to 3 s after it, the first one where Live's time in bufferSwitch rises (the transport starting in the
  audio engine), and over the window the slack, late blocks, cycles per block, missed frames, muting and quantum;
- the per-second lines after the full record: muted, mismatched, late blocks, missed frames, the phase range.
Also the PipeASIO lines in live.log (the launcher log for this run) and the telemetry aggregates, if any.
"""
import argparse
import json
import os
import re
import statistics


def parse(path):
    events, seconds = [], []
    for line in open(path, errors="replace"):
        p = line.split()
        if not p:
            continue
        kind = p[0]
        try:
            if kind == "CS" and len(p) == 8:
                events.append({"k": "CS", "t": int(p[1]), "tid": int(p[2]), "clock": int(p[3]), "next": int(p[4]),
                               "duration": int(p[5]), "position": int(p[6]), "flags": int(p[7])})
            elif kind == "CE" and len(p) == 5:
                events.append({"k": "CE", "t": int(p[1]), "tid": int(p[2]), "missed": int(p[3]), "delivered": int(p[4])})
            elif kind == "BS" and len(p) == 9:
                events.append({"k": "BS", "t": int(p[1]), "tid": int(p[2]), "seq": int(p[3]), "nframes": int(p[4]),
                               "rate": int(p[5]), "clock": int(p[6]), "deadline": int(p[7]), "flags": int(p[8])})
            elif kind in ("BL", "AL") and len(p) == 3:
                events.append({"k": kind, "t": int(p[1]), "seq": int(p[2])})
            elif kind == "BE" and len(p) == 5:
                events.append({"k": "BE", "t": int(p[1]), "seq": int(p[2]), "flags": int(p[3]), "missed": int(p[4])})
            elif kind == "OSC" and len(p) >= 3:
                events.append({"k": "OSC", "t": int(p[1]), "addr": p[2]})
            elif kind == "S":
                d = dict(x.split("=", 1) for x in p[2:] if "=" in x)
                d["t"] = int(p[1])
                seconds.append(d)
        except ValueError:
            continue
    return events, seconds


def blocks_of(events):
    """Per block: its BS fields plus the cycle it ran in (the last CS before it), BL, AL and BE times, and the cycles
    between it and the previous block."""
    out, last_cs, cycles_since = [], None, 0
    by_seq = {}
    for e in events:
        if e["k"] == "CS":
            last_cs = e
            cycles_since += 1
        elif e["k"] == "BS":
            b = dict(e)
            b["cycle"] = last_cs
            b["cycles_since_prev"] = cycles_since
            cycles_since = 0
            out.append(b)
            by_seq[e["seq"]] = b
        elif e["k"] in ("BL", "AL", "BE") and e["seq"] in by_seq:
            by_seq[e["seq"]][e["k"]] = e
    return out


def episodes(blocks):
    eps, cur = [], []
    for b in blocks:
        if b["seq"] == 1 and cur:
            eps.append(cur)
            cur = []
        cur.append(b)
    if cur:
        eps.append(cur)
    return eps


def us(ns):
    return None if ns is None else round(ns / 1000, 1)


def pct(values, q):
    v = sorted(values)
    return v[min(len(v) - 1, int(q * len(v)))] if v else None


def episode_report(ep, t_ref):
    first = ep[0]
    c = first["cycle"]
    rep = {"blocks": len(ep), "first_block": {
        "at_ms": round((first["t"] - t_ref) / 1e6, 1), "seq": first["seq"], "nframes": first["nframes"],
        "graph_quantum": c["duration"] if c else None, "flags": first["flags"],
        "after_cycle_start_us": us(first["t"] - first["clock"]), "deadline_after_start_us": us(first["deadline"] - first["t"])}}
    muted = [b for b in ep if b["flags"] & 4]
    rep["muted_blocks"] = len(muted)
    sync = next((i for i, b in enumerate(ep) if b["cycle"] and b["nframes"] == b["cycle"]["duration"]
                 and b["flags"] & 1 and not b["flags"] & 4), None)
    if sync is None:
        rep["in_sync_from"] = None
        return rep
    s = ep[sync]
    rep["in_sync_from"] = {"block": sync + 1, "at_ms": round((s["t"] - t_ref) / 1e6, 1),
                           "after_first_block_ms": round((s["t"] - first["t"]) / 1e6, 1), "quantum": s["nframes"]}
    steady = ep[sync + 1:]
    if steady:
        phase = [b["t"] - b["clock"] for b in steady]
        call = [b["BL"]["t"] - b["clock"] for b in steady if "BL" in b]
        live = [b["AL"]["t"] - b["BL"]["t"] for b in steady if "AL" in b and "BL" in b]
        slack = [b["deadline"] - b["BE"]["t"] for b in steady if "BE" in b]
        rep["steady"] = {
            "blocks": len(steady),
            "cycles_per_block": dict(sorted(((k, sum(1 for b in steady if b["cycles_since_prev"] == k))
                                             for k in {b["cycles_since_prev"] for b in steady}))),
            "other_size_blocks": sum(1 for b in steady if b["cycle"] and b["nframes"] != b["cycle"]["duration"]),
            "muted": sum(1 for b in steady if b["flags"] & 4),
            "late": sum(1 for x in slack if x < 0),
            "phase_us_p50_p99_max": [us(pct(phase, .5)), us(pct(phase, .99)), us(max(phase))],
            "bufferswitch_call_us_p50_p99_max": [us(pct(call, .5)), us(pct(call, .99)), us(max(call))] if call else None,
            "live_us_p50_p99_max": [us(pct(live, .5)), us(pct(live, .99)), us(max(live))] if live else None,
            "slack_us_min_p01_p50": [us(min(slack)), us(pct(slack, .01)), us(pct(slack, .5))] if slack else None,
            "missed_frames": sum(b["BE"]["missed"] for b in steady if "BE" in b)}
    return rep


def play_window(blocks, cs, play_t, before_ns=200_000_000, after_ns=3_000_000_000):
    """The blocks around the play instant: the transport's first heavy block and the window's timing."""
    pre = [b["AL"]["t"] - b["BL"]["t"] for b in blocks
           if "AL" in b and "BL" in b and play_t - 1_000_000_000 <= b["t"] < play_t]
    base = statistics.median(pre) if pre else None
    win = [b for b in blocks if play_t - before_ns <= b["t"] <= play_t + after_ns]
    after = [b for b in win if b["t"] >= play_t]
    rep = {"blocks_in_window": len(win), "live_us_before_p50": us(base)}
    if base:
        first_heavy = next((b for b in after if "AL" in b and "BL" in b and b["AL"]["t"] - b["BL"]["t"] > 2 * base), None)
        if first_heavy:
            rep["transport_start"] = {
                "after_play_ms": round((first_heavy["t"] - play_t) / 1e6, 2), "seq": first_heavy["seq"],
                "live_us": us(first_heavy["AL"]["t"] - first_heavy["BL"]["t"]),
                "phase_us": us(first_heavy["t"] - first_heavy["clock"]),
                "slack_us": us(first_heavy["deadline"] - first_heavy["BE"]["t"]) if "BE" in first_heavy else None,
                "cycles_since_prev": first_heavy["cycles_since_prev"], "flags": first_heavy["flags"]}
    slack = [b["deadline"] - b["BE"]["t"] for b in after if "BE" in b]
    live = [b["AL"]["t"] - b["BL"]["t"] for b in after if "AL" in b and "BL" in b]
    rep.update({
        "late": sum(1 for x in slack if x < 0),
        "slack_us_min": us(min(slack)) if slack else None,
        "live_us_max": us(max(live)) if live else None,
        "not_one_cycle_per_block": sum(1 for b in after if b["cycles_since_prev"] != 1),
        "muted": sum(1 for b in after if b["flags"] & 4),
        "missed_frames": sum(b["BE"]["missed"] for b in after if "BE" in b),
        "quanta": sorted({c["duration"] for c in cs if play_t - before_ns <= c["t"] <= play_t + after_ns})})
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out_dir")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    events, seconds = parse(os.path.join(a.out_dir, "probes.txt"))
    cs = [e for e in events if e["k"] == "CS"]
    t_ref = cs[0]["t"] if cs else (events[0]["t"] if events else 0)
    blocks = blocks_of(events)
    eps = episodes(blocks)
    quanta = []
    for e in cs:
        if not quanta or quanta[-1][1] != e["duration"]:
            quanta.append((round((e["t"] - t_ref) / 1e6, 1), e["duration"]))
    result = {"cycles_recorded": len(cs), "blocks_recorded": len(blocks), "quantum_changes_ms": quanta[:20],
              "first_cycle": {k: cs[0][k] for k in ("duration", "position", "flags")} if cs else None,
              "episodes": [episode_report(ep, t_ref) for ep in eps]}
    plays = [e["t"] for e in events if e["k"] == "OSC" and e["addr"] == "/abl/bench/play"]
    result["play"] = [dict(play_window(blocks, cs, t), at_ms=round((t - t_ref) / 1e6, 1)) for t in plays]
    later = [s for s in seconds]
    if later:
        def tot(key):
            return sum(int(s.get(key, 0) or 0) for s in later)
        result["per_second"] = {"seconds": len(later), "muted": tot("muted"), "mismatched": tot("mismatched"),
                                "late": tot("late"), "missed_frames": tot("missed"),
                                "quanta": sorted({s.get("quantum") for s in later}),
                                "phase_max_us": max(int(s["phase_ns"].split("/")[2]) for s in later if "phase_ns" in s) / 1000
                                if any("phase_ns" in s for s in later) else None}
    log = os.path.join(a.out_dir, "live.log")
    if os.path.exists(log):
        lines = [l.rstrip() for l in open(log, errors="replace") if re.search(r"pipeasio|asio|quantum|mute|telemetry", l, re.I)]
        result["pipeasio_log_lines"] = len(lines)
        result["pipeasio_log_first"] = [l[:200] for l in lines[:12]]
    if a.json:
        print(json.dumps(result, indent=1))
        return
    print(f"cycles recorded {result['cycles_recorded']}, blocks {result['blocks_recorded']}; graph quantum over time "
          f"(ms after the first cycle: frames): {result['quantum_changes_ms']}")
    for i, ep in enumerate(result["episodes"], 1):
        print(f"== driver instance {i}: {ep['blocks']} blocks recorded")
        print(f"   first block: {ep['first_block']}")
        print(f"   muted blocks: {ep['muted_blocks']}; in sync (one block per cycle at the quantum) from: {ep['in_sync_from']}")
        for k, v in (ep.get("steady") or {}).items():
            print(f"   steady {k}: {v}")
    for pl in result["play"]:
        print(f"== play at {pl['at_ms']} ms after the first cycle:")
        for k, v in pl.items():
            if k != "at_ms":
                print(f"   {k}: {v}")
    if not result["play"]:
        print("== no /abl/bench/play seen by the sendto probe")
    if "per_second" in result:
        print(f"after the full record, per second: {result['per_second']}")
    if "pipeasio_log_lines" in result:
        print(f"PipeASIO lines in the launcher log: {result['pipeasio_log_lines']}")
        for l in result["pipeasio_log_first"]:
            print(f"   {l}")


if __name__ == "__main__":
    main()
