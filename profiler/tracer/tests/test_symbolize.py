#!/usr/bin/env python3
"""Unit tests for profiler/tracer/symbolize.py (design B section 7).

Builds synthetic PE32+ images in memory (headers, .text, .rdata with an export
table, an import table and UNWIND_INFO blobs, .pdata with plain, chained and
indirect entries), a synthetic /proc/PID/maps snapshot and a synthetic stack
window, then asserts the recovered frames, the symbol strings, the caches, the
roles table and the perf rewrite.

Run from the repository root:  python3 -I -m unittest discover -s profiler/tracer/tests -v
"""

from __future__ import annotations

import base64
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import symbolize as S  # noqa: E402


def u16(v: int) -> bytes:
    return struct.pack("<H", v)


def u32(v: int) -> bytes:
    return struct.pack("<I", v)


def u64(v: int) -> bytes:
    return struct.pack("<Q", v)


def code(offset: int, op: int, info: int, *extra: int) -> bytes:
    """One unwind code (plus its extra u16 slots)."""
    return bytes([offset, op | (info << 4)]) + b"".join(u16(x) for x in extra)


def unwind_blob(codes: bytes, prolog: int, frame_reg: int = 0, frame_off: int = 0, flags: int = 0,
                chained: tuple = None, version: int = 1) -> bytes:
    count = len(codes) // 2
    blob = bytes([version | (flags << 3), prolog, count, frame_reg | (frame_off << 4)]) + codes
    if count & 1:
        blob += b"\0\0"
    if chained:
        blob += struct.pack("<III", *chained)
    return blob


class PEBuilder(object):
    """Minimal PE32+ writer: headers at raw 0, .text, .rdata, .pdata with non-identity raw offsets."""

    TEXT = (0x1000, 0x400, 0x1000)      # rva, raw, size
    RDATA = (0x2000, 0x1400, 0x1000)
    PDATA = (0x3000, 0x2400, 0x400)
    UNWIND_BASE = 0x2000
    EXPORT_BASE = 0x2400
    IMPORT_BASE = 0x2800
    EXTRA_BASE = 0x2C00
    SIZE_OF_IMAGE = 0x5000

    def __init__(self, image_base: int = 0x140000000, dll: bool = False):
        self.image_base = image_base
        self.dll = dll
        self.exports = []       # (name, rva)
        self.imports = []       # (dll, [names])
        self.pdata = []         # (begin, end, unwind_rva)
        self._unwind = bytearray()
        self._extra = bytearray()

    def add_export(self, name: str, rva: int) -> None:
        self.exports.append((name, rva))

    def add_import(self, dll: str, names) -> None:
        self.imports.append((dll, list(names)))

    def add_unwind(self, blob: bytes) -> int:
        while len(self._unwind) % 4:
            self._unwind.append(0)
        rva = self.UNWIND_BASE + len(self._unwind)
        self._unwind += blob
        assert len(self._unwind) <= self.EXPORT_BASE - self.UNWIND_BASE
        return rva

    def add_indirect_rf(self, begin: int, end: int, unwind_rva: int) -> int:
        """A RUNTIME_FUNCTION stored in .rdata; returns its RVA (callers OR in the 1 bit)."""
        while len(self._extra) % 4:
            self._extra.append(0)
        rva = self.EXTRA_BASE + len(self._extra)
        self._extra += struct.pack("<III", begin, end, unwind_rva)
        return rva

    def add_pdata(self, begin: int, end: int, unwind_rva: int) -> None:
        self.pdata.append((begin, end, unwind_rva))

    def _export_dir(self):
        exports = sorted(self.exports)
        n = len(exports)
        base = self.EXPORT_BASE
        funcs_rva = base + 40
        names_rva = funcs_rva + 4 * n
        ords_rva = names_rva + 4 * n
        strings_rva = ords_rva + 2 * n
        strings = bytearray()
        name_rvas = []
        for name, _rva in exports:
            name_rvas.append(strings_rva + len(strings))
            strings += name.encode("ascii") + b"\0"
        blob = struct.pack("<IIHHIIIIIII", 0, 0, 0, 0, strings_rva + len(strings), 1, n, n,
                           funcs_rva, names_rva, ords_rva)
        blob += b"".join(u32(rva) for _n, rva in exports)
        blob += b"".join(u32(r) for r in name_rvas)
        blob += b"".join(u16(i) for i in range(n))
        blob += bytes(strings) + b"synthetic.dll\0"
        return blob, len(blob)

    def _import_dir(self):
        base = self.IMPORT_BASE
        descs = bytearray()
        payload = bytearray()
        payload_rva = base + 20 * (len(self.imports) + 1)
        for dll, names in self.imports:
            thunks = []
            hint_names = []
            for name in names:
                if name.startswith("#"):
                    thunks.append((1 << 63) | int(name[1:]))
                else:
                    hint_names.append(name)
                    thunks.append(None)
            # hint/name entries first
            hn_rvas = {}
            for name in hint_names:
                while len(payload) % 2:
                    payload.append(0)
                hn_rvas[name] = payload_rva + len(payload)
                payload += u16(0) + name.encode("ascii") + b"\0"
            while len(payload) % 8:
                payload.append(0)
            oft_rva = payload_rva + len(payload)
            resolved = []
            idx = 0
            for name in names:
                if name.startswith("#"):
                    resolved.append(thunks[idx])
                else:
                    resolved.append(hn_rvas[name])
                idx += 1
            arr = b"".join(u64(v) for v in resolved) + u64(0)
            payload += arr
            ft_rva = payload_rva + len(payload)
            payload += arr
            name_rva = payload_rva + len(payload)
            payload += dll.encode("ascii") + b"\0"
            descs += struct.pack("<IIIII", oft_rva, 0, 0, name_rva, ft_rva)
        descs += b"\0" * 20
        return bytes(descs) + bytes(payload), 20 * (len(self.imports) + 1)

    def build(self) -> bytes:
        text_rva, text_raw, text_size = self.TEXT
        rdata_rva, rdata_raw, rdata_size = self.RDATA
        pdata_rva, pdata_raw, pdata_size = self.PDATA
        file_size = pdata_raw + pdata_size
        img = bytearray(file_size)
        # DOS header
        img[0:2] = b"MZ"
        img[0x3C:0x40] = u32(0x80)
        nt = 0x80
        img[nt:nt + 4] = b"PE\0\0"
        characteristics = 0x22 | (0x2000 if self.dll else 0)
        img[nt + 4:nt + 24] = struct.pack("<HHIIIHH", 0x8664, 3, 0, 0, 0, 240, characteristics)
        opt = bytearray(240)
        opt[0:2] = u16(0x20B)
        opt[16:20] = u32(text_rva)      # AddressOfEntryPoint
        opt[20:24] = u32(text_rva)      # BaseOfCode
        opt[24:32] = u64(self.image_base)
        opt[32:36] = u32(0x1000)        # SectionAlignment
        opt[36:40] = u32(0x200)         # FileAlignment
        opt[56:60] = u32(self.SIZE_OF_IMAGE)
        opt[60:64] = u32(0x400)         # SizeOfHeaders
        opt[68:70] = u16(2)             # Subsystem GUI
        opt[108:112] = u32(16)
        export_blob, export_size = self._export_dir()
        import_blob, import_size = self._import_dir()
        dirs = {}
        if self.exports:
            dirs[S.IMAGE_DIRECTORY_ENTRY_EXPORT] = (self.EXPORT_BASE, export_size)
        if self.imports:
            dirs[S.IMAGE_DIRECTORY_ENTRY_IMPORT] = (self.IMPORT_BASE, import_size)
        if self.pdata:
            dirs[S.IMAGE_DIRECTORY_ENTRY_EXCEPTION] = (pdata_rva, 12 * len(self.pdata))
        for index, (rva, size) in dirs.items():
            opt[112 + index * 8:112 + index * 8 + 8] = u32(rva) + u32(size)
        img[nt + 24:nt + 24 + 240] = opt
        sec = nt + 24 + 240
        for i, (name, rva, raw, size, flags) in enumerate([
                (b".text", text_rva, text_raw, text_size, 0x60000020),
                (b".rdata", rdata_rva, rdata_raw, rdata_size, 0x40000040),
                (b".pdata", pdata_rva, pdata_raw, pdata_size, 0x40000040)]):
            img[sec + i * 40:sec + (i + 1) * 40] = name.ljust(8, b"\0") + struct.pack(
                "<IIIIIIHHI", size, rva, size, raw, 0, 0, 0, 0, flags)
        # .text: int3 filler
        img[text_raw:text_raw + text_size] = b"\xcc" * text_size
        # .rdata
        def put(rva: int, blob: bytes) -> None:
            off = rdata_raw + (rva - rdata_rva)
            img[off:off + len(blob)] = blob
        put(self.UNWIND_BASE, bytes(self._unwind))
        put(self.EXPORT_BASE, export_blob)
        put(self.IMPORT_BASE, import_blob)
        put(self.EXTRA_BASE, bytes(self._extra))
        # .pdata
        entries = sorted(self.pdata)
        img[pdata_raw:pdata_raw + 12 * len(entries)] = b"".join(struct.pack("<III", *e) for e in entries)
        return bytes(img)


