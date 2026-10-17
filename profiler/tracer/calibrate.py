#!/usr/bin/env python3
"""Measure the uprobe trap cost per probe hit of the Wine interface tracer (B5c).

    calibrate.py [--out DIR] [--iterations N] [--repeats R] [--warmup N] [--cpu auto|C[,C...]]
                 [--extra-consumers K] [--wine-root DIR] [--prefix DIR] [--tracer PATH]
                 [--save PATH | --no-save] [--allow-busy-prefix] [--quiet]

Runs profiler/tracer/trapcal.exe (built from trapcal.c with x86_64-w64-mingw32-gcc on first use,
into profiler/tracer/build/) in the Wine prefix, pinned to one CPU at a time: R timed loops of N
NtYieldExecution calls, each one Wine syscall, i.e. one wine:syscall_entry and one
wine:syscall_exit probe hit when traced, on each CPU of --cpu (default auto: CPU 2, a P-core on
the CachyOS laptop, and on a hybrid CPU also the first E-core, where a trap costs about a third
more),

  1. untraced;
  2. traced: ``wine-trace start --libbpf --mode summary --pid <trapcal>`` (the loader runs its
     stack self-check before it attaches anything), the timed loops, ``wine-trace stop``;
  3. on the first CPU only, with --extra-consumers K > 0 (default 3): traced again with K idle
     trapcal processes attached as well.  Every traced process is one more consumer on the
     shared ntdll.so uprobes, and a hit runs all their handlers (the ones of other processes
     return at once).

    ns_per_trap = (traced - untraced - bpf_entry - bpf_exit) / 2

from the medians of the repeats, where bpf_entry / bpf_exit are the loader's measured run times
per run (tracer.json programs[], BPF_ENABLE_STATS) of wine_syscall_entry / wine_syscall_exit in
the same traced run.  It is the cost of one probe hit outside the BPF program: the int3 trap
(5-byte nop sites) or the optimised-uprobe entry (10-byte nop sites, kernel 7.2), the uprobe
lookup and handler chain, and the BPF run-time-statistics bookkeeping that the tracer always
enables.  ns_per_extra_consumer = (traced with K - traced) / (2 K).  A tight loop keeps every
cache hot, so even the slowest CPU's figure is a lower bound for Live's threads.

The record's top-level figures are the first CPU's (what the loader multiplies by the hits);
``by_cpu`` has every CPU's, ``ns_per_trap_by_type`` the slowest per core type, and
``ns_per_trap_max`` the slowest CPU (the loader's *_max overhead fields).

Writes DIR/trap-calibration.json and (unless --no-save) the machine-wide copy
~/.local/state/profiler/trap-calibration.json, which ``wine-trace start`` hands to the loader
(--trap-calibration).  The loader uses it only while the kernel release and the traced ntdll.so
(path, size, mtime) match; tracer.json overhead.trap_calibration keeps the record.

Run it as the prefix's user (the tracer then goes through ``sudo -n``) or through sudo (Wine then
runs as SUDO_USER), with Live stopped: a busy prefix is refused (--allow-busy-prefix).  Takes the
same lock as every other measurement when the caller holds it.  Python 3.9+, standard library.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import secrets
import shutil
import statistics
import struct
import subprocess
import sys
import time

SCHEMA = "wine-trace-trap-calibration/1"
TOOL = "calibrate.py/2"
TRACER_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(TRACER_DIR))
NOP5 = bytes.fromhex("0f1f440000")
NOP10 = bytes.fromhex("662e0f1f840000000000")
DISPATCHER_PROBES = ("syscall_entry", "syscall_exit", "unixcall_entry", "unixcall_exit")


class CalibrationError(Exception):
    pass


def log(opt, message):
    if not opt.quiet:
        print("calibrate: %s" % message, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------------------------
# users and environment
# --------------------------------------------------------------------------------------------

def invoking_user():
    """(name, uid, gid, home) of the prefix's owner: SUDO_USER under sudo, else ourselves."""
    import pwd   # POSIX only (the module's helpers stay importable for the unit tests elsewhere)

    name = os.environ.get("SUDO_USER") if os.geteuid() == 0 else None
    entry = pwd.getpwnam(name) if name else pwd.getpwuid(os.getuid())
    return entry.pw_name, entry.pw_uid, entry.pw_gid, entry.pw_dir


