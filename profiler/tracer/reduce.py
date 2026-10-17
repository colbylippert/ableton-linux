#!/usr/bin/env python3
"""Offline join of the prototype tracer's event lines (design B sections 3a, 3b and 9).

    reduce.py --in DIR [--out DIR] [--tracer-json FILE] [--tables FILE] [--mode summary|drilldown]
              [--near-late-fraction 0.15] [--window-ms 100] [--stopped-monotonic-ns N]
              [--lost-events-extra N] [--recursion-misses N] [--ns-per-hit 2000]

Input: ``DIR/events.txt`` written by ``wine-trace.bt`` (format: profiler/tracer/README.md), the
``T`` lines of ``DIR/tasks-start.txt`` / ``DIR/tasks-stop.txt`` (every thread of the traced pids
at start/stop, written by ``profiler/bin/wine-trace``; format 3 prints ``T`` lines only for threads
created while tracing), the optional ``DIR/tracer.json`` written by ``profiler/bin/wine-trace
start`` (pids, images, mode) and the optional ``DIR/maps-<pid>*.txt`` snapshots of
``/proc/<pid>/maps`` (unix-call handle -> .so).

Output (all times are ``offset_seconds`` from the header's ``monotonic_start_ns``, first line of
every .jsonl file is a ``{"type":"header"}`` record):

* ``blocks.jsonl``  -- one record per audio block (design B section 9).
* ``threads.jsonl`` -- one record per 100 ms window and tid.
* ``summary.json``  -- the ``interface`` rollup (design C section B) plus tracer counters.
* ``events.jsonl``  -- every completed crossing (``--mode drilldown`` only).
* ``tracer.json``   -- updated in place with ``stopped_monotonic_ns``, ``lost_events``,
  ``probe_hits`` and the reducer counters when ``--tracer-json`` is given.

Ordering and memory: lines are sorted by (timestamp, file order) first (bpftrace drains per-CPU
buffers, so the file is not globally ordered).  Inputs larger than ``--sort-chunk-lines`` are
sorted externally (sorted runs in a temporary directory next to the outputs, merged with
``heapq.merge``) and every completed crossing is aggregated as soon as it is paired, so memory
grows with the number of blocks and distinct call sites, not with the number of events
(``--mode drilldown`` still keeps the event list for ``events.jsonl``).

Lost events: bpftrace 0.27 drops ring-buffer records silently, so ``wine-trace.bt`` (format >= 2)
counts every printf in the ``@emitted`` map (key = ASCII code of the line letter; format 3 counts
the unix-call ``E`` line under 101 = ``e``, which stands for one ``E`` and one ``R`` line) and
prints it after the ``end`` line.  ``lost_events`` = max(reported, shortfall) + recursion misses,
where reported = bpftrace's own ``Lost N events`` lines + the wrapper's ``--lost-events-extra``
(both count the same dropped records as the shortfall), shortfall = the per-kind sum of
max(0, emitted - received lines) and recursion misses = ``--recursion-misses`` (fentry/fexit runs
the kernel skipped: their W/w/K lines were never emitted).  Lines received beyond ``@emitted``
(printed while the counters were read) are ``received_after_counters``: they can hide a shortfall
of the same size, so ``lower_bound`` is then true.  A format >= 2 trace without ``@emitted`` or any
trace without its ``end`` line (the tracer did not exit cleanly) reports ``lost_events`` as null
(unknown), never as a silent zero, and ``stopped_monotonic_ns`` = its last event.

Pairing rules: ``E``/``X`` records are paired per tid in LIFO order by the frame pointer: an
``X`` whose frame matches an open entry below the top pops the entries above it as
``abandoned`` (user-mode callbacks return through ``NtCallbackReturn`` without an exit); an ``X``
matching nothing is an ``unmatched`` exit (the first one on a tid is normally the thread start,
which jumps to the dispatcher return label).  ``S`` (server requests/waits), ``W``/``w``
(NTSync waits) and ``K`` (NTSync wakes) are nested inside the innermost open entry of their tid
and inherit its caller.  Block association follows the entry-time ``seq`` printed by the probe:
the block in progress at entry (``seq`` > 0) or the 100 ms window bucket (``seq`` == 0); events
of the callback thread with ``seq`` == 0 are flagged ``between_blocks``.

Python 3.9+, standard library only.
"""

from __future__ import annotations

import argparse
import bisect
import collections
import glob
import heapq
import importlib.util
import json
import math
import os
import re
import shutil
import sys
import tempfile

REDUCER_VERSION = "reduce.py/2"
SUMMARY_SCHEMA = "ableton-linux-tracer-summary/v1"
HEADER_RE = re.compile(r"^hdr\s+mono_start_ns=(\d+)")
HEADER_FORMAT_RE = re.compile(r"\bformat=(\d+)")
HEADER_CLOCK_RE = re.compile(r"\bclock=(\w+)")
END_RE = re.compile(r"^end\s+mono_end_ns=(\d+)")
LOST_RE = re.compile(r"^Lost\s+(\d+)\s+events?")
EMITTED_RE = re.compile(r"^@emitted\[(\d+)\]:\s*(\d+)\s*$")
EVENT_KINDS = frozenset(("E", "X", "R", "S", "B", "C", "W", "w", "K", "U", "O", "T", "N", "P"))
# Files next to events.txt with extra event lines (T lines of the threads alive at start/stop,
# written by profiler/bin/wine-trace).
TASK_FILES = ("tasks-start.txt", "tasks-stop.txt")
DEFAULT_SORT_CHUNK_LINES = 2_000_000
# Block states while streaming: OPEN (start seen, crossings buffered), DONE (valid start/end:
# crossings go straight to the block), DROPPED (ended without a usable start).
BLOCK_OPEN = "open"
BLOCK_DONE = "done"
BLOCK_DROPPED = "dropped"
# An R line (unix-call frame + PE caller, second program on the probe) joins the frameless unix-call
# entry of its thread when the two timestamps are this close.
R_JOIN_WINDOW_NS = 1_000_000

AUDIO_ROLES = ("pipeasio_callback", "audio_worker", "pipeasio_rt", "pipeasio_worker")
NTSYNC_WAIT_CMDS = {0xC0284E82: "WAIT_ANY", 0xC0284E83: "WAIT_ALL"}
NTSYNC_WAKE_CMDS = {
    0x80044E88: "EVENT_SET",
    0x80044E8A: "EVENT_PULSE",
    0xC0044E81: "SEM_RELEASE",
    0xC0084E85: "MUTEX_UNLOCK",
}
BLOCK_FLAG_NAMES = ((1, "admitted"), (2, "time_info"), (4, "muted"))
SELECT_FLAG_NAMES = ((1, "interruptible"), (2, "alertable"))
TASK_STATE_NAMES = {0: "R", 1: "S", 2: "D", 4: "T", 8: "t", 16: "X", 32: "Z", 64: "P", 128: "I"}
MAX_DURATION_NS = 600 * 10**9


class ReduceError(Exception):
    pass


def kv_fields(tokens):
    fields = {}
    for token in tokens:
        key, sep, value = token.partition("=")
        if sep:
            fields[key] = value
    return fields