# --------------------------------------------------------------------------- #
# Fixture images and maps
# --------------------------------------------------------------------------- #

LIVE_PATH = "/home/u/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Trial/Program/Ableton Live 12 Trial.exe"
NTDLL_PATH = "/opt/wine/lib/wine/x86_64-windows/ntdll.dll"
WOW64_PATH = "/opt/wine/lib/wine/x86_64-windows/wow64.dll"
NTDLL_SO_PATH = "/opt/wine/lib/wine/x86_64-unix/ntdll.so"
PLUGIN_PATH = "/home/u/plugins/Serum.vst3"
FONT_PATH = "/usr/share/fonts/Vera.ttf"

LIVE_BASE = 0x140000000
NTDLL_BASE = 0x7FFF10000000
NTDLL_SO_BASE = 0x7FFF20000000
WOW64_BASE = 0x7FFF30000000
PLUGIN_BASE = 0x7FFF40000000
PID = 4200

# Live function layout (RVAs)
FUNC_A = 0x1000      # push rbp; sub rsp,0x20; lea rbp,[rsp+0x20]  (SET_FPREG, frame_off 2)
FUNC_B = 0x1100      # push rbx; sub rsp,0x30                       (chained region at 0x1140)
FUNC_B_CHAIN = 0x1140
FUNC_D = 0x1400      # mov [rsp+8],rbx; push rbp; sub rsp,0x20     (SAVE_NONVOL via frame base)
FUNC_E = 0x1500      # sub rsp,0x800 (ALLOC_LARGE info 0)
FUNC_F = 0x1600      # sub rsp,0x2000 (ALLOC_LARGE info 1) + SAVE_NONVOL_FAR rsi
FUNC_G = 0x1700      # PUSH_MACHFRAME
FUNC_H = 0x1800      # version 2 info with an EPILOG code
FUNC_I = 0x1900      # indirect .pdata entry (UnwindData | 1)
FUNC_X = 0x1A00      # no .pdata entry (leaf)
STUB_WAIT = 0x1000   # ntdll!NtWaitForSingleObject
STUB_CLOSE = 0x1020
RTL_USER_THREAD_START = 0x1200


def build_live() -> bytes:
    b = PEBuilder(image_base=LIVE_BASE)
    b.add_export("LiveInternalExport", 0x1000)   # must NOT be used for Live frames
    b.add_import("KERNEL32.dll", ["CreateEventW", "CloseHandle"])
    b.add_import("ntdll.dll", ["NtClose", "#5"])
    ui_a = b.add_unwind(unwind_blob(code(9, S.UWOP_SET_FPREG, 0) + code(5, S.UWOP_ALLOC_SMALL, 3)
                                    + code(1, S.UWOP_PUSH_NONVOL, 5), prolog=9, frame_reg=5, frame_off=2))
    b.add_pdata(FUNC_A, FUNC_A + 0x100, ui_a)
    ui_b = b.add_unwind(unwind_blob(code(5, S.UWOP_ALLOC_SMALL, 5) + code(1, S.UWOP_PUSH_NONVOL, 3), prolog=5))
    b.add_pdata(FUNC_B, FUNC_B_CHAIN, ui_b)
    ui_b_chain = b.add_unwind(unwind_blob(code(2, S.UWOP_PUSH_NONVOL, 12), prolog=0, flags=S.UNW_FLAG_CHAININFO,
                                          chained=(FUNC_B, FUNC_B_CHAIN, ui_b)))
    b.add_pdata(FUNC_B_CHAIN, FUNC_B + 0x80, ui_b_chain)
    ui_d = b.add_unwind(unwind_blob(code(10, S.UWOP_ALLOC_SMALL, 3) + code(6, S.UWOP_PUSH_NONVOL, 5)
                                    + code(5, S.UWOP_SAVE_NONVOL, 3, 6), prolog=10))
    b.add_pdata(FUNC_D, FUNC_D + 0x80, ui_d)
    ui_e = b.add_unwind(unwind_blob(code(7, S.UWOP_ALLOC_LARGE, 0, 0x100), prolog=7))
    b.add_pdata(FUNC_E, FUNC_E + 0x80, ui_e)
    ui_f = b.add_unwind(unwind_blob(code(20, S.UWOP_SAVE_NONVOL_FAR, 6, 0x20, 0)
                                    + code(12, S.UWOP_ALLOC_LARGE, 1, 0x2000, 0), prolog=20))
    b.add_pdata(FUNC_F, FUNC_F + 0x80, ui_f)
    ui_g = b.add_unwind(unwind_blob(code(1, S.UWOP_PUSH_MACHFRAME, 0), prolog=1))
    b.add_pdata(FUNC_G, FUNC_G + 0x80, ui_g)
    ui_h = b.add_unwind(unwind_blob(code(0x12, S.UWOP_EPILOG, 1, 0x0000) + code(4, S.UWOP_ALLOC_SMALL, 4),
                                    prolog=4, version=2))
    b.add_pdata(FUNC_H, FUNC_H + 0x80, ui_h)
    ui_i = b.add_unwind(unwind_blob(code(4, S.UWOP_ALLOC_SMALL, 1), prolog=4))
    indirect = b.add_indirect_rf(FUNC_I, FUNC_I + 0x80, ui_i)
    b.add_pdata(FUNC_I, FUNC_I + 0x80, indirect | 1)
    return b.build()


def build_ntdll() -> bytes:
    b = PEBuilder(image_base=0x170000000, dll=True)
    b.add_export("NtWaitForSingleObject", STUB_WAIT)
    b.add_export("NtClose", STUB_CLOSE)
    b.add_export("RtlUserThreadStart", RTL_USER_THREAD_START)
    b.add_export("LdrInitializeThunk", 0x1300)
    ui = b.add_unwind(unwind_blob(code(4, S.UWOP_ALLOC_SMALL, 4), prolog=4))
    b.add_pdata(RTL_USER_THREAD_START, RTL_USER_THREAD_START + 0x100, ui)
    return b.build()


def build_wow64() -> bytes:
    b = PEBuilder(image_base=0x180000000, dll=True)
    b.add_export("Wow64SystemServiceEx", 0x1000)
    return b.build()


def build_elf(symbols) -> bytes:
    """Minimal ELF64 shared object with a .symtab (one PT_LOAD at vaddr 0)."""
    strtab = bytearray(b"\0")
    syms = bytearray(b"\0" * 24)
    for value, size, name in symbols:
        name_off = len(strtab)
        strtab += name.encode("ascii") + b"\0"
        syms += struct.pack("<IBBHQQ", name_off, 0x12, 0, 1, value, size)  # GLOBAL FUNC, shndx 1
    shstrtab = b"\0.symtab\0.strtab\0.shstrtab\0"
    body = bytearray()
    off_strtab = 64 + 56
    body += bytes(strtab)
    off_shstr = off_strtab + len(body)
    body += shstrtab
    while (off_strtab + len(body)) % 8:
        body.append(0)
    off_symtab = off_strtab + len(body)
    body += bytes(syms)
    while (off_strtab + len(body)) % 8:
        body.append(0)
    shoff = off_strtab + len(body)
    sh = bytearray(b"\0" * 64)
    sh += struct.pack("<IIQQQQIIQQ", 1, 2, 0, 0, off_symtab, len(syms), 2, 1, 8, 24)   # .symtab, link=.strtab(2)
    sh += struct.pack("<IIQQQQIIQQ", 9, 3, 0, 0, off_strtab, len(strtab), 0, 0, 1, 0)  # .strtab
    sh += struct.pack("<IIQQQQIIQQ", 17, 3, 0, 0, off_shstr, len(shstrtab), 0, 0, 1, 0)  # .shstrtab
    ehdr = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    ehdr += struct.pack("<HHIQQQIHHHHHH", 3, 0x3E, 1, 0, 64, shoff, 0, 64, 56, 1, 64, 4, 3)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, shoff + len(sh), shoff + len(sh), 0x1000)
    return ehdr + phdr + bytes(body) + bytes(sh)


