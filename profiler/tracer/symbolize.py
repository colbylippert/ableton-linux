#!/usr/bin/env python3
"""Caller resolution for the Wine interface tracer (design B section 4).

Stdlib only, Python 3.9+.  Three jobs:

1. Module map from ``/proc/PID/maps`` snapshots (``maps.json``).  A PE image is a
   mapping with file offset 0 whose file starts with ``MZ``; its extent is
   ``[base, base + SizeOfImage)`` taken from the optional header, never from the
   per-page backing (MSVC images with 0x200 file alignment are ``pread()`` into
   anonymous memory, only the header page stays file-backed).  ELF mappings are
   recorded to label unix-side addresses (``unix:ntdll.so+0x...``) and to stop
   the unwinder there.

2. A minimal PE32+ parser: DOS/NT headers, sections, EXPORT (nearest preceding
   export for Wine's own PE DLLs), IMPORT (dumped to ``imports.json``) and
   EXCEPTION (``.pdata`` ``RUNTIME_FUNCTION`` + ``UNWIND_INFO`` including chained
   and indirect entries), plus the offline x64 unwinder that replays the unwind
   codes over a captured stack window.

3. Symbol formatting and the persisted caches (``symcache.json``):
   ``ntdll.dll!NtWaitForSingleObject+0x14`` for Wine PE DLLs (path under
   ``lib/wine/<arch>-windows/``), ``Ableton Live 12 Trial.exe+0x1a2b3c4`` for
   everything else (Live and plugins stay module+offset), ``unix:ntdll.so+0x...``
   for ELF objects (``unix:ntdll.so!func+0x...`` with ``--symbols-root``).

The thread-role table (``roles.toml``, design B section 5) is also loaded from
here so ``reduce.py`` and the tracer share one classifier.

CLI::

  symbolize.py --blocks blocks.jsonl --stacks stacks.jsonl --maps maps.json \
      [--symcache symcache.json] --out blocks.symbolized.jsonl \
      [--stacks-out FILE] [--events FILE --events-out FILE] \
      [--imports-out imports.json] [--symbols-root DIR] [--max-frames 12]
  symbolize.py --perf [perf-script.txt|-] --maps maps.json [--pid N] [--out FILE]
  symbolize.py --dump-pe FILE          # header/export/pdata self-check (JSON)
  symbolize.py --dump-maps maps.json   # modules found per pid (JSON)
  symbolize.py --classify COMM [--exe EXE] [--pid P] [--tid T] [--process-comm C]

Input record shapes accepted (all addresses as JSON ints or "0x.." strings):

``maps.json``: ``{"type":"maps","snapshots":[{"t":0.0,"pid":4200,"text":"<raw /proc/PID/maps>"}]}``
(a bare list of snapshots, ``"maps"``/``"lines"`` instead of ``"text"``, or a raw
maps text file with ``--pid`` are accepted too).

``stacks.jsonl``: one record per captured stack::

  {"type":"stack","ref":17,"t":12.3,"tid":4301,"pid":4200,"seq":123,
   "kind":"syscall"|"unixcall"|"sample","id":"NtWaitForMultipleObjects",
   "frame":"0x...","rip":"0x...","rsp":"0x...",
   "regs":[20 u64: syscall_frame bytes 0x00..0x9f] | {"rbp":..,"rbx":..,...},
   "stack_hex":"<bytes copied from rsp upward>"}   (or "stack_b64")

``blocks.jsonl``/``events.jsonl`` entries reference a stack with ``stack_ref``
(``ref``/``stack_id`` accepted); the symbolizer adds ``frames`` (strings),
``addrs`` (hex), ``caller`` (depth-3 chain joined by " <- ") and ``stop``.
"""

from __future__ import annotations

import argparse
import base64
import bisect
import fnmatch
import hashlib
import io
import json
import os
import re
import struct
import sys
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

__version__ = "1"

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

UWOP_PUSH_NONVOL = 0
UWOP_ALLOC_LARGE = 1
UWOP_ALLOC_SMALL = 2
UWOP_SET_FPREG = 3
UWOP_SAVE_NONVOL = 4
UWOP_SAVE_NONVOL_FAR = 5
UWOP_EPILOG = 6
UWOP_SPARE_CODE = 7
UWOP_SAVE_XMM128 = 8
UWOP_SAVE_XMM128_FAR = 9
UWOP_PUSH_MACHFRAME = 10

UNW_FLAG_EHANDLER = 1
UNW_FLAG_UHANDLER = 2
UNW_FLAG_CHAININFO = 4

# x64 unwind-code register numbering
REG_NAMES = ("rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
             "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15")

# Order of the 20 u64 words at syscall_frame bytes 0x00..0x9f (Wine 11.13
# dlls/ntdll/unix/signal_x86_64.c:469-490); the tracer copies them verbatim.
FRAME_REG_ORDER = ("rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
                   "r12", "r13", "r14", "r15", "rip", "cs", "eflags", "rsp", "ss", "rbp")

IMAGE_DIRECTORY_ENTRY_EXPORT = 0
IMAGE_DIRECTORY_ENTRY_IMPORT = 1
IMAGE_DIRECTORY_ENTRY_EXCEPTION = 3
IMAGE_NT_OPTIONAL_HDR32_MAGIC = 0x10B
IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x20B
IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_FILE_MACHINE_I386 = 0x14C

WINE_PE_DIR_RE = re.compile(r"/lib(?:64)?/wine/(?:x86_64|i386|aarch64|arm64ec)-windows/")
WOW64_DLL_RE = re.compile(r"^wow64[a-z0-9_]*\.dll$", re.IGNORECASE)

DEFAULT_MAX_FRAMES = 12
STACK_CACHE_WORDS = 6
CHAIN_DEPTH = 3
CHAIN_SEP = " <- "

STOP_MAX_FRAMES = "max_frames"
STOP_END = "end"
STOP_NON_PE = "non_pe"
STOP_UNIX = "unix"
STOP_WOW64 = "wow64"
STOP_WINDOW = "stack_window_exhausted"
STOP_MACHFRAME = "machframe"
STOP_BAD_UNWIND = "bad_unwind_info"
STOP_REGISTER = "register_unavailable"
STOP_BAD_FRAME = "bad_frame"
STOP_UNREADABLE = "module_unreadable"


class PEError(Exception):
    """Malformed or unsupported PE structure."""


class WindowExhausted(Exception):
    """A stack read fell outside the captured window."""


class RegisterUnavailable(Exception):
    """The unwinder needed a register the capture does not carry."""


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def to_int(value: Any, default: Optional[int] = None) -> Optional[int]:
    """Accept JSON ints, decimal strings and 0x-prefixed hex strings."""
    if value is None:
        return default
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    text = str(value).strip()
    if not text:
        return default
    try:
        if text.lower().startswith(("0x", "-0x")):
            return int(text, 16)
        return int(text, 10)
    except ValueError:
        try:
            return int(text, 16)
        except ValueError:
            return default


def hexs(value: int) -> str:
    return "0x%x" % value


class ByteSource:
    """Random-access bytes, backed by an in-memory buffer or a file."""

    def __init__(self, data: Optional[bytes] = None, path: Optional[str] = None):
        self._data = data
        self._file: Optional[io.BufferedReader] = None
        if data is not None:
            self.size = len(data)
        elif path is not None:
            self._file = open(path, "rb")
            self._file.seek(0, os.SEEK_END)
            self.size = self._file.tell()
        else:
            raise ValueError("ByteSource needs data or path")

    def read(self, offset: int, size: int) -> bytes:
        if offset < 0 or size < 0:
            return b""
        if self._data is not None:
            return self._data[offset:offset + size]
        assert self._file is not None
        self._file.seek(offset)
        return self._file.read(size)

    def close(self) -> None:
        if self._file is not None:
            self._file.close()
            self._file = None


# --------------------------------------------------------------------------- #
# /proc/PID/maps
# --------------------------------------------------------------------------- #

class MapEntry(object):
    __slots__ = ("start", "end", "perms", "offset", "dev", "inode", "path")

    def __init__(self, start: int, end: int, perms: str, offset: int, dev: str, inode: int, path: str):
        self.start = start
        self.end = end
        self.perms = perms
        self.offset = offset
        self.dev = dev
        self.inode = inode
        self.path = path

    def as_dict(self) -> Dict[str, Any]:
        return {"start": hexs(self.start), "end": hexs(self.end), "perms": self.perms,
                "offset": hexs(self.offset), "dev": self.dev, "inode": self.inode, "path": self.path}


def parse_maps(text: str) -> List[MapEntry]:
    """Parse the text of /proc/PID/maps.  Paths may contain spaces."""
    entries: List[MapEntry] = []
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        parts = line.split(None, 5)
        if len(parts) < 5:
            continue
        rng, perms, offset, dev, inode = parts[:5]
        path = parts[5].strip() if len(parts) > 5 else ""
        if "-" not in rng:
            continue
        try:
            start_s, end_s = rng.split("-", 1)
            entries.append(MapEntry(int(start_s, 16), int(end_s, 16), perms, int(offset, 16),
                                    dev, int(inode), path))
        except ValueError:
            continue
    entries.sort(key=lambda e: e.start)
    return entries


# --------------------------------------------------------------------------- #
# PE32+ parser
# --------------------------------------------------------------------------- #

