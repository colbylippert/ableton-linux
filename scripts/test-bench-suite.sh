#!/usr/bin/env bash
# Deterministic dry-run/preflight tests. No Wine command or Live set is run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="$(mktemp -d)"
cleanup()
{
    rm -rf -- "$base"
}
trap cleanup EXIT

home="$base/home"
runtime="$base/runtime"
prefix="$base/prefix"
data="$base/data"
config="$base/config"
state="$base/state"
cache="$base/cache"
bin="$base/bin"
proc_fixture="$base/proc"
mkdir -p -- \
    "$home" "$runtime/bin" "$prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" \
    "$prefix/drive_c/Program Files/Common Files/VST3/Dexed.vst3" \
    "$prefix/drive_c/Program Files/Common Files/VST3/K1v_x64.vst3" \
    "$data" "$config" "$state" "$cache" "$bin" "$proc_fixture"
true_binary="$(type -P true)"
cp -- "$true_binary" "$runtime/bin/wine"
cp -- "$true_binary" "$runtime/bin/wineserver"
touch -- "$prefix/system.reg"
touch -- "$prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
# Tracing fixtures: the tracer and the root helper only need to exist for a
# dry run; sudo-ok and sudo-fail stand in for passwordless and prompting sudo.
cp -- "$true_binary" "$bin/wine-trace"
cp -- "$true_binary" "$bin/profiler-root-helper"
cp -- "$true_binary" "$bin/sudo-ok"
printf '#!/bin/sh\nexit 1\n' > "$bin/sudo-fail"
chmod +x -- "$bin/sudo-fail"
# Scenario fixture: only clip-launch-storm validates.
cat > "$bin/scenario-run.py" <<'EOF'
import sys
if sys.argv[1:] == ["--validate", "clip-launch-storm"]:
    sys.exit(0)
sys.stderr.write("scenario-run: unknown scenario\n")
sys.exit(1)
EOF

fixture_env=(
    env -i
    "PATH=$bin:$PATH"
    "HOME=$home"
    USER=bench
    DISPLAY=:fixture
    ABLETON_BENCH_TESTING=1
    "ABLETON_BENCH_PROC_ROOT=$proc_fixture"
    "ABLETON_BENCH_TRACER=$bin/wine-trace"
    "ABLETON_BENCH_SCENARIO_TOOL=$bin/scenario-run.py"
    "ABLETON_WINE_ROOT=$runtime"
    "ABLETON_WINEPREFIX=$prefix"
    "ABLETON_DATA_HOME=$data"
    "ABLETON_CONFIG_HOME=$config"
    "ABLETON_STATE_HOME=$state"
    "ABLETON_CACHE_HOME=$cache"
    "ABLETON_BIN_HOME=$bin"
    "ABLETON_CONFIG_FILE=$config/config"
)

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

ok()
{
    printf 'ok - %s\n' "$*"
}

dry_output="$base/dry-report"
"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture --output "$dry_output" \
    > "$base/default.out" 2> "$base/default.err" \
    || fail "valid dry-run preflight failed: $(cat "$base/default.err")"
[ ! -e "$dry_output" ] || fail "dry-run created its report directory"
[ ! -e "$config/cpu-benchmark-machine-id-v1" ] || fail "dry-run created a report source ID"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $4 == "30s" {count++} END {print count+0}' "$base/default.out")" -eq 5 ] \
    || fail "the default 30-second duration did not reach all five sets"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ {print $2}' "$base/default.out" | paste -sd, -)" \
    = "Benchmark_Zero,Benchmark_Empty,Benchmark_Inbuilts,Benchmark_Max4Live,Benchmark_VSTs" ] \
    || fail "the dry-run order is not canonical"
grep -q $'^1\tBenchmark_Zero\tidle-no-controller\t30s$' "$base/default.out" \
    || fail "Benchmark_Zero is not explicitly an idle/no-controller run"
grep -q '^osc send=19001 recv=19002 control=m4l$' "$base/default.out" \
    || fail "a run without a scenario does not default to the M4L device ports"
grep -q '^trace=off privilege=none structure=benchmark scenario=none$' "$base/default.out" \
    || fail "the default plan is not an untraced benchmark without a scenario"