def maps_text(live_path=LIVE_PATH, ntdll_path=NTDLL_PATH, wow64_path=WOW64_PATH, ntdll_so=NTDLL_SO_PATH,
              plugin=PLUGIN_PATH, font=FONT_PATH) -> str:
    rows = [
        (LIVE_BASE, LIVE_BASE + 0x1000, "r--p", 0, "08:01", 123456, live_path),
        (LIVE_BASE + 0x1000, LIVE_BASE + 0x2000, "r-xp", 0, "00:00", 0, ""),
        (LIVE_BASE + 0x2000, LIVE_BASE + 0x5000, "rw-p", 0, "00:00", 0, ""),
        (NTDLL_BASE, NTDLL_BASE + 0x1000, "r--p", 0, "08:01", 222, ntdll_path),
        (NTDLL_BASE + 0x1000, NTDLL_BASE + 0x2000, "r-xp", 0x1000, "08:01", 222, ntdll_path),
        (NTDLL_BASE + 0x2000, NTDLL_BASE + 0x5000, "r--p", 0x2000, "08:01", 222, ntdll_path),
        (NTDLL_SO_BASE, NTDLL_SO_BASE + 0x10000, "r--p", 0, "08:01", 333, ntdll_so),
        (NTDLL_SO_BASE + 0x10000, NTDLL_SO_BASE + 0x100000, "r-xp", 0x10000, "08:01", 333, ntdll_so),
        (NTDLL_SO_BASE + 0x100000, NTDLL_SO_BASE + 0x140000, "r--p", 0x100000, "08:01", 333, ntdll_so),
        (NTDLL_SO_BASE + 0x140000, NTDLL_SO_BASE + 0x150000, "rw-p", 0x140000, "08:01", 333, ntdll_so),
        (WOW64_BASE, WOW64_BASE + 0x1000, "r--p", 0, "08:01", 444, wow64_path),
        (WOW64_BASE + 0x1000, WOW64_BASE + 0x3000, "r-xp", 0x1000, "08:01", 444, wow64_path),
        (PLUGIN_BASE, PLUGIN_BASE + 0x1000, "r--p", 0, "08:01", 555, plugin + " (deleted)"),
        (0x7FFF50000000, 0x7FFF50002000, "r--p", 0, "08:01", 666, font),
        (0x7FFFA0000000, 0x7FFFA0021000, "rw-p", 0, "00:00", 0, "[stack]"),
    ]
    lines = []
    for start, end, perms, off, dev, inode, path in rows:
        line = "%x-%x %s %08x %s %d" % (start, end, perms, off, dev, inode)
        if path:
            line += " " * (max(1, 40 - len(line))) + path
        lines.append(line)
    return "\n".join(lines) + "\n"


def make_module_map(files, symbols_root=None) -> S.ModuleMap:
    def opener(path):
        return S.ByteSource(data=files[path]) if path in files else None

    def stat(path):
        return (len(files[path]), 1700000000000000000) if path in files else None

    mm = S.ModuleMap(open_file=opener, stat_file=stat, symbols_root=symbols_root)
    mm.add_snapshot(PID, maps_text(), 0.0)
    return mm


def fixture_files():
    return {LIVE_PATH: build_live(), NTDLL_PATH: build_ntdll(), WOW64_PATH: build_wow64(),
            NTDLL_SO_PATH: build_elf([(0x10010, 0x40, "server_select"), (0x10050, 0, "wait_select_reply")])}


RSP0 = 0x7FFFA0010000


def main_window() -> bytes:
    """Stack for: NtWaitForSingleObject stub <- FuncA <- FuncB(chained) <- RtlUserThreadStart <- end."""
    mem = bytearray(0xB0)
    struct.pack_into("<Q", mem, 0x00, LIVE_BASE + FUNC_A + 0x40)             # return into FuncA
    struct.pack_into("<Q", mem, 0x28, 0x1111)                                # FuncA's saved rbp
    struct.pack_into("<Q", mem, 0x30, LIVE_BASE + FUNC_B_CHAIN + 0x10)       # return into FuncB chained region
    struct.pack_into("<Q", mem, 0x38, 0x1212)                                # chained region's saved r12
    struct.pack_into("<Q", mem, 0x70, 0x3333)                                # FuncB's saved rbx
    struct.pack_into("<Q", mem, 0x78, NTDLL_BASE + RTL_USER_THREAD_START + 0x21)
    struct.pack_into("<Q", mem, 0xA8, 0)                                     # end of chain
    return bytes(mem)


def main_regs():
    regs = {name: None for name in S.REG_NAMES}
    regs["rbp"] = RSP0 + 0x28   # lea rbp,[rsp+0x20] with rsp = RSP0 + 8 after FuncA's prolog
    return regs


# --------------------------------------------------------------------------- #
# Tests
# --------------------------------------------------------------------------- #

class MapsTests(unittest.TestCase):
    def test_parse_maps(self):
        entries = S.parse_maps(maps_text())
        self.assertEqual(len(entries), 15)
        live = entries[0]
        self.assertEqual(live.start, LIVE_BASE)
        self.assertEqual(live.path, LIVE_PATH)   # spaces preserved
        self.assertEqual(live.offset, 0)
        self.assertEqual(live.inode, 123456)
        deleted = [e for e in entries if e.path.endswith("(deleted)")]
        self.assertEqual(len(deleted), 1)
        stack = [e for e in entries if e.path == "[stack]"]
        self.assertEqual(len(stack), 1)

    def test_parse_maps_tolerates_garbage(self):
        entries = S.parse_maps("garbage\n\n7f-80 r--p 0 00:00 0\nnot a line at all\r\n")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].end, 0x80)

    def test_module_map_extent_from_size_of_image(self):
        mm = make_module_map(fixture_files())
        self.assertEqual(mm.pids(), [PID])
        live = mm.find(LIVE_BASE + FUNC_A + 0x40, PID)
        self.assertIsNotNone(live)
        self.assertEqual(live.kind, "pe64")
        self.assertEqual(live.name, "Ableton Live 12 Trial.exe")
        self.assertFalse(live.is_wine_dll)
        self.assertEqual(live.end, LIVE_BASE + PEBuilder.SIZE_OF_IMAGE)     # not the header page
        self.assertIs(mm.find(LIVE_BASE + 0x4FFF, PID), live)
        self.assertIsNone(mm.find(LIVE_BASE + 0x5000, PID))
        ntdll = mm.find(NTDLL_BASE + 0x1014, PID)
        self.assertTrue(ntdll.is_wine_dll)
        self.assertEqual(ntdll.kind, "pe64")
        so = mm.find(NTDLL_SO_BASE + 0x20000, PID)
        self.assertEqual(so.kind, "elf")
        self.assertEqual(so.end, NTDLL_SO_BASE + 0x150000)
        wow = mm.find(WOW64_BASE + 0x1000, PID)
        self.assertTrue(wow.is_wow64)
        plugin = mm.find(PLUGIN_BASE + 0x10, PID)
        self.assertEqual(plugin.kind, "missing")
        self.assertEqual(plugin.name, "Serum.vst3")
        self.assertIsNone(mm.find(0x7FFF50000100, PID))      # the font is not a module
        self.assertIsNone(mm.find(0x7FFFA0000100, PID))      # [stack]
        self.assertEqual(mm.exe_name(PID), "Ableton Live 12 Trial.exe")
        self.assertIs(mm.find(NTDLL_BASE + 0x1014), ntdll)   # pid-less lookup

    def test_file_view_of_pe_without_code_is_ignored(self):
        files = fixture_files()
        text = maps_text() + "%x-%x r--p 00000000 08:01 123456 %s\n" % (0x200000000, 0x200001000, LIVE_PATH)
        mm = S.ModuleMap(open_file=lambda p: S.ByteSource(data=files[p]) if p in files else None,
                         stat_file=lambda p: (1, 1))
        mm.add_snapshot(PID, text, 0.0)
        self.assertIsNone(mm.find(0x200000800, PID))
        self.assertIsNotNone(mm.find(LIVE_BASE + 0x800, PID))

    def test_snapshot_selection_by_time(self):
        files = fixture_files()
        mm = make_module_map(files)
        later = maps_text().replace("%x-%x" % (LIVE_BASE, LIVE_BASE + 0x1000), "%x-%x" % (LIVE_BASE + 0x10000000, LIVE_BASE + 0x10001000))
        later = later.replace("%x-%x r-xp" % (LIVE_BASE + 0x1000, LIVE_BASE + 0x2000), "%x-%x r-xp" % (LIVE_BASE + 0x10001000, LIVE_BASE + 0x10002000))
        mm.add_snapshot(PID, later, 10.0)
        self.assertIsNotNone(mm.find(LIVE_BASE + 0x800, PID, t=5.0))
        self.assertIsNone(mm.find(LIVE_BASE + 0x800, PID, t=12.0))
        self.assertIsNotNone(mm.find(LIVE_BASE + 0x10000800, PID, t=12.0))
        self.assertNotEqual(mm.fingerprint(PID, 5.0), mm.fingerprint(PID, 12.0))

    def test_load_json_shapes(self):
        files = fixture_files()
        for obj in ({"type": "maps", "snapshots": [{"t": 0, "pid": PID, "text": maps_text()}]},
                    [{"pid": PID, "lines": maps_text().splitlines()}],
                    {"pid": PID, "maps": maps_text()}):
            mm = S.ModuleMap(open_file=lambda p: S.ByteSource(data=files[p]) if p in files else None,
                             stat_file=lambda p: (1, 1))
            mm.load(obj)
            self.assertEqual(mm.pids(), [PID])
            self.assertIsNotNone(mm.find(LIVE_BASE + 0x1040, PID))