def as_user(argv, user):
    """argv run as the prefix's user (sudo -u when we are root through sudo)."""
    if os.geteuid() == 0 and user[1] != 0:
        return ["sudo", "-u", user[0], "-H", "--"] + list(argv)
    return list(argv)


def as_root(argv):
    return list(argv) if os.geteuid() == 0 else ["sudo", "-n", "--"] + list(argv)


def wine_env(opt, user, extra=None):
    env = {
        "HOME": user[3],
        "USER": user[0],
        "PATH": os.path.join(opt.wine_root, "bin") + ":/usr/local/bin:/usr/bin:/bin",
        "WINEPREFIX": opt.prefix,
        "WINESERVER": os.path.join(opt.wine_root, "bin", "wineserver"),
        "WINEDEBUG": "-all",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    if extra:
        env.update(extra)
    return env


def env_argv(env):
    """`env -i K=V ... ` prefix: the environment survives sudo -u."""
    return ["env", "-i"] + ["%s=%s" % item for item in sorted(env.items())]


# --------------------------------------------------------------------------------------------
# ELF: the dispatcher probes' site bytes (stdlib parser, 64-bit little-endian only)
# --------------------------------------------------------------------------------------------

def elf_probe_sites(path, provider="wine", names=DISPATCHER_PROBES):
    """{name: {"pc": int, "offset": int, "bytes": hex, "kind": nop5|nop10|other, "crosses_page": bool}}"""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise CalibrationError("%s is not a 64-bit little-endian ELF file" % path)
    e_phoff, e_shoff = struct.unpack_from("<QQ", data, 0x20)
    e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", data, 0x36)
    loads = []
    for i in range(e_phnum):
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from("<IIQQQQ", data, e_phoff + i * e_phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
    sections = []
    for i in range(e_shnum):
        sh_name, sh_type, _flags, _addr, sh_offset, sh_size = struct.unpack_from("<IIQQQQ", data, e_shoff + i * e_shentsize)
        sections.append((sh_name, sh_type, sh_offset, sh_size))
    strtab = sections[e_shstrndx]

    def section_name(index):
        start = strtab[2] + sections[index][0]
        return data[start:data.index(b"\0", start)].decode("ascii", "replace")

    sites = {}
    for index, (_name, sh_type, offset, size) in enumerate(sections):
        if sh_type != 7 or section_name(index) != ".note.stapsdt":
            continue
        pos, end = offset, offset + size
        while pos + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
            name_start = pos + 12
            desc_start = name_start + ((namesz + 3) & ~3)
            if ntype == 3 and data[name_start:name_start + namesz].rstrip(b"\0") == b"stapsdt":
                pc = struct.unpack_from("<Q", data, desc_start)[0]
                strings = data[desc_start + 24:desc_start + descsz].split(b"\0")
                prov = strings[0].decode("ascii", "replace") if strings else ""
                name = strings[1].decode("ascii", "replace") if len(strings) > 1 else ""
                if prov == provider and name in names:
                    file_offset = None
                    for vaddr, poff, filesz in loads:
                        if vaddr <= pc < vaddr + filesz:
                            file_offset = poff + (pc - vaddr)
                            break
                    site = data[file_offset:file_offset + 10] if file_offset is not None else b""
                    kind = "nop10" if site[:10] == NOP10 else "nop5" if site[:5] == NOP5 else "other"
                    sites.setdefault(name, {
                        "pc": pc, "offset": file_offset, "bytes": site.hex(), "kind": kind,
                        "crosses_page": (pc & 4095) + (10 if kind == "nop10" else 5) > 4096,
                    })
            pos = desc_start + ((descsz + 3) & ~3)
    return sites


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


CORE_LISTS = (("P-core", "/sys/devices/cpu_core/cpus"), ("E-core", "/sys/devices/cpu_atom/cpus"))


def parse_cpu_list(text):
    """CPU numbers of a sysfs-style list ("0-11", "12-15", "0,2-3"); ValueError on anything else."""
    cpus = []
    for part in text.strip().split(","):
        low, dash, high = part.strip().partition("-")
        if not low.isdigit() or (dash and not high.isdigit()):
            raise ValueError("not a CPU list: %r" % text)
        first, last = int(low), int(high) if dash else int(low)
        if last < first:
            raise ValueError("not a CPU list: %r" % text)
        cpus.extend(range(first, last + 1))
    return cpus


def core_lists(lists=CORE_LISTS):
    """{core type: [cpu, ...]} of a hybrid CPU (empty on others)."""
    found = {}
    for kind, path in lists:
        try:
            with open(path, encoding="ascii") as handle:
                found[kind] = parse_cpu_list(handle.read())
        except (OSError, ValueError):
            continue
    return found


def default_cpus(lists=CORE_LISTS, cpu_count=None):
    """CPU 2 (a P-core on the CachyOS laptop), and on a hybrid CPU also the first E-core."""
    cores = core_lists(lists)
    pcores, ecores = cores.get("P-core", []), cores.get("E-core", [])
    if pcores and ecores:
        return [2 if 2 in pcores else pcores[0], ecores[0]]
    count = cpu_count if cpu_count is not None else (os.cpu_count() or 1)
    return [2 if count > 2 else 0]


def resolve_cpus(text, lists=CORE_LISTS, cpu_count=None):
    """--cpu: "auto" or a comma-separated list (ranges allowed), duplicates dropped, order kept."""
    cpus = default_cpus(lists, cpu_count) if text.strip() == "auto" else parse_cpu_list(text)
    return list(dict.fromkeys(cpus))


def cpu_record(cpu, lists=CORE_LISTS):
    record = {"index": cpu, "type": "unknown", "model": None}
    for kind, cpus in core_lists(lists).items():
        if cpu in cpus:
            record["type"] = kind
    try:
        for line in open("/proc/cpuinfo", encoding="utf-8", errors="replace"):
            if line.startswith("model name"):
                record["model"] = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    return record


# --------------------------------------------------------------------------------------------
# runs
# --------------------------------------------------------------------------------------------

def parse_results(text):
    values = []
    for line in text.splitlines():
        if line.startswith("RESULT "):
            fields = dict(part.split("=", 1) for part in line.split()[1:] if "=" in part)
            try:
                values.append(float(fields["ns_per_call"]))
            except (KeyError, ValueError):
                continue
    return values


def summarise(values):
    if not values:
        raise CalibrationError("trapcal printed no RESULT lines")
    return {"ns_per_call": values, "median": round(statistics.median(values), 1), "min": round(min(values), 1)}


def trapcal_argv(opt, exe, cpu, extra):
    return ["taskset", "-c", str(cpu), os.path.join(opt.wine_root, "bin", "wine"), exe] + extra


def run_untraced(opt, user, exe, cpu):
    argv = trapcal_argv(opt, exe, cpu, ["--iterations", str(opt.iterations), "--repeats", str(opt.repeats),
                                        "--warmup", str(opt.warmup)])
    result = subprocess.run(as_user(env_argv(wine_env(opt, user)) + argv, user), stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, timeout=600, check=False)
    if result.returncode != 0:
        raise CalibrationError("untraced trapcal exited %d" % result.returncode)
    return summarise(parse_results(result.stdout))


def linux_pids_with_token(token, comm="trapcal.exe"):
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            if open("/proc/%s/comm" % name, encoding="utf-8", errors="replace").read().strip() != comm:
                continue
            environ = open("/proc/%s/environ" % name, "rb").read().split(b"\0")
        except OSError:
            continue
        if ("TRAPCAL_TOKEN=%s" % token).encode() in environ:
            found.append(int(name))
    return found


def wait_pids(token, count, timeout=60.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pids = linux_pids_with_token(token)
        if len(pids) >= count:
            return sorted(pids)
        time.sleep(0.05)
    raise CalibrationError("trapcal (token %s) did not show up in /proc" % token)


def tracer(opt, verb, args):
    argv = as_root([opt.tracer, verb] + args)
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300, check=False)
    if result.returncode != 0:
        raise CalibrationError("wine-trace %s failed (exit %d): %s" % (verb, result.returncode, result.stderr.strip()[-2000:]))
    return result


def run_traced(opt, user, exe, out, cpu, extra_consumers=0):
    """The timed loops on `cpu` while the tracer is attached to trapcal (and to `extra_consumers`
    idle trapcal processes).  Returns the summary with the bpf ns per run of the entry / exit
    programs."""
    token = secrets.token_hex(6)
    go_unix = "/tmp/trapcal-go-%s" % token
    go_win = "Z:" + go_unix.replace("/", "\\")
    env = wine_env(opt, user, {"TRAPCAL_TOKEN": token})
    idle = []
    timed = None
    try:
        for _ in range(extra_consumers):
            argv = trapcal_argv(opt, exe, cpu, ["--idle-ms", "600000"])
            idle.append(subprocess.Popen(as_user(env_argv(env) + argv, user), stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL))
        idle_pids = wait_pids(token, extra_consumers) if extra_consumers else []
        argv = trapcal_argv(opt, exe, cpu, ["--iterations", str(opt.iterations), "--repeats", str(opt.repeats),
                                            "--warmup", str(opt.warmup), "--go-file", go_win])
        timed = subprocess.Popen(as_user(env_argv(env) + argv, user), stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True)
        all_pids = wait_pids(token, extra_consumers + 1)
        timed_pids = [pid for pid in all_pids if pid not in idle_pids]
        if len(timed_pids) != 1:
            raise CalibrationError("cannot tell the timed trapcal process from the idle ones: %s" % all_pids)
        args = ["--out", out, "--libbpf", "--mode", "summary"]
        for pid in timed_pids + idle_pids:
            args += ["--pid", str(pid)]
        tracer(opt, "start", args)
        try:
            with open(go_unix, "w", encoding="ascii") as handle:
                handle.write("go\n")
            os.chmod(go_unix, 0o644)
            stdout, _ = timed.communicate(timeout=600)
        finally:
            tracer(opt, "stop", ["--out", out])
        if timed.returncode != 0:
            raise CalibrationError("traced trapcal exited %d" % timed.returncode)
        summary = summarise(parse_results(stdout))
    finally:
        for proc in idle + ([timed] if timed is not None and timed.poll() is None else []):
            if proc.poll() is None:
                proc.terminate()
        for proc in idle:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        for pid in linux_pids_with_token(token):
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        try:
            os.unlink(go_unix)
        except OSError:
            pass
    with open(os.path.join(out, "tracer.json"), encoding="utf-8") as handle:
        traced = json.load(handle)
    bpf = {}
    for prog in traced.get("programs", []):
        if prog.get("name") in ("wine_syscall_entry", "wine_syscall_exit") and prog.get("run_cnt"):
            bpf[prog["name"]] = round(prog["run_time_ns"] / prog["run_cnt"], 1)
    if len(bpf) != 2:
        raise CalibrationError("%s/tracer.json has no run times of wine_syscall_entry/exit (BPF stats off?)" % out)
    summary["bpf_ns_per_run"] = bpf
    summary["run"] = out
    summary["tracer_exit"] = traced.get("tracer_exit")
    summary["lost_events"] = traced.get("lost_events")
    return summary


def prefix_busy(opt, user):
    script = ('. "$1/scripts/lib/config.sh" 2>/dev/null; . "$1/scripts/lib/lifecycle.sh" && '
              'ableton_prefix_pids "$2" "$3"')
    result = subprocess.run(as_user(env_argv(wine_env(opt, user)) + ["bash", "-c", script, "_", REPO, opt.wine_root,
                                                                      opt.prefix], user),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    return [line for line in result.stdout.split() if line.isdigit()]


def build_trapcal(opt, user):
    src = os.path.join(TRACER_DIR, "trapcal.c")
    build = os.path.join(TRACER_DIR, "build")
    exe = os.path.join(build, "trapcal.exe")
    if os.path.isfile(exe) and os.path.getmtime(exe) >= os.path.getmtime(src):
        return exe
    compiler = shutil.which("x86_64-w64-mingw32-gcc")
    if not compiler:
        raise CalibrationError("x86_64-w64-mingw32-gcc is missing (pacman -S mingw-w64-gcc) and %s is not built" % exe)
    subprocess.run(as_user(["mkdir", "-p", build], user), check=True)
    subprocess.run(as_user([compiler, "-Wall", "-Wextra", "-O1", "-nostartfiles", "-Wl,-e,mainCRTStartup", "-o", exe,
                            src, "-lkernel32", "-lntdll"], user), check=True)
    return exe


def write_json(path, value, user):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=1)
        handle.write("\n")
    os.replace(tmp, path)
    if os.geteuid() == 0:
        try:
            os.chown(path, user[1], user[2])
        except OSError:
            pass


def trap_ns(untraced, traced):
    """ns per probe hit outside the BPF program, from one CPU's untraced and traced summaries."""
    bpf = traced["bpf_ns_per_run"]
    return (traced["median"] - untraced["median"] - bpf["wine_syscall_entry"] - bpf["wine_syscall_exit"]) / 2


def per_cpu_figures(runs):
    """runs: [{"cpu": cpu_record, "untraced": summary, "traced": summary}, ...] in --cpu order.
    Returns (by_cpu: the runs with ns_per_trap, {core type: slowest ns_per_trap}, slowest overall);
    CalibrationError when a CPU gives an implausible figure."""
    by_cpu, by_type = [], {}
    for run in runs:
        ns = trap_ns(run["untraced"], run["traced"])
        if ns <= 0:
            raise CalibrationError("implausible result on CPU %d: ns_per_trap %.1f (untraced %.1f, traced %.1f, bpf %s)"
                                   % (run["cpu"]["index"], ns, run["untraced"]["median"], run["traced"]["median"],
                                      run["traced"]["bpf_ns_per_run"]))
        entry = dict(run, ns_per_trap=round(ns, 1))
        by_cpu.append(entry)
        kind = entry["cpu"]["type"]
        by_type[kind] = max(by_type.get(kind, 0.0), entry["ns_per_trap"])
    return by_cpu, by_type, max(entry["ns_per_trap"] for entry in by_cpu)


def summary_line(record, path):
    """The one-line result printed on stdout."""
    first = record["by_cpu"][0]
    parts = ["%.1f ns per probe hit outside BPF (%s sites, CPU %d %s)"
             % (first["ns_per_trap"], record["site_kind"], first["cpu"]["index"], first["cpu"]["type"])]
    parts += ["CPU %d %s %.1f ns" % (entry["cpu"]["index"], entry["cpu"]["type"], entry["ns_per_trap"])
              for entry in record["by_cpu"][1:]]
    if record.get("ns_per_extra_consumer") is not None:
        parts.append("+%.1f ns per further traced process" % record["ns_per_extra_consumer"])
    parts.append("untraced %.1f / traced %.1f ns per NtYieldExecution on CPU %d"
                 % (first["untraced"]["median"], first["traced"]["median"], first["cpu"]["index"]))
    return "trap calibration: %s; %s" % ("; ".join(parts), path)


def main(argv=None):
    user = invoking_user()
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--out", help="run directory (default ~/.local/share/profiler/runs/trapcal-<UTC>)")
    parser.add_argument("--iterations", type=int, default=200000)
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--warmup", type=int, default=20000)
    parser.add_argument("--cpu", default="auto",
                        help="CPUs to pin trapcal to, one after the other: a list such as 2,12, or auto (default: "
                             "CPU 2, and on a hybrid CPU also the first E-core); the first one's figures are the "
                             "record's top-level values")
    parser.add_argument("--extra-consumers", type=int, default=3,
                        help="idle traced processes for the per-consumer cost, first CPU only (0 skips; default 3)")
    parser.add_argument("--wine-root", default=os.environ.get("ABLETON_WINE_ROOT") or
                        os.path.join(user[3], ".local/opt/wine-d2d1-nspa-11.13"))
    parser.add_argument("--prefix", default=os.environ.get("ABLETON_WINEPREFIX") or os.path.join(user[3], ".wine-ableton"))
    parser.add_argument("--tracer", default=os.path.join(REPO, "profiler", "bin", "wine-trace"))
    parser.add_argument("--save", default=os.path.join(user[3], ".local/state/profiler/trap-calibration.json"),
                        help="machine-wide copy for wine-trace start (default ~/.local/state/profiler/trap-calibration.json)")
    parser.add_argument("--no-save", action="store_true")
    parser.add_argument("--allow-busy-prefix", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    opt = parser.parse_args(argv)
    if opt.iterations <= 0 or opt.repeats <= 0 or opt.warmup < 0 or opt.extra_consumers < 0:
        parser.error("--iterations/--repeats must be positive, --warmup/--extra-consumers not negative")
    try:
        cpus = resolve_cpus(opt.cpu)
    except ValueError as exc:
        parser.error("--cpu: %s" % exc)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = opt.out or os.path.join(user[3], ".local/share/profiler/runs", "trapcal-%s" % stamp)
    try:
        allowed = os.sched_getaffinity(0)
        missing = [cpu for cpu in cpus if cpu not in allowed]
        if missing:
            raise CalibrationError("CPU %s not available here (allowed: %s)"
                                   % (",".join(map(str, missing)), ",".join(map(str, sorted(allowed)))))
        ntdll = os.path.realpath(os.path.join(opt.wine_root, "lib/wine/x86_64-unix/ntdll.so"))
        if not os.path.isfile(ntdll):
            raise CalibrationError("no ntdll.so under %s" % opt.wine_root)
        busy = prefix_busy(opt, user)
        if busy and not opt.allow_busy_prefix:
            raise CalibrationError("the prefix %s is busy (pids %s): stop Live first, or --allow-busy-prefix"
                                   % (opt.prefix, " ".join(busy)))
        exe = build_trapcal(opt, user)
        subprocess.run(as_user(["mkdir", "-p", out], user), check=True)
        sites = elf_probe_sites(ntdll)
        kinds = sorted({site["kind"] for site in sites.values()})
        log(opt, "ntdll.so %s: dispatcher probe sites %s" % (ntdll, ", ".join(kinds) or "none found"))
        runs = []
        for index, cpu in enumerate(cpus):
            info = cpu_record(cpu)
            log(opt, "untraced: %d x %d NtYieldExecution on CPU %d (%s)" % (opt.repeats, opt.iterations, cpu, info["type"]))
            untraced = run_untraced(opt, user, exe, cpu)
            log(opt, "untraced median %.1f ns per call" % untraced["median"])
            traced = run_traced(opt, user, exe, os.path.join(out, "traced" if index == 0 else "traced-cpu%d" % cpu), cpu)
            log(opt, "traced median %.1f ns per call (bpf %s)" % (traced["median"], traced["bpf_ns_per_run"]))
            runs.append({"cpu": info, "untraced": untraced, "traced": traced})
        by_cpu, by_type, slowest = per_cpu_figures(runs)
        first = by_cpu[0]
        extra = None
        if opt.extra_consumers:
            extra = run_traced(opt, user, exe, os.path.join(out, "traced-extra"), cpus[0], opt.extra_consumers)
            extra["count"] = opt.extra_consumers
            log(opt, "traced with %d more traced processes: median %.1f ns per call" % (opt.extra_consumers, extra["median"]))
        per_consumer = None
        if extra:
            per_consumer = max(0.0, (extra["median"] - first["traced"]["median"]) / (2 * opt.extra_consumers))
        st = os.stat(ntdll)
        record = {
            "schema": SCHEMA,
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
            "kernel": os.uname().release,
            "cpu": first["cpu"],
            "ntdll": {
                "path": ntdll, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha256": sha256_file(ntdll),
                "probe_sites": sites,
            },
            "site_kind": kinds[0] if len(kinds) == 1 else ("mixed" if kinds else "unknown"),
            "iterations": opt.iterations, "repeats": opt.repeats, "warmup": opt.warmup,
            "untraced": first["untraced"],
            "traced": first["traced"],
            "extra_consumers": extra,
            "ns_per_trap": first["ns_per_trap"],
            "ns_per_extra_consumer": round(per_consumer, 1) if per_consumer is not None else None,
            "by_cpu": by_cpu,
            "ns_per_trap_by_type": by_type,
            "ns_per_trap_max": slowest,
            "method": "trapcal.exe NtYieldExecution loops pinned to one CPU, medians of the repeats: ns_per_trap = "
                      "(traced - untraced - bpf(wine_syscall_entry) - bpf(wine_syscall_exit)) / 2, the cost of one "
                      "probe hit outside the BPF program (trap or optimised-uprobe entry, uprobe lookup and handler "
                      "chain, BPF run-time statistics), on every CPU of by_cpu; the top-level figures are the first "
                      "CPU's, ns_per_trap_max the slowest CPU's; a tight loop keeps the caches hot, so each is a "
                      "lower bound for its CPU type; ns_per_extra_consumer = (traced with K idle traced processes "
                      "- traced) / 2K on the first CPU",
            "tool": TOOL,
        }
        path = os.path.join(out, "trap-calibration.json")
        write_json(path, record, user)
        if not opt.no_save:
            write_json(opt.save, record, user)
        print(summary_line(record, path) + ("" if opt.no_save else " (saved: %s)" % opt.save))
        return 0
    except (CalibrationError, subprocess.SubprocessError, OSError) as exc:
        print("calibrate: error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