class RuntimeFunction(object):
    __slots__ = ("begin", "end", "unwind_rva")

    def __init__(self, begin: int, end: int, unwind_rva: int):
        self.begin = begin
        self.end = end
        self.unwind_rva = unwind_rva

    def to_json(self) -> List[int]:
        return [self.begin, self.end, self.unwind_rva]

    @classmethod
    def from_json(cls, obj: Sequence[int]) -> "RuntimeFunction":
        return cls(int(obj[0]), int(obj[1]), int(obj[2]))


class UnwindCode(object):
    __slots__ = ("op", "info", "offset", "extra")

    def __init__(self, op: int, info: int, offset: int, extra: Optional[int] = None):
        self.op = op
        self.info = info
        self.offset = offset
        self.extra = extra

    def to_json(self) -> List[Any]:
        return [self.op, self.info, self.offset, self.extra]

    @classmethod
    def from_json(cls, obj: Sequence[Any]) -> "UnwindCode":
        return cls(int(obj[0]), int(obj[1]), int(obj[2]), None if obj[3] is None else int(obj[3]))


class UnwindInfo(object):
    __slots__ = ("version", "flags", "prolog", "count", "frame_reg", "frame_off", "codes", "chained")

    def __init__(self, version: int, flags: int, prolog: int, count: int, frame_reg: int,
                 frame_off: int, codes: List[UnwindCode], chained: Optional[RuntimeFunction]):
        self.version = version
        self.flags = flags
        self.prolog = prolog
        self.count = count
        self.frame_reg = frame_reg
        self.frame_off = frame_off
        self.codes = codes
        self.chained = chained

    def to_json(self) -> List[Any]:
        return [self.version, self.flags, self.prolog, self.count, self.frame_reg, self.frame_off,
                [c.to_json() for c in self.codes], self.chained.to_json() if self.chained else None]

    @classmethod
    def from_json(cls, obj: Sequence[Any]) -> "UnwindInfo":
        return cls(int(obj[0]), int(obj[1]), int(obj[2]), int(obj[3]), int(obj[4]), int(obj[5]),
                   [UnwindCode.from_json(c) for c in obj[6]],
                   RuntimeFunction.from_json(obj[7]) if obj[7] else None)


def unwind_code_slots(op: int, info: int) -> int:
    """Slots occupied by an unwind code (ntdll's RtlpUnwindOpSlotTable; Wine get_opcode_size)."""
    if op == UWOP_ALLOC_LARGE:
        return 3 if info else 2
    if op in (UWOP_SAVE_NONVOL, UWOP_SAVE_XMM128, UWOP_EPILOG):
        return 2
    if op in (UWOP_SAVE_NONVOL_FAR, UWOP_SAVE_XMM128_FAR, UWOP_SPARE_CODE):
        return 3
    return 1


class Section(object):
    __slots__ = ("name", "va", "vsize", "raw_ptr", "raw_size", "characteristics")

    def __init__(self, name: str, va: int, vsize: int, raw_ptr: int, raw_size: int, characteristics: int):
        self.name = name
        self.va = va
        self.vsize = vsize
        self.raw_ptr = raw_ptr
        self.raw_size = raw_size
        self.characteristics = characteristics