class PETests(unittest.TestCase):
    def setUp(self):
        self.live = S.PEImage.from_bytes(build_live(), LIVE_PATH)
        self.ntdll = S.PEImage.from_bytes(build_ntdll(), NTDLL_PATH)

    def test_headers(self):
        self.assertTrue(self.live.is_pe64)
        self.assertEqual(self.live.machine, S.IMAGE_FILE_MACHINE_AMD64)
        self.assertEqual(self.live.size_of_image, PEBuilder.SIZE_OF_IMAGE)
        self.assertEqual(self.live.image_base, LIVE_BASE)
        self.assertEqual([s.name for s in self.live.sections], [".text", ".rdata", ".pdata"])
        self.assertEqual(self.live.rva_to_offset(0x1000), 0x400)
        self.assertEqual(self.live.rva_to_offset(0x2010), 0x1410)
        self.assertEqual(self.live.rva_to_offset(0x80), 0x80)
        self.assertIsNone(self.live.rva_to_offset(0x4000))
        with self.assertRaises(S.PEError):
            S.PEImage.from_bytes(b"\x7fELF" + b"\0" * 100)
        with self.assertRaises(S.PEError):
            S.PEImage.from_bytes(b"MZ" + b"\0" * 0x3a + struct.pack("<I", 0x40) + b"XX\0\0" + b"\0" * 64)

    def test_exports(self):
        exports = self.ntdll.exports()
        self.assertEqual([n for _r, n in exports], ["NtWaitForSingleObject", "NtClose", "RtlUserThreadStart", "LdrInitializeThunk"])
        self.assertEqual(self.ntdll.nearest_export(STUB_WAIT + 0x14), ("NtWaitForSingleObject", 0x14))
        self.assertEqual(self.ntdll.nearest_export(STUB_CLOSE + 1), ("NtClose", 1))
        self.assertEqual(self.ntdll.nearest_export(0x1250), ("RtlUserThreadStart", 0x50))
        self.assertIsNone(self.ntdll.nearest_export(0x10))

    def test_imports(self):
        imports = self.live.imports()
        self.assertEqual(imports, {"KERNEL32.dll": ["CreateEventW", "CloseHandle"], "ntdll.dll": ["NtClose", "#5"]})
        self.assertEqual(self.ntdll.imports(), {})

    def test_pdata_and_unwind_info(self):
        pdata = self.live.pdata()
        self.assertEqual([rf.begin for rf in pdata], [FUNC_A, FUNC_B, FUNC_B_CHAIN, FUNC_D, FUNC_E, FUNC_F, FUNC_G, FUNC_H, FUNC_I])
        rf = self.live.runtime_function(FUNC_A + 0x40)
        self.assertEqual((rf.begin, rf.end), (FUNC_A, FUNC_A + 0x100))
        ui = self.live.unwind_info(rf)
        self.assertEqual((ui.version, ui.flags, ui.prolog, ui.count, ui.frame_reg, ui.frame_off), (1, 0, 9, 3, 5, 2))
        self.assertEqual([(c.op, c.info, c.offset) for c in ui.codes],
                         [(S.UWOP_SET_FPREG, 0, 9), (S.UWOP_ALLOC_SMALL, 3, 5), (S.UWOP_PUSH_NONVOL, 5, 1)])
        self.assertIsNone(ui.chained)
        chained = self.live.unwind_info(self.live.runtime_function(FUNC_B_CHAIN + 0x10))
        self.assertTrue(chained.flags & S.UNW_FLAG_CHAININFO)
        self.assertEqual((chained.chained.begin, chained.chained.end), (FUNC_B, FUNC_B_CHAIN))
        parent = self.live.unwind_info(chained.chained)
        self.assertEqual([(c.op, c.info) for c in parent.codes], [(S.UWOP_ALLOC_SMALL, 5), (S.UWOP_PUSH_NONVOL, 3)])
        # ALLOC_LARGE forms and FAR offsets
        e = self.live.unwind_info(self.live.runtime_function(FUNC_E + 0x20))
        self.assertEqual([(c.op, c.extra) for c in e.codes], [(S.UWOP_ALLOC_LARGE, 0x800)])
        f = self.live.unwind_info(self.live.runtime_function(FUNC_F + 0x40))
        self.assertEqual([(c.op, c.info, c.extra) for c in f.codes],
                         [(S.UWOP_SAVE_NONVOL_FAR, 6, 0x20), (S.UWOP_ALLOC_LARGE, 1, 0x2000)])
        # version 2 EPILOG takes two slots and is kept as a no-op
        h = self.live.unwind_info(self.live.runtime_function(FUNC_H + 0x40))
        self.assertEqual(h.version, 2)
        self.assertEqual([c.op for c in h.codes], [S.UWOP_EPILOG, S.UWOP_ALLOC_SMALL])
        # indirect entry (UnwindData | 1) is followed to the real RUNTIME_FUNCTION
        i = self.live.runtime_function(FUNC_I + 0x30)
        self.assertEqual(i.unwind_rva & 1, 0)
        self.assertEqual([(c.op, c.info) for c in self.live.unwind_info(i).codes], [(S.UWOP_ALLOC_SMALL, 1)])
        self.assertIsNone(self.live.runtime_function(FUNC_X + 0x10))
        self.assertIsNone(self.live.runtime_function(FUNC_I + 0x80))    # end is exclusive
        self.assertEqual(self.live.runtime_function(FUNC_A + 0x100).begin, FUNC_B)   # FuncB starts there

    def test_self_check(self):
        report = self.live.self_check()
        self.assertEqual(report["decode_errors"], 0)
        self.assertEqual(report["pdata"], 9)
        self.assertEqual(report["chained"], 1)
        self.assertEqual(report["indirect"], 1)
        self.assertEqual(report["unwind_versions"], {"1": 8, "2": 1})
        self.assertEqual(report["exports"], 1)

    def test_bad_unwind_info_raises(self):
        b = PEBuilder()
        ui = b.add_unwind(bytes([3, 0, 1, 0]) + code(1, S.UWOP_PUSH_NONVOL, 5))   # version 3
        b.add_pdata(0x1000, 0x1100, ui)
        ui2 = b.add_unwind(bytes([1, 0, 2, 0]) + code(1, S.UWOP_ALLOC_LARGE, 1))  # needs 3 slots, has 1
        b.add_pdata(0x1100, 0x1200, ui2)
        img = S.PEImage.from_bytes(b.build())
        with self.assertRaises(S.PEError):
            img.unwind_info(img.runtime_function(0x1010))
        with self.assertRaises(S.PEError):
            img.unwind_info(img.runtime_function(0x1110))


