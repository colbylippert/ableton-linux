#!/usr/bin/env python3
"""Static checks of profiler/tracer/wine-trace.bt and of the script generator in
profiler/bin/wine-trace (no bpftrace needed).  They pin the B5 fixes:

* every timestamp is nsecs(monotonic) (plain nsecs is CLOCK_BOOTTIME in bpftrace 0.27);
* the config block keeps printf arguments on the BPF stack (on_stack_limit; the per-CPU scratch
  buffer is shared by preemptible USDT programs and was the std::bad_alloc abort);
* every printf of an event line is counted in @emitted[<ASCII code of its letter>] (format 3: the
  unix-call E line under 101, standing for itself and the uncounted R line) and END clears @pids,
  then prints @emitted after the "end" line (reduce.py derives lost_events from it);
* the multi-thread ntdll USDT programs keep one printf with a record of <= 40 bytes (the frame
  budget measured with bpftool: 40-48 byte frames, below the 64-byte private-stack threshold) and
  the daemon runs with --no-warnings (part of that budget);
* no delete() (0.27 warns "Return value discarded");
* task:task_newtask provides the T lines of new threads and seeds @tids;
* the generator substitutes the placeholders, strips sections and absent probes, seeds @tids from
  tasks-start.txt, lists each probe once in attach.txt and keeps the config block.

Run from the repository root:  python3 -I -m unittest discover -s profiler/tracer/tests -v
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRACER_DIR = HERE.parent
REPO = TRACER_DIR.parent.parent
TEMPLATE = TRACER_DIR / "wine-trace.bt"
WRAPPER = REPO / "profiler" / "bin" / "wine-trace"
LINE_KINDS = "EXRSBCWwKUOTNP"
# @emitted keys that may count a line letter: format 3 counts the unix-call E line under 101 ('e'),
# which also stands for the R line of the second program on the same probe (no count of its own).
COUNT_CODES = {"E": (69, 101)}
UNCOUNTED = {("R", "unixcall_entry")}
# Multi-thread USDT probes whose programs must stay off the per-CPU private stack.
HOT_PROBES = ("syscall_entry", "syscall_exit", "unixcall_entry", "unixcall_exit", "server_req_start",
              "server_req_end", "server_wait_start", "server_wait_end")
RECORD_BUDGET = 40  # bytes incl. the 8-byte printf id; measured: <= 40 keeps the frame at 40-48


def printf_calls(code):
    """[(format, [arg expressions])] of the printf calls in code (args split at top-level commas)."""
    calls = []
    for match in re.finditer(r'printf\("((?:[^"\\]|\\.)*)"', code):
        index = match.end()
        depth = 1
        args = []
        current = ""
        while depth and index < len(code):
            char = code[index]
            index += 1
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
            if char == "," and depth == 1:
                if current.strip():
                    args.append(current.strip())
                current = ""
                continue
            current += char
        if current.strip():
            args.append(current.strip())
        calls.append((match.group(1), args))
    return calls


def arg_width(expr):
    """Byte width bpftrace gives a printf argument of the template (4 or 8)."""
    expr = expr.strip()
    if re.match(r"^\((u?int32)\)", expr) or expr in ("tid", "pid") or expr.startswith("@swf["):
        return 4
    return 8


def record_size(args):
    """printf record: an 8-byte id, then the arguments at their natural alignment, padded to 8."""
    size = 8
    for expr in args:
        width = arg_width(expr)
        size = (size + width - 1) // width * width + width
    return (size + 7) // 8 * 8


def code_lines(text):
    """Template lines with // comments removed (string literals here never contain //)."""
    return [line.split("//", 1)[0] for line in text.split("\n")]


def probe_blocks(text):
    """[(head, body_lines)] of every probe block: a head line up to the next line that is '}'."""
    lines = text.split("\n")
    blocks = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if re.match(r"^(usdt:|fentry:|fexit:|tracepoint:|BEGIN$|END$)", line):
            end = index
            while lines[end] != "}":
                end += 1
            blocks.append((line, lines[index + 1:end]))
            index = end + 1
        else:
            index += 1
    return blocks