class PEImage(object):
    """Minimal PE parser over a ByteSource (file offsets, not a loaded image)."""

    def __init__(self, source: ByteSource, path: str = ""):
        self.source = source
        self.path = path
        self.is_pe64 = False
        self.machine = 0
        self.size_of_image = 0
        self.size_of_headers = 0
        self.image_base = 0
        self.sections: List[Section] = []
        self.directories: List[Tuple[int, int]] = []
        self._exports: Optional[List[Tuple[int, str]]] = None
        self._export_rvas: Optional[List[int]] = None
        self._pdata: Optional[List[RuntimeFunction]] = None
        self._pdata_begins: Optional[List[int]] = None
        self._unwind_cache: Dict[int, UnwindInfo] = {}
        self._parse_headers()

    # -- construction ------------------------------------------------------
    @classmethod
    def from_bytes(cls, data: bytes, path: str = "") -> "PEImage":
        return cls(ByteSource(data=data), path)

    @classmethod
    def from_file(cls, path: str) -> "PEImage":
        return cls(ByteSource(path=path), path)

    def close(self) -> None:
        self.source.close()

    # -- raw access --------------------------------------------------------
    def _u16(self, off: int) -> int:
        b = self.source.read(off, 2)
        if len(b) < 2:
            raise PEError("short read at 0x%x" % off)
        return struct.unpack("<H", b)[0]

    def _u32(self, off: int) -> int:
        b = self.source.read(off, 4)
        if len(b) < 4:
            raise PEError("short read at 0x%x" % off)
        return struct.unpack("<I", b)[0]

    def _u64(self, off: int) -> int:
        b = self.source.read(off, 8)
        if len(b) < 8:
            raise PEError("short read at 0x%x" % off)
        return struct.unpack("<Q", b)[0]

    def _parse_headers(self) -> None:
        if self.source.read(0, 2) != b"MZ":
            raise PEError("not an MZ image")
        nt = self._u32(0x3C)
        if self.source.read(nt, 4) != b"PE\0\0":
            raise PEError("bad PE signature")
        self.machine = self._u16(nt + 4)
        nsections = self._u16(nt + 6)
        opt_size = self._u16(nt + 20)
        opt = nt + 24
        magic = self._u16(opt)
        if magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC:
            self.is_pe64 = True
            self.image_base = self._u64(opt + 24)
            ndirs_off, dirs_off = 108, 112
        elif magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC:
            self.is_pe64 = False
            self.image_base = self._u32(opt + 28)
            ndirs_off, dirs_off = 92, 96
        else:
            raise PEError("unknown optional header magic 0x%x" % magic)
        self.size_of_image = self._u32(opt + 56)
        self.size_of_headers = self._u32(opt + 60)
        ndirs = self._u32(opt + ndirs_off) if opt_size >= ndirs_off + 4 else 0
        ndirs = min(ndirs, 16)
        self.directories = []
        for i in range(ndirs):
            if dirs_off + i * 8 + 8 > opt_size:
                break
            self.directories.append((self._u32(opt + dirs_off + i * 8), self._u32(opt + dirs_off + i * 8 + 4)))
        sec_off = opt + opt_size
        for i in range(nsections):
            raw = self.source.read(sec_off + i * 40, 40)
            if len(raw) < 40:
                raise PEError("truncated section table")
            name = raw[:8].split(b"\0", 1)[0].decode("latin-1")
            vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", raw, 8)
            characteristics = struct.unpack_from("<I", raw, 36)[0]
            self.sections.append(Section(name, va, vsize, raw_ptr, raw_size, characteristics))
        self.sections.sort(key=lambda s: s.va)

    # -- RVA translation ---------------------------------------------------
    def directory(self, index: int) -> Tuple[int, int]:
        if index < len(self.directories):
            return self.directories[index]
        return (0, 0)

    def rva_to_offset(self, rva: int) -> Optional[int]:
        """File offset for an RVA, or None when the RVA is not file-backed."""
        if rva < 0:
            return None
        if not self.sections or rva < self.sections[0].va:
            return rva if rva < max(self.size_of_headers, 0x1000) else None
        for s in self.sections:
            extent = max(s.vsize, s.raw_size)
            if s.va <= rva < s.va + extent:
                delta = rva - s.va
                if delta >= s.raw_size:
                    return None
                return s.raw_ptr + delta
        return None

    def read(self, rva: int, size: int) -> bytes:
        """Read `size` bytes at an RVA (zero-filled past the raw data, truncated past the section)."""
        off = self.rva_to_offset(rva)
        if off is None:
            return b""
        data = self.source.read(off, size)
        if len(data) < size:
            # the tail may be uninitialised (VirtualSize > SizeOfRawData)
            for s in self.sections:
                if s.va <= rva < s.va + max(s.vsize, s.raw_size):
                    avail = s.va + max(s.vsize, s.raw_size) - rva
                    data = data + b"\0" * (min(size, avail) - len(data))
                    break
        return data

    def read_cstring(self, rva: int, limit: int = 512) -> str:
        data = self.read(rva, limit)
        return data.split(b"\0", 1)[0].decode("latin-1")

    # -- exports -----------------------------------------------------------
    def exports(self) -> List[Tuple[int, str]]:
        """Sorted (rva, name) list; forwarders excluded; ordinal-only exports as '#N'."""
        if self._exports is not None:
            return self._exports
        result: List[Tuple[int, str]] = []
        dir_rva, dir_size = self.directory(IMAGE_DIRECTORY_ENTRY_EXPORT)
        if dir_rva and dir_size >= 40:
            hdr = self.read(dir_rva, 40)
            if len(hdr) == 40:
                (_chars, _ts, _maj, _min, _name, base, nfuncs, nnames,
                 addr_funcs, addr_names, addr_ords) = struct.unpack("<IIHHIIIIIII", hdr)
                nfuncs = min(nfuncs, 1 << 20)
                nnames = min(nnames, 1 << 20)
                funcs_raw = self.read(addr_funcs, nfuncs * 4)
                funcs = list(struct.unpack("<%dI" % (len(funcs_raw) // 4), funcs_raw[:len(funcs_raw) // 4 * 4]))
                names_raw = self.read(addr_names, nnames * 4)
                names = struct.unpack("<%dI" % (len(names_raw) // 4), names_raw[:len(names_raw) // 4 * 4])
                ords_raw = self.read(addr_ords, nnames * 2)
                ords = struct.unpack("<%dH" % (len(ords_raw) // 2), ords_raw[:len(ords_raw) // 2 * 2])
                named = {}
                for name_rva, ordinal in zip(names, ords):
                    if ordinal < len(funcs):
                        named[ordinal] = self.read_cstring(name_rva)
                for index, rva in enumerate(funcs):
                    if not rva:
                        continue
                    if dir_rva <= rva < dir_rva + dir_size:
                        continue  # forwarder string, not code
                    result.append((rva, named.get(index, "#%d" % (base + index))))
        result.sort()
        self._exports = result
        self._export_rvas = [r for r, _ in result]
        return result

    def nearest_export(self, rva: int) -> Optional[Tuple[str, int]]:
        """(name, offset) of the nearest export at or before `rva`."""
        exports = self.exports()
        assert self._export_rvas is not None
        pos = bisect.bisect_right(self._export_rvas, rva) - 1
        if pos < 0:
            return None
        export_rva, name = exports[pos]
        return name, rva - export_rva

    # -- imports -----------------------------------------------------------
    def imports(self) -> Dict[str, List[str]]:
        """{dll name: [imported symbol names or '#ordinal']} from the import directory."""
        result: Dict[str, List[str]] = {}
        dir_rva, dir_size = self.directory(IMAGE_DIRECTORY_ENTRY_IMPORT)
        if not dir_rva:
            return result
        thunk_size = 8 if self.is_pe64 else 4
        ordinal_flag = (1 << 63) if self.is_pe64 else (1 << 31)
        for i in range(4096):
            desc = self.read(dir_rva + i * 20, 20)
            if len(desc) < 20:
                break
            oft, _ts, _fwd, name_rva, ft = struct.unpack("<IIIII", desc)
            if not (oft or name_rva or ft):
                break
            dll = self.read_cstring(name_rva) if name_rva else "?"
            names: List[str] = []
            thunks = oft or ft
            for j in range(1 << 16):
                raw = self.read(thunks + j * thunk_size, thunk_size)
                if len(raw) < thunk_size:
                    break
                value = struct.unpack("<Q" if self.is_pe64 else "<I", raw)[0]
                if not value:
                    break
                if value & ordinal_flag:
                    names.append("#%d" % (value & 0xFFFF))
                else:
                    names.append(self.read_cstring((value & 0x7FFFFFFF) + 2))
            result.setdefault(dll, []).extend(names)
        return result

    # -- exception directory ----------------------------------------------
    def pdata(self) -> List[RuntimeFunction]:
        if self._pdata is not None:
            return self._pdata
        entries: List[RuntimeFunction] = []
        dir_rva, dir_size = self.directory(IMAGE_DIRECTORY_ENTRY_EXCEPTION)
        if dir_rva and dir_size >= 12 and self.is_pe64:
            raw = self.read(dir_rva, dir_size - dir_size % 12)
            for off in range(0, len(raw) - len(raw) % 12, 12):
                begin, end, unwind = struct.unpack_from("<III", raw, off)
                if begin or end or unwind:
                    entries.append(RuntimeFunction(begin, end, unwind))
        entries.sort(key=lambda rf: rf.begin)
        self._pdata = entries
        self._pdata_begins = [rf.begin for rf in entries]
        return entries

    def runtime_function(self, rva: int) -> Optional[RuntimeFunction]:
        """The RUNTIME_FUNCTION covering `rva`, following indirect (UnwindData & 1) entries."""
        pdata = self.pdata()
        assert self._pdata_begins is not None
        pos = bisect.bisect_right(self._pdata_begins, rva) - 1
        if pos < 0:
            return None
        rf = pdata[pos]
        if not (rf.begin <= rva < rf.end):
            return None
        for _ in range(8):
            if not (rf.unwind_rva & 1):
                return rf
            raw = self.read(rf.unwind_rva & ~1, 12)
            if len(raw) < 12:
                raise PEError("bad indirect RUNTIME_FUNCTION at 0x%x" % rf.unwind_rva)
            begin, end, unwind = struct.unpack("<III", raw)
            rf = RuntimeFunction(begin, end, unwind)
        raise PEError("indirect RUNTIME_FUNCTION loop")

    def unwind_info(self, rf: RuntimeFunction) -> UnwindInfo:
        rva = rf.unwind_rva & ~1
        cached = self._unwind_cache.get(rva)
        if cached is not None:
            return cached
        hdr = self.read(rva, 4)
        if len(hdr) < 4:
            raise PEError("unwind info 0x%x outside the image" % rva)
        version = hdr[0] & 7
        flags = hdr[0] >> 3
        prolog = hdr[1]
        count = hdr[2]
        frame_reg = hdr[3] & 0xF
        frame_off = hdr[3] >> 4
        if version not in (1, 2):
            raise PEError("unwind info version %d at 0x%x" % (version, rva))
        raw = self.read(rva + 4, count * 2)
        if len(raw) < count * 2:
            raise PEError("truncated unwind codes at 0x%x" % rva)
        codes: List[UnwindCode] = []
        i = 0
        while i < count:
            offset = raw[2 * i]
            op = raw[2 * i + 1] & 0xF
            info = raw[2 * i + 1] >> 4
            slots = unwind_code_slots(op, info)
            if i + slots > count:
                raise PEError("unwind code overruns the array at 0x%x" % rva)
            extra: Optional[int] = None
            if op == UWOP_ALLOC_LARGE:
                if info:
                    extra = struct.unpack_from("<I", raw, 2 * i + 2)[0]
                else:
                    extra = struct.unpack_from("<H", raw, 2 * i + 2)[0] * 8
            elif op == UWOP_SAVE_NONVOL:
                extra = struct.unpack_from("<H", raw, 2 * i + 2)[0] * 8
            elif op == UWOP_SAVE_XMM128:
                extra = struct.unpack_from("<H", raw, 2 * i + 2)[0] * 16
            elif op in (UWOP_SAVE_NONVOL_FAR, UWOP_SAVE_XMM128_FAR):
                extra = struct.unpack_from("<I", raw, 2 * i + 2)[0]
            elif op > UWOP_PUSH_MACHFRAME:
                raise PEError("unknown unwind op %d at 0x%x" % (op, rva))
            codes.append(UnwindCode(op, info, offset, extra))
            i += slots
        chained: Optional[RuntimeFunction] = None
        if flags & UNW_FLAG_CHAININFO:
            pos = rva + 4 + ((count + 1) & ~1) * 2
            raw_chain = self.read(pos, 12)
            if len(raw_chain) < 12:
                raise PEError("truncated chained RUNTIME_FUNCTION at 0x%x" % pos)
            begin, end, unwind = struct.unpack("<III", raw_chain)
            chained = RuntimeFunction(begin, end, unwind)
        result = UnwindInfo(version, flags, prolog, count, frame_reg, frame_off, codes, chained)
        self._unwind_cache[rva] = result
        return result

    # -- diagnostics -------------------------------------------------------
    def self_check(self) -> Dict[str, Any]:
        """Decode every unwind info; used by --dump-pe to VERIFY real images."""
        versions: Dict[str, int] = {}
        ops: Dict[str, int] = {}
        chained = indirect = handlers = errors = 0
        samples: List[str] = []
        for rf in self.pdata():
            try:
                if rf.unwind_rva & 1:
                    indirect += 1
                    rf = self.runtime_function(rf.begin) or rf
                ui = self.unwind_info(rf)
            except PEError as exc:
                errors += 1
                if len(samples) < 10:
                    samples.append("0x%x: %s" % (rf.begin, exc))
                continue
            versions[str(ui.version)] = versions.get(str(ui.version), 0) + 1
            if ui.chained:
                chained += 1
            if ui.flags & (UNW_FLAG_EHANDLER | UNW_FLAG_UHANDLER):
                handlers += 1
            for code in ui.codes:
                ops[str(code.op)] = ops.get(str(code.op), 0) + 1
        return {"path": self.path, "machine": hexs(self.machine), "pe64": self.is_pe64,
                "size_of_image": hexs(self.size_of_image), "image_base": hexs(self.image_base),
                "sections": [{"name": s.name, "va": hexs(s.va), "vsize": hexs(s.vsize),
                              "raw": hexs(s.raw_ptr), "raw_size": hexs(s.raw_size)} for s in self.sections],
                "exports": len(self.exports()), "imports": {k: len(v) for k, v in self.imports().items()},
                "pdata": len(self.pdata()), "unwind_versions": versions, "unwind_ops": ops,
                "chained": chained, "indirect": indirect, "with_handler": handlers,
                "decode_errors": errors, "error_samples": samples}


# --------------------------------------------------------------------------- #
# ELF symbols (optional, --symbols-root)
# --------------------------------------------------------------------------- #

class ElfSymbols(object):
    """Function symbols of an ELF64 object from .symtab (fallback .dynsym)."""

    SHT_SYMTAB = 2
    SHT_DYNSYM = 11
    PT_LOAD = 1

    def __init__(self, data: bytes, path: str = ""):
        self.path = path
        self.values: List[int] = []
        self.symbols: List[Tuple[int, int, str]] = []
        self.load_vaddr = 0
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            raise PEError("not a little-endian ELF64 object")
        phoff = struct.unpack_from("<Q", data, 0x20)[0]
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        phentsize, phnum, shentsize, shnum = struct.unpack_from("<HHHH", data, 0x36)
        for i in range(phnum):
            off = phoff + i * phentsize
            if off + 56 > len(data):
                break
            p_type, _flags, p_offset, p_vaddr = struct.unpack_from("<IIQQ", data, off)
            if p_type == self.PT_LOAD and p_offset == 0:
                self.load_vaddr = p_vaddr
                break
        sections = []
        for i in range(shnum):
            off = shoff + i * shentsize
            if off + 64 > len(data):
                break
            sections.append(struct.unpack_from("<IIQQQQIIQQ", data, off))
        best = None
        for sh in sections:
            if sh[1] == self.SHT_SYMTAB:
                best = sh
                break
        if best is None:
            for sh in sections:
                if sh[1] == self.SHT_DYNSYM:
                    best = sh
                    break
        if best is None:
            return
        _name, _type, _flags, _addr, sym_off, sym_size, link, _info, _align, entsize = best
        entsize = entsize or 24
        if link >= len(sections):
            return
        str_off, str_size = sections[link][4], sections[link][5]
        strtab = data[str_off:str_off + str_size]
        syms: List[Tuple[int, int, str]] = []
        for off in range(sym_off, sym_off + sym_size - entsize + 1, entsize):
            st_name, st_info, _other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, off)
            if not st_value or not st_shndx or st_shndx >= 0xFF00:
                continue
            if (st_info & 0xF) not in (0, 2):  # NOTYPE or FUNC
                continue
            end = strtab.find(b"\0", st_name)
            name = strtab[st_name:end if end >= 0 else None].decode("latin-1")
            if name:
                syms.append((st_value, st_size, name))
        syms.sort()
        self.symbols = syms
        self.values = [s[0] for s in syms]

    @classmethod
    def from_file(cls, path: str) -> "ElfSymbols":
        with open(path, "rb") as fh:
            return cls(fh.read(), path)

    def lookup(self, vaddr: int) -> Optional[Tuple[str, int]]:
        pos = bisect.bisect_right(self.values, vaddr) - 1
        if pos < 0:
            return None
        value, size, name = self.symbols[pos]
        if size and vaddr >= value + size:
            return None
        return name, vaddr - value


# --------------------------------------------------------------------------- #
# Module map
# --------------------------------------------------------------------------- #

class Module(object):
    __slots__ = ("path", "name", "base", "end", "kind", "pe", "identity", "is_wine_dll", "is_wow64", "elf_bias")

    def __init__(self, path: str, base: int, end: int, kind: str, pe: Optional[PEImage],
                 identity: Dict[str, Any]):
        self.path = path
        self.name = os.path.basename(path.rstrip("/")) or path
        self.base = base
        self.end = end
        self.kind = kind            # pe64 | pe32 | elf | missing
        self.pe = pe
        self.identity = identity
        self.is_wine_dll = bool(WINE_PE_DIR_RE.search(path))
        self.is_wow64 = bool(WOW64_DLL_RE.match(self.name))
        self.elf_bias = 0

    @property
    def key(self) -> str:
        return identity_key(self.identity)

    def contains(self, addr: int) -> bool:
        return self.base <= addr < self.end

    def as_dict(self) -> Dict[str, Any]:
        return {"path": self.path, "name": self.name, "base": hexs(self.base), "end": hexs(self.end),
                "kind": self.kind, "wine_dll": self.is_wine_dll, "identity": self.identity}


def identity_key(identity: Dict[str, Any]) -> str:
    return "%s|%s|%s" % (identity.get("path", ""), identity.get("size", ""), identity.get("mtime_ns", ""))


class Snapshot(object):
    __slots__ = ("pid", "t", "modules", "bases", "fingerprint", "entries")

    def __init__(self, pid: int, t: float, modules: List[Module], entries: List[MapEntry]):
        self.pid = pid
        self.t = t
        self.modules = sorted(modules, key=lambda m: m.base)
        self.bases = [m.base for m in self.modules]
        self.entries = entries
        digest = hashlib.sha1()
        for m in self.modules:
            digest.update(("%s@%x;" % (m.key, m.base)).encode("utf-8"))
        self.fingerprint = digest.hexdigest()[:16]

    def find(self, addr: int) -> Optional[Module]:
        pos = bisect.bisect_right(self.bases, addr) - 1
        while pos >= 0:
            mod = self.modules[pos]
            if mod.contains(addr):
                return mod
            if mod.base + (64 << 20) < addr:
                break
            pos -= 1
        return None


def _default_open(path: str) -> Optional[ByteSource]:
    try:
        return ByteSource(path=path)
    except OSError:
        return None


def _default_stat(path: str) -> Optional[Tuple[int, int]]:
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_size, getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9))


class ModuleMap(object):
    """PE/ELF modules of every traced pid, from /proc/PID/maps snapshots."""

    def __init__(self, open_file: Optional[Callable[[str], Optional[ByteSource]]] = None,
                 stat_file: Optional[Callable[[str], Optional[Tuple[int, int]]]] = None,
                 symbols_root: Optional[str] = None):
        self._open = open_file or _default_open
        self._stat = stat_file or _default_stat
        self._images: Dict[str, Optional[PEImage]] = {}
        self._magic: Dict[str, bytes] = {}
        self._snapshots: Dict[int, List[Snapshot]] = {}
        self.symbols_root = symbols_root
        self._elf: Dict[str, Optional[ElfSymbols]] = {}
        self._symbols_index: Optional[Dict[str, str]] = None

    # -- loading -----------------------------------------------------------
    def load(self, source: Any, pid: Optional[int] = None) -> None:
        """Load maps.json (path, dict or list) or a raw maps text (needs pid)."""
        obj = source
        if isinstance(source, str) and (os.path.exists(source) or "\n" in source):
            if os.path.exists(source):
                with open(source, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            else:
                text = source
            stripped = text.lstrip()
            if stripped.startswith(("{", "[")):
                obj = json.loads(stripped)
            else:
                if pid is None:
                    raise ValueError("raw maps text needs a pid")
                self.add_snapshot(pid, text, 0.0)
                return
        if isinstance(obj, dict):
            snaps = obj.get("snapshots")
            if snaps is None and ("text" in obj or "maps" in obj or "lines" in obj):
                snaps = [obj]
            if snaps is None:
                snaps = []
        else:
            snaps = list(obj)
        for snap in snaps:
            spid = to_int(snap.get("pid"), pid)
            if spid is None:
                continue
            text = snap.get("text")
            if text is None:
                lines = snap.get("lines")
                if lines is None:
                    lines = snap.get("maps")
                if isinstance(lines, list) and lines and isinstance(lines[0], dict):
                    text = "\n".join("%x-%x %s %08x 00:00 %d %s" % (
                        to_int(e.get("start"), 0), to_int(e.get("end"), 0), e.get("perms", "r--p"),
                        to_int(e.get("offset"), 0), to_int(e.get("inode"), 0), e.get("path", ""))
                        for e in lines)
                elif isinstance(lines, list):
                    text = "\n".join(str(x) for x in lines)
                else:
                    text = lines or ""
            t = snap.get("t")
            self.add_snapshot(spid, text, float(t) if t is not None else 0.0)

    def add_snapshot(self, pid: int, text: str, t: float = 0.0) -> Snapshot:
        entries = parse_maps(text)
        modules: List[Module] = []
        exec_ranges = [(e.start, e.end) for e in entries if "x" in e.perms]
        seen: set = set()
        for index, entry in enumerate(entries):
            if entry.offset != 0 or not entry.path or entry.path.startswith("["):
                continue
            path = entry.path
            if path.endswith(" (deleted)"):
                path = path[:-len(" (deleted)")]
            magic = self._magic_of(path)
            if magic[:2] == b"MZ":
                image = self._image_of(path)
                if image is None:
                    mod = Module(path, entry.start, self._contiguous_end(entries, index), "missing", None,
                                 self._identity(path, entry.start))
                else:
                    end = entry.start + max(image.size_of_image, entry.end - entry.start)
                    if not any(s < end and e > entry.start for s, e in exec_ranges):
                        continue  # a plain file view of a PE file, not a loaded image
                    kind = "pe64" if image.is_pe64 else "pe32"
                    mod = Module(path, entry.start, end, kind, image, self._identity(path, entry.start))
            elif magic[:4] == b"\x7fELF":
                mod = Module(path, entry.start, self._contiguous_end(entries, index), "elf", None,
                             self._identity(path, entry.start))
            elif not magic and re.search(r"\.(exe|dll|vst3|ocx|drv|sys)$", path, re.IGNORECASE):
                mod = Module(path, entry.start, self._contiguous_end(entries, index), "missing", None,
                             self._identity(path, entry.start))
            else:
                continue
            marker = (mod.path, mod.base)
            if marker in seen:
                continue
            seen.add(marker)
            modules.append(mod)
        snap = Snapshot(pid, t, modules, entries)
        lst = self._snapshots.setdefault(pid, [])
        lst.append(snap)
        lst.sort(key=lambda s: s.t)
        return snap

    @staticmethod
    def _contiguous_end(entries: List[MapEntry], index: int) -> int:
        first = entries[index]
        end = first.end
        for entry in entries[index + 1:]:
            if entry.path != first.path or entry.offset == 0:
                break
            end = entry.end
        return end

    def _identity(self, path: str, base: int) -> Dict[str, Any]:
        st = self._stat(path)
        return {"path": path, "size": st[0] if st else None, "mtime_ns": st[1] if st else None,
                "base": hexs(base)}

    def _magic_of(self, path: str) -> bytes:
        if path in self._magic:
            return self._magic[path]
        src = self._open(path)
        magic = b""
        if src is not None:
            try:
                magic = src.read(0, 4)
            finally:
                if path not in self._images:
                    src.close()
        self._magic[path] = magic
        return magic

    def _image_of(self, path: str) -> Optional[PEImage]:
        if path in self._images:
            return self._images[path]
        image: Optional[PEImage] = None
        src = self._open(path)
        if src is not None:
            try:
                image = PEImage(src, path)
            except PEError:
                src.close()
                image = None
        self._images[path] = image
        return image

    def close(self) -> None:
        """Release the file handles of every parsed image."""
        for image in self._images.values():
            if image is not None:
                image.close()

    def __enter__(self) -> "ModuleMap":
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    # -- lookup ------------------------------------------------------------
    def pids(self) -> List[int]:
        return sorted(self._snapshots)

    def snapshot(self, pid: int, t: Optional[float] = None) -> Optional[Snapshot]:
        snaps = self._snapshots.get(pid)
        if not snaps:
            return None
        if t is None:
            return snaps[-1]
        chosen = snaps[0]
        for snap in snaps:
            if snap.t <= t:
                chosen = snap
            else:
                break
        return chosen

    def find(self, addr: int, pid: Optional[int] = None, t: Optional[float] = None) -> Optional[Module]:
        if pid is not None:
            snap = self.snapshot(pid, t)
            if snap is not None:
                return snap.find(addr)
            return None
        for spid in self.pids():
            snap = self.snapshot(spid, t)
            if snap is not None:
                mod = snap.find(addr)
                if mod is not None:
                    return mod
        return None

    def fingerprint(self, pid: Optional[int] = None, t: Optional[float] = None) -> str:
        if pid is not None:
            snap = self.snapshot(pid, t)
            return snap.fingerprint if snap else "none"
        return "+".join(self.fingerprint(p, t) for p in self.pids()) or "none"

    def modules(self, pid: int, t: Optional[float] = None) -> List[Module]:
        snap = self.snapshot(pid, t)
        return list(snap.modules) if snap else []

    def exe_name(self, pid: int) -> Optional[str]:
        """Basename of the process executable (a non-Wine .exe preferred)."""
        best: Optional[str] = None
        for mod in self.modules(pid):
            if mod.kind in ("pe64", "pe32", "missing") and mod.name.lower().endswith(".exe"):
                if not mod.is_wine_dll:
                    return mod.name
                best = best or mod.name
        return best

    def identities(self) -> Dict[str, Dict[str, Any]]:
        result: Dict[str, Dict[str, Any]] = {}
        for snaps in self._snapshots.values():
            for snap in snaps:
                for mod in snap.modules:
                    result.setdefault(mod.key, {k: v for k, v in mod.identity.items() if k != "base"})
        return result

    # -- ELF symbols -------------------------------------------------------
    def elf_symbols(self, mod: Module) -> Optional[ElfSymbols]:
        if not self.symbols_root:
            return None
        if mod.path in self._elf:
            return self._elf[mod.path]
        result: Optional[ElfSymbols] = None
        candidate = self._symbols_file(mod.path)
        if candidate:
            try:
                result = ElfSymbols.from_file(candidate)
            except (OSError, PEError, struct.error):
                result = None
        self._elf[mod.path] = result
        return result

    def _symbols_file(self, path: str) -> Optional[str]:
        root = self.symbols_root
        if not root:
            return None
        candidates = [os.path.join(root, path.lstrip("/"))]
        m = re.search(r"/lib(?:64)?/wine/(.*)$", path)
        if m:
            candidates.append(os.path.join(root, "lib", "wine", m.group(1)))
        candidates.append(os.path.join(root, os.path.basename(path)))
        for cand in candidates:
            if os.path.isfile(cand):
                return cand
        if self._symbols_index is None:
            self._symbols_index = {}
            for dirpath, _dirs, files in os.walk(root):
                for name in files:
                    self._symbols_index.setdefault(name, os.path.join(dirpath, name))
        return self._symbols_index.get(os.path.basename(path))


# --------------------------------------------------------------------------- #
# Symbol formatting
# --------------------------------------------------------------------------- #

def format_address(mod: Optional[Module], addr: int, modules: Optional[ModuleMap] = None) -> str:
    """One frame string for `addr` inside `mod` (None -> bare hex)."""
    if mod is None:
        return hexs(addr)
    rva = addr - mod.base
    if mod.kind in ("pe64", "pe32"):
        if mod.is_wine_dll and mod.pe is not None:
            hit = mod.pe.nearest_export(rva)
            if hit is not None:
                return "%s!%s+0x%x" % (mod.name, hit[0], hit[1])
        return "%s+0x%x" % (mod.name, rva)
    if mod.kind == "elf":
        syms = modules.elf_symbols(mod) if modules is not None else None
        if syms is not None:
            hit = syms.lookup(rva + syms.load_vaddr)
            if hit is not None:
                return "unix:%s!%s+0x%x" % (mod.name, hit[0], hit[1])
        return "unix:%s+0x%x" % (mod.name, rva)
    return "%s+0x%x" % (mod.name, rva)


def caller_chain(frames: Sequence[str], depth: int = CHAIN_DEPTH) -> str:
    return CHAIN_SEP.join(frames[:depth])


# --------------------------------------------------------------------------- #
# Stack window and unwinder
# --------------------------------------------------------------------------- #

class StackWindow(object):
    """Captured user-stack bytes [base, base+len)."""

    __slots__ = ("base", "data")

    def __init__(self, base: int, data: bytes):
        self.base = base
        self.data = data

    @property
    def end(self) -> int:
        return self.base + len(self.data)

    def u64(self, addr: int) -> int:
        off = addr - self.base
        if off < 0 or off + 8 > len(self.data):
            raise WindowExhausted(addr)
        return struct.unpack_from("<Q", self.data, off)[0]

    def words(self) -> Iterable[Tuple[int, int]]:
        for off in range(0, len(self.data) - 7, 8):
            yield self.base + off, struct.unpack_from("<Q", self.data, off)[0]


def regs_from_record(value: Any) -> Dict[str, Optional[int]]:
    """Register file from a 20-word syscall_frame copy or a {name: value} dict."""
    regs: Dict[str, Optional[int]] = {name: None for name in REG_NAMES}
    if isinstance(value, dict):
        for name, v in value.items():
            regs[str(name).lower()] = to_int(v)
    elif isinstance(value, (list, tuple)):
        for name, v in zip(FRAME_REG_ORDER, value):
            regs[name] = to_int(v)
    return regs


def unwind_frame(pe: PEImage, rva: int, rsp: int, regs: Dict[str, Optional[int]], mem: StackWindow,
                 precise: bool = False) -> Tuple[int, int, Optional[str]]:
    """Unwind one PE64 frame.  Returns (caller rip, caller rsp, stop reason or None).

    Mirrors ntdll's RtlVirtualUnwind (Wine dlls/ntdll/unwind.c:2080-2200): codes
    are applied in array order (reverse prolog order), codes past the current
    prolog offset are skipped, SAVE_NONVOL offsets are relative to the frame base
    (frame register minus FrameOffset*16, else the rsp before any code is
    applied), chained infos restart with all codes applied.
    """
    lookup_rva = rva if precise else rva - 1
    rf = pe.runtime_function(lookup_rva)
    if rf is None:  # leaf function: the return address sits at rsp
        return mem.u64(rsp), rsp + 8, None

    def reg(name: str) -> int:
        value = regs.get(name)
        if value is None:
            raise RegisterUnavailable(name)
        return value

    ui = pe.unwind_info(rf)
    prolog_offset: Optional[int] = None
    if rf.begin <= rva < rf.begin + ui.prolog:
        prolog_offset = rva - rf.begin
    for _ in range(32):
        use_fp = ui.frame_reg != 0 and (
            prolog_offset is None
            or any(c.op == UWOP_SET_FPREG and c.offset <= prolog_offset for c in ui.codes))
        frame = reg(REG_NAMES[ui.frame_reg]) - ui.frame_off * 16 if use_fp else rsp
        for code in ui.codes:
            if prolog_offset is not None and prolog_offset < code.offset:
                continue
            op = code.op
            if op == UWOP_PUSH_NONVOL:
                regs[REG_NAMES[code.info]] = mem.u64(rsp)
                rsp += 8
            elif op == UWOP_ALLOC_LARGE:
                rsp += code.extra or 0
            elif op == UWOP_ALLOC_SMALL:
                rsp += (code.info + 1) * 8
            elif op == UWOP_SET_FPREG:
                rsp = frame
            elif op in (UWOP_SAVE_NONVOL, UWOP_SAVE_NONVOL_FAR):
                regs[REG_NAMES[code.info]] = mem.u64(frame + (code.extra or 0))
            elif op in (UWOP_SAVE_XMM128, UWOP_SAVE_XMM128_FAR, UWOP_EPILOG, UWOP_SPARE_CODE):
                continue
            elif op == UWOP_PUSH_MACHFRAME:
                return 0, rsp, STOP_MACHFRAME
            else:
                raise PEError("unknown unwind op %d" % op)
        if ui.chained is None:
            break
        ui = pe.unwind_info(ui.chained)
        prolog_offset = None
    else:
        raise PEError("chained unwind info too deep")
    return mem.u64(rsp), rsp + 8, None


def unwind(rip: int, rsp: int, regs: Dict[str, Optional[int]], mem: StackWindow, start_mode: str,
           modules: ModuleMap, pid: Optional[int] = None, t: Optional[float] = None,
           max_frames: int = DEFAULT_MAX_FRAMES) -> Tuple[List[str], List[int], str]:
    """Offline x64 unwind.  Returns (frames, addresses, stop reason).

    start_mode: "syscall" (rip = NtXxx stub, *(rsp) = return into its caller),
    "unixcall" (rip = return address inside the PE caller), "sample" (precise pc).
    """
    frames: List[str] = []
    addrs: List[int] = []
    regs = dict(regs)
    precise = False
    if start_mode == "syscall":
        mod = modules.find(rip, pid, t)
        frames.append(format_address(mod, rip, modules))
        addrs.append(rip)
        try:
            rip = mem.u64(rsp)
        except WindowExhausted:
            return frames, addrs, STOP_WINDOW
        rsp += 8
    elif start_mode == "sample":
        precise = True
    while True:
        if len(frames) >= max_frames:
            return frames, addrs, STOP_MAX_FRAMES
        if rip == 0:
            return frames, addrs, STOP_END
        mod = modules.find(rip, pid, t)
        frames.append(format_address(mod, rip, modules))
        addrs.append(rip)
        if mod is None:
            return frames, addrs, STOP_NON_PE
        if mod.kind == "elf":
            return frames, addrs, STOP_UNIX
        if mod.is_wow64:
            return frames, addrs, STOP_WOW64
        if mod.kind != "pe64" or mod.pe is None:
            return frames, addrs, STOP_UNREADABLE if mod.kind == "missing" else STOP_NON_PE
        try:
            new_rip, new_rsp, stop = unwind_frame(mod.pe, rip - mod.base, rsp, regs, mem, precise)
        except WindowExhausted:
            return frames, addrs, STOP_WINDOW
        except RegisterUnavailable:
            return frames, addrs, STOP_REGISTER
        except PEError:
            return frames, addrs, STOP_BAD_UNWIND
        if stop:
            return frames, addrs, stop
        if new_rsp <= rsp:
            return frames, addrs, STOP_BAD_FRAME
        rip, rsp = new_rip, new_rsp
        precise = False


# --------------------------------------------------------------------------- #
# Persistent caches
# --------------------------------------------------------------------------- #

class SymCache(object):
    """symcache.json: symbols and unwind infos per module identity, stacks per window hash."""

    def __init__(self) -> None:
        self.modules: Dict[str, Dict[str, Any]] = {}
        self.symbols: Dict[str, Dict[str, str]] = {}
        self.unwind: Dict[str, Dict[str, Any]] = {}
        self.stacks: Dict[str, List[Any]] = {}
        self.hits = 0
        self.misses = 0
        self.path: Optional[str] = None

    @classmethod
    def load(cls, path: Optional[str]) -> "SymCache":
        cache = cls()
        cache.path = path
        if path and os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    obj = json.load(fh)
            except (OSError, ValueError):
                obj = {}
            if isinstance(obj, dict) and obj.get("version") == __version__:
                cache.modules = obj.get("modules", {}) or {}
                cache.symbols = obj.get("symbols", {}) or {}
                cache.unwind = obj.get("unwind", {}) or {}
                cache.stacks = obj.get("stacks", {}) or {}
        return cache

    def save(self, path: Optional[str] = None) -> None:
        path = path or self.path
        if not path:
            return
        obj = {"version": __version__, "modules": self.modules, "symbols": self.symbols,
               "unwind": self.unwind, "stacks": self.stacks}
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(obj, fh, separators=(",", ":"), sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)

    def seed_unwind(self, mod: Module) -> None:
        """Pre-load decoded unwind infos of a module into its PEImage."""
        if mod.pe is None:
            return
        for rva_hex, obj in self.unwind.get(mod.key, {}).items():
            try:
                mod.pe._unwind_cache.setdefault(int(rva_hex, 16), UnwindInfo.from_json(obj))
            except (ValueError, TypeError, IndexError):
                continue

    def collect_unwind(self, mod: Module) -> None:
        if mod.pe is None or not mod.pe._unwind_cache:
            return
        bucket = self.unwind.setdefault(mod.key, {})
        for rva, ui in mod.pe._unwind_cache.items():
            key = "%x" % rva
            if key not in bucket:
                bucket[key] = ui.to_json()


class Symbolizer(object):
    """ModuleMap + caches + the record decoder used by the CLI."""

    def __init__(self, modules: ModuleMap, cache: Optional[SymCache] = None,
                 max_frames: int = DEFAULT_MAX_FRAMES):
        self.modules = modules
        self.cache = cache or SymCache()
        self.max_frames = max_frames
        self._seeded: set = set()
        self.stats = {"stacks": 0, "stack_cache_hits": 0, "symbol_cache_hits": 0,
                      "stops": {}}
        for pid in modules.pids():
            for snap in modules._snapshots[pid]:
                for mod in snap.modules:
                    self.cache.modules.setdefault(mod.key, {k: v for k, v in mod.identity.items() if k != "base"})
                    if mod.key not in self._seeded:
                        self.cache.seed_unwind(mod)
                        self._seeded.add(mod.key)

    # -- symbols -----------------------------------------------------------
    def symbol(self, addr: int, pid: Optional[int] = None, t: Optional[float] = None) -> str:
        mod = self.modules.find(addr, pid, t)
        if mod is None:
            return hexs(addr)
        bucket = self.cache.symbols.setdefault(mod.key, {})
        rva_hex = "%x" % (addr - mod.base)
        hit = bucket.get(rva_hex)
        if hit is not None:
            self.stats["symbol_cache_hits"] += 1
            return hit
        text = format_address(mod, addr, self.modules)
        bucket[rva_hex] = text
        return text

    # -- stacks ------------------------------------------------------------
    @staticmethod
    def decode_record(rec: Dict[str, Any]) -> Tuple[str, int, int, Dict[str, Optional[int]], StackWindow]:
        """(start_mode, rip, rsp, regs, window) from a stacks.jsonl record."""
        kind = str(rec.get("kind", "syscall")).lower()
        mode = "sample" if kind in ("sample", "perf", "cpu") else ("unixcall" if kind == "unixcall" else "syscall")
        rip = to_int(rec.get("rip"), 0) or 0
        rsp = to_int(rec.get("rsp"), 0) or 0
        regs = regs_from_record(rec.get("regs"))
        if regs.get("rbp") is None and rec.get("rbp") is not None:
            regs["rbp"] = to_int(rec.get("rbp"))
        data = b""
        for key in ("stack_hex", "bytes_hex", "window_hex", "stack", "bytes", "data"):
            value = rec.get(key)
            if isinstance(value, str) and value:
                try:
                    data = bytes.fromhex(value)
                    break
                except ValueError:
                    continue
        if not data:
            for key in ("stack_b64", "bytes_b64", "window_b64"):
                value = rec.get(key)
                if isinstance(value, str) and value:
                    try:
                        data = base64.b64decode(value)
                        break
                    except ValueError:
                        continue
        base = to_int(rec.get("window_base"), None)
        if base is None:
            base = to_int(rec.get("stack_base"), rsp)
        return mode, rip, rsp, regs, StackWindow(base or rsp, data)

    def _stack_key(self, mode: str, rip: int, rsp: int, mem: StackWindow, pid: Optional[int],
                   t: Optional[float]) -> str:
        parts = [self.modules.fingerprint(pid, t), mode, "%x" % rip, "%x" % (rsp & 0xF)]
        found = 0
        for addr, word in mem.words():
            if word and self.modules.find(word, pid, t) is not None:
                parts.append("%x:%x" % (addr - mem.base, word))
                found += 1
                if found >= STACK_CACHE_WORDS:
                    break
        return hashlib.sha1("|".join(parts).encode("utf-8")).hexdigest()[:24]

    def unwind_record(self, rec: Dict[str, Any]) -> Dict[str, Any]:
        """Symbolize one stacks.jsonl record -> {"frames", "addrs", "caller", "stop"}."""
        self.stats["stacks"] += 1
        pid = to_int(rec.get("pid"), None)
        t = rec.get("t")
        t = float(t) if isinstance(t, (int, float)) else None
        mode, rip, rsp, regs, mem = self.decode_record(rec)
        key = self._stack_key(mode, rip, rsp, mem, pid, t)
        cached = self.cache.stacks.get(key)
        if cached:
            self.stats["stack_cache_hits"] += 1
            frames, addrs_hex, stop = cached[0], cached[1], cached[2]
        else:
            frames, addrs, stop = unwind(rip, rsp, regs, mem, mode, self.modules, pid, t, self.max_frames)
            addrs_hex = [hexs(a) for a in addrs]
            self.cache.stacks[key] = [frames, addrs_hex, stop]
        self.stats["stops"][stop] = self.stats["stops"].get(stop, 0) + 1
        return {"frames": list(frames), "addrs": list(addrs_hex), "caller": caller_chain(frames), "stop": stop}

    def finish(self) -> None:
        for pid in self.modules.pids():
            for snap in self.modules._snapshots[pid]:
                for mod in snap.modules:
                    self.cache.collect_unwind(mod)
        self.cache.save()


# --------------------------------------------------------------------------- #
# Thread roles (roles.toml)
# --------------------------------------------------------------------------- #

def _toml_strip_comment(line: str) -> str:
    out = []
    quote: Optional[str] = None
    escaped = False
    for ch in line:
        if quote:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\" and quote == '"':
                escaped = True
            elif ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


def _toml_unescape(text: str) -> str:
    result = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "b": "\b", "f": "\f"}
            if nxt in mapping:
                result.append(mapping[nxt])
                i += 2
                continue
            if nxt == "u" and i + 5 < len(text):
                result.append(chr(int(text[i + 2:i + 6], 16)))
                i += 6
                continue
            if nxt == "U" and i + 9 < len(text):
                result.append(chr(int(text[i + 2:i + 10], 16)))
                i += 10
                continue
        result.append(ch)
        i += 1
    return "".join(result)


def _toml_split_array(body: str) -> List[str]:
    items: List[str] = []
    cur: List[str] = []
    quote: Optional[str] = None
    escaped = False
    for ch in body:
        if quote:
            cur.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\" and quote == '"':
                escaped = True
            elif ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
            cur.append(ch)
        elif ch == ",":
            items.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        items.append(tail)
    return [item for item in items if item]


def _toml_value(text: str) -> Any:
    text = text.strip()
    if not text:
        raise ValueError("empty TOML value")
    if text.startswith('"'):
        if not text.endswith('"') or len(text) < 2:
            raise ValueError("unterminated string: %s" % text)
        return _toml_unescape(text[1:-1])
    if text.startswith("'"):
        if not text.endswith("'") or len(text) < 2:
            raise ValueError("unterminated literal string: %s" % text)
        return text[1:-1]
    if text == "true":
        return True
    if text == "false":
        return False
    if text.startswith("["):
        if not text.endswith("]"):
            raise ValueError("unterminated array: %s" % text)
        return [_toml_value(item) for item in _toml_split_array(text[1:-1])]
    if text.startswith("{"):
        raise ValueError("inline tables are not supported by the fallback TOML parser")
    cleaned = text.replace("_", "")
    try:
        if re.match(r"^[+-]?\d+$", cleaned):
            return int(cleaned, 10)
        return float(cleaned)
    except ValueError:
        raise ValueError("unsupported TOML value: %s" % text)


def parse_toml_subset(text: str) -> Dict[str, Any]:
    """Tiny TOML reader for roles.toml (tables, arrays of tables, scalars, flat arrays)."""
    root: Dict[str, Any] = {}
    current: Dict[str, Any] = root
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _toml_strip_comment(raw).strip()
        if not line:
            continue
        try:
            if line.startswith("[["):
                name = line[2:line.index("]]")].strip()
                target = root
                parts = name.split(".")
                for part in parts[:-1]:
                    target = target.setdefault(part.strip(), {})
                arr = target.setdefault(parts[-1].strip(), [])
                if not isinstance(arr, list):
                    raise ValueError("%s is not an array of tables" % name)
                current = {}
                arr.append(current)
                continue
            if line.startswith("["):
                name = line[1:line.index("]")].strip()
                target = root
                parts = name.split(".")
                for part in parts[:-1]:
                    target = target.setdefault(part.strip(), {})
                current = target.setdefault(parts[-1].strip(), {})
                if not isinstance(current, dict):
                    raise ValueError("%s is not a table" % name)
                continue
            key, sep, value = line.partition("=")
            if not sep:
                raise ValueError("expected key = value")
            key = key.strip()
            if key.startswith('"') and key.endswith('"'):
                key = key[1:-1]
            current[key] = _toml_value(value)
        except ValueError as exc:
            raise ValueError("roles.toml line %d: %s" % (lineno, exc))
    return root


def load_toml(path: str) -> Dict[str, Any]:
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        import tomllib  # Python 3.11+
    except ImportError:  # pragma: no cover - exercised on 3.9/3.10 only
        return parse_toml_subset(data.decode("utf-8"))
    return tomllib.loads(data.decode("utf-8"))


class RoleRule(object):
    __slots__ = ("role", "comm", "exe", "process_comm", "main", "named")

    def __init__(self, obj: Dict[str, Any]):
        self.role = str(obj.get("role", "unknown:{comm}"))
        self.comm = re.compile(obj["comm"]) if obj.get("comm") else None
        self.exe = re.compile(obj["exe"], re.IGNORECASE) if obj.get("exe") else None
        self.process_comm = re.compile(obj["process_comm"]) if obj.get("process_comm") else None
        self.main = obj.get("main")
        self.named = obj.get("named")


class RoleTable(object):
    """Ordered comm/exe rules -> role (design B section 5)."""

    def __init__(self, obj: Dict[str, Any]):
        self.version = obj.get("version", 1)
        self.rules = [RoleRule(r) for r in obj.get("rule", [])]
        self.audio_roles = [str(x) for x in obj.get("audio_roles", [])]
        self.dynamic = dict(obj.get("dynamic", {}))
        self.fallback = str(obj.get("fallback", "unknown:{comm}"))

    @classmethod
    def load(cls, path: Optional[str] = None) -> "RoleTable":
        path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "roles.toml")
        return cls(load_toml(path))

    def classify(self, comm: str, exe: Optional[str] = None, pid: Optional[int] = None,
                 tid: Optional[int] = None, process_comm: Optional[str] = None) -> str:
        comm = comm or ""
        named: Optional[bool] = None
        if process_comm is not None:
            named = comm != process_comm
        for rule in self.rules:
            if rule.comm is not None and not rule.comm.search(comm):
                continue
            if rule.exe is not None and (exe is None or not rule.exe.search(exe)):
                continue
            if rule.process_comm is not None and (process_comm is None or not rule.process_comm.search(process_comm)):
                continue
            if rule.main is not None:
                if pid is None or tid is None or (tid == pid) != bool(rule.main):
                    continue
            if rule.named is not None:
                if named is None or named != bool(rule.named):
                    continue
            return rule.role.format(comm=comm, exe=exe or "")
        return self.fallback.format(comm=comm, exe=exe or "")

    def is_audio(self, role: str) -> bool:
        return any(fnmatch.fnmatchcase(role, pattern) for pattern in self.audio_roles)


def load_roles(path: Optional[str] = None) -> RoleTable:
    return RoleTable.load(path)


# --------------------------------------------------------------------------- #
# JSONL helpers and the CLI commands
# --------------------------------------------------------------------------- #

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


def stack_ref_of(entry: Dict[str, Any]) -> Optional[str]:
    for key in ("stack_ref", "ref", "stack_id", "stack"):
        value = entry.get(key)
        if isinstance(value, (int, str)) and not isinstance(value, bool):
            return str(value)
    return None


def write_jsonl_line(fh: Any, obj: Dict[str, Any]) -> None:
    fh.write(json.dumps(obj, separators=(",", ":")))
    fh.write("\n")


PLACEHOLDER_RE = re.compile(r"pe!0x([0-9a-fA-F]+)")
MAPS_TXT_RE = re.compile(r"^maps-(\d+)(-stop)?\.txt$")


def load_maps_dir(modules: ModuleMap, directory: str) -> List[str]:
    """Load DIR/maps.json, else the wrapper's raw maps-<pid>[-stop].txt snapshots.  Returns the files used."""
    used: List[str] = []
    json_path = os.path.join(directory, "maps.json")
    if os.path.isfile(json_path):
        modules.load(json_path)
        used.append(json_path)
        return used
    for name in sorted(os.listdir(directory)):
        m = MAPS_TXT_RE.match(name)
        if not m:
            continue
        path = os.path.join(directory, name)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        modules.add_snapshot(int(m.group(1)), text, 1e12 if m.group(2) else 0.0)
        used.append(path)
    return used


def rewrite_placeholders(obj: Any, resolve: Callable[[int], str]) -> int:
    """Replace reduce.py's `pe!0x<rip>` placeholders inside `caller`/`key` strings, in place."""
    count = 0
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in ("caller", "key") and isinstance(value, str) and "pe!0x" in value:
                def repl(m: Any) -> str:
                    return resolve(int(m.group(1), 16))
                obj[key] = PLACEHOLDER_RE.sub(repl, value)
                count += 1
            elif isinstance(value, (dict, list)):
                count += rewrite_placeholders(value, resolve)
    elif isinstance(obj, list):
        for item in obj:
            count += rewrite_placeholders(item, resolve)
    return count


def _replace_file(path: str, writer: Callable[[Any], None]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        writer(fh)
    os.replace(tmp, path)


def cmd_symbolize(args: argparse.Namespace) -> int:
    with ModuleMap(symbols_root=args.symbols_root) as modules:
        run_dir = os.path.dirname(os.path.abspath(args.blocks)) if args.blocks else None
        if args.maps:
            modules.load(args.maps, pid=args.pid)
        elif run_dir:
            used = load_maps_dir(modules, run_dir)
            if not used:
                print("symbolize: no maps.json or maps-<pid>.txt in %s" % run_dir, file=sys.stderr)
                return 1
        else:
            print("symbolize: --maps is required", file=sys.stderr)
            return 2
        if run_dir and not args.maps:
            # run-directory mode (profiler/bin/wine-trace stop): defaults from DIR, in-place output
            if not args.stacks and os.path.isfile(os.path.join(run_dir, "stacks.jsonl")):
                args.stacks = os.path.join(run_dir, "stacks.jsonl")
            if not args.symcache:
                args.symcache = os.path.join(run_dir, "symcache.json")
            if not args.events and os.path.isfile(os.path.join(run_dir, "events.jsonl")):
                args.events = os.path.join(run_dir, "events.jsonl")
                args.events_out = args.events_out or args.events
            if not args.out:
                args.out = args.blocks
            if args.summary is None and os.path.isfile(os.path.join(run_dir, "summary.json")):
                args.summary = os.path.join(run_dir, "summary.json")
        return _symbolize_files(args, modules)


def _symbolize_files(args: argparse.Namespace, modules: ModuleMap) -> int:
    cache = SymCache.load(args.symcache)
    sym = Symbolizer(modules, cache, args.max_frames)
    results: Dict[str, Dict[str, Any]] = {}
    placeholders = 0

    def resolve(addr: int) -> str:
        return sym.symbol(addr)

    stacks_out = open(args.stacks_out, "w", encoding="utf-8", newline="\n") if args.stacks_out else None
    try:
        if args.stacks:
            for rec in iter_jsonl(args.stacks):
                if rec.get("type") == "header":
                    if stacks_out:
                        rec = dict(rec)
                        rec["symbolized"] = True
                        write_jsonl_line(stacks_out, rec)
                    continue
                ref = stack_ref_of(rec)
                res = sym.unwind_record(rec)
                if ref is not None:
                    results[ref] = res
                if stacks_out:
                    out = dict(rec)
                    for key in ("stack_hex", "stack_b64", "bytes_hex", "bytes_b64", "regs", "stack", "bytes", "data"):
                        out.pop(key, None)
                    out.update(res)
                    write_jsonl_line(stacks_out, out)
    finally:
        if stacks_out:
            stacks_out.close()

    def attach(entry: Dict[str, Any]) -> Dict[str, Any]:
        ref = stack_ref_of(entry)
        res = results.get(ref) if ref is not None else None
        if res is None and ("rip" in entry or "stack_hex" in entry or "stack_b64" in entry):
            res = sym.unwind_record(entry)
        out = dict(entry)
        if res is None:
            out.setdefault("frames", [])
            out.setdefault("stop", "missing_stack")
        else:
            out.update(res)
        return out

    if args.blocks and args.out:
        records = list(iter_jsonl(args.blocks))   # read fully first: --out may be the input (in place)

        def write_blocks(fh: Any) -> None:
            nonlocal placeholders
            for rec in records:
                if rec.get("type") == "header":
                    rec = dict(rec)
                    rec["symbolized"] = True
                    rec["symbolizer_version"] = __version__
                    write_jsonl_line(fh, rec)
                    continue
                stacks = rec.get("stacks")
                if isinstance(stacks, list):
                    rec = dict(rec)
                    rec["stacks"] = [attach(s) if isinstance(s, dict) else s for s in stacks]
                placeholders += rewrite_placeholders(rec, resolve)
                write_jsonl_line(fh, rec)
        _replace_file(args.out, write_blocks)

    if args.events and args.events_out:
        records = list(iter_jsonl(args.events))

        def write_events(fh: Any) -> None:
            nonlocal placeholders
            for rec in records:
                if rec.get("type") != "header" and stack_ref_of(rec) is not None:
                    rec = attach(rec)
                placeholders += rewrite_placeholders(rec, resolve)
                write_jsonl_line(fh, rec)
        _replace_file(args.events_out, write_events)

    if args.summary:
        try:
            with open(args.summary, "r", encoding="utf-8") as fh:
                summary = json.load(fh)
        except (OSError, ValueError) as exc:
            print("symbolize: cannot read %s: %s" % (args.summary, exc), file=sys.stderr)
            summary = None
        if isinstance(summary, dict):
            placeholders += rewrite_placeholders(summary, resolve)
            summary["symbolized"] = True

            def write_summary(fh: Any) -> None:
                json.dump(summary, fh, indent=1, sort_keys=True)
                fh.write("\n")
            _replace_file(args.summary, write_summary)

    if args.imports_out:
        dump: Dict[str, Any] = {"type": "imports", "modules": {}}
        for pid in modules.pids():
            for mod in modules.modules(pid):
                if mod.pe is None or mod.is_wine_dll or not mod.name.lower().endswith(".exe"):
                    continue
                if mod.path in dump["modules"]:
                    continue
                dump["modules"][mod.path] = {"identity": {k: v for k, v in mod.identity.items() if k != "base"},
                                             "imports": mod.pe.imports()}
        with open(args.imports_out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(dump, fh, indent=1, sort_keys=True)
            fh.write("\n")

    sym.finish()
    if not args.quiet:
        print(json.dumps({"stacks": sym.stats["stacks"], "stack_cache_hits": sym.stats["stack_cache_hits"],
                          "stops": sym.stats["stops"], "placeholders_rewritten": placeholders,
                          "pids": modules.pids(), "symcache": args.symcache}, sort_keys=True), file=sys.stderr)
    return 0


PERF_HEADER_RE = re.compile(r"^(?P<comm>\S.*?)\s+(?P<a>\d+)(?:/(?P<b>\d+))?\s+(?P<time>\d+\.\d+):")
PERF_FRAME_RE = re.compile(r"^(?P<lead>\s+)(?P<ip>[0-9a-fA-F]+)\s+\[unknown\](?P<rest>.*)$")


def rewrite_perf_lines(lines: Iterable[str], modules: ModuleMap, pid_override: Optional[int] = None) -> Iterable[str]:
    """Replace `[unknown]` PE frames in perf-script output with module+offset symbols."""
    sym = Symbolizer(modules)
    pid: Optional[int] = pid_override
    known_pids = set(modules.pids())
    for line in lines:
        text = line.rstrip("\n")
        m = PERF_HEADER_RE.match(text)
        if m and pid_override is None:
            a = int(m.group("a"))
            b = m.group("b")
            if b is not None:
                pid = a
            else:
                pid = a if a in known_pids else None
            yield line
            continue
        f = PERF_FRAME_RE.match(text)
        if not f:
            yield line
            continue
        ip = int(f.group("ip"), 16)
        mod = modules.find(ip, pid) if pid is not None else modules.find(ip)
        if mod is None:
            yield line
            continue
        symbol = sym.symbol(ip, pid if mod else None)
        yield "%s%s %s%s\n" % (f.group("lead"), f.group("ip"), symbol, f.group("rest"))


def cmd_perf(args: argparse.Namespace) -> int:
    with ModuleMap(symbols_root=args.symbols_root) as modules:
        modules.load(args.maps, pid=args.pid)
        source = sys.stdin if args.perf in (None, "-") else open(args.perf, "r", encoding="utf-8", errors="replace")
        sink = open(args.out, "w", encoding="utf-8", newline="\n") if args.out else sys.stdout
        try:
            for out in rewrite_perf_lines(source, modules, args.pid):
                sink.write(out)
        finally:
            if source is not sys.stdin:
                source.close()
            if sink is not sys.stdout:
                sink.close()
    return 0


def cmd_dump_pe(args: argparse.Namespace) -> int:
    image = PEImage.from_file(args.dump_pe)
    try:
        report = image.self_check()
        if args.verbose:
            report["export_list"] = ["%x %s" % (rva, name) for rva, name in image.exports()[:200]]
    finally:
        image.close()
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0


def cmd_dump_maps(args: argparse.Namespace) -> int:
    with ModuleMap(symbols_root=args.symbols_root) as modules:
        modules.load(args.dump_maps, pid=args.pid)
        report = {pid: [m.as_dict() for m in modules.modules(pid)] for pid in modules.pids()}
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0


def cmd_classify(args: argparse.Namespace) -> int:
    table = load_roles(args.roles)
    role = table.classify(args.classify, exe=args.exe, pid=args.pid, tid=args.tid, process_comm=args.process_comm)
    print(json.dumps({"comm": args.classify, "role": role, "audio": table.is_audio(role)}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--blocks", help="blocks.jsonl from reduce.py; alone (no --maps) = run-directory mode: maps, "
                                    "stacks.jsonl, events.jsonl, summary.json and symcache.json are taken from "
                                    "its directory and the files are rewritten in place")
    p.add_argument("--stacks", help="stacks.jsonl (raw stack records)")
    p.add_argument("--maps", help="maps.json (/proc/PID/maps snapshots) or a raw maps text with --pid")
    p.add_argument("--symcache", help="persistent cache file (read and updated)")
    p.add_argument("--out", help="output: blocks.symbolized.jsonl (or the rewritten perf script with --perf)")
    p.add_argument("--summary", help="summary.json whose caller placeholders are rewritten (default: DIR/summary.json in run-directory mode)")
    p.add_argument("--stacks-out", help="write symbolized stack records here")
    p.add_argument("--events", help="events.jsonl to annotate (with --events-out)")
    p.add_argument("--events-out")
    p.add_argument("--imports-out", help="dump the import tables of non-Wine .exe modules (imports.json)")
    p.add_argument("--symbols-root", help="unstripped runtime tree for unix-side .symtab lookups")
    p.add_argument("--max-frames", type=int, default=DEFAULT_MAX_FRAMES)
    p.add_argument("--pid", type=int, help="pid for a raw maps text / perf script without pid field")
    p.add_argument("--perf", nargs="?", const="-", metavar="FILE", help="rewrite perf script output ([unknown] PE frames)")
    p.add_argument("--dump-pe", metavar="FILE", help="decode a PE file's headers, exports and unwind infos")
    p.add_argument("--dump-maps", metavar="FILE", help="list the modules found in a maps.json")
    p.add_argument("--classify", metavar="COMM", help="classify one thread with roles.toml")
    p.add_argument("--exe")
    p.add_argument("--tid", type=int)
    p.add_argument("--process-comm")
    p.add_argument("--roles", help="roles.toml path (default: next to this script)")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--quiet", "-q", action="store_true")
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.dump_pe:
        return cmd_dump_pe(args)
    if args.dump_maps:
        return cmd_dump_maps(args)
    if args.classify:
        return cmd_classify(args)
    if args.perf is not None:
        if not args.maps:
            build_parser().error("--perf needs --maps")
        return cmd_perf(args)
    if not (args.blocks or args.stacks or args.events or args.imports_out):
        build_parser().error("nothing to do: give --blocks/--stacks/--events/--imports-out or --perf")
    if not args.maps and not args.blocks:
        build_parser().error("--maps is required unless --blocks gives a run directory")
    return cmd_symbolize(args)


if __name__ == "__main__":
    sys.exit(main())