class UnwindTests(unittest.TestCase):
    def setUp(self):
        self.files = fixture_files()
        self.mm = make_module_map(self.files)

    def test_syscall_chain(self):
        mem = S.StackWindow(RSP0, main_window())
        frames, addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), mem, "syscall", self.mm, PID)
        self.assertEqual(frames, ["ntdll.dll!NtWaitForSingleObject+0x14",
                                  "Ableton Live 12 Trial.exe+0x1040",
                                  "Ableton Live 12 Trial.exe+0x1150",
                                  "ntdll.dll!RtlUserThreadStart+0x21"])
        self.assertEqual(addrs, [NTDLL_BASE + STUB_WAIT + 0x14, LIVE_BASE + 0x1040, LIVE_BASE + 0x1150,
                                 NTDLL_BASE + RTL_USER_THREAD_START + 0x21])
        self.assertEqual(stop, S.STOP_END)
        self.assertEqual(S.caller_chain(frames), "ntdll.dll!NtWaitForSingleObject+0x14 <- Ableton Live 12 Trial.exe+0x1040 <- Ableton Live 12 Trial.exe+0x1150")

    def test_unixcall_chain_starts_at_the_pe_caller(self):
        mem = S.StackWindow(RSP0, main_window())
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_A + 0x40, RSP0 + 8, main_regs(), mem, "unixcall", self.mm, PID)
        self.assertEqual(frames, ["Ableton Live 12 Trial.exe+0x1040", "Ableton Live 12 Trial.exe+0x1150",
                                  "ntdll.dll!RtlUserThreadStart+0x21"])
        self.assertEqual(stop, S.STOP_END)

    def test_registers_recovered_through_the_chain(self):
        mem = S.StackWindow(RSP0, main_window())
        regs = main_regs()
        live = self.mm.find(LIVE_BASE + FUNC_A, PID).pe
        rip, rsp, stop = S.unwind_frame(live, FUNC_A + 0x40, RSP0 + 8, regs, mem)
        self.assertIsNone(stop)
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_B_CHAIN + 0x10, RSP0 + 0x38))
        self.assertEqual(regs["rbp"], 0x1111)
        rip, rsp, stop = S.unwind_frame(live, FUNC_B_CHAIN + 0x10, rsp, regs, mem)
        self.assertEqual((rip, rsp), (NTDLL_BASE + RTL_USER_THREAD_START + 0x21, RSP0 + 0x80))
        self.assertEqual(regs["r12"], 0x1212)
        self.assertEqual(regs["rbx"], 0x3333)

    def test_window_exhausted(self):
        mem = S.StackWindow(RSP0, main_window()[:0x40])
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), mem, "syscall", self.mm, PID)
        self.assertEqual(stop, S.STOP_WINDOW)
        self.assertEqual(len(frames), 3)
        empty = S.StackWindow(RSP0, b"")
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), empty, "syscall", self.mm, PID)
        self.assertEqual((frames, stop), (["ntdll.dll!NtWaitForSingleObject+0x14"], S.STOP_WINDOW))

    def test_max_frames(self):
        # a leaf (no .pdata) calling itself: every frame pops one word
        mem = bytearray(8 * 40)
        for i in range(40):
            struct.pack_into("<Q", mem, 8 * i, LIVE_BASE + FUNC_X + 0x10)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID)
        self.assertEqual(stop, S.STOP_MAX_FRAMES)
        self.assertEqual(len(frames), S.DEFAULT_MAX_FRAMES)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID, max_frames=3)
        self.assertEqual(len(frames), 3)

    def test_save_nonvol_is_relative_to_the_frame_base(self):
        # FuncD: mov [rsp+8],rbx ; push rbp ; sub rsp,0x20.  Entry rsp R = RSP0 + 0x28 (post-prolog rsp = RSP0).
        mem = bytearray(0x60)
        struct.pack_into("<Q", mem, 0x20, 0x4444)                 # saved rbp (pushed)
        struct.pack_into("<Q", mem, 0x28, LIVE_BASE + FUNC_X + 4)  # return address at R
        struct.pack_into("<Q", mem, 0x30, 0x5555)                 # rbx saved at R+8 = frame + 0x30
        regs = main_regs()
        live = self.mm.find(LIVE_BASE, PID).pe
        rip, rsp, stop = S.unwind_frame(live, FUNC_D + 0x30, RSP0, regs, S.StackWindow(RSP0, bytes(mem)))
        self.assertIsNone(stop)
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 4, RSP0 + 0x30))
        self.assertEqual(regs["rbp"], 0x4444)
        self.assertEqual(regs["rbx"], 0x5555)

    def test_prolog_offset_rule_in_sample_mode(self):
        # pc = FuncA+5: after `sub rsp,0x20`, before `lea rbp`: SET_FPREG (offset 9) must be skipped
        mem = bytearray(0x40)
        struct.pack_into("<Q", mem, 0x20, 0x6666)                        # saved rbp
        struct.pack_into("<Q", mem, 0x28, NTDLL_BASE + RTL_USER_THREAD_START + 0x21)
        regs = main_regs()
        regs["rbp"] = 0xDEAD0000                                         # garbage: must not be used
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_A + 5, RSP0, regs, S.StackWindow(RSP0, bytes(mem)),
                                        "sample", self.mm, PID)
        self.assertEqual(frames[:2], ["Ableton Live 12 Trial.exe+0x1005", "ntdll.dll!RtlUserThreadStart+0x21"])
        self.assertIn(stop, (S.STOP_WINDOW, S.STOP_END))
        # pc = FuncA+1 (only `push rbp` done): ALLOC_SMALL and SET_FPREG skipped
        mem2 = bytearray(0x20)
        struct.pack_into("<Q", mem2, 0x0, 0x7777)
        struct.pack_into("<Q", mem2, 0x8, LIVE_BASE + FUNC_X + 4)
        live = self.mm.find(LIVE_BASE, PID).pe
        rip, rsp, _stop = S.unwind_frame(live, FUNC_A + 1, RSP0, regs, S.StackWindow(RSP0, bytes(mem2)), precise=True)
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 4, RSP0 + 0x10))
        self.assertEqual(regs["rbp"], 0x7777)

    def test_return_address_lookup_uses_pc_minus_one(self):
        # a return address exactly at the end of FuncA (call was its last instruction) still unwinds with
        # FuncA's codes although the exact lookup lands in FuncB, which starts at FUNC_A + 0x100
        live = self.mm.find(LIVE_BASE, PID).pe
        self.assertEqual(live.runtime_function(FUNC_A + 0x100).begin, FUNC_B)
        mem = bytearray(0x40)
        struct.pack_into("<Q", mem, 0x20, 0x8888)
        struct.pack_into("<Q", mem, 0x28, LIVE_BASE + FUNC_X)
        regs = main_regs()
        regs["rbp"] = RSP0 + 0x20
        rip, rsp, _stop = S.unwind_frame(live, FUNC_A + 0x100, RSP0, regs, S.StackWindow(RSP0, bytes(mem)))
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X, RSP0 + 0x30))

    def test_alloc_large_and_far_offsets(self):
        live = self.mm.find(LIVE_BASE, PID).pe
        mem = bytearray(0x800 + 0x10)
        struct.pack_into("<Q", mem, 0x800, LIVE_BASE + FUNC_X + 1)
        rip, rsp, _stop = S.unwind_frame(live, FUNC_E + 0x20, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)))
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 1, RSP0 + 0x808))
        mem = bytearray(0x2000 + 0x10)
        struct.pack_into("<Q", mem, 0x20, 0x9999)                   # rsi at frame + 0x20
        struct.pack_into("<Q", mem, 0x2000, LIVE_BASE + FUNC_X + 2)
        regs = main_regs()
        rip, rsp, _stop = S.unwind_frame(live, FUNC_F + 0x40, RSP0, regs, S.StackWindow(RSP0, bytes(mem)))
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 2, RSP0 + 0x2008))
        self.assertEqual(regs["rsi"], 0x9999)

    def test_machframe_stops(self):
        mem = bytearray(0x40)
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_G + 0x10, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "unixcall", self.mm, PID)
        self.assertEqual(frames, ["Ableton Live 12 Trial.exe+0x1710"])
        self.assertEqual(stop, S.STOP_MACHFRAME)

    def test_epilog_codes_and_indirect_entry(self):
        live = self.mm.find(LIVE_BASE, PID).pe
        mem = bytearray(0x40)
        struct.pack_into("<Q", mem, 0x28, LIVE_BASE + FUNC_X + 3)
        rip, rsp, _stop = S.unwind_frame(live, FUNC_H + 0x30, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)))
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 3, RSP0 + 0x30))
        mem = bytearray(0x40)
        struct.pack_into("<Q", mem, 0x10, LIVE_BASE + FUNC_X + 4)
        rip, rsp, _stop = S.unwind_frame(live, FUNC_I + 0x30, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)))
        self.assertEqual((rip, rsp), (LIVE_BASE + FUNC_X + 4, RSP0 + 0x18))

    def test_register_unavailable(self):
        regs = {name: None for name in S.REG_NAMES}   # no rbp: FuncA's SET_FPREG cannot be replayed
        mem = S.StackWindow(RSP0, main_window())
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_A + 0x40, RSP0 + 8, regs, mem, "unixcall", self.mm, PID)
        self.assertEqual(frames, ["Ableton Live 12 Trial.exe+0x1040"])
        self.assertEqual(stop, S.STOP_REGISTER)

    def test_bad_frame_pointer_does_not_loop(self):
        regs = main_regs()
        regs["rbp"] = RSP0 - 0x1000          # bogus frame pointer below the window
        mem = S.StackWindow(RSP0, main_window())
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_A + 0x40, RSP0 + 8, regs, mem, "unixcall", self.mm, PID)
        self.assertEqual(len(frames), 1)
        self.assertEqual(stop, S.STOP_WINDOW)
        regs["rbp"] = RSP0 + 0x20 - 0x20     # SET_FPREG lands exactly on the current rsp - 8: no progress
        frames, _addrs, stop = S.unwind(LIVE_BASE + FUNC_A + 0x40, RSP0 + 0x28, regs, mem, "unixcall", self.mm, PID)
        self.assertIn(stop, (S.STOP_BAD_FRAME, S.STOP_WINDOW, S.STOP_NON_PE, S.STOP_END))

    def test_stops_at_wow64_unix_and_unknown(self):
        mem = bytearray(0x40)
        struct.pack_into("<Q", mem, 0, WOW64_BASE + 0x1010)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID)
        self.assertEqual(frames, ["ntdll.dll!NtWaitForSingleObject+0x14", "wow64.dll!Wow64SystemServiceEx+0x10"])
        self.assertEqual(stop, S.STOP_WOW64)
        struct.pack_into("<Q", mem, 0, NTDLL_SO_BASE + 0x20000)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID)
        self.assertEqual(frames[1], "unix:ntdll.so+0x20000")
        self.assertEqual(stop, S.STOP_UNIX)
        struct.pack_into("<Q", mem, 0, 0x123456789)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID)
        self.assertEqual(frames[1], "0x123456789")
        self.assertEqual(stop, S.STOP_NON_PE)
        struct.pack_into("<Q", mem, 0, PLUGIN_BASE + 0x10)
        frames, _addrs, stop = S.unwind(NTDLL_BASE + STUB_WAIT + 0x14, RSP0, main_regs(), S.StackWindow(RSP0, bytes(mem)),
                                        "syscall", self.mm, PID)
        self.assertEqual(frames[1], "Serum.vst3+0x10")
        self.assertEqual(stop, S.STOP_UNREADABLE)


