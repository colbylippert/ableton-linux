#!/usr/bin/env python3
"""Validation of the Wine interface tracer against known workloads (design B section 7).

Two checks, selected by the inputs given (both may run in one invocation):

1. EXPECT comparison (``--expect``).  ``tools/traceprobe.exe`` prints lines

       EXPECT <kind> <id> <op> <n> [key=value ...]

   kind  syscall | unixcall | server_req | server_wait | ntsync_wait | ntsync_wake | offcpu
   id    the tracer's id string (NtYieldExecution, create_event, WAIT_ANY,
         winscard.so:scard_establish_context ...); fnmatch globs allowed
         (``winscard.so:*``); a hex/decimal number is matched against the event's
         ``id_num`` or translated with ``--tables``
   op    == != >= <= > < ~        (~ : within max(1, 5 %) of n)
   key=value filters (need per-event data, i.e. ``events.jsonl``):
         thread=<comm>        count on another thread of the probe process
         status=<v>|<v>...    NTSTATUS / errno values or names (STATUS_TIMEOUT, ETIMEDOUT)
         dur_ms=10+-1         duration window; also dur_us=, dur_ns=, and lo..hi ranges
         within=<id glob>     enclosed (by time, same tid) in a syscall/unixcall with that id
         woken_by=<tid>|comm:<name>
         count=<n>            any other key compares against the event field of that name

   The tracer's observations come from ``--events events.jsonl`` (drill-down; exact
   and filterable: PASS/FAIL), else from ``--blocks blocks.jsonl`` crossings and
   ``--threads threads.jsonl``.  Aggregates are incomplete by construction (block
   crossings exclude between-block events, ``top_ids`` are top-N), so they yield
   PASS when satisfied and SKIP otherwise; only ``*`` ids against the per-kind
   totals of threads.jsonl are exact.  The probe's tid is
   given with ``--tid`` or found by ``--comm`` (default ``traceprobe.exe``) in the
   thread tables of ``threads.jsonl`` / ``events.jsonl`` / ``tracer.json``.
   Pairing checks (orphan server/ntsync events, ``unmatched_exits``,
   ``abandoned_entries`` from ``tracer.json``) run when the data allows.

2. Telemetry join (``--telemetry live.log --blocks blocks.jsonl``).  Each per-second
   ``[pipeasio telemetry] cycles=N ... block_range=A-B late=L`` line (PipeASIO
   patch 0017) is joined with the tracer's blocks by seq: ``cycles`` must equal the
   number of blocks in ``[A, B]`` (tolerance ``--tolerance-blocks`` plus the line's
   ``muted``/``dropped`` counts), ``late`` must equal the tracer's late count, and
   the ``monotonic_wall_ns phase=live_callback`` p50/p95/p99 must agree with the
   tracer's ``t_after_live - t_before_live`` within ``--tolerance-ns`` (2 us).

Output: PASS/FAIL/SKIP lines and a SUMMARY line; exit code = FAIL count
(``--json`` prints a machine-readable result instead).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

KINDS = ("syscall", "unixcall", "server_req", "server_wait", "ntsync_wait", "ntsync_wake", "offcpu")
ENCLOSING_KINDS = ("syscall", "unixcall")
NESTED_KINDS = ("server_req", "server_wait", "ntsync_wait")
OPS = ("==", "!=", ">=", "<=", ">", "<", "~")
ENCLOSE_TOLERANCE_NS = 1000

STATUS_NAMES = {
    "STATUS_SUCCESS": 0, "STATUS_WAIT_0": 0, "STATUS_ABANDONED_WAIT_0": 0x80,
    "STATUS_USER_APC": 0xC0, "STATUS_KERNEL_APC": 0x100, "STATUS_ALERTED": 0x101,
    "STATUS_TIMEOUT": 0x102, "STATUS_PENDING": 0x103, "STATUS_NO_YIELD_PERFORMED": 0x40000024,
    "STATUS_INVALID_HANDLE": 0xC0000008, "STATUS_INVALID_PARAMETER": 0xC000000D,
    "STATUS_ACCESS_DENIED": 0xC0000022, "STATUS_OBJECT_NAME_NOT_FOUND": 0xC0000034,
    "STATUS_NOT_IMPLEMENTED": 0xC0000002, "STATUS_CANCELLED": 0xC0000120,
    "EPERM": -1, "EINTR": -4, "EAGAIN": -11, "ENOMEM": -12, "EBUSY": -16, "EINVAL": -22,
    "ETIMEDOUT": -110, "EOWNERDEAD": -130, "ENOTTY": -25,
}

EXPECT_RE = re.compile(r"^\s*EXPECT\s+(\S+)\s+(\S+)\s+(==|!=|>=|<=|>|<|~)\s+(\d+)\s*(.*?)\s*$")
TELEMETRY_RE = re.compile(r"\[pipeasio telemetry\]\s*(.*?)\s*$")


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def parse_number(text: Any, default: Optional[int] = None) -> Optional[int]:
    if text is None:
        return default
    if isinstance(text, bool):
        return int(text)
    if isinstance(text, int):
        return text
    if isinstance(text, float):
        return int(text)
    s = str(text).strip()
    if not s:
        return default
    if s.upper() in STATUS_NAMES:
        return STATUS_NAMES[s.upper()]
    try:
        if s.lower().startswith(("0x", "-0x")):
            return int(s, 16)
        return int(s, 10)
    except ValueError:
        return default


def norm_status(value: Any) -> Optional[int]:
    """NTSTATUS as unsigned 32-bit; small negatives (errno) stay negative."""
    v = parse_number(value)
    if v is None:
        return None
    if -4096 < v < 0:
        return v
    return v & 0xFFFFFFFF


def compare(op: str, observed: int, expected: int) -> bool:
    if op == "==":
        return observed == expected
    if op == "!=":
        return observed != expected
    if op == ">=":
        return observed >= expected
    if op == "<=":
        return observed <= expected
    if op == ">":
        return observed > expected
    if op == "<":
        return observed < expected
    if op == "~":
        return abs(observed - expected) <= max(1, int(round(expected * 0.05)))
    raise ValueError("unknown op %s" % op)


def id_matches(pattern: str, value: Any, id_num: Optional[int] = None) -> bool:
    text = "" if value is None else str(value)
    if pattern == "*":
        return True
    num = None
    if re.match(r"^(0x[0-9a-fA-F]+|\d+)$", pattern):
        num = parse_number(pattern)
    if num is not None:
        if id_num is not None and id_num == num:
            return True
        if re.match(r"^(0x[0-9a-fA-F]+|\d+)$", text) and parse_number(text) == num:
            return True
        return False
    if text == pattern or text.lower() == pattern.lower():
        return True
    if any(ch in pattern for ch in "*?["):
        return fnmatch.fnmatchcase(text, pattern) or fnmatch.fnmatchcase(text.lower(), pattern.lower())
    return False


def percentile_index(count: int, percentile: int) -> int:
    """Mirror of pipeasio_telemetry_percentile_index (nearest rank)."""
    if not count:
        return 0
    percentile = min(percentile, 100)
    rank = (count * percentile + 99) // 100
    return rank - 1 if rank else 0


def iter_jsonl(path: str) -> Iterable[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                yield obj


def read_lines(path: str) -> List[str]:
    if path == "-":
        return sys.stdin.read().splitlines()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


# --------------------------------------------------------------------------- #
# Results
# --------------------------------------------------------------------------- #

class Result(object):
    __slots__ = ("status", "check", "detail")

    def __init__(self, status: str, check: str, detail: str = ""):
        self.status = status  # PASS | FAIL | SKIP | INFO
        self.check = check
        self.detail = detail

    def line(self) -> str:
        return "%s %s%s" % (self.status, self.check, (": " + self.detail) if self.detail else "")

    def as_dict(self) -> Dict[str, str]:
        return {"status": self.status, "check": self.check, "detail": self.detail}


class Report(object):
    def __init__(self) -> None:
        self.results: List[Result] = []

    def add(self, status: str, check: str, detail: str = "") -> Result:
        res = Result(status, check, detail)
        self.results.append(res)
        return res

    def count(self, status: str) -> int:
        return sum(1 for r in self.results if r.status == status)

    @property
    def failures(self) -> int:
        return self.count("FAIL")

    def summary(self) -> str:
        return "SUMMARY pass=%d fail=%d skip=%d" % (self.count("PASS"), self.failures, self.count("SKIP"))

    def as_dict(self) -> Dict[str, Any]:
        return {"results": [r.as_dict() for r in self.results], "pass": self.count("PASS"),
                "fail": self.failures, "skip": self.count("SKIP")}


# --------------------------------------------------------------------------- #
# EXPECT lines
# --------------------------------------------------------------------------- #

class Expectation(object):
    __slots__ = ("kind", "id", "op", "n", "filters", "raw")

    def __init__(self, kind: str, id_pattern: str, op: str, n: int, filters: Dict[str, str], raw: str):
        self.kind = kind
        self.id = id_pattern
        self.op = op
        self.n = n
        self.filters = filters
        self.raw = raw

    def label(self) -> str:
        extra = " ".join("%s=%s" % kv for kv in self.filters.items())
        return "EXPECT %s %s %s %d%s" % (self.kind, self.id, self.op, self.n, (" " + extra) if extra else "")


def parse_expect_lines(lines: Iterable[str]) -> List[Expectation]:
    result: List[Expectation] = []
    for raw in lines:
        m = EXPECT_RE.match(raw)
        if not m:
            continue
        kind, id_pattern, op, n, rest = m.groups()
        filters: Dict[str, str] = {}
        for token in rest.split():
            key, sep, value = token.partition("=")
            if sep:
                filters[key.strip().lower()] = value.strip()
        result.append(Expectation(kind.lower(), id_pattern, op, int(n), filters, raw.strip()))
    return result


def parse_range(text: str, scale: int = 1) -> Optional[Tuple[int, int]]:
    """'10+-1' (U+00B1 accepted for the sign), '9..11', '10' -> (lo, hi) scaled to ns."""
    t = text.strip().replace(chr(0xB1), "+-")   # U+00B1 PLUS-MINUS SIGN
    m = re.match(r"^([0-9.]+)\+-([0-9.]+)$", t)
    if m:
        mid, dev = float(m.group(1)), float(m.group(2))
        return int((mid - dev) * scale), int((mid + dev) * scale)
    m = re.match(r"^([0-9.]+)\.\.([0-9.]+)$", t)
    if m:
        return int(float(m.group(1)) * scale), int(float(m.group(2)) * scale)
    m = re.match(r"^([0-9.]+)$", t)
    if m:
        v = int(float(m.group(1)) * scale)
        return v, v
    return None


# --------------------------------------------------------------------------- #
# Observations
# --------------------------------------------------------------------------- #

class Event(object):
    __slots__ = ("tid", "pid", "kind", "id", "id_num", "t", "dur_ns", "status", "fields")

    def __init__(self, rec: Dict[str, Any]):
        self.tid = parse_number(rec.get("tid"), 0) or 0
        self.pid = parse_number(rec.get("pid"))
        self.kind = str(rec.get("kind", "")).lower()
        self.id = rec.get("id")
        self.id_num = parse_number(rec.get("id_num"))
        t = rec.get("t")
        self.t = float(t) if isinstance(t, (int, float)) else None
        self.dur_ns = parse_number(rec.get("dur_ns"))
        self.status = rec.get("status")
        self.fields = rec

    @property
    def t_end(self) -> Optional[float]:
        if self.t is None:
            return None
        return self.t + (self.dur_ns or 0) / 1e9

    def woken_by_tid(self) -> Optional[int]:
        w = self.fields.get("woken_by")
        if isinstance(w, dict):
            return parse_number(w.get("tid"))
        return parse_number(w)


class Observations(object):
    """What the tracer saw: per-event data (events.jsonl) or aggregates."""

    def __init__(self) -> None:
        self.events: List[Event] = []
        self.counts: Dict[Tuple[int, str, str], int] = {}          # blocks.jsonl crossings (exact per block)
        self.kind_totals_blocks: Dict[Tuple[int, str], int] = {}
        self.approx_counts: Dict[Tuple[int, str, str], int] = {}   # threads.jsonl top_ids (top-N)
        self.kind_totals: Dict[Tuple[int, str], int] = {}          # threads.jsonl per-kind totals (exact)
        self.comms: Dict[int, str] = {}
        self.pids: Dict[int, int] = {}
        self.tracer: Dict[str, Any] = {}
        self.sources: List[str] = []

    @property
    def has_events(self) -> bool:
        return bool(self.events)

    # -- loading -----------------------------------------------------------
    def load_events(self, path: str) -> None:
        for rec in iter_jsonl(path):
            if rec.get("type") == "header":
                self._load_header_threads(rec)
                continue
            if rec.get("type") in ("name", "thread", "comm"):
                self._note_thread(rec)
                continue
            if "kind" not in rec:
                continue
            ev = Event(rec)
            self.events.append(ev)
            if rec.get("comm"):
                self.comms.setdefault(ev.tid, str(rec["comm"]))
            if ev.pid is not None:
                self.pids.setdefault(ev.tid, ev.pid)
        self.sources.append("events")

    def load_blocks(self, path: str) -> None:
        for rec in iter_jsonl(path):
            if rec.get("type") == "header":
                self._load_header_threads(rec)
                continue
            for crossing in rec.get("crossings", []) or []:
                tid = parse_number(crossing.get("tid"), 0) or 0
                kind = str(crossing.get("kind", "")).lower()
                cid = str(crossing.get("id", ""))
                n = parse_number(crossing.get("n"), 0) or 0
                self.counts[(tid, kind, cid)] = self.counts.get((tid, kind, cid), 0) + n
                self.kind_totals_blocks[(tid, kind)] = self.kind_totals_blocks.get((tid, kind), 0) + n
                if crossing.get("comm"):
                    self.comms.setdefault(tid, str(crossing["comm"]))
        self.sources.append("blocks")

    def load_threads(self, path: str) -> None:
        for rec in iter_jsonl(path):
            if rec.get("type") == "header":
                self._load_header_threads(rec)
                continue
            tid = parse_number(rec.get("tid"))
            if tid is None:
                continue
            if rec.get("comm"):
                self.comms.setdefault(tid, str(rec["comm"]))
            pid = parse_number(rec.get("pid"))
            if pid is not None:
                self.pids.setdefault(tid, pid)
            crossings = rec.get("crossings") or {}
            if isinstance(crossings, dict):
                for kind, agg in crossings.items():
                    n = parse_number(agg.get("n") if isinstance(agg, dict) else agg, 0) or 0
                    self.kind_totals[(tid, kind)] = self.kind_totals.get((tid, kind), 0) + n
            for item in rec.get("top_ids") or []:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    cid, n = str(item[0]), parse_number(item[1], 0) or 0
                    kind = str(item[2]) if len(item) >= 4 and isinstance(item[2], str) and item[2] in KINDS else None
                elif isinstance(item, dict):
                    cid, n = str(item.get("id")), parse_number(item.get("n"), 0) or 0
                    kind = item.get("kind")
                else:
                    continue
                if kind is None:
                    kind = guess_kind(cid)
                self.approx_counts[(tid, kind, cid)] = self.approx_counts.get((tid, kind, cid), 0) + n
        self.sources.append("threads")

    def load_tracer(self, path: str) -> None:
        with open(path, "r", encoding="utf-8") as fh:
            self.tracer = json.load(fh)
        self._load_header_threads(self.tracer)
        self.sources.append("tracer")

    def _load_header_threads(self, rec: Dict[str, Any]) -> None:
        threads = rec.get("threads")
        if isinstance(threads, dict):
            for tid_s, info in threads.items():
                tid = parse_number(tid_s)
                if tid is None:
                    continue
                if isinstance(info, dict):
                    self._note_thread(dict(info, tid=tid))
                else:
                    self.comms.setdefault(tid, str(info))
        elif isinstance(threads, list):
            for info in threads:
                if isinstance(info, dict):
                    self._note_thread(info)

    def _note_thread(self, rec: Dict[str, Any]) -> None:
        tid = parse_number(rec.get("tid"))
        if tid is None:
            return
        if rec.get("comm"):
            self.comms[tid] = str(rec["comm"])
        pid = parse_number(rec.get("pid"))
        if pid is not None:
            self.pids.setdefault(tid, pid)

    # -- thread lookup -----------------------------------------------------
    def tids_with_comm(self, comm: str, pid: Optional[int] = None) -> List[int]:
        comm15 = comm[:15]
        hits = []
        for tid, c in self.comms.items():
            if c == comm or c == comm15 or (len(c) == 15 and comm.startswith(c)):
                if pid is None or self.pids.get(tid) == pid:
                    hits.append(tid)
        return sorted(hits)

    def activity(self, tid: int) -> int:
        if self.events:
            return sum(1 for ev in self.events if ev.tid == tid)
        return (sum(n for (t, _k), n in self.kind_totals.items() if t == tid)
                + sum(n for (t, _k), n in self.kind_totals_blocks.items() if t == tid))

    def resolve_tid(self, comm: str, pid: Optional[int] = None) -> Tuple[Optional[int], str]:
        hits = self.tids_with_comm(comm, pid)
        if not hits:
            return None, "no thread with comm %r in %s" % (comm, "/".join(self.sources) or "no inputs")
        main = [t for t in hits if self.pids.get(t) == t]
        if len(main) == 1:
            return main[0], "main thread (tid == pid)"
        best = max(hits, key=self.activity)
        note = "most active of %d candidates %s" % (len(hits), hits) if len(hits) > 1 else "by comm"
        return best, note


def guess_kind(cid: str) -> str:
    if cid.startswith("Nt") or cid.startswith("Zw"):
        return "syscall"
    if ".so:" in cid or cid.endswith(".so") or "#" in cid:
        return "unixcall"
    if cid.upper() in ("WAIT_ANY", "WAIT_ALL"):
        return "ntsync_wait"
    if cid.upper() in ("EVENT_SET", "EVENT_PULSE", "SEM_RELEASE", "MUTEX_UNLOCK"):
        return "ntsync_wake"
    return "server_req"


# --------------------------------------------------------------------------- #
# Tables (syscall number -> name)
# --------------------------------------------------------------------------- #

def load_tables(path: str) -> Dict[int, str]:
    """Best-effort reader of profiler/tracer/tables/wine-<ver>.json for number->name."""
    with open(path, "r", encoding="utf-8") as fh:
        obj = json.load(fh)
    result: Dict[int, str] = {}

    def absorb(value: Any) -> None:
        if isinstance(value, dict):
            for k, v in value.items():
                if isinstance(v, int) and not isinstance(v, bool) and isinstance(k, str) and not k.startswith("0x"):
                    result.setdefault(v, k)
                elif isinstance(v, str) and parse_number(k) is not None:
                    result.setdefault(parse_number(k) or 0, v)
                elif isinstance(v, dict) and "id" in v and isinstance(v["id"], int):
                    result.setdefault(v["id"], k)
        elif isinstance(value, list):
            for i, v in enumerate(value):
                if isinstance(v, str):
                    result.setdefault(i, v)
                elif isinstance(v, dict) and "name" in v:
                    num = parse_number(v.get("id", v.get("num", i)))
                    if num is not None:
                        result.setdefault(num, str(v["name"]))

    if isinstance(obj, dict):
        for key, value in obj.items():
            if "syscall" in key.lower() or "win32u" in key.lower() or "ntdll" in key.lower():
                absorb(value)
        if not result:
            absorb(obj)
    else:
        absorb(obj)
    return result


# --------------------------------------------------------------------------- #
# EXPECT evaluation
# --------------------------------------------------------------------------- #

def event_passes_filters(ev: Event, exp: Expectation, obs: Observations, tid: int,
                         tables: Dict[int, str]) -> Tuple[bool, Optional[str]]:
    for key, value in exp.filters.items():
        if key == "thread":
            continue
        if key == "status":
            wanted = [norm_status(v) for v in value.split("|")]
            if norm_status(ev.status) not in wanted:
                return False, None
        elif key in ("dur_ns", "dur_us", "dur_ms", "dur_s"):
            scale = {"dur_ns": 1, "dur_us": 1000, "dur_ms": 1000000, "dur_s": 1000000000}[key]
            rng = parse_range(value, scale)
            if rng is None:
                return False, "bad range %s=%s" % (key, value)
            if ev.dur_ns is None or not (rng[0] <= ev.dur_ns <= rng[1]):
                return False, None
        elif key == "within":
            if ev.t is None:
                return False, "events carry no timestamps"
            if not enclosed_by(ev, obs, value, tables):
                return False, None
        elif key == "woken_by":
            want: Optional[int]
            if value.startswith(("comm:", "thread:")):
                name = value.split(":", 1)[1]
                hits = obs.tids_with_comm(name, obs.pids.get(tid))
                if not hits:
                    return False, "no thread with comm %r for woken_by" % name
                want = None
                if ev.woken_by_tid() not in hits:
                    return False, None
            else:
                want = parse_number(value)
                if ev.woken_by_tid() != want:
                    return False, None
        else:
            actual = ev.fields.get(key)
            if actual is None:
                return False, None
            wanted_any = value.split("|")
            if isinstance(actual, (int, float)) and not isinstance(actual, bool):
                if not any(parse_number(w) == int(actual) for w in wanted_any):
                    return False, None
            elif str(actual) not in wanted_any and str(actual).lower() not in [w.lower() for w in wanted_any]:
                return False, None
    return True, None


def enclosed_by(ev: Event, obs: Observations, pattern: str, tables: Dict[int, str]) -> bool:
    tol = ENCLOSE_TOLERANCE_NS / 1e9
    assert ev.t is not None
    start, end = ev.t, ev.t_end or ev.t
    for other in obs.events:
        if other is ev or other.tid != ev.tid or other.kind not in ENCLOSING_KINDS or other.t is None:
            continue
        if other.t - tol <= start and (other.t_end or other.t) + tol >= end:
            name = other.id
            if other.id_num is not None and other.id_num in tables:
                name = tables[other.id_num]
            if pattern == "*" or id_matches(pattern, name, other.id_num) or id_matches(pattern, other.id, other.id_num):
                return True
    return False


def evaluate_expectation(exp: Expectation, obs: Observations, tid: int, tables: Dict[int, str],
                         report: Report) -> None:
    label = exp.label()
    target = tid
    if "thread" in exp.filters:
        hits = obs.tids_with_comm(exp.filters["thread"], obs.pids.get(tid))
        if not hits:
            report.add("SKIP", label, "no thread with comm %r" % exp.filters["thread"])
            return
        target = hits[0] if len(hits) == 1 else max(hits, key=obs.activity)
    if exp.kind not in KINDS:
        report.add("SKIP", label, "unknown kind %r" % exp.kind)
        return

    if obs.has_events:
        observed = 0
        for ev in obs.events:
            if ev.tid != target or ev.kind != exp.kind:
                continue
            name = ev.id
            if ev.id_num is not None and ev.id_num in tables and not id_matches(exp.id, ev.id, ev.id_num):
                name = tables[ev.id_num]
            if not id_matches(exp.id, name, ev.id_num):
                continue
            ok, problem = event_passes_filters(ev, exp, obs, tid, tables)
            if problem:
                report.add("SKIP", label, problem)
                return
            if ok:
                observed += 1
        status = "PASS" if compare(exp.op, observed, exp.n) else "FAIL"
        report.add(status, label, "observed %d on tid %d" % (observed, target))
        return

    # aggregates only: PASS when satisfied, SKIP otherwise (never FAIL, see the module docstring)
    extra = [k for k in exp.filters if k != "thread"]
    if extra:
        report.add("SKIP", label, "filters %s need events.jsonl" % ",".join(extra))
        return
    observed = 0
    source = "no data"
    if exp.id == "*" and (target, exp.kind) in obs.kind_totals:
        observed = obs.kind_totals[(target, exp.kind)]
        source = "threads.jsonl kind total"
    else:
        exact = [n for (t, kind, cid), n in obs.counts.items()
                 if t == target and kind == exp.kind and id_matches(exp.id, cid)]
        approx = [n for (t, kind, cid), n in obs.approx_counts.items()
                  if t == target and kind == exp.kind and id_matches(exp.id, cid)]
        if exact:
            observed, source = sum(exact), "blocks.jsonl crossings (between-block events excluded)"
        elif approx:
            observed, source = sum(approx), "threads.jsonl top_ids (top-N only)"
        elif exp.id == "*" and (target, exp.kind) in obs.kind_totals_blocks:
            observed, source = obs.kind_totals_blocks[(target, exp.kind)], "blocks.jsonl crossings"
    if compare(exp.op, observed, exp.n):
        report.add("PASS", label, "observed %d on tid %d (%s)" % (observed, target, source))
    else:
        report.add("SKIP", label, "observed %d on tid %d (%s); aggregates are inconclusive, rerun with events.jsonl"
                   % (observed, target, source))


def pairing_checks(obs: Observations, tid: int, report: Report) -> None:
    if obs.has_events:
        orphans = 0
        nested = 0
        timed = True
        for ev in obs.events:
            if ev.tid != tid or ev.kind not in NESTED_KINDS:
                continue
            nested += 1
            if ev.t is None:
                timed = False
                break
            if not enclosed_by(ev, obs, "*", {}):
                orphans += 1
        if not timed:
            report.add("SKIP", "pairing-enclosure", "events carry no timestamps")
        elif nested:
            report.add("PASS" if orphans == 0 else "FAIL", "pairing-enclosure",
                       "%d of %d server/ntsync events without an enclosing syscall/unixcall on tid %d" % (orphans, nested, tid))
        else:
            report.add("SKIP", "pairing-enclosure", "no server/ntsync events on tid %d" % tid)
    else:
        report.add("SKIP", "pairing-enclosure", "needs events.jsonl")

    for name, limit in (("unmatched_exits", 1), ("abandoned_entries", 0)):
        value, scope = tracer_counter(obs.tracer, name, tid)
        if value is None:
            report.add("SKIP", "pairing-" + name, "no counter in tracer.json")
            continue
        detail = "%s=%d (%s)" % (name, value, scope)
        if name == "unmatched_exits" and scope == "global":
            report.add("INFO", "pairing-" + name, detail + "; per-tid limit is %d (thread start)" % limit)
            continue
        report.add("PASS" if value <= limit else "FAIL", "pairing-" + name, detail + "; limit %d" % limit)


def tracer_counter(tracer: Dict[str, Any], name: str, tid: int) -> Tuple[Optional[int], str]:
    if not tracer:
        return None, ""
    for scope_key in ("per_tid", "threads"):
        scoped = tracer.get(scope_key)
        if isinstance(scoped, dict):
            entry = scoped.get(str(tid), scoped.get(tid))
            if isinstance(entry, dict) and name in entry:
                return parse_number(entry[name], 0), "tid %d" % tid
            by_name = scoped.get(name)
            if isinstance(by_name, dict):
                v = by_name.get(str(tid), by_name.get(tid))
                if v is not None:
                    return parse_number(v, 0), "tid %d" % tid
    for container in (tracer, tracer.get("counters") or {}, tracer.get("stats") or {}):
        if isinstance(container, dict) and name in container:
            value = container[name]
            if isinstance(value, dict):
                v = value.get(str(tid), value.get(tid))
                if v is not None:
                    return parse_number(v, 0), "tid %d" % tid
                return parse_number(value.get("total"), None), "global"
            return parse_number(value, 0), "global"
    return None, ""


def run_expect(args: argparse.Namespace, report: Report) -> None:
    obs = Observations()
    if args.events:
        obs.load_events(args.events)
    if args.blocks:
        obs.load_blocks(args.blocks)
    if args.threads:
        obs.load_threads(args.threads)
    if args.tracer:
        obs.load_tracer(args.tracer)
    tables = load_tables(args.tables) if args.tables else {}
    expectations = parse_expect_lines(read_lines(args.expect))
    if not expectations:
        report.add("FAIL", "expect-input", "no EXPECT lines in %s" % args.expect)
        return
    if args.tid is not None:
        tid, note = args.tid, "--tid"
    else:
        tid, note = obs.resolve_tid(args.comm, args.pid)
    if tid is None:
        report.add("FAIL", "expect-thread", note)
        for exp in expectations:
            report.add("SKIP", exp.label(), "probe thread unresolved")
        return
    report.add("INFO", "expect-thread", "tid %d (%s); observations from %s" % (tid, note, "+".join(obs.sources)))
    for exp in expectations:
        evaluate_expectation(exp, obs, tid, tables, report)
    pairing_checks(obs, tid, report)


# --------------------------------------------------------------------------- #
# Telemetry join
# --------------------------------------------------------------------------- #

class Interval(object):
    __slots__ = ("lineno", "fields", "phases")

    def __init__(self, lineno: int, fields: Dict[str, Any]):
        self.lineno = lineno
        self.fields = fields
        self.phases: Dict[Tuple[str, str], Dict[str, int]] = {}

    @property
    def block_range(self) -> Optional[Tuple[int, int]]:
        return self.fields.get("block_range")

    def get(self, key: str, default: int = 0) -> int:
        v = self.fields.get(key)
        return default if v is None or isinstance(v, tuple) else int(v)


def parse_telemetry(lines: Iterable[str]) -> List[Interval]:
    intervals: List[Interval] = []
    for lineno, raw in enumerate(lines, 1):
        m = TELEMETRY_RE.search(raw)
        if not m:
            continue
        body = m.group(1)
        tokens = body.split()
        if not tokens:
            continue
        if tokens[0].startswith("cycles="):
            fields: Dict[str, Any] = {}
            for token in tokens:
                key, sep, value = token.partition("=")
                if not sep:
                    continue
                if key == "block_range":
                    rm = re.match(r"^(\d+)-(\d+)$", value)
                    fields[key] = (int(rm.group(1)), int(rm.group(2))) if rm else None
                else:
                    fields[key] = parse_number(value, 0)
            intervals.append(Interval(lineno, fields))
            continue
        pm = re.match(r"^(monotonic_wall|thread_cpu)_ns$", tokens[0])
        if pm and intervals:
            clock = pm.group(1)
            vals: Dict[str, int] = {}
            phase = ""
            for token in tokens[1:]:
                key, sep, value = token.partition("=")
                if not sep:
                    continue
                if key == "phase":
                    phase = value
                else:
                    vals[key] = parse_number(value, 0) or 0
            intervals[-1].phases[(clock, phase)] = vals
    return intervals


class Block(object):
    __slots__ = ("seq", "late", "muted", "live_ns", "t_start")

    def __init__(self, rec: Dict[str, Any]):
        self.seq = parse_number(rec.get("seq"), 0) or 0
        self.late = bool(rec.get("late", False))
        flags = rec.get("flags") or []
        self.muted = "muted" in flags if isinstance(flags, list) else bool(rec.get("muted"))
        live = rec.get("live_ns")
        if live is None and isinstance(rec.get("t_before_live"), (int, float)) and isinstance(rec.get("t_after_live"), (int, float)):
            live = int(round((rec["t_after_live"] - rec["t_before_live"]) * 1e9))
        self.live_ns = parse_number(live)
        t = rec.get("t_start")
        self.t_start = float(t) if isinstance(t, (int, float)) else None


def load_blocks(path: str) -> List[Block]:
    return [Block(rec) for rec in iter_jsonl(path) if rec.get("type") != "header" and "seq" in rec]


def check_telemetry(intervals: List[Interval], blocks: List[Block], report: Report,
                    tolerance_ns: int = 2000, tolerance_blocks: int = 1) -> None:
    if not intervals:
        report.add("FAIL", "telemetry-input", "no '[pipeasio telemetry] cycles=' lines")
        return
    if not blocks:
        report.add("FAIL", "telemetry-input", "no blocks in blocks.jsonl")
        return
    by_seq = {b.seq: b for b in blocks}
    seqs = sorted(by_seq)
    lo, hi = seqs[0], seqs[-1]
    report.add("INFO", "telemetry-input", "%d telemetry intervals, %d tracer blocks seq %d..%d" % (len(intervals), len(blocks), lo, hi))
    compared = 0
    prev_end: Optional[int] = None
    for k, iv in enumerate(intervals):
        tag = "telemetry[%d@line%d]" % (k, iv.lineno)
        rng = iv.block_range
        if rng is None:
            if "block_range" in iv.fields or iv.get("cycles") == 0:
                report.add("SKIP", tag, "no block_range (no published samples)")
            else:
                report.add("SKIP", tag, "no block_range= field (PipeASIO patch 0017 missing?)")
            continue
        a, b = rng
        if prev_end is not None and a != prev_end + 1:
            report.add("INFO", tag + "-contiguity", "block_range starts at %d after previous end %d" % (a, prev_end))
        prev_end = b
        if b < lo or a > hi:
            report.add("SKIP", tag, "block_range %d-%d outside the tracer's %d..%d" % (a, b, lo, hi))
            continue
        if a < lo or b > hi:
            report.add("SKIP", tag, "block_range %d-%d straddles the tracer window %d..%d" % (a, b, lo, hi))
            continue
        compared += 1
        in_range = [by_seq[s] for s in range(a, b + 1) if s in by_seq]
        cycles = iv.get("cycles")
        muted = iv.get("muted")
        dropped = iv.get("dropped")
        slack = tolerance_blocks + muted + dropped
        diff = len(in_range) - cycles
        report.add("PASS" if abs(diff) <= slack else "FAIL", tag + "-cycles",
                   "cycles=%d tracer=%d in %d-%d (muted=%d dropped=%d tolerance=%d)" % (cycles, len(in_range), a, b, muted, dropped, slack))
        if "late" in iv.fields:
            late_tracer = sum(1 for blk in in_range if blk.late)
            late_tel = iv.get("late")
            report.add("PASS" if abs(late_tracer - late_tel) <= tolerance_blocks else "FAIL", tag + "-late",
                       "late=%d tracer=%d" % (late_tel, late_tracer))
        phase = iv.phases.get(("monotonic_wall", "live_callback"))
        if phase:
            if dropped:
                report.add("SKIP", tag + "-live_callback", "dropped=%d samples; percentiles not comparable" % dropped)
                continue
            samples = sorted(blk.live_ns for blk in in_range if not blk.muted and blk.live_ns is not None)
            if not samples:
                report.add("SKIP", tag + "-live_callback", "no live timing in the tracer's blocks")
                continue
            parts = []
            worst = 0
            for p in (50, 95, 99):
                key = "p%d" % p
                if key not in phase:
                    continue
                mine = samples[percentile_index(len(samples), p)]
                delta = abs(mine - phase[key])
                worst = max(worst, delta)
                parts.append("%s=%d/%d" % (key, phase[key], mine))
            report.add("PASS" if worst <= tolerance_ns else "FAIL", tag + "-live_callback",
                       "telemetry/tracer ns %s (n=%d, worst delta %d ns, tolerance %d)" % (" ".join(parts), len(samples), worst, tolerance_ns))
    if not compared:
        report.add("FAIL", "telemetry-coverage", "no telemetry interval lies inside the tracer window")


def run_telemetry(args: argparse.Namespace, report: Report) -> None:
    if not args.blocks:
        report.add("FAIL", "telemetry-input", "--telemetry needs --blocks")
        return
    intervals = parse_telemetry(read_lines(args.telemetry))
    blocks = load_blocks(args.blocks)
    check_telemetry(intervals, blocks, report, args.tolerance_ns, args.tolerance_blocks)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--expect", metavar="FILE", help="traceprobe output with EXPECT lines ('-' = stdin)")
    p.add_argument("--events", metavar="FILE", help="events.jsonl (drill-down)")
    p.add_argument("--blocks", metavar="FILE", help="blocks.jsonl")
    p.add_argument("--threads", metavar="FILE", help="threads.jsonl")
    p.add_argument("--tracer", metavar="FILE", help="tracer.json (counters, thread table)")
    p.add_argument("--tables", metavar="FILE", help="tables/wine-<ver>.json for numeric syscall ids")
    p.add_argument("--tid", type=int, help="the probe's main thread (Linux tid)")
    p.add_argument("--comm", default="traceprobe.exe", help="find the probe thread by comm (default traceprobe.exe)")
    p.add_argument("--pid", type=int, help="restrict --comm matches to this pid")
    p.add_argument("--telemetry", metavar="FILE", help="Live/launcher log with [pipeasio telemetry] lines")
    p.add_argument("--tolerance-ns", type=int, default=2000)
    p.add_argument("--tolerance-blocks", type=int, default=1)
    p.add_argument("--json", action="store_true", help="print a JSON result document")
    p.add_argument("--quiet", "-q", action="store_true")
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.expect and not args.telemetry:
        parser.error("give --expect FILE and/or --telemetry FILE")
    report = Report()
    if args.expect:
        run_expect(args, report)
    if args.telemetry:
        run_telemetry(args, report)
    if args.json:
        print(json.dumps(report.as_dict(), indent=1))
    elif not args.quiet:
        for res in report.results:
            print(res.line())
        print(report.summary())
    return min(report.failures, 255)


if __name__ == "__main__":
    sys.exit(main())