def generator_source():
    text = WRAPPER.read_text(encoding="utf-8")
    start = text.index("generate_script()")
    body = text[start:]
    begin = body.index("<<'PY'\n") + len("<<'PY'\n")
    return body[begin:body.index("\nPY\n", begin)]


class TemplateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = TEMPLATE.read_text(encoding="utf-8")
        cls.code = "\n".join(code_lines(cls.text))

    def test_every_timestamp_is_monotonic(self):
        bare = [line for line in code_lines(self.text) if re.search(r"\bnsecs\b(?!\(monotonic\))", line)]
        self.assertEqual(bare, [], "plain nsecs is CLOCK_BOOTTIME in bpftrace 0.27")
        self.assertIn("nsecs(monotonic)", self.code)

    def test_header_announces_format_3_and_clock(self):
        self.assertRegex(self.code, r'printf\("hdr mono_start_ns=%llu format=3 clock=monotonic\\n", nsecs\(monotonic\)\)')

    def test_hot_usdt_programs_fit_the_stack_budget(self):
        seen = set()
        for head, body in probe_blocks(self.text):
            match = re.match(r"^usdt:@NTDLL@:wine:(\w+)$", head)
            if not match or match.group(1) not in HOT_PROBES:
                continue
            seen.add(match.group(1))
            calls = printf_calls("\n".join(code_lines("\n".join(body))))
            self.assertLessEqual(len(calls), 1, "%s: one printf per USDT program" % head)
            for fmt, args in calls:
                self.assertEqual(fmt.count("%"), len(args), "%s: %r" % (head, fmt))
                self.assertLessEqual(record_size(args), RECORD_BUDGET,
                                     "%s: printf record %d bytes > %d (frame >= 64 -> per-CPU private stack)"
                                     % (head, record_size(args), RECORD_BUDGET))
        self.assertEqual(seen, set(HOT_PROBES))

    def test_record_size_model(self):
        # X syscall: id, ts, tid+st, fr = 32 (measured frame 48); the B4/B5 layout tid, fr, st = 40
        self.assertEqual(record_size(["nsecs(monotonic)", "tid", "(uint32)arg0", "arg1"]), 32)
        self.assertEqual(record_size(["nsecs(monotonic)", "tid", "arg1", "(uint32)arg0"]), 40)
        self.assertEqual(record_size(["nsecs(monotonic)", "tid", "arg0", "(uint32)arg1", "@seq"]), 48)

    def test_new_threads_come_from_task_newtask(self):
        blocks = {head: "\n".join(code_lines("\n".join(body))) for head, body in probe_blocks(self.text)}
        body = blocks.get("tracepoint:task:task_newtask")
        self.assertIsNotNone(body, "task:task_newtask block missing")
        self.assertIn("@tids[(uint32)args.pid] = 1;", body)
        self.assertRegex(body, r'printf\("T %llu %d %d comm=%s\\n"')
        for head, code in blocks.items():
            if head.startswith("usdt:"):
                self.assertNotIn('printf("T ', code, "%s: T lines come from tasks-*.txt and task_newtask" % head)

    def test_end_clears_the_pid_filter_before_reading_counters(self):
        end = [body for head, body in probe_blocks(self.text) if head == "END"][0]
        code = "\n".join(code_lines("\n".join(end)))
        self.assertLess(code.index("clear(@pids);"), code.index("print(@emitted)"))

    def test_daemon_runs_without_warnings(self):
        wrapper = WRAPPER.read_text(encoding="utf-8")
        self.assertRegex(wrapper, r'daemonise "\$out/wine-trace.pid" "\$out/events.txt" "\$out/bpftrace.stderr" '
                                  r'bpftrace -q -B full --no-warnings "\$out/wine-trace.bt"')

    def test_config_keeps_printf_args_on_the_stack(self):
        match = re.search(r"^config = \{(.*?)^\}", self.code, re.S | re.M)
        self.assertIsNotNone(match, "config block missing")
        settings = dict(re.findall(r"(\w+)\s*=\s*(\w+)\s*;", match.group(1)))
        self.assertGreaterEqual(int(settings["on_stack_limit"]), 128)
        self.assertEqual(settings.get("print_maps_on_exit"), "false")
        self.assertLess(self.code.index("config = {"), self.code.index("BEGIN"))

    def test_every_event_printf_is_counted(self):
        for head, body in probe_blocks(self.text):
            if head in ("BEGIN", "END"):
                continue
            code = code_lines("\n".join(body))
            for number, line in enumerate(code):
                match = re.search(r'printf\("([A-Za-z]) ', line)
                if not match:
                    continue
                letter = match.group(1)
                self.assertIn(letter, LINE_KINDS, "%s: unknown line kind %r" % (head, letter))
                probe = head.rsplit(":", 1)[-1]
                previous = "\n".join(code[max(0, number - 2):number])
                if (letter, probe) in UNCOUNTED:
                    self.assertNotIn("@emitted[", previous)
                    siblings = ["\n".join(other) for other_head, other in probe_blocks(self.text) if other_head == head]
                    self.assertTrue(any("@emitted[101] = count();" in other for other in siblings),
                                    "%s: the uncounted R line needs the E program counting under 101" % head)
                    continue
                codes = COUNT_CODES.get(letter, (ord(letter),))
                self.assertTrue(any("@emitted[%d] = count();" % code in previous for code in codes),
                                "%s: printf %r is not counted in @emitted" % (head, letter))

    def test_begin_pushes_hdr_through_the_stdout_buffer(self):
        begin = [body for head, body in probe_blocks(self.text) if head == "BEGIN"][0]
        code = "\n".join(code_lines("\n".join(begin)))
        pads = re.findall(r'printf\("(#[^"]*)\\n"\);', code)
        self.assertGreaterEqual(sum(len(pad) + 1 for pad in pads), 16 * 1000,
                                "BEGIN must print >= 16 KB of '#' lines after hdr (-B full buffering)")
        self.assertLess(code.index("hdr mono_start_ns"), code.index('printf("#'))

    def test_end_prints_emitted_after_end_line(self):
        end = [body for head, body in probe_blocks(self.text) if head == "END"]
        self.assertEqual(len(end), 1)
        body = "\n".join(end[0])
        self.assertIn('printf("end mono_end_ns=%llu\\n", nsecs(monotonic));', body)
        self.assertGreater(body.index("print(@emitted)"), body.index("end mono_end_ns"))

    def test_no_delete_and_no_c_struct_definitions(self):
        self.assertNotIn("delete(", self.code)
        self.assertIsNone(re.search(r"^struct \w+ \{", self.code, re.M),
                          "C definitions make bpftrace run clang over vmlinux.h; use the module BTF type")

    def test_reducer_knows_every_line_kind(self):
        sys.path.insert(0, str(TRACER_DIR))
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("wine_trace_reduce_bt", TRACER_DIR / "reduce.py")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        finally:
            sys.path.pop(0)
        letters = set(re.findall(r'printf\("([A-Za-z]) ', self.code))
        self.assertTrue(letters <= set(module.EVENT_KINDS), letters - set(module.EVENT_KINDS))