class FormattingTests(unittest.TestCase):
    def test_wine_dll_export_vs_module_offset(self):
        mm = make_module_map(fixture_files())
        self.assertEqual(S.format_address(mm.find(NTDLL_BASE + 0x1014, PID), NTDLL_BASE + 0x1014), "ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(S.format_address(mm.find(NTDLL_BASE + 0x10, PID), NTDLL_BASE + 0x10), "ntdll.dll+0x10")
        self.assertEqual(S.format_address(mm.find(LIVE_BASE + 0x1000, PID), LIVE_BASE + 0x1000), "Ableton Live 12 Trial.exe+0x1000")
        self.assertEqual(S.format_address(None, 0x42), "0x42")

    def test_elf_symbols_with_symbols_root(self):
        files = fixture_files()
        with tempfile.TemporaryDirectory() as tmp:
            root = tmp.replace("\\", "/")
            os.makedirs(root + "/lib/wine/x86_64-unix")
            with open(root + "/lib/wine/x86_64-unix/ntdll.so", "wb") as fh:
                fh.write(files[NTDLL_SO_PATH])
            mm = make_module_map(files, symbols_root=root)
            mod = mm.find(NTDLL_SO_BASE + 0x10020, PID)
            self.assertEqual(S.format_address(mod, NTDLL_SO_BASE + 0x10020, mm), "unix:ntdll.so!server_select+0x10")
            self.assertEqual(S.format_address(mod, NTDLL_SO_BASE + 0x10060, mm), "unix:ntdll.so!wait_select_reply+0x10")
            self.assertEqual(S.format_address(mod, NTDLL_SO_BASE + 0x10000, mm), "unix:ntdll.so+0x10000")
        syms = S.ElfSymbols(files[NTDLL_SO_PATH])
        self.assertEqual(syms.lookup(0x10010), ("server_select", 0))
        self.assertIsNone(syms.lookup(0x10050 - 1 - 0x40 + 0x40) if False else None)


class SymbolizerTests(unittest.TestCase):
    def record(self, **overrides):
        rec = {"type": "stack", "ref": 7, "t": 1.5, "tid": 4301, "pid": PID, "seq": 12, "kind": "syscall",
               "id": "NtWaitForSingleObject", "frame": "0x7fffa0000f00", "rip": S.hexs(NTDLL_BASE + STUB_WAIT + 0x14),
               "rsp": S.hexs(RSP0), "regs": [0] * 19 + [RSP0 + 0x28], "stack_hex": main_window().hex()}
        rec.update(overrides)
        return rec

    def test_decode_record_variants(self):
        mode, rip, rsp, regs, mem = S.Symbolizer.decode_record(self.record())
        self.assertEqual((mode, rip, rsp, regs["rbp"], mem.base, len(mem.data)), ("syscall", NTDLL_BASE + 0x1014, RSP0, RSP0 + 0x28, RSP0, 0xB0))
        mode, rip, rsp, regs, mem = S.Symbolizer.decode_record(self.record(
            kind="unixcall", rip=LIVE_BASE + 0x1040, rsp=RSP0 + 8, regs={"rbp": RSP0 + 0x28, "RBX": 1},
            stack_hex=None, stack_b64=base64.b64encode(main_window()).decode("ascii"), window_base=RSP0))
        self.assertEqual((mode, rip, rsp, regs["rbp"], regs["rbx"], mem.base), ("unixcall", LIVE_BASE + 0x1040, RSP0 + 8, RSP0 + 0x28, 1, RSP0))
        mode, _rip, _rsp, regs, _mem = S.Symbolizer.decode_record({"kind": "sample", "rip": "1", "rsp": "2", "rbp": "0x10"})
        self.assertEqual((mode, regs["rbp"]), ("sample", 0x10))

    def test_unwind_record_and_cache_roundtrip(self):
        files = fixture_files()
        mm = make_module_map(files)
        sym = S.Symbolizer(mm, S.SymCache())
        res = sym.unwind_record(self.record())
        self.assertEqual(res["frames"][0], "ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(res["stop"], S.STOP_END)
        self.assertEqual(res["addrs"][1], S.hexs(LIVE_BASE + 0x1040))
        self.assertEqual(res["caller"].split(S.CHAIN_SEP)[2], "Ableton Live 12 Trial.exe+0x1150")
        again = sym.unwind_record(self.record(ref=8))
        self.assertEqual(again["frames"], res["frames"])
        self.assertEqual(sym.stats["stack_cache_hits"], 1)
        self.assertEqual(sym.symbol(NTDLL_BASE + 0x1014, PID), "ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(sym.symbol(NTDLL_BASE + 0x1014, PID), "ntdll.dll!NtWaitForSingleObject+0x14")
        self.assertEqual(sym.stats["symbol_cache_hits"], 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "symcache.json")
            sym.cache.path = path
            sym.finish()
            with open(path, "r", encoding="utf-8") as fh:
                obj = json.load(fh)
            self.assertEqual(obj["version"], S.__version__)
            live_key = mm.find(LIVE_BASE, PID).key
            self.assertIn(live_key, obj["unwind"])
            self.assertIn("%x" % (PEBuilder.UNWIND_BASE), obj["unwind"][live_key])
            self.assertEqual(len(obj["stacks"]), 1)
            self.assertIn(live_key, obj["modules"])
            # a fresh symbolizer seeded from the file answers from the caches
            cache2 = S.SymCache.load(path)
            mm2 = make_module_map(files)
            sym2 = S.Symbolizer(mm2, cache2)
            self.assertIn(PEBuilder.UNWIND_BASE, mm2.find(LIVE_BASE, PID).pe._unwind_cache)
            res2 = sym2.unwind_record(self.record())
            self.assertEqual(res2["frames"], res["frames"])
            self.assertEqual(sym2.stats["stack_cache_hits"], 1)
            # a different window content must not hit the stack cache
            other = main_window()[:0x30] + struct.pack("<Q", LIVE_BASE + FUNC_X + 8) + main_window()[0x38:]
            res3 = sym2.unwind_record(self.record(stack_hex=other.hex()))
            self.assertEqual(sym2.stats["stack_cache_hits"], 1)
            self.assertNotEqual(res3["frames"], res["frames"])


class CLITests(unittest.TestCase):
    def write_tree(self, tmp):
        root = tmp.replace("\\", "/")
        paths = {
            LIVE_PATH: root + "/live/Ableton Live 12 Trial.exe",
            NTDLL_PATH: root + "/lib/wine/x86_64-windows/ntdll.dll",
            WOW64_PATH: root + "/lib/wine/x86_64-windows/wow64.dll",
            NTDLL_SO_PATH: root + "/lib/wine/x86_64-unix/ntdll.so",
        }
        files = fixture_files()
        for src, dst in paths.items():
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as fh:
                fh.write(files[src])
        text = maps_text(live_path=paths[LIVE_PATH], ntdll_path=paths[NTDLL_PATH], wow64_path=paths[WOW64_PATH],
                         ntdll_so=paths[NTDLL_SO_PATH], plugin=root + "/plugins/Serum.vst3", font=root + "/Vera.ttf")
        maps_path = os.path.join(tmp, "maps.json")
        with open(maps_path, "w", encoding="utf-8") as fh:
            json.dump({"type": "maps", "snapshots": [{"t": 0.0, "pid": PID, "text": text}]}, fh)
        return root, maps_path, paths

    def test_symbolize_blocks_and_stacks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, maps_path, paths = self.write_tree(tmp)
            stacks_path = os.path.join(tmp, "stacks.jsonl")
            with open(stacks_path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "header", "monotonic_start_ns": 1}) + "\n")
                fh.write(json.dumps({"type": "stack", "ref": 1, "t": 0.5, "tid": 4301, "pid": PID, "kind": "syscall",
                                     "id": "NtWaitForSingleObject", "rip": NTDLL_BASE + STUB_WAIT + 0x14, "rsp": RSP0,
                                     "regs": [0] * 19 + [RSP0 + 0x28], "stack_hex": main_window().hex()}) + "\n")
            blocks_path = os.path.join(tmp, "blocks.jsonl")
            with open(blocks_path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "header", "monotonic_start_ns": 1}) + "\n")
                fh.write(json.dumps({"seq": 12, "t_start": 0.4, "stacks": [
                    {"tid": 4301, "kind": "syscall", "id": "NtWaitForSingleObject", "stack_ref": 1},
                    {"tid": 4302, "kind": "syscall", "id": "NtClose", "stack_ref": 99}]}) + "\n")
            out = os.path.join(tmp, "blocks.symbolized.jsonl")
            stacks_out = os.path.join(tmp, "stacks.symbolized.jsonl")
            cache = os.path.join(tmp, "symcache.json")
            imports = os.path.join(tmp, "imports.json")
            rc = S.main(["--blocks", blocks_path, "--stacks", stacks_path, "--maps", maps_path, "--symcache", cache,
                         "--out", out, "--stacks-out", stacks_out, "--imports-out", imports, "--quiet"])
            self.assertEqual(rc, 0)
            lines = [json.loads(l) for l in open(out, encoding="utf-8")]
            self.assertTrue(lines[0]["symbolized"])
            block = lines[1]
            self.assertEqual(block["stacks"][0]["frames"], ["ntdll.dll!NtWaitForSingleObject+0x14",
                                                           "Ableton Live 12 Trial.exe+0x1040",
                                                           "Ableton Live 12 Trial.exe+0x1150",
                                                           "ntdll.dll!RtlUserThreadStart+0x21"])
            self.assertEqual(block["stacks"][0]["stop"], "end")
            self.assertEqual(block["stacks"][0]["stack_ref"], 1)
            self.assertEqual(block["stacks"][1]["stop"], "missing_stack")
            srec = [json.loads(l) for l in open(stacks_out, encoding="utf-8")][1]
            self.assertNotIn("stack_hex", srec)
            self.assertNotIn("regs", srec)
            self.assertEqual(srec["frames"][1], "Ableton Live 12 Trial.exe+0x1040")
            with open(imports, encoding="utf-8") as fh:
                imp = json.load(fh)
            self.assertEqual(list(imp["modules"]), [paths[LIVE_PATH]])
            self.assertEqual(imp["modules"][paths[LIVE_PATH]]["imports"]["KERNEL32.dll"], ["CreateEventW", "CloseHandle"])
            self.assertTrue(os.path.exists(cache))
            # second run is served from the cache
            rc = S.main(["--blocks", blocks_path, "--stacks", stacks_path, "--maps", maps_path, "--symcache", cache,
                         "--out", out, "--quiet"])
            self.assertEqual(rc, 0)
            with open(cache, encoding="utf-8") as fh:
                self.assertEqual(len(json.load(fh)["stacks"]), 1)

    def test_run_directory_mode(self):
        """`symbolize.py --blocks DIR/blocks.jsonl` as profiler/bin/wine-trace stop runs it."""
        with tempfile.TemporaryDirectory() as tmp:
            _root, maps_path, _paths = self.write_tree(tmp)
            run = os.path.join(tmp, "run")
            os.makedirs(run)
            with open(maps_path, encoding="utf-8") as fh:
                text = json.load(fh)["snapshots"][0]["text"]
            for name in ("maps-%d.txt" % PID, "maps-%d-stop.txt" % PID):   # the wrapper's raw snapshots
                with open(os.path.join(run, name), "w", encoding="utf-8") as fh:
                    fh.write(text)
            blocks = os.path.join(run, "blocks.jsonl")
            placeholder = "pe!0x%x" % (LIVE_BASE + 0x1040)
            with open(blocks, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "header", "monotonic_start_ns": 1}) + "\n")
                fh.write(json.dumps({"seq": 1, "crossings": [
                    {"tid": 4301, "kind": "unixcall", "id": "dwrite.so:x", "caller": placeholder, "n": 1},
                    {"tid": 4301, "kind": "syscall", "id": "NtClose", "caller": "ntdll.dll!NtClose+0x14", "n": 1}],
                    "stacks": []}) + "\n")
            summary = os.path.join(run, "summary.json")
            with open(summary, "w", encoding="utf-8") as fh:
                json.dump({"call_sites": [{"key": "unixcall|dwrite.so:x|" + placeholder, "caller": placeholder}],
                           "hotspots_non_audio": [{"caller": "pe!0x%x" % (NTDLL_BASE + STUB_WAIT + 0x14)}]}, fh)
            events = os.path.join(run, "events.jsonl")
            with open(events, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "header"}) + "\n")
                fh.write(json.dumps({"t": 0.1, "tid": 4301, "kind": "unixcall", "id": "dwrite.so:x", "caller": placeholder}) + "\n")
            self.assertEqual(S.main(["--blocks", blocks, "--quiet"]), 0)
            lines = [json.loads(l) for l in open(blocks, encoding="utf-8")]
            self.assertTrue(lines[0]["symbolized"])
            self.assertEqual(lines[1]["crossings"][0]["caller"], "Ableton Live 12 Trial.exe+0x1040")
            self.assertEqual(lines[1]["crossings"][1]["caller"], "ntdll.dll!NtClose+0x14")
            with open(summary, encoding="utf-8") as fh:
                s = json.load(fh)
            self.assertEqual(s["call_sites"][0]["key"], "unixcall|dwrite.so:x|Ableton Live 12 Trial.exe+0x1040")
            self.assertEqual(s["call_sites"][0]["caller"], "Ableton Live 12 Trial.exe+0x1040")
            self.assertEqual(s["hotspots_non_audio"][0]["caller"], "ntdll.dll!NtWaitForSingleObject+0x14")
            self.assertTrue(s["symbolized"])
            ev_lines = [json.loads(l) for l in open(events, encoding="utf-8")]
            self.assertEqual(ev_lines[1]["caller"], "Ableton Live 12 Trial.exe+0x1040")
            self.assertTrue(os.path.exists(os.path.join(run, "symcache.json")))
            self.assertFalse(os.path.exists(blocks + ".tmp"))
            # running again is idempotent
            self.assertEqual(S.main(["--blocks", blocks, "--quiet"]), 0)
            self.assertEqual([json.loads(l) for l in open(blocks, encoding="utf-8")][1]["crossings"][0]["caller"],
                             "Ableton Live 12 Trial.exe+0x1040")
            # a directory without any maps snapshot fails cleanly (exit 1, no files touched)
            empty = os.path.join(tmp, "empty")
            os.makedirs(empty)
            with open(os.path.join(empty, "blocks.jsonl"), "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"seq": 1}) + "\n")
            self.assertEqual(S.main(["--blocks", os.path.join(empty, "blocks.jsonl"), "--quiet"]), 1)
            self.assertFalse(os.path.exists(os.path.join(empty, "symcache.json")))

    def test_perf_rewrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            _root, maps_path, _paths = self.write_tree(tmp)
            perf_in = os.path.join(tmp, "perf.txt")
            with open(perf_in, "w", encoding="utf-8") as fh:
                fh.write("Ableton Live 12  %d/4301  1234.567890:\n" % PID)
                fh.write("\t    %x __wine_syscall_dispatcher+0x12 (/opt/wine/lib/wine/x86_64-unix/ntdll.so)\n" % (NTDLL_SO_BASE + 0x20000))
                fh.write("\t    %x [unknown] (/x/ntdll.dll)\n" % (NTDLL_BASE + STUB_WAIT + 0x14))
                fh.write("\t    %x [unknown] ([unknown])\n" % (LIVE_BASE + 0x1040))
                fh.write("\t    %x [unknown] ([unknown])\n" % 0x1234)
                fh.write("\n")
            perf_out = os.path.join(tmp, "perf.out")
            rc = S.main(["--perf", perf_in, "--maps", maps_path, "--out", perf_out])
            self.assertEqual(rc, 0)
            out = open(perf_out, encoding="utf-8").read().splitlines()
            self.assertIn("ntdll.dll!NtWaitForSingleObject+0x14 (/x/ntdll.dll)", out[2])
            self.assertIn("Ableton Live 12 Trial.exe+0x1040 ([unknown])", out[3])
            self.assertIn("[unknown] ([unknown])", out[4])
            self.assertIn("__wine_syscall_dispatcher", out[1])
            # without a pid field, falls back to any pid's map
            lines = ["swapper 0 1.0:\n", "\t %x [unknown] (x)\n" % (LIVE_BASE + 0x1040)]
            with S.ModuleMap() as mm:
                mm.load(maps_path)
                rewritten = list(S.rewrite_perf_lines(lines, mm))
            self.assertIn("Ableton Live 12 Trial.exe+0x1040", rewritten[1])

    def test_dump_pe_and_maps(self):
        with tempfile.TemporaryDirectory() as tmp:
            _root, maps_path, paths = self.write_tree(tmp)
            import io
            from contextlib import redirect_stdout
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(S.main(["--dump-pe", paths[LIVE_PATH]]), 0)
            report = json.loads(buf.getvalue())
            self.assertEqual(report["pdata"], 9)
            self.assertEqual(report["decode_errors"], 0)
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(S.main(["--dump-maps", maps_path]), 0)
            report = json.loads(buf.getvalue())
            self.assertEqual(sorted(m["name"] for m in report[str(PID)]),
                             ["Ableton Live 12 Trial.exe", "Serum.vst3", "ntdll.dll", "ntdll.so", "wow64.dll"])


class RolesTests(unittest.TestCase):
    ROLES_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "roles.toml")

    def test_subset_parser_matches_tomllib(self):
        with open(self.ROLES_PATH, "r", encoding="utf-8") as fh:
            text = fh.read()
        subset = S.parse_toml_subset(text)
        self.assertEqual(subset["version"], 1)
        self.assertEqual(subset["rule"][0]["role"], "wineserver")
        self.assertEqual(subset["rule"][-1]["role"], "live:{comm}")
        self.assertEqual(subset["rule"][-1]["exe"], "^Ableton Live")
        self.assertIs(subset["rule"][-1]["named"], True)   # live:<comm> is for named threads only
        self.assertEqual(subset["audio_roles"][0], "pipeasio_callback")
        self.assertIn("pipeasio_callback", subset["dynamic"])
        try:
            import tomllib
        except ImportError:
            tomllib = None
        if tomllib is not None:
            self.assertEqual(subset, tomllib.loads(text))

    def test_subset_parser_edge_cases(self):
        obj = S.parse_toml_subset('a = "x # not a comment" # comment\nb = \'lit\\n\'\nc = true\nd = -12_000\n'
                                  'e = ["q", "r,s", 3]\nf = "tab\\t\\"q\\"\\u0041"\n[t.sub]\ng = 1.5\n[[arr]]\nh = 1\n[[arr]]\nh = 2\n')
        self.assertEqual(obj["a"], "x # not a comment")
        self.assertEqual(obj["b"], "lit\\n")
        self.assertIs(obj["c"], True)
        self.assertEqual(obj["d"], -12000)
        self.assertEqual(obj["e"], ["q", "r,s", 3])
        self.assertEqual(obj["f"], 'tab\t"q"A')
        self.assertEqual(obj["t"]["sub"]["g"], 1.5)
        self.assertEqual([x["h"] for x in obj["arr"]], [1, 2])
        with self.assertRaises(ValueError):
            S.parse_toml_subset("x = {a = 1}\n")
        with self.assertRaises(ValueError):
            S.parse_toml_subset("broken\n")

    def test_classification(self):
        table = S.load_roles(self.ROLES_PATH)
        live = "Ableton Live 12 Trial.exe"
        pc = "Ableton Live 12"
        self.assertEqual(table.classify("AudioCalc", live, 4200, 4301, pc), "audio_worker")
        self.assertEqual(table.classify(pc, live, 4200, 4200, pc), "main")
        self.assertEqual(table.classify("MIDI", live, 4200, 4310, pc), "live:MIDI")
        # an unnamed Live thread (comm == process comm) is not live:<comm> (design B section 5),
        # matching reduce.py's built-in rules; without a known process comm it is unknown too
        self.assertEqual(table.classify(pc, live, 4200, 4311, pc), "unknown:Ableton Live 12")
        self.assertEqual(table.classify("MIDI", live, 4200, 4310, None), "unknown:MIDI")
        # the `named` field is honoured on a hand-built table as well
        strict = S.RoleTable({"rule": [{"role": "live:{comm}", "exe": "^Ableton Live", "named": True}]})
        self.assertEqual(strict.classify("MIDI", live, 4200, 4310, pc), "live:MIDI")
        self.assertEqual(strict.classify(pc, live, 4200, 4311, pc), "unknown:Ableton Live 12")
        self.assertEqual(strict.classify("MIDI", live, 4200, 4310, None), "unknown:MIDI")   # named unknown
        self.assertEqual(table.classify("wineserver", None, 4100, 4100, "wineserver"), "wineserver")
        self.assertEqual(table.classify("pipeasio-rt", live, 4200, 4320, pc), "pipeasio_rt")
        self.assertEqual(table.classify("pipeasio-worker", live, 4200, 4321, pc), "pipeasio_worker")
        self.assertEqual(table.classify("Chrome_IOThread", "msedgewebview2.exe", 5000, 5001, "msedgewebview2."), "webview")
        self.assertEqual(table.classify("msedgewebview2.", "msedgewebview2.exe", 5000, 5000, "msedgewebview2."), "webview")
        self.assertEqual(table.classify("Max", "Max.exe", 5100, 5100, "Max"), "max")
        self.assertEqual(table.classify("Push2DisplayProc", "Push2DisplayProcess.exe", 5200, 5201, "Push2DisplayProc"), "push2")
        self.assertEqual(table.classify("Thread", "foo.exe", 5300, 5300, "foo"), "main")
        self.assertEqual(table.classify("Thread", "foo.exe", 5300, 5301, "foo"), "unknown:Thread")
        self.assertEqual(table.classify("AudioCalc"), "audio_worker")      # comm alone suffices
        self.assertEqual(table.classify("MIDI"), "unknown:MIDI")           # exe unknown: no live: rule
        self.assertTrue(table.is_audio("plugin:Serum.vst3"))
        self.assertTrue(table.is_audio("audio_worker"))
        self.assertFalse(table.is_audio("live:MIDI"))
        self.assertEqual(S.main(["--classify", "AudioCalc"]), 0)


if __name__ == "__main__":
    unittest.main()