def parse_line(line, index):
    """Return a parsed record tuple (type, ts, ...) or None for lines that carry no event."""
    tokens = line.split()
    if not tokens:
        return None
    kind = tokens[0]
    if kind == "E":
        ts, tid, what = int(tokens[1]), int(tokens[2]), tokens[3]
        fields = kv_fields(tokens[5:])
        if what == "syscall":
            return ("E", ts, tid, "syscall", int(tokens[4], 16), 0, int(fields["fr"], 16),
                    int(fields["seq"]), int(fields.get("rsp", "0"), 16), int(fields.get("rip", "0"), 16))
        if what == "unixcall":
            if "=" in tokens[4]:
                # format 3: "c=CODE h=HANDLE seq=S"; fr/rip follow in an R line from a second program
                fields = kv_fields(tokens[4:])
                return ("E", ts, tid, "unixcall", int(fields["h"], 16), int(fields["c"]), None,
                        int(fields["seq"]), 0, 0)
            handle, _, code = tokens[4].partition(":")
            frame = int(fields["fr"], 16) if "fr" in fields else None
            return ("E", ts, tid, "unixcall", int(handle, 16), int(code), frame,
                    int(fields["seq"]), 0, int(fields.get("rip", "0"), 16))
        raise ValueError("unknown entry kind %r" % what)
    if kind == "X":
        ts, tid, what = int(tokens[1]), int(tokens[2]), tokens[3]
        if what == "syscall":
            # format 3 drops the id (pairing is by frame) and restore_flags and prints st before fr
            has_id = "=" not in tokens[4]
            fields = kv_fields(tokens[5:] if has_id else tokens[4:])
            return ("X", ts, tid, "syscall", int(tokens[4], 16) if has_id else 0, int(fields["fr"], 16),
                    int(fields.get("st", "0"), 16), int(fields.get("rf", "0"), 16))
        if what == "unixcall":
            fields = kv_fields(tokens[4:])
            return ("X", ts, tid, "unixcall", 0, int(fields["fr"], 16), int(fields.get("st", "0"), 16), 0)
        raise ValueError("unknown exit kind %r" % what)
    if kind == "R":
        fields = kv_fields(tokens[3:])
        return ("R", int(tokens[1]), int(tokens[2]), int(fields["fr"], 16), int(fields.get("rip", "0"), 16))
    if kind == "S":
        ts, tid, what = int(tokens[1]), int(tokens[2]), tokens[3]
        fields = kv_fields(tokens[5:])
        if what == "req":
            value = int(tokens[4])
        elif what == "wait":
            value = int(tokens[4], 16)
        else:
            raise ValueError("unknown server record %r" % what)
        return ("S", ts, tid, what, value, int(fields["dur"]), int(fields.get("st", "0"), 16), int(fields.get("seq", "0")))
    if kind == "B":
        ts, tid, phase = int(tokens[1]), int(tokens[2]), tokens[3]
        fields = kv_fields(tokens[4:])
        return ("B", ts, tid, phase, int(fields["seq"]), fields)
    if kind == "C":
        ts, tid, phase = int(tokens[1]), int(tokens[2]), tokens[3]
        return ("C", ts, tid, phase, kv_fields(tokens[4:]))
    if kind == "W":
        ts, tid = int(tokens[1]), int(tokens[2])
        fields = kv_fields(tokens[3:])
        return ("W", ts, tid, int(fields["cmd"], 16), int(fields.get("count", "0")), int(fields.get("alert", "0")),
                int(fields.get("owner", "0")), int(fields.get("seq", "0")))
    if kind == "w":
        ts, tid = int(tokens[1]), int(tokens[2])
        fields = kv_fields(tokens[3:])
        return ("w", ts, tid, int(fields.get("ret", "0")), int(fields.get("idx", "0")))
    if kind == "K":
        ts, tid, pid = int(tokens[1]), int(tokens[2]), int(tokens[3])
        fields = kv_fields(tokens[4:])
        return ("K", ts, tid, pid, int(fields["cmd"], 16), int(fields.get("seq", "0")))
    if kind == "U":
        ts, tid, pid = int(tokens[1]), int(tokens[2]), int(tokens[3])
        fields = kv_fields(tokens[4:])
        return ("U", ts, tid, pid, int(fields["wakee"]))
    if kind == "O":
        ts, tid = int(tokens[1]), int(tokens[2])
        fields = kv_fields(tokens[3:])
        return ("O", ts, tid, int(fields["off"]), int(fields.get("wake", "0")), int(fields.get("st", "0")))
    if kind in ("T", "N", "P"):
        # comm is the last field and may contain spaces ("Ableton Live 12").
        head, sep, comm = line.partition(" comm=")
        tokens = head.split()
        comm = comm.strip() if sep else ""
        if kind == "T":
            return ("T", int(tokens[1]), int(tokens[2]), int(tokens[3]), comm)
        if kind == "N":
            return ("N", int(tokens[1]), int(tokens[2]), comm)
        fields = kv_fields(tokens[3:])
        return ("P", int(tokens[1]), int(tokens[2]), int(fields.get("parent", "0")), comm)
    return None


def percentile(sorted_values, pct):
    """Nearest-rank percentile of an ascending list (None when empty)."""
    if not sorted_values:
        return None
    rank = int(math.ceil(pct / 100.0 * len(sorted_values))) - 1
    rank = min(max(rank, 0), len(sorted_values) - 1)
    return sorted_values[rank]


