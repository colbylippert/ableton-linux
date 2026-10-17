#!/usr/bin/env python3
"""Tests of calibrate.py (the uprobe trap calibration): the stdlib ELF reader of the dispatcher
probe sites, the RESULT parser and the summary.  The timed runs themselves need Wine, root and
the laptop (BUILD.md, "Trap calibration")."""

from __future__ import annotations

import importlib.util
import os
import struct
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRACER_DIR = HERE.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TRACER_DIR / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


calibrate = load("wine_trace_calibrate", "calibrate.py")

VADDR = 0x400000
NOP5 = bytes.fromhex("0f1f440000")
NOP10 = bytes.fromhex("662e0f1f840000000000")


def note(provider, name, args, pc):
    desc = struct.pack("<QQQ", pc, 0, 0) + provider.encode() + b"\0" + name.encode() + b"\0" + args.encode() + b"\0"
    body = struct.pack("<III", 8, len(desc), 3) + b"stapsdt\0" + desc
    return body + b"\0" * (-len(body) % 4)


def build_elf(path, sites):
    """A minimal ELF64 shared object: one PT_LOAD mapping the whole file at VADDR, a .text holding
    `sites` ({name: (text offset, bytes)}) and a .note.stapsdt describing them (provider wine)."""
    text = bytearray(b"\xcc" * 0x2000)
    for offset, code in sites.values():
        text[offset:offset + len(code)] = code
    text_off = 0x1000
    notes = b"".join(note("wine", name, "8@%rcx", VADDR + text_off + offset) for name, (offset, _) in sites.items())
    notes += note("other", "syscall_entry", "", VADDR + text_off)          # another provider: ignored
    shstr = b"\0.text\0.note.stapsdt\0.shstrtab\0"
    note_off = text_off + len(text)
    shstr_off = note_off + len(notes)
    sh_off = (shstr_off + len(shstr) + 7) & ~7
    size = sh_off + 4 * 64
    header = bytearray(64)
    header[0:16] = b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9
    struct.pack_into("<HHIQQQIHHHHHH", header, 16, 3, 62, 1, 0, 64, sh_off, 0, 64, 56, 1, 64, 4, 3)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, VADDR, VADDR, size, size, 0x1000)
    sections = [
        struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        struct.pack("<IIQQQQIIQQ", 1, 1, 6, VADDR + text_off, text_off, len(text), 0, 0, 16, 0),
        struct.pack("<IIQQQQIIQQ", 7, 7, 2, 0, note_off, len(notes), 0, 0, 4, 0),
        struct.pack("<IIQQQQIIQQ", 21, 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0),
    ]
    data = bytearray(size)
    data[0:64] = header
    data[64:64 + len(phdr)] = phdr
    data[text_off:text_off + len(text)] = text
    data[note_off:note_off + len(notes)] = notes
    data[shstr_off:shstr_off + len(shstr)] = shstr
    data[sh_off:sh_off + 4 * 64] = b"".join(sections)
    with open(path, "wb") as handle:
        handle.write(bytes(data))


class ProbeSiteTest(unittest.TestCase):
    def test_site_kinds_and_page_crossing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.join(temporary, "ntdll.so")
            build_elf(path, {
                "syscall_entry": (0x100, NOP5),
                "syscall_exit": (0x200, NOP10),
                "unixcall_entry": (0xffc, NOP10),        # VADDR + 0x1000 + 0xffc: crosses into the next page
                "unixcall_exit": (0x300, b"\x90\x90\x90\x90\x90"),
            })
            sites = calibrate.elf_probe_sites(path)
        self.assertEqual(sorted(sites), sorted(calibrate.DISPATCHER_PROBES))
        self.assertEqual(sites["syscall_entry"]["kind"], "nop5")
        self.assertEqual(sites["syscall_entry"]["pc"], VADDR + 0x1100)
        self.assertEqual(sites["syscall_entry"]["offset"], 0x1100)
        self.assertTrue(sites["syscall_entry"]["bytes"].startswith("0f1f440000"))
        self.assertFalse(sites["syscall_entry"]["crosses_page"])
        self.assertEqual(sites["syscall_exit"]["kind"], "nop10")
        self.assertFalse(sites["syscall_exit"]["crosses_page"])
        self.assertEqual(sites["unixcall_entry"]["kind"], "nop10")
        self.assertTrue(sites["unixcall_entry"]["crosses_page"])
        self.assertEqual(sites["unixcall_exit"]["kind"], "other")

    def test_not_an_elf_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.join(temporary, "junk")
            with open(path, "wb") as handle:
                handle.write(b"MZ" + b"\0" * 100)
            with self.assertRaises(calibrate.CalibrationError):
                calibrate.elf_probe_sites(path)


