"""Analyse a D0004 census (census-capture's census.json per Set window) into the kernel plan's gates.

usage: analyze.py BENCH_DIR      (the bench output of d0004.sh; every sets/*/**/census.json is read)

Per Set it prints, then a JSON summary as the last line:
  rates     blocks per second; sets, resets and waits per block by role (other Live thread, AudioCalc, pipeasio-rt,
            wineserver)
  K5        the share of event calls a LiveSync fast path could take without a syscall: sets and resets with no
            waiter queued and no wait-all hint, waits satisfied without sleeping, polls that timed out without
            sleeping; plus the share of audio waits that are alertable or wait on more than one object
  K3        the audio threads' sleeps inside waits: the share no longer than 5/10/20/40/100 us (the spin budget)
  K4/K7     the idle state an audio thread's CPU came out of when it was woken, and the wake latency per state;
            the K4 gate fires when at least 10 % of audio wakes come from C2 or deeper
  K6        hard and soft IRQ time per second on the audio CPUs (0, 2, 4, 6, 8, 10) and on the others
"""
import glob
import json
import os
import statistics
import sys

ROLES = {0: "live", 1: "AudioCalc", 2: "pipeasio-rt", 3: "wineserver"}
AUDIO_CPUS = {0, 2, 4, 6, 8, 10}
ETIMEDOUT = -110


def val(x):
    if x in ("true", True):
        return 1
    if x in ("false", False):
        return 0
    try:
        return int(x)
    except (TypeError, ValueError):
        return x


def entries(m):
    """a bpftrace JSON map body -> [(key, value)]: {"k1,k2": v}, [{"key": [...], "value": v}], or an unkeyed value"""
    if isinstance(m, dict):
        return list(m.items())
    if isinstance(m, list) and m and isinstance(m[0], dict) and "key" in m[0]:
        return [(e["key"], e["value"]) for e in m]
    return [((), m)]


def keytuple(k):
    if isinstance(k, (list, tuple)):
        return tuple(val(x) for x in k)
    return tuple(val(x.strip().strip('"')) for x in str(k).strip("[]()").split(","))


def load(path):
    """census.json -> (per-second rows, {map name: {key tuple: value}})"""
    secs, maps = [], {}
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t, d = o.get("type"), o.get("data")
        if t == "printf" and isinstance(d, str) and d.startswith("S "):
            secs.append([int(v) for v in d.split()[1:6]])
        elif t in ("map", "hist", "lhist", "stats") and isinstance(d, dict):
            for name, m in d.items():
                maps[name] = {keytuple(k) if k != () else (): v for k, v in entries(m)}
    return secs, maps


def buckets_quantile(buckets, frac):
    """approximate quantile from bpftrace hist/lhist buckets [{min, max, count}]"""
    total = sum(b.get("count", 0) for b in buckets)
    if not total:
        return None
    acc = 0
    for b in buckets:
        acc += b.get("count", 0)
        if acc >= frac * total:
            return b.get("max", b.get("min"))
    return buckets[-1].get("max", buckets[-1].get("min"))


def share_le(buckets, limit):
    total = sum(b.get("count", 0) for b in buckets)
    if not total:
        return None
    return round(sum(b.get("count", 0) for b in buckets if b.get("max") is not None and b["max"] <= limit) / total, 3)