def flag_names(value, names):
    return [name for bit, name in names if value & bit]


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_role_table(roles_path, warnings):
    """The shared comm/exe classifier (symbolize.py + roles.toml, design B section 5), or None.

    symbolize.py lives next to this script; when it or roles.toml is missing or fails to load the
    reducer falls back to its built-in copy of the same rules (Reducer.builtin_role).
    """
    here = os.path.dirname(os.path.abspath(__file__))
    module_path = os.path.join(here, "symbolize.py")
    if not os.path.isfile(module_path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("wine_trace_symbolize", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        table = module.load_roles(roles_path)
    except Exception as exc:  # noqa: BLE001 - any failure means "use the built-in rules"
        warnings.append("roles.toml classifier unavailable (%s: %s); using built-in rules" % (type(exc).__name__, exc))
        return None
    if not hasattr(table, "classify"):
        warnings.append("symbolize.load_roles() returned no classifier; using built-in rules")
        return None
    return table


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")
    os.replace(tmp, path)


class ModuleMap:
    """Address -> ELF module name from /proc/<pid>/maps snapshots (unix-call handle lookup)."""

    def __init__(self):
        self.ranges = []

    def load(self, path):
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                parts = line.split(None, 5)
                if len(parts) < 6:
                    continue
                target = parts[5].strip()
                if not target.endswith(".so"):
                    continue
                start, _, end = parts[0].partition("-")
                try:
                    self.ranges.append((int(start, 16), int(end, 16), os.path.basename(target)))
                except ValueError:
                    continue
        self.ranges.sort()

    def lookup(self, address):
        index = bisect.bisect_right(self.ranges, (address, float("inf"), "")) - 1
        if index >= 0:
            start, end, name = self.ranges[index]
            if start <= address < end:
                return name
        return None


class Tables:
    def __init__(self, data=None, path=None):
        self.data = data or {}
        self.path = path
        self.syscalls = self.data.get("syscalls", {})
        self.requests = self.data.get("requests", {})
        self.unixcalls = self.data.get("unixcalls", {})
        self.wine_version = self.data.get("wine_version")
        self.protocol = self.data.get("server_protocol_version")

    @classmethod
    def locate(cls, explicit, wine_version, warnings):
        here = os.path.dirname(os.path.abspath(__file__))
        candidates = []
        if explicit:
            candidates.append(explicit)
        elif wine_version:
            candidates.append(os.path.join(here, "tables", "wine-%s.json" % wine_version))
        candidates.extend(sorted(glob.glob(os.path.join(here, "tables", "wine-*.json"))))
        for path in candidates:
            if os.path.isfile(path):
                tables = cls(load_json(path), path)
                if wine_version and tables.wine_version and tables.wine_version != wine_version:
                    warnings.append("tables %s are for Wine %s but the runtime is %s" % (path, tables.wine_version, wine_version))
                return tables
        warnings.append("no id table found (looked for %s); ids stay numeric" % ", ".join(candidates) if candidates else "no id table found")
        return cls()

    def syscall_name(self, sid):
        name = self.syscalls.get("0x%04x" % sid)
        if name:
            return name
        return "syscall_0x%04x" % sid

    def request_name(self, number):
        return self.requests.get(str(number), "request_%d" % number)

    def unixcall_name(self, module, code):
        if module:
            codes = self.unixcalls.get(module[:-3] if module.endswith(".so") else module)
            if codes and str(code) in codes:
                return "%s:%s" % (module, codes[str(code)])
            return "%s#%d" % (module, code)
        return "unixcall#%d" % code


class Reducer:
    def __init__(self, options):
        self.opt = options
        self.warnings = []
        self.counters = collections.Counter()
        self.probe_hits = collections.Counter()
        self.mono_start_ns = None
        self.mono_end_ns = None
        self.last_event_ns = None
        self.lost_events = 0
        self.records = []
        self.names = {}
        self.tid_pid = {}
        self.pid_image = {}
        self.pid_comm = {}
        self.callback_tids = set()
        self.callback_tid = 0
        self.blocks = {}
        self.cycles_by_tid = collections.defaultdict(list)
        self.events = []
        self.wakes_by_tid = collections.defaultdict(list)
        self.offcpu_by_tid = collections.defaultdict(list)
        self.offcpu_ons = {}
        self.oncpu_by_tid = collections.defaultdict(list)
        self.tracer = {}
        self.modules = ModuleMap()
        self.tables = Tables()
        self.roles = None
        self.role_cache = {}
        # streaming state (format 2 reducer): sorted runs, per-kind line counts, @emitted
        self.trace_format = None
        self.trace_clock = None
        self.emitted = collections.Counter()
        self.received = collections.Counter()
        self.sort_chunk = []
        self.sort_runs = []
        self.sort_dir = None
        self.n_events = 0
        self.keep_events = bool(options is not None and getattr(options, "mode", "summary") == "drilldown")
        self.block_state = {}
        self.block_pending = {}
        self.block_agg = collections.defaultdict(dict)
        self.windows = collections.defaultdict(lambda: {"kinds": {}, "ids": {}, "wakeups": 0})
        self.kinds_total = collections.defaultdict(lambda: [0, 0])
        self.site_all = collections.defaultdict(lambda: [0, 0, 0])
        self.site_woken = collections.defaultdict(collections.Counter)
        self.hot_by_tid = collections.defaultdict(lambda: [0, 0])
        self.syscall_cache = {}
        self.unixcall_cache = {}

    # -- loading ------------------------------------------------------------------------------

    def load_tracer_json(self, path):
        if not path or not os.path.isfile(path):
            return
        try:
            self.tracer = load_json(path)
        except (OSError, ValueError) as exc:
            self.warnings.append("cannot read %s: %s" % (path, exc))
            return
        for entry in self.tracer.get("pids", []) or []:
            try:
                pid = int(entry.get("pid"))
            except (TypeError, ValueError, AttributeError):
                continue
            self.pid_image[pid] = entry.get("image") or ""
            self.pid_comm[pid] = entry.get("comm") or ""

    def load_maps(self, directory):
        for path in sorted(glob.glob(os.path.join(directory, "maps-*.txt"))):
            try:
                self.modules.load(path)
            except OSError as exc:
                self.warnings.append("cannot read %s: %s" % (path, exc))

    def load_events(self, path, sort_dir=None, chunk_lines=DEFAULT_SORT_CHUNK_LINES, extra_paths=()):
        """Pass 1: header/end/lost/@emitted lines, per-kind counts and sorted runs of event lines.

        Event lines are kept raw as (ts, file index, line); every ``chunk_lines`` lines the chunk is
        sorted and spilled to a run file under ``sort_dir`` (default: a temporary directory), so
        the memory of this pass is bounded by one chunk.  ``sorted_records`` merges the runs.
        """
        if not os.path.isfile(path):
            raise ReduceError("%s: events file missing" % path)
        chunk_lines = max(1, int(chunk_lines or DEFAULT_SORT_CHUNK_LINES))
        chunk = self.sort_chunk
        received = self.received
        min_ts = None
        kept = 0
        index = -1
        for source in [path] + [extra for extra in extra_paths if os.path.isfile(extra)]:
            with open(source, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    index += 1
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    first = line[0]
                    if first == "@":
                        match = EMITTED_RE.match(line)
                        if match:
                            code = int(match.group(1))
                            if 0 < code < 128:
                                self.emitted[chr(code)] += int(match.group(2))
                        continue
                    if first == "#":
                        continue
                    if first == "h":
                        match = HEADER_RE.match(line)
                        if match:
                            if self.mono_start_ns is None:
                                self.mono_start_ns = int(match.group(1))
                                fmt = HEADER_FORMAT_RE.search(line)
                                self.trace_format = int(fmt.group(1)) if fmt else 1
                                clock = HEADER_CLOCK_RE.search(line)
                                self.trace_clock = clock.group(1) if clock else None
                            else:
                                self.counters["duplicate_headers"] += 1
                            continue
                    if first == "e":
                        match = END_RE.match(line)
                        if match:
                            self.mono_end_ns = int(match.group(1))
                            continue
                    if first == "L":
                        match = LOST_RE.match(line)
                        if match:
                            self.lost_events += int(match.group(1))
                            self.counters["lost_event_lines"] += 1
                            continue
                    parts = line.split(" ", 2)
                    kind = parts[0]
                    if kind not in EVENT_KINDS:
                        self.counters["ignored_lines"] += 1
                        continue
                    try:
                        ts = int(parts[1])
                    except (IndexError, ValueError):
                        self.counters["malformed_lines"] += 1
                        continue
                    if source == path:
                        received[kind] += 1
                        # the tracer's own last event (tasks-stop.txt is stamped by the wrapper)
                        if self.last_event_ns is None or ts > self.last_event_ns:
                            self.last_event_ns = ts
                    if min_ts is None or ts < min_ts:
                        min_ts = ts
                    chunk.append((ts, index, line))
                    kept += 1
                    if len(chunk) >= chunk_lines:
                        self.spill_chunk(sort_dir)
                        chunk = self.sort_chunk
        if self.mono_start_ns is None:
            if not kept:
                self.cleanup()
                raise ReduceError("%s: no header line and no events" % path)
            self.mono_start_ns = min_ts
            self.warnings.append("no 'hdr mono_start_ns=' line; using the first event timestamp")
        self.sort_chunk.sort()
        if self.sort_runs:
            self.counters["sort_runs"] = len(self.sort_runs) + (1 if self.sort_chunk else 0)

    def spill_chunk(self, sort_dir):
        if self.sort_dir is None:
            if sort_dir:
                os.makedirs(sort_dir, exist_ok=True)
            self.sort_dir = tempfile.mkdtemp(prefix=".reduce-sort-", dir=sort_dir or None)
        chunk = self.sort_chunk
        chunk.sort()
        path = os.path.join(self.sort_dir, "run-%05d.txt" % len(self.sort_runs))
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.writelines(item[2] + "\n" for item in chunk)
        self.sort_runs.append(path)
        self.sort_chunk = []

    @staticmethod
    def iter_run(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                yield (int(line.split(" ", 2)[1]), line)

    def sorted_records(self):
        """Pass 2: parsed records in (timestamp, file order) order.

        Runs hold contiguous, ascending file-index ranges and heapq.merge is stable for equal
        keys, so ties keep their file order exactly as an in-memory sort by (ts, index) would.
        """
        tail = ((ts, line) for ts, _index, line in self.sort_chunk)
        if self.sort_runs:
            sources = [self.iter_run(path) for path in self.sort_runs] + [tail]
            merged = heapq.merge(*sources, key=lambda item: item[0])
        else:
            merged = tail
        probe_hits = self.probe_hits
        counters = self.counters
        try:
            for _ts, line in merged:
                try:
                    record = parse_line(line, 0)
                except (ValueError, KeyError, IndexError):
                    counters["malformed_lines"] += 1
                    continue
                if record is None:
                    counters["ignored_lines"] += 1
                    continue
                probe_hits[record[0]] += 1
                yield record
        finally:
            self.sort_chunk = []
            self.cleanup()

    def cleanup(self):
        if self.sort_dir is not None:
            shutil.rmtree(self.sort_dir, ignore_errors=True)
            self.sort_dir = None
            self.sort_runs = []

    # -- naming -------------------------------------------------------------------------------

    def role_of(self, tid):
        role = self.role_cache.get(tid)
        if role is not None:
            return role
        if tid in self.callback_tids:
            role = "pipeasio_callback"
        elif self.roles is not None:
            pid = self.tid_pid.get(tid, 0)
            try:
                role = self.roles.classify(self.names.get(tid, ""), exe=self.pid_image.get(pid) or None,
                                           pid=pid or None, tid=tid, process_comm=self.pid_comm.get(pid))
            except Exception as exc:  # noqa: BLE001
                self.warnings.append("roles.toml classifier failed (%s); using built-in rules" % exc)
                self.roles = None
                role = self.builtin_role(tid)
        else:
            role = self.builtin_role(tid)
        self.role_cache[tid] = role
        return role

    def builtin_role(self, tid):
        """Built-in copy of the roles.toml rules (design B section 5)."""
        comm = self.names.get(tid, "")
        pid = self.tid_pid.get(tid, 0)
        image = (self.pid_image.get(pid) or "").lower()
        if comm == "AudioCalc":
            role = "audio_worker"
        elif comm == "pipeasio-rt":
            role = "pipeasio_rt"
        elif comm == "pipeasio-worker":
            role = "pipeasio_worker"
        elif image == "wineserver" or comm == "wineserver" or (self.pid_comm.get(pid) == "wineserver"):
            role = "wineserver"
        elif image == "msedgewebview2.exe":
            role = "webview"
        elif image == "max.exe":
            role = "max"
        elif image == "push2displayprocess.exe":
            role = "push2"
        elif tid == pid and image.endswith(".exe"):
            role = "main"
        elif (image.startswith("ableton live") and comm and self.pid_comm.get(pid) is not None
              and comm != self.pid_comm[pid]):
            # Named Live threads only; like roles.toml's `named`, this needs the process comm.
            role = "live:%s" % comm
        else:
            role = "unknown:%s" % (comm or tid)
        return role

    def syscall_caller(self, sid):
        cached = self.syscall_cache.get(sid)
        if cached is None:
            name = self.tables.syscall_name(sid)
            module = "win32u.dll" if sid >= 0x1000 else "ntdll.dll"
            cached = self.syscall_cache[sid] = (name, "%s!%s+0x14" % (module, name))
        return cached

    def unixcall_id(self, handle, code):
        key = (handle, code)
        cached = self.unixcall_cache.get(key)
        if cached is None:
            module = self.modules.lookup(handle)
            cached = self.unixcall_cache[key] = (module, self.tables.unixcall_name(module, code))
        module, name = cached
        if module is None and self.modules.ranges:
            self.counters["unixcall_handle_unmapped"] += 1
        return name

    # -- processing ---------------------------------------------------------------------------

    def process(self):
        stacks = collections.defaultdict(list)
        seen_entry = set()
        pending_wait = {}
        pending_r = {}
        emit = self.emit
        counters = self.counters
        for rec in self.sorted_records():
            kind = rec[0]
            ts = rec[1]
            if kind == "E":
                _, _, tid, what, ident, code, frame, seq, _rsp, rip = rec
                if what == "syscall":
                    name, caller = self.syscall_caller(ident)
                else:
                    name = self.unixcall_id(ident, code)
                    caller = "pe!0x%x" % rip
                entry = [what, name, caller, frame, ts, seq]
                if frame is None:
                    # format 3 unix call: frame and PE caller arrive in the R line of the second
                    # program on the same probe (normally just after this line, same thread)
                    pending = pending_r.pop(tid, None)
                    if pending is not None and abs(ts - pending[2]) <= R_JOIN_WINDOW_NS:
                        entry[3], entry[2] = pending[0], "pe!0x%x" % pending[1]
                stacks[tid].append(entry)
                seen_entry.add(tid)
                if len(stacks[tid]) > 64:
                    stacks[tid].pop(0)
                    counters["stack_overflow_drops"] += 1
            elif kind == "R":
                _, _, tid, frame, rip = rec
                for entry in reversed(stacks[tid]):
                    if entry[0] == "unixcall" and entry[3] is None:
                        if abs(ts - entry[4]) <= R_JOIN_WINDOW_NS:
                            entry[3], entry[2] = frame, "pe!0x%x" % rip
                        else:
                            counters["unixcall_r_lines_too_late"] += 1
                        break
                else:
                    pending_r[tid] = (frame, rip, ts)
            elif kind == "X":
                _, _, tid, what, _ident, frame, status, _rflags = rec
                stack = stacks[tid]
                depth = None
                for index in range(len(stack) - 1, -1, -1):
                    if stack[index][3] == frame and stack[index][0] == what:
                        depth = index
                        break
                if depth is None:
                    # Thread start (init_syscall_frame's tail), NtContinue/exception returns and
                    # the unix-call slow path all reach the dispatcher return label without a
                    # matching entry.  (Format 3 prints no restore_flags, so the former
                    # unmatched_exits_with_restore_flags split is gone.)
                    counters["unmatched_exits"] += 1
                    if tid not in seen_entry and not stack:
                        counters["unmatched_exits_first_on_tid"] += 1
                    continue
                abandoned = len(stack) - depth - 1
                if abandoned:
                    counters["abandoned_entries"] += abandoned
                entry = stack[depth]
                del stack[depth:]
                dur = ts - entry[4]
                if dur < 0 or dur > MAX_DURATION_NS:
                    counters["invalid_durations"] += 1
                    continue
                emit((entry[0], entry[1], entry[2], tid, entry[4], ts, entry[5], status, None))
            elif kind == "S":
                _, _, tid, what, value, dur, status, seq = rec
                if dur < 0 or dur > MAX_DURATION_NS:
                    counters["invalid_durations"] += 1
                    continue
                if what == "req":
                    name = self.tables.request_name(value)
                    ekind = "server_req"
                else:
                    names = flag_names(value, SELECT_FLAG_NAMES)
                    name = "|".join(names) if names else "0"
                    ekind = "server_wait"
                enclosing = stacks[tid][-1] if stacks[tid] else None
                if enclosing is None:
                    counters["%s_without_enclosing" % ekind] += 1
                    caller = "none"
                else:
                    caller = enclosing[2]
                emit((ekind, name, caller, tid, ts - dur, ts, seq, status, None))
            elif kind == "W":
                _, _, tid, cmd, count, alert, owner, seq = rec
                if tid in pending_wait:
                    counters["ntsync_wait_without_exit"] += 1
                pending_wait[tid] = (ts, cmd, count, alert, owner, seq)
            elif kind == "w":
                _, _, tid, ret, idx = rec
                pending = pending_wait.pop(tid, None)
                if pending is None:
                    counters["ntsync_wait_exit_without_entry"] += 1
                    continue
                t0, cmd, count, alert, owner, seq = pending
                name = NTSYNC_WAIT_CMDS.get(cmd, "cmd_0x%x" % cmd)
                enclosing = stacks[tid][-1] if stacks[tid] else None
                caller = enclosing[2] if enclosing else "none"
                if enclosing is None:
                    counters["ntsync_wait_without_enclosing"] += 1
                extra = {"count": count, "alert": alert, "owner": owner, "index": idx}
                woken = self.find_waker(tid, t0, ts)
                if woken is not None:
                    extra["woken_by"] = woken
                emit(("ntsync_wait", name, caller, tid, t0, ts, seq, ret, extra))
            elif kind == "K":
                _, _, tid, pid, cmd, seq = rec
                self.tid_pid.setdefault(tid, pid)
                name = NTSYNC_WAKE_CMDS.get(cmd, "cmd_0x%x" % cmd)
                enclosing = stacks[tid][-1] if stacks[tid] else None
                caller = enclosing[2] if enclosing else "none"
                emit(("ntsync_wake", name, caller, tid, ts, ts, seq, 0, None))
            elif kind == "B":
                _, _, tid, phase, seq, fields = rec
                block = self.blocks.setdefault(seq, {})
                if phase == "start":
                    self.callback_tids.add(tid)
                    self.callback_tid = tid
                    block["start"] = (ts, tid, int(fields.get("n", "0")), int(fields.get("rate", "0")),
                                      int(fields.get("clk", "0")), int(fields.get("dl", "0")))
                    self.role_cache.pop(tid, None)
                    cycles = self.cycles_by_tid.get(tid)
                    if cycles and cycles[-1][1] is None:
                        cycles[-1][2] = seq
                    if self.block_state.get(seq) is None:
                        self.block_state[seq] = BLOCK_OPEN
                    else:
                        counters["duplicate_block_starts"] += 1
                elif phase == "before":
                    block["before"] = ts
                elif phase == "after":
                    block["after"] = ts
                elif phase == "end":
                    block["end"] = (ts, int(fields.get("fl", "0"), 16), int(fields.get("missed", "0")))
                    self.close_block(seq)
                else:
                    counters["unknown_block_phase"] += 1
            elif kind == "C":
                _, _, tid, phase, fields = rec
                cycles = self.cycles_by_tid[tid]
                if phase == "start":
                    cycles.append([ts, None, None, fields])
                elif phase == "end" and cycles and cycles[-1][1] is None:
                    cycles[-1][1] = ts
                    cycles[-1][3] = dict(cycles[-1][3], **fields)
                else:
                    counters["unpaired_cycle_lines"] += 1
            elif kind == "U":
                _, _, waker_tid, waker_pid, wakee = rec
                self.tid_pid.setdefault(waker_tid, waker_pid)
                self.wakes_by_tid[wakee].append((ts, waker_tid))
            elif kind == "O":
                _, ts_on, tid, ts_off, ts_wake, state = rec
                if ts_off > ts_on:
                    counters["invalid_offcpu_intervals"] += 1
                    continue
                intervals = self.offcpu_by_tid[tid]
                if intervals:
                    previous_on = intervals[-1][1]
                    if ts_off >= previous_on:
                        self.oncpu_by_tid[tid].append((previous_on, ts_off))
                intervals.append((ts_off, ts_on, ts_wake, state))
            elif kind == "T":
                _, _, tid, pid, comm = rec
                self.tid_pid.setdefault(tid, pid)
                self.names.setdefault(tid, comm)
                if tid == pid and pid not in self.pid_comm:
                    self.pid_comm[pid] = comm
            elif kind == "N":
                _, _, tid, comm = rec
                self.names[tid] = comm
                self.role_cache.pop(tid, None)
            elif kind == "P":
                _, _, pid, _parent, comm = rec
                self.pid_comm.setdefault(pid, comm)
                self.pid_image.setdefault(pid, comm)
        for tid, stack in stacks.items():
            if stack:
                counters["open_entries_at_end"] += len(stack)
                counters["unixcall_entries_without_r"] += sum(1 for entry in stack if entry[3] is None)
        counters["unixcall_r_lines_unmatched"] += len(pending_r)
        counters["ntsync_wait_without_exit"] += len(pending_wait)
        # Blocks that never ended (trace stopped mid-block, lost end line): their events go to
        # the window buckets, like events of any block without a record.
        for seq in sorted(self.block_pending):
            for event in self.block_pending[seq]:
                self.to_window(event, unknown_block=True)
        self.block_pending = {}
        for wakes in self.wakes_by_tid.values():
            wakes.sort()
        if self.keep_events:
            self.events.sort(key=lambda event: event[4])

    # -- streaming aggregation ----------------------------------------------------------------

    def emit(self, event):
        """Account one completed crossing: global totals at once, then its block or window."""
        kind, name, caller, tid, t0, t1, seq, _status, extra = event
        self.n_events += 1
        if self.keep_events:
            self.events.append(event)
        dur = t1 - t0
        total = self.kinds_total[kind]
        total[0] += 1
        total[1] += dur
        site_key = (kind, name, caller)
        site = self.site_all[site_key]
        site[0] += 1
        site[1] += dur
        if dur > site[2]:
            site[2] = dur
        woken = extra.get("woken_by") if extra else None
        if woken is not None:
            self.site_woken[site_key][woken] += 1
        hot = self.hot_by_tid[(tid, kind, name, caller)]
        hot[0] += 1
        hot[1] += dur
        if not seq:
            self.to_window(event)
            return
        state = self.block_state.get(seq)
        if state is BLOCK_OPEN:
            self.block_pending.setdefault(seq, []).append(event)
        elif state is BLOCK_DONE:
            self.to_block(seq, event)
        else:
            self.to_window(event, unknown_block=True)

    def close_block(self, seq):
        """A block_end line: decide once whether the block gets a record (see build_blocks)."""
        block = self.blocks.get(seq, {})
        if self.block_state.get(seq) is BLOCK_DONE:
            self.counters["duplicate_block_ends"] += 1
            return
        pending = self.block_pending.pop(seq, ())
        if (seq != 0 and self.block_state.get(seq) is BLOCK_OPEN and "start" in block
                and block["end"][0] >= block["start"][0]):
            self.block_state[seq] = BLOCK_DONE
            for event in pending:
                self.to_block(seq, event)
        else:
            if self.block_state.get(seq) is not None:
                self.block_state[seq] = BLOCK_DROPPED
            for event in pending:
                self.to_window(event, unknown_block=True)

    def to_block(self, seq, event):
        kind, name, caller, tid, t0, t1, _seq, _status, extra = event
        block = self.blocks[seq]
        window_ns = self.opt.window_ms * 10**6
        if not block["start"][0] - window_ns <= t0 <= block["end"][0] + window_ns:
            self.counters["events_outside_their_block"] += 1
        dur = t1 - t0
        agg = self.block_agg[seq].get((tid, kind, name, caller))
        if agg is None:
            agg = self.block_agg[seq][(tid, kind, name, caller)] = [0, 0, 0, None]
        agg[0] += 1
        agg[1] += dur
        if dur > agg[2]:
            agg[2] = dur
        woken = extra.get("woken_by") if extra else None
        if woken is not None:
            if agg[3] is None:
                agg[3] = collections.Counter()
            agg[3][woken] += 1

    def to_window(self, event, unknown_block=False):
        kind, name, _caller, tid, t0, t1, _seq, _status, _extra = event
        if unknown_block:
            self.counters["events_for_unknown_block"] += 1
        dur = t1 - t0
        bucket = self.windows[((t0 - self.mono_start_ns) // (self.opt.window_ms * 10**6), tid)]
        kind_agg = bucket["kinds"].get(kind)
        if kind_agg is None:
            kind_agg = bucket["kinds"][kind] = [0, 0]
        kind_agg[0] += 1
        kind_agg[1] += dur
        id_agg = bucket["ids"].get((kind, name))
        if id_agg is None:
            id_agg = bucket["ids"][(kind, name)] = [0, 0]
        id_agg[0] += 1
        id_agg[1] += dur

    def find_waker(self, tid, t0, t1):
        wakes = self.wakes_by_tid.get(tid)
        if not wakes:
            return None
        index = bisect.bisect_right(wakes, (t1, float("inf"))) - 1
        if index >= 0 and wakes[index][0] >= t0:
            return wakes[index][1]
        return None

    # -- blocks -------------------------------------------------------------------------------

    def offset(self, ns):
        return round((ns - self.mono_start_ns) / 1e9, 6)

    def build_blocks(self):
        records = {}
        periods = []
        for seq in sorted(self.blocks):
            block = self.blocks[seq]
            if "start" not in block or "end" not in block or seq == 0:
                self.counters["incomplete_blocks"] += 1
                continue
            t_start, tid, nframes, rate, clock_nsec, deadline_ns = block["start"]
            t_end, flags, missed = block["end"]
            if t_end < t_start:
                self.counters["invalid_blocks"] += 1
                continue
            if self.block_state.get(seq) is not BLOCK_DONE:
                # start line sorted after the end line (lost or skewed): its crossings already
                # went to the window buckets, so it gets no record either
                self.counters["incomplete_blocks"] += 1
                continue
            period_ns = (nframes * 10**9 + rate // 2) // rate if rate else 0
            periods.append(period_ns)
            before = block.get("before")
            after = block.get("after")
            record = {
                "seq": seq,
                "t_start": self.offset(t_start),
                "t_before_live": self.offset(before) if before is not None else None,
                "t_after_live": self.offset(after) if after is not None else None,
                "t_end": self.offset(t_end),
                "clock_nsec": clock_nsec,
                "deadline_ns": deadline_ns,
                "period_ns": period_ns,
                "nframes": nframes,
                "rate": rate,
                "callback_tid": tid,
                "wake_latency_ns": t_start - clock_nsec if clock_nsec else None,
                "pre_ns": before - t_start if before is not None else None,
                "live_ns": after - before if before is not None and after is not None else None,
                "post_ns": t_end - after if after is not None else None,
                "elapsed_ns": t_end - t_start,
                "slack_ns": deadline_ns - t_end if deadline_ns else None,
                "late": False,
                "near_late": False,
                "missed_cycles": missed,
                "flags": flag_names(flags, BLOCK_FLAG_NAMES),
                "crossings": [],
                "offcpu": [],
                "stacks": [],
                "_t0": t_start,
                "_t1": t_end,
                "_agg": self.block_agg.pop(seq, {}),
            }
            records[seq] = record
        if periods:
            mode_period = collections.Counter(periods).most_common(1)[0][0]
        else:
            mode_period = 0
        self.deadline_ns_mode = mode_period
        self.near_late_slack_ns = int(round(mode_period * self.opt.near_late_fraction))
        for record in records.values():
            slack = record["slack_ns"]
            if slack is None:
                continue
            if slack < 0:
                record["late"] = True
            elif slack < self.near_late_slack_ns:
                record["near_late"] = True
        self.block_records = records
        self.attach_cycles()

    def attach_cycles(self):
        for tid, cycles in self.cycles_by_tid.items():
            for c_start, c_end, seq, fields in cycles:
                if seq is None or seq not in self.block_records:
                    continue
                record = self.block_records[seq]
                cycle = {"t_start": self.offset(c_start), "pre_ns": record["_t0"] - c_start}
                if c_end is not None:
                    cycle["t_end"] = self.offset(c_end)
                    cycle["post_ns"] = c_end - record["_t1"]
                    cycle["missed"] = int(fields.get("missed", "0"))
                    cycle["delivered"] = int(fields.get("delivered", "0"))
                record["cycle"] = cycle

    def aggregate(self):
        """Finish the streaming aggregation: wakeups per window, then the block rollups."""
        window_ns = self.opt.window_ms * 10**6
        for tid, wakes in self.wakes_by_tid.items():
            for ts, _ in wakes:
                self.windows[((ts - self.mono_start_ns) // window_ns, tid)]["wakeups"] += 1
        self.block_agg.clear()
        self.finish_blocks()

    def finish_blocks(self):
        lost_total = 0
        attributed_total = 0
        sites = collections.defaultdict(lambda: {
            "late_blocks": 0, "near_late_blocks": 0, "n_in_late_blocks": 0, "total_ns_in_late_blocks": 0,
            "attributed_ns": 0.0, "blocks_with_site": 0,
        })
        self.sites = sites
        for record in self.block_records.values():
            crossings = []
            for (tid, kind, name, caller), (n, total, maximum, woken) in record["_agg"].items():
                crossing = {
                    "tid": tid, "role": self.role_of(tid), "kind": kind, "id": name, "caller": caller,
                    "n": n, "total_ns": total, "max_ns": maximum,
                }
                if woken:
                    waker, count = woken.most_common(1)[0]
                    crossing["woken_by"] = {"tid": waker, "role": self.role_of(waker), "count": count}
                crossings.append(crossing)
            crossings.sort(key=lambda item: (-item["total_ns"], item["tid"], item["kind"], item["id"]))
            record["crossings"] = crossings
            record["offcpu"] = self.block_offcpu(record)
            if record["late"] or record["near_late"]:
                lost = self.near_late_slack_ns - record["slack_ns"]
                crossing_total = sum(item["total_ns"] for item in crossings)
                attributed = min(lost, crossing_total)
                lost_total += lost
                attributed_total += attributed
                for item in crossings:
                    site = sites[(item["kind"], item["id"], item["caller"])]
                    site["blocks_with_site"] += 1
                    if record["late"]:
                        site["late_blocks"] += 1
                    else:
                        site["near_late_blocks"] += 1
                    site["n_in_late_blocks"] += item["n"]
                    site["total_ns_in_late_blocks"] += item["total_ns"]
                    if crossing_total:
                        site["attributed_ns"] += attributed * item["total_ns"] / crossing_total
        self.lost_slack = {
            "definition": "sum over late and near-late blocks of (near_late_slack_ns - slack_ns)",
            "total_ns": lost_total,
            "attributed_ns": int(round(attributed_total)),
            "unattributed_ns": lost_total - int(round(attributed_total)),
        }

    def block_offcpu(self, record):
        """Off-CPU time of the audio-role threads inside [t_start, t_end] of one block."""
        result = []
        t0, t1 = record["_t0"], record["_t1"]
        for tid, intervals in self.offcpu_by_tid.items():
            if self.role_of(tid) not in AUDIO_ROLES:
                continue
            # Intervals of one tid are disjoint and ordered, so the switch-in timestamps are
            # sorted too: start at the first interval that ends after the block starts.
            ons = self.offcpu_ons.setdefault(tid, [interval[1] for interval in intervals])
            total = 0
            count = 0
            max_delay = 0
            index = bisect.bisect_right(ons, t0)
            while index < len(intervals):
                off, on, wake, _state = intervals[index]
                if off >= t1:
                    break
                total += min(on, t1) - max(off, t0)
                count += 1
                if wake and off <= wake <= on:
                    max_delay = max(max_delay, on - wake)
                index += 1
            if count:
                result.append({"tid": tid, "role": self.role_of(tid), "ns": total, "intervals": count,
                               "max_run_delay_ns": max_delay})
        result.sort(key=lambda item: -item["ns"])
        return result

    # -- windows ------------------------------------------------------------------------------

    def sched_window_stats(self, tids):
        """Per (window, tid) on/off-CPU nanoseconds and run-queue delay from sched records."""
        window_ns = self.opt.window_ms * 10**6
        stats = collections.defaultdict(lambda: [0, 0, 0])
        base = self.mono_start_ns

        def spread(tid, start, end, slot):
            if end <= start:
                return
            first = (start - base) // window_ns
            last = (end - 1 - base) // window_ns
            for index in range(first, last + 1):
                lo = max(start, base + index * window_ns)
                hi = min(end, base + (index + 1) * window_ns)
                stats[(index, tid)][slot] += hi - lo

        for tid in tids:
            for off, on, wake, _state in self.offcpu_by_tid.get(tid, ()):
                spread(tid, off, on, 1)
                if wake and off <= wake <= on:
                    stats[((wake - base) // window_ns, tid)][2] += on - wake
            for start, end in self.oncpu_by_tid.get(tid, ()):
                spread(tid, start, end, 0)
        return stats

    def window_records(self):
        """Return [(window_index, record)] for threads.jsonl."""
        window_ms = self.opt.window_ms
        between_events = 0
        tids = set(tid for _, tid in self.windows) | set(self.offcpu_by_tid)
        sched = self.sched_window_stats(tids) if (self.offcpu_by_tid or self.oncpu_by_tid) else {}
        keys = set(self.windows) | set(sched)
        records = []
        for index, tid in sorted(keys):
            bucket = self.windows.get((index, tid)) or {"kinds": {}, "ids": {}, "wakeups": 0}
            oncpu, offcpu, delay = sched.get((index, tid), (None, None, None))
            top = sorted(bucket["ids"].items(), key=lambda item: (-item[1][1], item[0]))[:5]
            record = {
                "t": round(index * window_ms / 1000.0, 3),
                "window_ms": window_ms,
                "pid": self.tid_pid.get(tid, 0),
                "tid": tid,
                "comm": self.names.get(tid, ""),
                "role": self.role_of(tid),
                "oncpu_ns": oncpu,
                "offcpu_ns": offcpu,
                "wakeups": bucket["wakeups"],
                "run_delay_ns": delay,
                "crossings": {kind: {"n": n, "total_ns": total} for kind, (n, total) in sorted(bucket["kinds"].items())},
                "top_ids": [[name, n, total] for (_kind, name), (n, total) in top],
            }
            if tid in self.callback_tids and bucket["kinds"]:
                # every window-bucket crossing of the callback thread happened between blocks
                n = sum(value[0] for value in bucket["kinds"].values())
                record["between_blocks"] = {"n": n, "total_ns": sum(value[1] for value in bucket["kinds"].values())}
                between_events += n
            records.append((index, record))
        if between_events:
            self.counters["between_blocks_events"] = between_events
        return records

    # -- summary ------------------------------------------------------------------------------

    def header(self, kind):
        tracer = self.tracer
        return {
            "type": "header",
            "file": kind,
            "roles": "roles.toml" if self.roles is not None else "builtin",
            "monotonic_start_ns": self.mono_start_ns,
            "monotonic_end_ns": self.mono_end_ns,
            "version": tracer.get("version", "proto-bpftrace"),
            "reducer": REDUCER_VERSION,
            "wine_version": tracer.get("wine_version") or self.tables.wine_version,
            "tables": os.path.basename(self.tables.path) if self.tables.path else None,
            "server_protocol_version": self.tables.protocol,
            "pids": [entry.get("pid") for entry in tracer.get("pids", []) or [] if isinstance(entry, dict)],
            "mode": self.opt.mode,
            "sample": {"rate": tracer.get("sample_rate", 1)},
            "near_late_fraction": self.opt.near_late_fraction,
            "window_ms": self.opt.window_ms,
        }

    def loss_accounting(self):
        """lost_events and its evidence (see the module docstring); computed once."""
        cached = getattr(self, "_loss", None)
        if cached is not None:
            return cached
        reported = self.lost_events + (self.opt.lost_events_extra if self.opt is not None else 0)
        rmisses = int(getattr(self.opt, "recursion_misses", 0) or 0) if self.opt is not None else 0
        by_kind = {}
        lag = 0
        emitted = self.expected_lines()
        lower_bound = False
        if emitted:
            for kind, count in sorted(emitted.items()):
                got = self.received.get(kind, 0)
                if count > got:
                    by_kind[kind] = count - got
                elif got > count:
                    lag += got - count
            shortfall = sum(by_kind.values())
            # bpftrace's "Lost N" and the shortfall count the same dropped records: never add them
            total = max(reported, shortfall) + rmisses
            source = "emitted_counters"
            lower_bound = lag > 0
            if total:
                self.warnings.append("%d events lost (%s%s); per kind %s" % (
                    total, "bpftrace reports %d, shortfall %d" % (reported, shortfall) if reported else "ring buffer drops %d" % shortfall,
                    ", %d fentry/fexit recursion misses" % rmisses if rmisses else "",
                    ", ".join("%s=%d" % item for item in sorted(by_kind.items())) or "-"))
            if lag:
                self.warnings.append("%d lines arrived after the @emitted counters were read: lost_events is a "
                                     "lower bound (a shortfall of up to that size can hide behind them)" % lag)
        elif (self.trace_format or 1) >= 2 or self.mono_end_ns is None:
            total = None
            source = "unknown"
            self.warnings.append("lost events unknown: the trace has no @emitted counters (the tracer did not "
                                 "exit cleanly: no END output)%s" % (" and bpftrace reported %d" % reported if reported else ""))
        else:
            total = reported + rmisses
            source = "bpftrace_reports"
        self._loss = {
            "total": total,
            "source": source,
            "lower_bound": lower_bound,
            "reported_by_bpftrace": reported,
            "recursion_misses": rmisses,
            "by_kind": by_kind,
            "emitted": dict(sorted(emitted.items())),
            "received": dict(sorted(self.received.items())),
            "received_after_counters": lag,
        }
        return self._loss

    def stopped_ns(self):
        """End of the traced interval: the END line, else (crashed/killed tracer) its last event --
        never the wrapper's stop time, which would claim coverage the trace does not have."""
        if self.mono_end_ns is not None:
            return self.mono_end_ns
        if self.last_event_ns is not None:
            return self.last_event_ns
        return self.mono_start_ns

    def expected_lines(self):
        """Lines per kind the tracer printed, from @emitted.  Format 3 counts the unix-call entry
        under 'e' (101): one E and one R line each (the R program has no count of its own)."""
        emitted = collections.Counter()
        for kind, count in self.emitted.items():
            if kind == "e":
                emitted["E"] += count
                emitted["R"] += count
            else:
                emitted[kind] += count
        return emitted

    def summary(self, blocks, windows):
        slacks = sorted(record["slack_ns"] for record in blocks if record["slack_ns"] is not None)
        elapsed = sorted(record["elapsed_ns"] for record in blocks)
        periods = sorted(record["period_ns"] for record in blocks)
        late = sum(1 for record in blocks if record["late"])
        near_late = sum(1 for record in blocks if record["near_late"])
        if blocks:
            span_ns = blocks[-1]["_t1"] - blocks[0]["_t0"]
        else:
            span_ns = 0
        minutes = span_ns / 60e9 if span_ns > 0 else 0
        lost_total = self.lost_slack["total_ns"]
        call_sites = []
        for (kind, name, caller), site in self.sites.items():
            overall = self.site_all.get((kind, name, caller), [0, 0, 0])
            woken = [{"tid": tid, "role": self.role_of(tid), "count": count}
                     for tid, count in self.site_woken.get((kind, name, caller), collections.Counter()).most_common(5)]
            call_sites.append({
                "rank": 0,
                "key": "%s|%s|%s" % (kind, name, caller),
                "kind": kind,
                "name": name,
                "caller": caller,
                "late_blocks": site["late_blocks"],
                "near_late_blocks": site["near_late_blocks"],
                "n_in_late_blocks": site["n_in_late_blocks"],
                "per_late_block": round(site["n_in_late_blocks"] / site["blocks_with_site"], 3) if site["blocks_with_site"] else 0.0,
                "total_ns_in_late_blocks": site["total_ns_in_late_blocks"],
                "max_ns": overall[2],
                "share_of_lost_slack": round(site["attributed_ns"] / lost_total, 4) if lost_total else 0.0,
                "n_all_blocks": overall[0],
                "total_ns_all_blocks": overall[1],
                "woken_by": woken,
            })
        call_sites.sort(key=lambda item: (-item["total_ns_in_late_blocks"], -item["n_in_late_blocks"], item["key"]))
        for rank, site in enumerate(call_sites, 1):
            site["rank"] = rank
        kinds = {kind: {"n": n, "total_ns": total} for kind, (n, total) in sorted(self.kinds_total.items())}
        roles = self.role_summary(windows)
        hotspots = self.hotspots()
        counters = dict(sorted(self.counters.items()))
        blocks_per_minute = len(blocks) / minutes if minutes else 0.0
        hits_per_block = (sum(self.probe_hits[kind] for kind in ("E", "X", "S", "W", "w", "K")) / len(blocks)) if blocks else 0.0
        tracer = dict(self.tracer)
        loss = self.loss_accounting()
        tracer_section = {
            "version": tracer.get("version", "proto-bpftrace"),
            "backend": tracer.get("backend", "bpftrace"),
            "mode": self.opt.mode,
            "sample_rate": tracer.get("sample_rate", 1),
            "attach": tracer.get("attach", []),
            "lost_events": loss["total"],
            "loss": loss,
            "clean_exit": self.mono_end_ns is not None,
            "clock": self.trace_clock,
            "started_monotonic_ns": self.mono_start_ns,
            "stopped_monotonic_ns": self.stopped_ns(),
            "overhead_estimate_ns_per_block": int(round(hits_per_block * self.opt.ns_per_hit)),
            "overhead_estimate": {
                "assumed_ns_per_hit": self.opt.ns_per_hit,
                "hits_per_block": round(hits_per_block, 2),
                "note": "prototype estimate: probe hits per block x assumed cost; not a measurement",
            },
        }
        return {
            "schema": SUMMARY_SCHEMA,
            "tracer": tracer_section,
            "thresholds": {
                "near_late_fraction": self.opt.near_late_fraction,
                "deadline_ns_mode": self.deadline_ns_mode,
                "near_late_slack_ns": self.near_late_slack_ns,
            },
            "blocks": {
                "count": len(blocks),
                "late": late,
                "near_late": near_late,
                "late_per_minute": round(late / minutes, 3) if minutes else 0.0,
                "blocks_per_minute": round(blocks_per_minute, 1),
                "slack_ns": {"min": slacks[0] if slacks else None, "p01": percentile(slacks, 1),
                             "p50": percentile(slacks, 50), "p99": percentile(slacks, 99)},
                "elapsed_ns": {"p50": percentile(elapsed, 50), "p99": percentile(elapsed, 99),
                               "max": elapsed[-1] if elapsed else None},
                "deadline_ns": {"min": periods[0] if periods else None, "max": periods[-1] if periods else None},
                "missed_cycles": sum(record["missed_cycles"] for record in blocks),
                "incomplete": self.counters.get("incomplete_blocks", 0),
            },
            "lost_slack": self.lost_slack,
            "call_sites": call_sites,
            "kinds": kinds,
            "roles": roles,
            "hotspots_non_audio": hotspots,
            "counters": {
                "unmatched_exits": counters.get("unmatched_exits", 0),
                "unmatched_exits_first_on_tid": counters.get("unmatched_exits_first_on_tid", 0),
                "abandoned_entries": counters.get("abandoned_entries", 0),
                "ringbuf_drops": 0,
                "lost_events": loss["total"],
                "probe_hits": dict(sorted(self.probe_hits.items())),
                "events": self.n_events,
                "all": counters,
            },
            "warnings": list(self.warnings),
        }

    def role_summary(self, windows):
        per_role = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
        for index, record in windows:
            agg = per_role[record["role"]][index]
            for stats in record["crossings"].values():
                agg[0] += stats["n"]
                agg[1] += stats["total_ns"]
        roles = {}
        for role, bins in sorted(per_role.items()):
            counts = sorted(value[0] for value in bins.values())
            totals = sorted(value[1] for value in bins.values())
            roles[role] = {
                "bins": len(bins),
                "crossings_per_100ms": {"p50": percentile(counts, 50), "p99": percentile(counts, 99)},
                "total_ns_per_100ms": {"p50": percentile(totals, 50), "p99": percentile(totals, 99)},
            }
        return roles

    def hotspots(self):
        """Top (role, kind, id, caller) sites of the non-audio threads over the whole trace."""
        agg = collections.defaultdict(lambda: [0, 0])
        for (tid, kind, name, caller), (n, total) in self.hot_by_tid.items():
            role = self.role_of(tid)
            if role in AUDIO_ROLES:
                continue
            entry = agg[(role, kind, name, caller)]
            entry[0] += n
            entry[1] += total
        items = [
            {"role": role, "kind": kind, "name": name, "caller": caller, "n": n, "total_ns": total}
            for (role, kind, name, caller), (n, total) in agg.items()
        ]
        items.sort(key=lambda item: (-item["total_ns"], item["role"], item["kind"], item["name"]))
        return items[: self.opt.top]

    # -- output -------------------------------------------------------------------------------

    def write_outputs(self, out_dir):
        os.makedirs(out_dir, exist_ok=True)
        blocks = [self.block_records[seq] for seq in sorted(self.block_records)]
        windows = self.window_records()
        self.write_jsonl(os.path.join(out_dir, "blocks.jsonl"), "blocks", (self.public_block(record) for record in blocks))
        self.write_jsonl(os.path.join(out_dir, "threads.jsonl"), "threads", (record for _, record in windows))
        summary = self.summary(blocks, windows)
        write_json(os.path.join(out_dir, "summary.json"), summary)
        if self.opt.mode == "drilldown":
            self.write_jsonl(os.path.join(out_dir, "events.jsonl"), "events", self.public_events())
        return summary

    def public_block(self, record):
        public = {key: value for key, value in record.items() if not key.startswith("_")}
        return public

    def public_events(self):
        for kind, name, caller, tid, t0, t1, seq, status, extra in self.events:
            event = {
                "t": self.offset(t0), "tid": tid, "role": self.role_of(tid), "kind": kind, "id": name,
                "caller": caller, "dur_ns": t1 - t0,
                "status": status if kind in ("ntsync_wait", "ntsync_wake") else "0x%x" % status,
                "seq": seq,
            }
            if extra:
                event.update({key: value for key, value in extra.items() if key != "woken_by"})
                if "woken_by" in extra:
                    event["woken_by"] = {"tid": extra["woken_by"], "role": self.role_of(extra["woken_by"])}
            yield event

    def write_jsonl(self, path, kind, records):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(self.header(kind), sort_keys=False) + "\n")
            for record in records:
                handle.write(json.dumps(record, sort_keys=False) + "\n")
        os.replace(tmp, path)

    def update_tracer_json(self, path, summary):
        if not path:
            return
        data = dict(self.tracer) if self.tracer else {}
        data["stopped_monotonic_ns"] = self.stopped_ns()
        loss = self.loss_accounting()
        data["lost_events"] = loss["total"]
        data["loss"] = loss
        data["clean_exit"] = self.mono_end_ns is not None
        if self.trace_clock:
            data["clock"] = self.trace_clock
        data["probe_hits"] = dict(sorted(self.probe_hits.items()))
        # The Counter holds only keys that were incremented; validate.py needs the pairing counters
        # even when they are zero (design B section 7: abandoned_entries == 0).
        counters = dict(summary["counters"]["all"])
        for key in ("unmatched_exits", "unmatched_exits_first_on_tid", "abandoned_entries"):
            counters.setdefault(key, summary["counters"][key])
        data["counters"] = counters
        data["blocks"] = {"count": summary["blocks"]["count"], "late": summary["blocks"]["late"],
                          "near_late": summary["blocks"]["near_late"]}
        data["overhead_estimate_ns_per_block"] = summary["tracer"]["overhead_estimate_ns_per_block"]
        data["reduce"] = {"version": REDUCER_VERSION, "warnings": list(self.warnings),
                          "tables": os.path.basename(self.tables.path) if self.tables.path else None}
        if self.mono_start_ns and not data.get("started_monotonic_ns"):
            data["started_monotonic_ns"] = self.mono_start_ns
        write_json(path, data)


def run(options):
    reducer = Reducer(options)
    events_path = options.events or os.path.join(options.in_dir, "events.txt")
    tracer_json = options.tracer_json
    if tracer_json is None:
        candidate = os.path.join(options.in_dir, "tracer.json")
        tracer_json = candidate if os.path.isfile(candidate) else None
    reducer.load_tracer_json(tracer_json)
    if not options.no_roles:
        reducer.roles = load_role_table(options.roles, reducer.warnings)
    reducer.tables = Tables.locate(options.tables, reducer.tracer.get("wine_version"), reducer.warnings)
    reducer.load_maps(options.in_dir)
    out_dir = options.out or options.in_dir
    try:
        # the T lines of every thread alive at start/stop (format 3 prints none for them)
        task_paths = [os.path.join(options.in_dir, name) for name in TASK_FILES]
        reducer.load_events(events_path, sort_dir=options.sort_dir or out_dir, chunk_lines=options.sort_chunk_lines,
                            extra_paths=task_paths)
        reducer.process()
    finally:
        reducer.cleanup()
    reducer.build_blocks()
    reducer.aggregate()
    summary = reducer.write_outputs(out_dir)
    reducer.update_tracer_json(tracer_json, summary)
    return reducer, summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--in", dest="in_dir", required=True, help="directory with events.txt (and tracer.json, maps-*.txt)")
    parser.add_argument("--events", help="events file (default: <in>/events.txt)")
    parser.add_argument("--out", help="output directory (default: <in>)")
    parser.add_argument("--tracer-json", help="tracer.json to read and update (default: <in>/tracer.json when present)")
    parser.add_argument("--tables", help="id table JSON (default: tables/wine-<ver>.json next to this script)")
    parser.add_argument("--roles", help="roles.toml for the shared classifier (default: next to symbolize.py)")
    parser.add_argument("--no-roles", action="store_true", help="ignore symbolize.py/roles.toml; built-in role rules only")
    parser.add_argument("--mode", choices=("summary", "drilldown"), default="summary")
    parser.add_argument("--near-late-fraction", type=float, default=0.15)
    parser.add_argument("--window-ms", type=int, default=100)
    parser.add_argument("--stopped-monotonic-ns", type=int, default=None)
    parser.add_argument("--lost-events-extra", type=int, default=0, help="lost events reported outside events.txt")
    parser.add_argument("--recursion-misses", type=int, default=0,
                        help="fentry/fexit runs the kernel skipped (bpftool recursion_misses), added to lost_events")
    parser.add_argument("--ns-per-hit", type=int, default=2000, help="assumed probe cost for the overhead estimate")
    parser.add_argument("--top", type=int, default=20, help="hotspots_non_audio entries")
    parser.add_argument("--sort-chunk-lines", type=int, default=DEFAULT_SORT_CHUNK_LINES,
                        help="event lines sorted in memory at a time; larger inputs are merged from sorted runs")
    parser.add_argument("--sort-dir", help="where the temporary sorted runs go (default: the output directory)")
    parser.add_argument("--quiet", action="store_true")
    options = parser.parse_args(argv)
    if options.window_ms <= 0:
        parser.error("--window-ms must be positive")
    if options.sort_chunk_lines <= 0:
        parser.error("--sort-chunk-lines must be positive")
    try:
        reducer, summary = run(options)
    except ReduceError as exc:
        print("reduce: %s" % exc, file=sys.stderr)
        return 1
    if not options.quiet:
        blocks = summary["blocks"]
        print(
            "reduce: %d events, %d blocks (%d late, %d near-late), lost=%s unmatched=%d abandoned=%d"
            % (
                summary["counters"]["events"],
                blocks["count"],
                blocks["late"],
                blocks["near_late"],
                "unknown" if summary["counters"]["lost_events"] is None else summary["counters"]["lost_events"],
                summary["counters"]["unmatched_exits"],
                summary["counters"]["abandoned_entries"],
            ),
            file=sys.stderr,
        )
        for warning in reducer.warnings:
            print("reduce: warning: %s" % warning, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
