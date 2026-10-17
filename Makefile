# Convenience wrapper over the scripts. See README.md.
.PHONY: all build install setup refresh uninstall test test-bench test-profiler bench-compare test-glyph-path test-d2d-resize test-pipewire-pro-audio-ab vendor-cache verify check pointer-safety-check clean distclean

all: build

build:                        ## build runtime and Link helper with Podman -> dist/
	./build.sh

install:                      ## install the built Wine tree + launcher (end user)
	./scripts/installer.sh install --skip-live-install

setup:                        ## create the Wine prefix (end user)
	./scripts/installer.sh prefix create

refresh:                      ## refresh the existing Wine prefix (end user)
	./scripts/installer.sh prefix update

uninstall:                    ## remove installed Wine tree + launcher
	./scripts/installer.sh uninstall --keep-prefix

test:                         ## run installer and launcher lifecycle gates
	./scripts/test-tsan-policy.sh
	./scripts/test-release-policy.sh
	./scripts/test-build-audit-usdt.sh
	./scripts/test-config-boundary.sh
	./scripts/test-project-file-installer.sh
	./scripts/test-installer-ui.sh
	./scripts/test-preflight-preferences.sh
	./scripts/test-preflight-menu.sh
	./scripts/test-preflight-integration.sh
	./scripts/test-check-ntsync.sh
	./scripts/test-shortcut-hold.sh
	./scripts/test-cpu-topology.sh
	./scripts/test-live-options.sh
	./scripts/test-pipewire-pro-audio-ab.sh
	./scripts/test-desktop-integration.sh
	./scripts/test-launcher-transactions.sh
	./scripts/test-link-boundary.sh
	./scripts/test-uninstall-boundary.sh
	./scripts/test-nix-packaging.sh
	./scripts/test-installer-lifecycle.sh
	./scripts/test-pipeasio-installer.sh
	./scripts/test-bench-report.py
	./scripts/test-bench-suite.sh
	$(MAKE) test-profiler

test-bench:                    ## run benchmark report and run checks
	./scripts/test-bench-report.py
	./scripts/test-bench-suite.sh

# The profiler workbench (local fork) keeps its tests beside its code. They
# run through python3 -I so a planted module next to the test cannot load.
# `make test` already runs the test-bench scripts before it recurses here, so
# test-profiler does not depend on test-bench (`make test-bench test-profiler`
# runs both on their own).
test-profiler:                 ## run profiler workbench checks (control layer, scenarios, tracer, ledger, history)
	./profiler/control/vendor.sh --check
	python3 -I ./profiler/control/tests/test_bench_handler.py
	python3 -I ./profiler/control/tests/test_liveosc.py
	python3 -I ./profiler/control/tests/test_scenario_run.py
	python3 -I ./profiler/scenarios/tests/test_scenarios.py
	python3 -I ./profiler/tracer/tests/test_gen_tables.py
	python3 -I ./profiler/tracer/tests/test_symbolize.py
	python3 -I ./profiler/tracer/tests/test_reduce.py
	python3 -I ./profiler/tracer/tests/test_validate.py
	python3 -I ./profiler/tracer/tests/test_bt_template.py
	python3 -I ./profiler/tracer/tests/test_jit_classifier.py
	python3 -I ./profiler/tracer/tests/test_calibrate.py
	python3 -I ./profiler/bin/tests/test-ledger-report.py
	python3 -I ./profiler/bin/tests/test-history-add.py
	./profiler/bin/tests/test-state-leftovers.sh
	./profiler/setup/tests/test-audio-device.sh

bench-compare:                 ## compare completed runs (BEFORE=... AFTER=... OUTPUT=...)
	@test -n "$(BEFORE)" -a -n "$(AFTER)" -a -n "$(OUTPUT)"
	./scripts/bench-report.py compare --before "$(BEFORE)" --after "$(AFTER)" --output "$(OUTPUT)"

test-glyph-path:              ## assert a built runtime's dwrite glyph path (RUNTIME=<root>)
	./scripts/test-dwrite-glyph-path.sh $(RUNTIME)

test-d2d-resize:              ## assert an hwnd render target survives Resize (RUNTIME=<root>)
	./scripts/test-d2d-resize.sh $(RUNTIME)

test-pipewire-pro-audio-ab:   ## test Pro Audio comparison and profile restoration
	./scripts/test-pipewire-pro-audio-ab.sh

vendor-cache:                 ## populate vendor/winetricks-cache for offline setup
	./scripts/vendor-winetricks-cache.sh

verify: pointer-safety-check  ## check vendored inputs and pointer safety rules
	cd vendor && sha256sum -c wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 ntsync-uapi.sha256 link.sha256 cabextract.sha256 bitstream-vera.sha256 llvm-apt-key.sha256

check: pointer-safety-check   ## run deterministic pointer safety checks

pointer-safety-check:
	@set -eu; \
	trap 'rm -f -- tools/.pointer-safety-invariants.tmp' EXIT HUP INT TERM; \
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror \
		tools/pointer-safety-invariants.c -lm -o tools/.pointer-safety-invariants.tmp; \
	tools/.pointer-safety-invariants.tmp

clean:                        ## remove build outputs
	rm -rf dist

distclean: clean              ## also drop the container image
	-$${ENGINE:-podman} rmi ableton-wine-build:22.04
