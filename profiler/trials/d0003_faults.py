"""D0003: the page faults of slow blocks against Live's memory map (run on the laptop from the checkout root).

usage: python3 d0003_faults.py INTERFACE_DIR

Reads blocks.txt (B slow blocks, P every user page fault of Live: tid, time, address, faulting IP, error code) and
smaps-start.txt / smaps-stop.txt. For every slow block: its faults by thread and error code (bit 0 present, bit 1
write), the address span, the memory regions (VMAs) they fall in with size, VmFlags (uw = userfaultfd write-protect,
nh = no huge pages, hg = huge pages advised) and THP eligibility, and the code that faulted (PE module + offset).
"""
import bisect
import collections
import os
import re
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "profiler", "tracer"))
import symbolize  # noqa: E402

I = sys.argv[1]
BEAT_NS = 60e9 / 112
t_play = int(open(f"{I}/start-mono.txt").read()) - 150_000_000
pid = int(open(f"{I}/live.pid").read())

slow, faults = [], []
for line in open(f"{I}/blocks.txt", errors="replace"):
    p = line.split()
    if len(p) == 5 and p[0] == "B":
        slow.append((int(p[2]), int(p[2]) + int(p[3]), int(p[1]), int(p[3]), int(p[4])))
    elif len(p) == 6 and p[0] == "P":
        faults.append((int(p[2]), int(p[1]), int(p[3], 16), int(p[4], 16), int(p[5])))
slow.sort()
faults.sort()
starts = [s[0] for s in slow]


def parse_smaps(path):
    vmas, cur = [], None
    head = re.compile(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) (\S+) \S+ \d+\s*(.*)$")
    for line in open(path, errors="replace"):
        m = head.match(line)
        if m:
            cur = {"start": int(m.group(1), 16), "end": int(m.group(2), 16), "perms": m.group(3), "path": m.group(5).strip()}
            vmas.append(cur)
        elif cur is not None and ":" in line:
            k, _, v = line.partition(":")
            cur[k.strip()] = v.strip()
    vmas.sort(key=lambda v: v["start"])
    return vmas


smaps = {name: parse_smaps(f"{I}/smaps-{name}.txt") for name in ("start", "stop") if os.path.exists(f"{I}/smaps-{name}.txt")}
vma_starts = {k: [v["start"] for v in vs] for k, vs in smaps.items()}


def vma_of(addr, which="start"):
    vs = smaps.get(which, [])
    i = bisect.bisect_right(vma_starts.get(which, []), addr) - 1
    if i >= 0 and vs[i]["start"] <= addr < vs[i]["end"]:
        return vs[i]
    return None


modules = symbolize.ModuleMap()
modules.load(f"{I}/maps-start.txt", pid=pid)


def code(ip):
    mod = modules.find(ip, pid)
    if mod is None:
        return "anon:0x%x" % (ip & ~0xfff)
    if mod.kind in ("pe64", "pe32") and not mod.is_wine_dll:
        return "%s+0x%x" % (mod.name, ip - mod.base)
    return symbolize.format_address(mod, ip, modules)


def describe(v):
    if v is None:
        return "no VMA in the start snapshot"
    size = (v["end"] - v["start"]) // 1024
    return (f"{v['start']:x}-{v['end']:x} {size} KiB {v['perms']} {v['path'] or '[anon]'} flags [{v.get('VmFlags', '')}] "
            f"THPeligible {v.get('THPeligible', '?')} Rss {v.get('Rss', '?')} AnonHuge {v.get('AnonHugePages', '?')}")


in_slow = 0
print(f"{len(faults)} user page faults in Live, {len(slow)} slow blocks")
for t0, t1, seq, e, slack in slow:
    lo = bisect.bisect_left(faults, (t0,))
    hi = bisect.bisect_right(faults, (t1, 1 << 62))
    fs = faults[lo:hi]
    in_slow += len(fs)
    beat = (t0 - t_play) / BEAT_NS
    print(f"\n== seq {seq} beat {beat:.2f} elapsed {e / 1e3:.0f} us slack {slack / 1e3:.0f} us: {len(fs)} faults")
    if not fs:
        continue
    by_tid = collections.Counter(f[1] for f in fs)
    by_err = collections.Counter(f[4] for f in fs)
    print(f"   by thread {dict(by_tid)}; by error code {dict(by_err)} (1 present, 2 write, 4 user)")
    addrs = sorted(f[2] for f in fs)
    pages = {a >> 12 for a in addrs}
    print(f"   address span {addrs[0]:x}-{addrs[-1]:x} ({(addrs[-1] - addrs[0]) / 1048576:.1f} MiB), {len(pages)} distinct pages, "
          f"{len(fs) / max(1, len(pages)):.2f} faults per page")
    vcount = collections.Counter()
    for f in fs:
        v = vma_of(f[2])
        vcount[describe(v)] += 1
    for d, n in vcount.most_common(4):
        print(f"   {n:5} in {d}")
    ccount = collections.Counter(code(f[3]) for f in fs)
    print("   faulting code: " + ", ".join(f"{c} {n}" for c, n in ccount.most_common(6)))
    # the same VMAs at stop: did they change (THP, Rss)?
    if "stop" in smaps:
        for d, n in vcount.most_common(1):
            v = vma_of(fs[0][2], "stop")
            print(f"   at stop: {describe(v)}")
print(f"\n{in_slow} of {len(faults)} faults ({in_slow / max(1, len(faults)):.0%}) fall inside slow blocks")
flags = collections.Counter()
for v in smaps.get("start", []):
    for fl in v.get("VmFlags", "").split():
        if fl in ("uw", "um", "nh", "hg"):
            flags[fl] += 1
print("VMAs with userfaultfd/THP flags at start:", dict(flags))
uw = [v for v in smaps.get("start", []) if "uw" in v.get("VmFlags", "").split()]
print("userfaultfd write-protect VMAs:", len(uw), "total", sum(v["end"] - v["start"] for v in uw) // 1048576, "MiB")