ok "dry-run is mutation-free and fixes every set to the default 30-second window"

"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --duration 17 --tag fixture \
    --output "$base/custom-report" > "$base/custom.out" 2> "$base/custom.err" \
    || fail "custom-duration dry-run failed"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $4 == "17s" {count++} END {print count+0}' "$base/custom.out")" -eq 5 ] \
    || fail "a custom common duration did not reach all five sets"
ok "one duration value governs every planned set"

if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture \
    --output "$prefix/benchmark-output" > "$base/overlap.out" 2> "$base/overlap.err"; then
    fail "preflight accepted report output inside the Wine prefix"
fi
grep -q 'output must not overlap the runtime, prefix, or immutable set project' "$base/overlap.err" \
    || fail "unsafe output overlap refusal was not precise"
ok "preflight keeps reports outside the runtime, prefix, and immutable sets"

mkdir -p -- "$proc_fixture/4242"
printf 'C:\\ProgramData\\Ableton\\Live 12 Suite\\Program\\Ableton Live 12 Suite.exe\000fixture\000' \
    > "$proc_fixture/4242/cmdline"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture \
    --output "$base/existing-live-report" > "$base/existing.out" 2> "$base/existing.err"; then
    fail "preflight accepted an existing Live session"
fi
grep -q 'session already exists (pid(s): 4242' "$base/existing.err" \
    || fail "existing-session refusal did not identify the pid"
ok "preflight refuses an existing Live session before creating output"

if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --duration 9 --tag fixture \
    --output "$base/short-report" > "$base/short.out" 2> "$base/short.err"; then
    fail "preflight accepted a duration below the instrumentation floor"
fi
grep -q 'duration must be between 10 and 3600 seconds' "$base/short.err" \
    || fail "invalid-duration refusal was not precise"
if "${fixture_env[@]}" "$here/bench-run.sh" --duration 9 --output-dir "$base/short-run" \
    > "$base/short-run.out" 2> "$base/short-run.err"; then
    fail "individual measurement accepted a duration below the instrumentation floor"
fi
grep -q 'duration must be between 10 and 3600 seconds' "$base/short-run.err" \
    || fail "individual measurement duration refusal was not precise"
ok "duration validation preserves the 10-second instrumentation floor"

# The remaining plans need an idle machine again.
rm -rf -- "$proc_fixture/4242"
"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --trace interface --tag fixture \
    --output "$base/trace-report" > "$base/trace.out" 2> "$base/trace.err" \
    || fail "traced dry-run failed: $(cat "$base/trace.err")"
grep -q '^trace=interface privilege=root-helper structure=benchmark scenario=none$' "$base/trace.out" \
    || fail "traced dry-run did not report the root helper route"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $4 == "30s" {count++} END {print count+0}' "$base/trace.out")" -eq 5 ] \
    || fail "tracing changed the planned sets"
[ ! -e "$base/trace-report" ] || fail "traced dry-run created its report directory"
"${fixture_env[@]}" ABLETON_BENCH_TRACE=drilldown ABLETON_BENCH_ROOT_HELPER=/nonexistent \
    "ABLETON_BENCH_SUDO=$bin/sudo-ok" "$here/bench-suite.sh" --dry-run --tag fixture \
    --output "$base/sudo-report" > "$base/sudo.out" 2> "$base/sudo.err" \
    || fail "sudo-route dry-run failed: $(cat "$base/sudo.err")"
grep -q '^trace=drilldown privilege=sudo structure=benchmark scenario=none$' "$base/sudo.out" \
    || fail "dry-run without the helper did not fall back to passwordless sudo"
if "${fixture_env[@]}" ABLETON_BENCH_ROOT_HELPER=/nonexistent "ABLETON_BENCH_SUDO=$bin/sudo-fail" \
    "$here/bench-suite.sh" --dry-run --trace interface --tag fixture \
    --output "$base/no-root-report" > "$base/no-root.out" 2> "$base/no-root.err"; then
    fail "preflight accepted tracing without a privilege route"
