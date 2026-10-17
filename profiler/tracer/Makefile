# SPDX-License-Identifier: LGPL-2.1-or-later
# wine-trace — libbpf CO-RE tracer for the Wine interface profiler (design B §3b).
#
# Built on the Linux host that runs the tracer (CachyOS: clang, bpf (bpftool), libbpf,
# elfutils, zlib).  Everything generated lands in $(BUILD) (profiler/.gitignore:
# tracer/build/), so `build.sh`'s source snapshot never sees the artifacts.  BUILD.md has the
# prerequisites and the regeneration rules.
#
#   make            -> build/wine-trace (+ build/vmlinux.h, build/wine-trace.bpf.o, build/wine-trace.skel.h)
#   make check      -> build + static sanity checks (program sections, maps, --version)
#   make test       -> JIT prologue classifier unit test (no root, no BPF load)
#   make self-check -> build + `sudo -n build/wine-trace --self-check` (loads, never attaches)
#   make test-gate  -> a deliberately broken build (one USDT program with a 128-byte frame) whose
#                      self-check must refuse with exit 2 (loads, never attaches; needs sudo -n)
#   make clean
#
# Overrides: CLANG=, BPFTOOL=, CC=, BUILD=, VMLINUX_BTF=, BPF_CPU=v3, BPF_EXTRA= (extra clang flags)

CLANG      ?= clang
BPFTOOL    ?= bpftool
CC         ?= cc
BUILD      ?= build
VMLINUX_BTF ?= /sys/kernel/btf/vmlinux
BPF_CPU    ?= v3
ARCH       ?= x86
BPF_EXTRA  ?=
SUDO       ?= sudo -n

# vmlinux.h is generated from the kernel's BTF and is not -Wextra clean (missing declarations):
# it comes in through -isystem so that only warnings of our own code are printed.
BPF_CFLAGS := -O2 -g -target bpf -mcpu=$(BPF_CPU) -D__TARGET_ARCH_$(ARCH) -I. -isystem $(BUILD) \
              -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-missing-field-initializers \
              $(BPF_EXTRA)
CFLAGS     ?= -O2 -g
CFLAGS     += -Wall -Wextra -std=gnu11 -I. -I$(BUILD) -D_GNU_SOURCE
LDLIBS     := -lbpf -lelf -lz -lm -pthread

BIN   := $(BUILD)/wine-trace
BPFO  := $(BUILD)/wine-trace.bpf.o
SKEL  := $(BUILD)/wine-trace.skel.h
VMLX  := $(BUILD)/vmlinux.h
JITT  := $(BUILD)/test-jit-classifier
GATE  := $(BUILD)/gate

.PHONY: all clean check vmlinux test self-check test-gate

all: $(BIN)

vmlinux: $(VMLX)

$(BUILD):
	mkdir -p $(BUILD)

# Generated from the running kernel's BTF; regenerate after a kernel update (make clean).
$(VMLX): | $(BUILD)
	$(BPFTOOL) btf dump file $(VMLINUX_BTF) format c > $@.tmp && mv $@.tmp $@

$(BPFO): wine-trace.bpf.c wine-trace.h $(VMLX) | $(BUILD)
	$(CLANG) $(BPF_CFLAGS) -c wine-trace.bpf.c -o $@

# `name wine_trace` pins the skeleton's identifiers (struct wine_trace, wine_trace__open, ...)
$(SKEL): $(BPFO)
	$(BPFTOOL) gen skeleton $(BPFO) name wine_trace > $@.tmp && mv $@.tmp $@

$(BIN): wine-trace.c wine-trace.h $(SKEL)
	$(CC) $(CFLAGS) wine-trace.c -o $@ $(LDLIBS)

check: all
	@echo "== programs in $(BPFO)"
	@readelf -S -W $(BPFO) | grep -oE ' (usdt|fentry/[a-z_]+|fexit/[a-z_]+|kprobe/[a-z_]+|kretprobe/[a-z_]+|tp_btf/[a-z_]+|tracepoint/[a-z_/]+|perf_event) ' | sort | uniq -c
	@test "$$(readelf -S -W $(BPFO) | grep -c ' usdt ')" -ge 1
	@echo "== maps"
	@$(BPFTOOL) btf dump file $(BPFO) format raw 2>/dev/null | grep -E "VAR '(agg|agg0|agg1|agg2|agg3|tstate|pids|tids|rb|unixlibs|trigger_ids|CFG|gl|counters|hits)'" | sed 's/.*VAR/VAR/'
	@echo "== loader"
	@$(BIN) --version
	@ls -l $(BIN) $(BPFO)

$(JITT): tests/test_jit_classifier.c wine-trace.h | $(BUILD)
	$(CC) $(CFLAGS) tests/test_jit_classifier.c -o $@

test: $(JITT)
	$(JITT)

self-check: all
	$(SUDO) $(BIN) --self-check > $(BUILD)/stack-check.json
	@echo "stack check passed: $(BUILD)/stack-check.json"

test-gate:
	$(MAKE) BUILD=$(GATE) BPF_EXTRA=-DWT_SELFTEST_BIG_FRAME all
	@rc=0; $(SUDO) $(GATE)/wine-trace --self-check > $(GATE)/stack-check.json 2> $(GATE)/stack-check.err || rc=$$?; \
	 cat $(GATE)/stack-check.err; \
	 if [ $$rc -eq 2 ] && grep -q 'wine_syscall_exit .*private-stack.*RISKY' $(GATE)/stack-check.err; then \
	     echo "test-gate: PASS (the broken build was refused with exit 2)"; \
	 else echo "test-gate: FAIL (exit $$rc; expected 2 with wine_syscall_exit on the private stack)"; exit 1; fi

clean:
	rm -rf $(BUILD)