class GeneratorTest(unittest.TestCase):
    def generate(self, strip, available, pid_filter="@pids[pid]", tasks=None):
        with tempfile.TemporaryDirectory() as tmp:
            probes = os.path.join(tmp, "probes.txt")
            with open(probes, "w", encoding="utf-8") as handle:
                handle.write("\n".join(available) + "\n")
            script = os.path.join(tmp, "gen.py")
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(generator_source())
            dest = os.path.join(tmp, "wine-trace.bt")
            attach = os.path.join(tmp, "attach.txt")
            argv = [sys.executable, "-I", script, str(TEMPLATE), dest, "/opt/w/ntdll.so", "/opt/w/pipeasio64.dll.so",
                    pid_filter, "4200,4100", strip, probes, attach]
            if tasks is not None:
                tasks_path = os.path.join(tmp, "tasks-start.txt")
                with open(tasks_path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(tasks)
                argv.append(tasks_path)
            subprocess.run(argv, check=True)
            with open(dest, encoding="utf-8") as handle:
                text = handle.read()
            with open(attach, encoding="utf-8") as handle:
                attached = [line.strip() for line in handle if line.strip()]
        return text, attached

    def test_generated_script(self):
        available = ["wine:syscall_entry", "wine:syscall_exit", "wine:unixcall_entry", "wine:unixcall_exit",
                     "wine:server_req_start", "wine:server_req_end", "wine:server_wait_start",
                     "wine:server_wait_end", "pipeasio:block_start", "pipeasio:block_before_live",
                     "pipeasio:block_after_live", "pipeasio:block_end",
                     "fentry:ntsync:ntsync_char_ioctl", "fexit:ntsync:ntsync_char_ioctl",
                     "fentry:ntsync:ntsync_obj_ioctl", "tracepoint:sched:sched_process_exec",
                     "tracepoint:task:task_rename", "tracepoint:task:task_newtask"]
        text, attached = self.generate("sched", available)
        # two programs on unixcall_entry, one attach.txt line
        self.assertEqual(text.count("usdt:/opt/w/ntdll.so:wine:unixcall_entry\n"), 2)
        self.assertEqual(attached.count("wine:unixcall_entry"), 1)
        self.assertIn("tracepoint:task:task_newtask", text)
        self.assertNotIn("@tids[(uint32)", text.split("BEGIN", 1)[1].split("}", 1)[0],
                         "no tasks-start.txt: no @tids seeds")
        self.assertIn("config = {", text)
        self.assertIn("on_stack_limit = 256;", text)
        self.assertIn("@pids[(uint32)4200] = 1; @pids[(uint32)4100] = 1;", text)
        self.assertIn("usdt:/opt/w/ntdll.so:wine:syscall_entry", text)
        self.assertIn("usdt:/opt/w/pipeasio64.dll.so:pipeasio:block_end", text)
        self.assertNotIn("pipeasio:cycle_start", text, "absent probes are stripped")
        self.assertNotIn("sched_switch", text, "the sched section is stripped")
        self.assertNotRegex(text, r"(?m)^// @@SECTION")
        self.assertNotRegex(text, r"@(NTDLL|PIPEASIO|FILTER|PIDS_INIT)@")
        self.assertEqual(len(attached), len(available))
        self.assertIn("fentry:ntsync:ntsync_char_ioctl", attached)

    def test_tasks_start_seeds_tids(self):
        tasks = ("T 900 4200 4200 comm=Ableton Live 12 Trial.exe\n"
                 "T 900 4301 4200 comm=AudioCalc\n"
                 "T 900 4100 4100 comm=wineserver\n"
                 "garbage line\n")
        text, _ = self.generate("", ["wine:syscall_entry", "wine:syscall_exit", "tracepoint:task:task_newtask",
                                     "tracepoint:sched:sched_switch"], tasks=tasks)
        begin = text.split("\nBEGIN\n", 1)[1].split("\n}", 1)[0]
        self.assertIn("@pids[(uint32)4200] = 1; @pids[(uint32)4100] = 1; @tids[(uint32)4200] = 1; "
                      "@tids[(uint32)4301] = 1; @tids[(uint32)4100] = 1;", begin)
        self.assertIn("sched_switch", text)
        self.assertIn("task_newtask", text)

    def test_without_ntsync_and_follow(self):
        text, attached = self.generate("ntsync,sched,follow", ["wine:syscall_entry", "wine:syscall_exit"], "1")
        self.assertNotIn("ntsync_char_ioctl", text)
        self.assertNotIn("task_rename", text)
        self.assertIn("/1/", text)
        self.assertEqual(attached, ["wine:syscall_entry", "wine:syscall_exit"])
        self.assertIn("print(@emitted);", text)


if __name__ == "__main__":
    unittest.main()