fi
grep -q 'tracing needs profiler-root-helper or passwordless sudo' "$base/no-root.err" \
    || fail "missing-privilege refusal was not precise"
if "${fixture_env[@]}" ABLETON_BENCH_TRACER=/nonexistent "$here/bench-suite.sh" --dry-run --trace interface \
    --tag fixture --output "$base/no-tracer-report" > "$base/no-tracer.out" 2> "$base/no-tracer.err"; then
    fail "preflight accepted a missing tracer"
fi
grep -q 'tracer is not executable: /nonexistent' "$base/no-tracer.err" \
    || fail "missing-tracer refusal was not precise"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --trace sometimes --tag fixture \
    --output "$base/bad-trace-report" > "$base/bad-trace.out" 2> "$base/bad-trace.err"; then
    fail "an unknown trace mode was accepted"
fi
grep -q -- '--trace must be off, interface, or drilldown' "$base/bad-trace.err" \
    || fail "trace mode refusal was not precise"
ok "tracing needs the root helper or passwordless sudo and reports its route"

"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --sets Zero,VSTs --tag fixture \
    --output "$base/subset-report" > "$base/subset.out" 2> "$base/subset.err" \
    || fail "subset dry-run failed: $(cat "$base/subset.err")"
[ "$(awk -F '\t' '$1 ~ /^[0-9]+$/ {print $1 ":" $2 ":" $3}' "$base/subset.out" | paste -sd, -)" \
    = "1:Benchmark_Zero:idle-no-controller,2:Benchmark_VSTs:playback" ] \
    || fail "--sets did not plan exactly the chosen sets in order"
grep -q '^trace=off privilege=none structure=diagnostic scenario=none$' "$base/subset.out" \
    || fail "a subset run is not marked diagnostic"
"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --sets Benchmark_Zero,Empty,Inbuilts,Max4Live,VSTs \
    --tag fixture --output "$base/explicit-report" > "$base/explicit.out" 2> "$base/explicit.err" \
    || fail "explicit canonical --sets dry-run failed: $(cat "$base/explicit.err")"
grep -q '^trace=off privilege=none structure=benchmark scenario=none$' "$base/explicit.out" \
    || fail "the canonical list given explicitly is not a benchmark"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ {print $2}' "$base/explicit.out" | paste -sd, -)" \
    = "Benchmark_Zero,Benchmark_Empty,Benchmark_Inbuilts,Benchmark_Max4Live,Benchmark_VSTs" ] \
    || fail "explicit canonical --sets changed the order"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --sets Zero,Nope --tag fixture \
    --output "$base/unknown-set-report" > "$base/unknown-set.out" 2> "$base/unknown-set.err"; then
    fail "an unknown set name was accepted"
fi
grep -q 'benchmark set is missing: .*/profiler/sets/Nope\.als' "$base/unknown-set.err" \
    || fail "unknown set refusal did not name the profiler/sets path"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --sets Zero,Zero --tag fixture \
    --output "$base/duplicate-set-report" > "$base/duplicate-set.out" 2> "$base/duplicate-set.err"; then
    fail "a duplicate set was accepted"
fi
grep -q 'duplicate set in --sets: Benchmark_Zero' "$base/duplicate-set.err" \
    || fail "duplicate set refusal was not precise"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --sets 'Zero,../Zero' --tag fixture \
    --output "$base/bad-set-report" > "$base/bad-set.out" 2> "$base/bad-set.err"; then
    fail "a set name with a path separator was accepted"
fi
grep -q 'invalid set name in --sets' "$base/bad-set.err" || fail "set name refusal was not precise"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --crackle VSTs=heard --sets Zero --tag fixture \
    --output "$base/crackle-report" > "$base/crackle.out" 2> "$base/crackle.err"; then
    fail "a crackle report for a set outside the run was accepted"
fi
grep -q 'unknown crackle set: Benchmark_VSTs' "$base/crackle.err" || fail "crackle set refusal was not precise"
ok "--sets plans the chosen sets in order and marks a non-canonical run diagnostic"

