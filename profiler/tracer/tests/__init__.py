"""Tests of the Wine interface tracer (profiler/tracer).

This file makes the directory a package so that unittest can import the tests by their dotted
name from the repository root:

    python3 -I -m unittest discover -s profiler/tracer/tests -t .

The other forms keep working: ``python3 -I -m unittest discover -s profiler/tracer/tests -v``
(README.md) and one file at a time, ``python3 -I profiler/tracer/tests/test_reduce.py``
(the top-level Makefile's test-profiler target).  Every test module finds the tracer's sources
through its own ``__file__``, so none of them depends on how it was imported.
"""
