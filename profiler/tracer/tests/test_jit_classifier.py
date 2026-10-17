#!/usr/bin/env python3
"""Runs the C unit test of the stack self-check's JIT prologue classifier.

tests/test_jit_classifier.c checks wine-trace.h's jit_prologue_class() and
xlated_stack_depth() against prologue bytes captured from the kernel's x86-64 JIT
(kernel-stack, frame-less and per-CPU private-stack functions) and synthetic variants.
Needs a C compiler and the Linux uapi headers (skipped elsewhere); the same test runs
as `make -C profiler/tracer test`.

Run from the repository root:  python3 -I -m unittest discover -s profiler/tracer/tests -v
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TRACER = os.path.dirname(HERE)


def find_cc():
    for name in (os.environ.get("CC") or "", "cc", "gcc", "clang"):
        if name and shutil.which(name):
            return shutil.which(name)
    return None


@unittest.skipUnless(sys.platform.startswith("linux"), "needs Linux uapi headers")
class JitClassifierTests(unittest.TestCase):
    def test_c_unit_test(self):
        cc = find_cc()
        if cc is None:
            self.skipTest("no C compiler")
        with tempfile.TemporaryDirectory() as tmp:
            exe = os.path.join(tmp, "test-jit-classifier")
            build = subprocess.run(
                [cc, "-O2", "-Wall", "-Wextra", "-Werror", "-std=gnu11", "-I", TRACER,
                 os.path.join(HERE, "test_jit_classifier.c"), "-o", exe],
                capture_output=True, text=True)
            if build.returncode != 0 and "linux/types.h" in build.stderr:
                self.skipTest("no linux/types.h")
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([exe], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS real-private-stack", run.stdout)
            self.assertIn("PASS real-kernel-stack-main", run.stdout)
            self.assertIn("SUMMARY fails=0", run.stdout)


if __name__ == "__main__":
    unittest.main()