class ResultTest(unittest.TestCase):
    def test_parse_and_summarise(self):
        text = ("info ready winpid=32\n"
                "RESULT r=0 calls=200000 ns_per_call=477.902\n"
                "RESULT r=1 calls=200000 ns_per_call=478.949\n"
                "RESULT r=2 calls=200000 ns_per_call=476.988\n"
                "RESULT r=3 calls=200000\n")
        values = calibrate.parse_results(text)
        self.assertEqual(values, [477.902, 478.949, 476.988])
        summary = calibrate.summarise(values)
        self.assertEqual((summary["median"], summary["min"]), (477.9, 477.0))
        with self.assertRaises(calibrate.CalibrationError):
            calibrate.summarise([])

    def test_env_argv_keeps_the_environment_across_sudo(self):
        argv = calibrate.env_argv({"WINEPREFIX": "/p", "B": "2"})
        self.assertEqual(argv, ["env", "-i", "B=2", "WINEPREFIX=/p"])


def run(cpu, kind, untraced, traced, entry=60.0, exit_=45.0):
    return {"cpu": {"index": cpu, "type": kind, "model": None},
            "untraced": {"median": untraced}, "traced": {"median": traced,
                                                          "bpf_ns_per_run": {"wine_syscall_entry": entry,
                                                                             "wine_syscall_exit": exit_}}}


class CpuTest(unittest.TestCase):
    """The per-CPU calibration: a hybrid CPU's traps cost more on an E-core (laptop, nop5 sites:
    446 ns on CPU 2, 598 ns on CPU 12)."""

    def sysfs(self, temporary, pcores, ecores):
        lists = []
        for kind, text in (("P-core", pcores), ("E-core", ecores)):
            path = os.path.join(temporary, kind)
            if text is not None:
                with open(path, "w", encoding="ascii") as handle:
                    handle.write(text + "\n")
            lists.append((kind, path))
        return tuple(lists)

    def test_parse_cpu_list(self):
        self.assertEqual(calibrate.parse_cpu_list("0-3,8,10-11\n"), [0, 1, 2, 3, 8, 10, 11])
        for bad in ("", "a", "3-1", "1-", "-2", "1,,2"):
            with self.assertRaises(ValueError, msg=bad):
                calibrate.parse_cpu_list(bad)

    def test_default_cpus_hybrid_and_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            lists = self.sysfs(temporary, "0-11", "12-15")
            self.assertEqual(calibrate.default_cpus(lists), [2, 12])
            self.assertEqual(calibrate.cpu_record(12, lists)["type"], "E-core")
            self.assertEqual(calibrate.cpu_record(2, lists)["type"], "P-core")
        with tempfile.TemporaryDirectory() as temporary:
            lists = self.sysfs(temporary, "4-7", "0-3")          # CPU 2 is not a P-core here
            self.assertEqual(calibrate.default_cpus(lists), [4, 0])
        with tempfile.TemporaryDirectory() as temporary:
            lists = self.sysfs(temporary, None, None)            # not hybrid
            self.assertEqual(calibrate.default_cpus(lists, cpu_count=16), [2])
            self.assertEqual(calibrate.default_cpus(lists, cpu_count=2), [0])
            self.assertEqual(calibrate.cpu_record(2, lists)["type"], "unknown")
            self.assertEqual(calibrate.resolve_cpus("auto", lists, cpu_count=8), [2])
            self.assertEqual(calibrate.resolve_cpus("2,12,2", lists), [2, 12])
            with self.assertRaises(ValueError):
                calibrate.resolve_cpus("two", lists)

    def test_per_cpu_figures(self):
        runs = [run(2, "P-core", 477.9, 1487.2, 61.6, 45.1), run(12, "E-core", 1191.8, 2558.7, 102.2, 68.7),
                run(13, "E-core", 1191.8, 2400.1, 102.2, 68.7)]
        by_cpu, by_type, slowest = calibrate.per_cpu_figures(runs)
        self.assertEqual([entry["ns_per_trap"] for entry in by_cpu], [451.3, 598.0, 518.7])
        self.assertEqual(by_type, {"P-core": 451.3, "E-core": 598.0})
        self.assertEqual(slowest, 598.0)
        with self.assertRaises(calibrate.CalibrationError):
            calibrate.per_cpu_figures([run(2, "P-core", 500.0, 600.0)])

    def test_summary_line_without_extra_consumers(self):
        by_cpu, by_type, slowest = calibrate.per_cpu_figures([run(2, "P-core", 477.9, 1487.2, 61.6, 45.1),
                                                              run(12, "E-core", 1191.8, 2558.7, 102.2, 68.7)])
        record = {"by_cpu": by_cpu, "site_kind": "nop5", "ns_per_extra_consumer": None}
        line = calibrate.summary_line(record, "/run/trap-calibration.json")
        self.assertNotIn("None", line)
        self.assertIn("451.3 ns per probe hit outside BPF (nop5 sites, CPU 2 P-core)", line)
        self.assertIn("CPU 12 E-core 598.0 ns", line)
        record["ns_per_extra_consumer"] = 5.6
        self.assertIn("+5.6 ns per further traced process", calibrate.summary_line(record, "x"))


if __name__ == "__main__":
    unittest.main()