grep -q '^live-window=normal$' "$base/default.out" || fail "the default plan does not keep Live's window normal"
touch -- "$bin/livewin.exe"
"${fixture_env[@]}" "ABLETON_BENCH_WINDOW_TOOL=$bin/livewin.exe" "$here/bench-suite.sh" --dry-run \
    --live-window minimized --sets Inbuilts --tag fixture --output "$base/minimized-report" \
    > "$base/minimized.out" 2> "$base/minimized.err" \
    || fail "minimised-window dry-run failed: $(cat "$base/minimized.err")"
grep -q '^live-window=minimized$' "$base/minimized.out" || fail "--live-window minimized is not in the plan"
"${fixture_env[@]}" "ABLETON_BENCH_WINDOW_TOOL=$bin/livewin.exe" ABLETON_BENCH_LIVE_WINDOW=minimized \
    "$here/bench-suite.sh" --dry-run --sets Inbuilts --tag fixture --output "$base/minimized-env-report" \
    > "$base/minimized-env.out" 2> "$base/minimized-env.err" \
    || fail "ABLETON_BENCH_LIVE_WINDOW=minimized dry-run failed: $(cat "$base/minimized-env.err")"
grep -q '^live-window=minimized$' "$base/minimized-env.out" || fail "ABLETON_BENCH_LIVE_WINDOW=minimized is not in the plan"
if "${fixture_env[@]}" "ABLETON_BENCH_WINDOW_TOOL=$bin/missing.exe" "$here/bench-suite.sh" --dry-run \
    --live-window minimized --sets Inbuilts --tag fixture --output "$base/no-tool-report" \
    > "$base/no-tool.out" 2> "$base/no-tool.err"; then
    fail "a minimised-window run without tools/livewin.exe was accepted"
fi
grep -q 'build it with tools/build_livewin.sh' "$base/no-tool.err" || fail "missing livewin.exe refusal was not precise"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --live-window hidden --tag fixture \
    --output "$base/bad-window-report" > "$base/bad-window.out" 2> "$base/bad-window.err"; then
    fail "an unknown --live-window mode was accepted"
fi
grep -q -- '--live-window must be normal or minimized' "$base/bad-window.err" || fail "--live-window refusal was not precise"
ok "--live-window minimized is planned only with tools/livewin.exe present; unknown modes are refused"

"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --scenario clip-launch-storm --tag fixture \
    --output "$base/scenario-report" > "$base/scenario.out" 2> "$base/scenario.err" \
    || fail "scenario dry-run failed: $(cat "$base/scenario.err")"
grep -q '^trace=off privilege=none structure=diagnostic scenario=clip-launch-storm$' "$base/scenario.out" \
    || fail "a scenario run is not marked diagnostic with its name"
grep -q '^osc send=11000 recv=11001 control=abletonosc$' "$base/scenario.out" \
    || fail "a scenario run without ABL_BENCH_OSC_* does not default every OSC use to AbletonOSC"
"${fixture_env[@]}" ABL_BENCH_OSC_SEND=12000 ABL_BENCH_OSC_RECV=12001 "$here/bench-suite.sh" --dry-run \
    --scenario clip-launch-storm --tag fixture --output "$base/scenario-ports-report" \
    > "$base/scenario-ports.out" 2> "$base/scenario-ports.err" \
    || fail "scenario dry-run with explicit ports failed: $(cat "$base/scenario-ports.err")"
grep -q '^osc send=12000 recv=12001 control=abletonosc$' "$base/scenario-ports.out" \
    || fail "explicit ABL_BENCH_OSC_* ports were not kept for a scenario run"
if "${fixture_env[@]}" ABL_BENCH_OSC_SEND=11000 ABL_BENCH_OSC_RECV=11000 "$here/bench-suite.sh" --dry-run \
    --tag fixture --output "$base/same-ports-report" > "$base/same-ports.out" 2> "$base/same-ports.err"; then
    fail "identical send and receive ports were accepted"
fi
grep -q 'must differ' "$base/same-ports.err" || fail "identical port refusal was not precise"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $3 == "scenario" && $4 == "30s" {count++} END {print count+0}' "$base/scenario.out")" -eq 5 ] \
    || fail "the scenario does not drive every planned set"