def analyse(path):
    secs, maps = load(path)
    play = [s for s in secs if s[1] > 0]
    n_sec = len(play) or 1
    blocks = sum(s[1] for s in play) or 1
    res = {"seconds": len(play), "blocks_per_s": round(statistics.median(s[1] for s in play), 1) if play else 0}

    sets, resets, waits = maps.get("@set", {}), maps.get("@reset", {}), maps.get("@wait", {})
    per_block = {}
    for role, name in ROLES.items():
        s = sum(v for k, v in sets.items() if k[0] == role)
        r = sum(v for k, v in resets.items() if k[0] == role)
        w = sum(v for k, v in waits.items() if k[0] == role)
        if s or r or w:
            per_block[name] = {"sets": round(s / blocks, 1), "resets": round(r / blocks, 1), "waits": round(w / blocks, 1)}
    res["per_block"] = per_block

    live = lambda k: k[0] in (0, 1, 2)
    n_set = sum(v for k, v in sets.items() if live(k)) or 1
    n_reset = sum(v for k, v in resets.items() if live(k)) or 1
    n_wait = sum(v for k, v in waits.items() if live(k)) or 1
    # @set[role, manual, signaled, any waiter, all hint, pulse]; @reset[role, manual, signaled, any waiter, all hint]
    # @wait[role, wait_all, count, alertable, poll, slept, retval]
    set_free = sum(v for k, v in sets.items() if live(k) and not k[3] and not k[4] and not k[5])
    set_noop = sum(v for k, v in sets.items() if live(k) and k[2])
    reset_free = sum(v for k, v in resets.items() if live(k) and not k[3] and not k[4])
    reset_noop = sum(v for k, v in resets.items() if live(k) and not k[2])
    wait_fast = sum(v for k, v in waits.items() if live(k) and not k[5] and k[6] == 0)
    poll_miss = sum(v for k, v in waits.items() if live(k) and not k[5] and k[4] == 1 and k[6] == ETIMEDOUT)
    audio_w = {k: v for k, v in waits.items() if k[0] in (1, 2)}
    n_audio_w = sum(audio_w.values()) or 1
    res["K5"] = {
        "sets_no_waiter": round(set_free / n_set, 3), "sets_already_signaled": round(set_noop / n_set, 3),
        "resets_no_waiter": round(reset_free / n_reset, 3), "resets_already_reset": round(reset_noop / n_reset, 3),
        "waits_satisfied_without_sleep": round(wait_fast / n_wait, 3), "polls_timed_out_without_sleep": round(poll_miss / n_wait, 3),
        "audio_waits_alertable": round(sum(v for k, v in audio_w.items() if k[3]) / n_audio_w, 3),
        "audio_waits_multi_object": round(sum(v for k, v in audio_w.items() if k[2] > 1 or k[1]) / n_audio_w, 3),
        "syscall_free_share": round((set_free + reset_free + wait_fast + poll_miss) / (n_set + n_reset + n_wait), 3),
    }

    lin = maps.get("@sleep_lin", {})
    k3 = {}
    for role in (1, 2):
        b = lin.get((role,))
        if isinstance(b, list):
            k3[ROLES[role]] = {f"le_{u}us": share_le(b, u) for u in (5, 10, 20, 40, 100)}
            k3[ROLES[role]]["median_us"] = buckets_quantile(b, 0.5)
    res["K3_sleeps"] = k3

    wf = maps.get("@wake_from", {})
    k4 = {}
    for role in (1, 2):
        tot = sum(v for k, v in wf.items() if k[0] == role) or 1
        k4[ROLES[role]] = {("busy" if k[1] == 99 else f"state{k[1]}"): round(v / tot, 3) for k, v in sorted(wf.items()) if k[0] == role}
    deep = sum(v for k, v in wf.items() if k[0] in (1, 2) and k[1] != 99 and k[1] >= 2)
    all_audio = sum(v for k, v in wf.items() if k[0] in (1, 2)) or 1
    lat = maps.get("@wake_lat_us", {})
    k4["latency_median_us"] = {("busy" if k[1] == 99 else f"state{k[1]}"): buckets_quantile(b, 0.5)
                               for k, b in sorted(lat.items()) if k[0] == 1 and isinstance(b, list)}
    k4["share_from_c2_or_deeper"] = round(deep / all_audio, 3)
    k4["gate_fires"] = deep / all_audio >= 0.10
    res["K4_K7_wakes"] = k4

    irq = maps.get("@irq_ns", {})
    sirq = maps.get("@sirq_ns", {})
    per_cpu = {}
    for k, v in irq.items():
        per_cpu[k[0]] = per_cpu.get(k[0], 0) + v
    for k, v in sirq.items():
        per_cpu[k[0]] = per_cpu.get(k[0], 0) + v
    a = [per_cpu.get(c, 0) / n_sec / 1e3 for c in sorted(AUDIO_CPUS)]
    o = [v / n_sec / 1e3 for c, v in per_cpu.items() if c not in AUDIO_CPUS]
    res["K6_irq_us_per_s"] = {"audio_cpus": [round(x, 1) for x in a], "other_cpus_median": round(statistics.median(o), 1) if o else 0}
    return res


def main():
    files = sorted(glob.glob(os.path.join(sys.argv[1], "sets", "*", "**", "census.json"), recursive=True))
    if not files:
        sys.exit(f"no census.json under {sys.argv[1]}/sets")
    out = {}
    for f in files:
        name = f.split("/sets/")[1].split("/")[0].split("-", 1)[-1]
        r = analyse(f)
        out[name] = r
        print(f"== {name}: {r['seconds']} s playing, {r['blocks_per_s']} blocks/s")
        for role, v in r["per_block"].items():
            print(f"  per block, {role:11}: sets {v['sets']:6.1f}  resets {v['resets']:6.1f}  waits {v['waits']:6.1f}")
        print("  K5 " + " ".join(f"{k}={v}" for k, v in r["K5"].items()))
        for role, v in r["K3_sleeps"].items():
            print(f"  K3 {role} sleeps: " + " ".join(f"{k}={x}" for k, x in v.items()))
        for role in ("AudioCalc", "pipeasio-rt"):
            print(f"  K4 {role} woken from: " + " ".join(f"{k}={x}" for k, x in r["K4_K7_wakes"].get(role, {}).items()))
        print(f"  K4 wake latency median (us, AudioCalc) by state: {r['K4_K7_wakes']['latency_median_us']}; "
              f"from C2 or deeper {r['K4_K7_wakes']['share_from_c2_or_deeper']} -> gate {'FIRES' if r['K4_K7_wakes']['gate_fires'] else 'does not fire'}")
        print(f"  K6 IRQ time (us per s) on audio CPUs {r['K6_irq_us_per_s']['audio_cpus']}, other CPUs median {r['K6_irq_us_per_s']['other_cpus_median']}")
    print(json.dumps(out))


if __name__ == "__main__":
    main()