"${fixture_env[@]}" ABLETON_BENCH_SCENARIO=clip-launch-storm "$here/bench-suite.sh" --dry-run --sets Inbuilts \
    --tag fixture --output "$base/scenario-set-report" > "$base/scenario-set.out" 2> "$base/scenario-set.err" \
    || fail "scenario dry-run with one set failed: $(cat "$base/scenario-set.err")"
[ "$(awk -F '\t' '$1 ~ /^[0-9]+$/ {print $1 ":" $2 ":" $3}' "$base/scenario-set.out" | paste -sd, -)" \
    = "1:Benchmark_Inbuilts:scenario" ] \
    || fail "ABLETON_BENCH_SCENARIO with --sets did not plan one scenario set"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --scenario no-such-scenario --tag fixture \
    --output "$base/bad-scenario-report" > "$base/bad-scenario.out" 2> "$base/bad-scenario.err"; then
    fail "an unknown scenario was accepted"
fi
grep -q 'unknown or invalid scenario: no-such-scenario' "$base/bad-scenario.err" \
    || fail "unknown scenario refusal was not precise"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --scenario 'clip;storm' --tag fixture \
    --output "$base/bad-scenario-name-report" > "$base/bad-scenario-name.out" 2> "$base/bad-scenario-name.err"; then
    fail "a scenario name with shell characters was accepted"
fi
grep -q 'scenario name may use' "$base/bad-scenario-name.err" || fail "scenario name refusal was not precise"
if "${fixture_env[@]}" ABLETON_BENCH_SCENARIO_TOOL=/nonexistent "$here/bench-suite.sh" --dry-run \
    --scenario clip-launch-storm --tag fixture --output "$base/no-tool-report" \
    > "$base/no-tool.out" 2> "$base/no-tool.err"; then
    fail "preflight accepted a missing scenario tool"
fi
grep -q 'scenario tool is missing: /nonexistent' "$base/no-tool.err" || fail "missing scenario tool refusal was not precise"
ok "a scenario drives every planned set on the AbletonOSC ports and only a validated scenario runs"

if "${fixture_env[@]}" "$here/bench-run.sh" --mode scenario --scenario clip-launch-storm \
    --output-dir "$base/scenario-run" > "$base/scenario-run.out" 2> "$base/scenario-run.err"; then
    fail "individual measurement ran without a Live process"
fi
grep -q 'no Live process matches' "$base/scenario-run.err" \
    || fail "individual measurement did not accept scenario mode: $(cat "$base/scenario-run.err")"
if "${fixture_env[@]}" "$here/bench-run.sh" --mode scenario --output-dir "$base/scenario-run" \
    > "$base/nameless-run.out" 2> "$base/nameless-run.err"; then
    fail "individual measurement accepted scenario mode without a scenario name"
fi
grep -q 'mode scenario needs --scenario NAME' "$base/nameless-run.err" \
    || fail "nameless scenario refusal was not precise"
if "${fixture_env[@]}" "$here/bench-run.sh" --mode skip --output-dir "$base/mode-run" \
    > "$base/mode-run.out" 2> "$base/mode-run.err"; then
    fail "individual measurement accepted an unknown mode"
fi
grep -q 'invalid mode: skip' "$base/mode-run.err" || fail "unknown mode refusal was not precise"
if "${fixture_env[@]}" "$here/bench-run.sh" --set-sha256 abc --output-dir "$base/sha-run" \
    > "$base/sha-run.out" 2> "$base/sha-run.err"; then
    fail "individual measurement accepted a malformed set digest"
fi
grep -q -- '--set-sha256 wants 64 hex digits' "$base/sha-run.err" || fail "set digest refusal was not precise"
if "${fixture_env[@]}" "$here/bench-run.sh" --trace-mode sometimes --output-dir "$base/trace-run" \
    > "$base/trace-run.out" 2> "$base/trace-run.err"; then
    fail "individual measurement accepted an unknown trace mode"
fi
grep -q -- '--trace-mode must be off, interface, or drilldown' "$base/trace-run.err" \
    || fail "trace mode refusal of the individual measurement was not precise"
ok "individual measurement accepts scenario mode and checks the pass-through values"
