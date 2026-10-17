#!/usr/bin/env bash
# Measure the 5 standard Live sets in a fixed order, or a chosen list. Each
# launch uses the selected runtime and prefix. A unique value identifies every
# Live session.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/config.sh"
ableton_config_init
. "$here/lib/lifecycle.sh"

canonical_sets=(Benchmark_Zero Benchmark_Empty Benchmark_Inbuilts Benchmark_Max4Live Benchmark_VSTs)
sets=("${canonical_sets[@]}")
duration="${ABLETON_BENCH_DURATION:-30}"
launch_timeout="${ABLETON_BENCH_LAUNCH_TIMEOUT:-180}"
settle="${ABLETON_BENCH_SETTLE_SECONDS:-5}"
tag="manual"
output=""
launcher="${ABLETON_BENCH_LAUNCHER:-$here/ableton-live}"
trace="${ABLETON_BENCH_TRACE:-off}"
scenario="${ABLETON_BENCH_SCENARIO:-}"
tracer="${ABLETON_BENCH_TRACER:-$root/profiler/bin/wine-trace}"
root_helper="${ABLETON_BENCH_ROOT_HELPER:-profiler-root-helper}"
sudo="${ABLETON_BENCH_SUDO:-sudo}"
scenario_tool="${ABLETON_BENCH_SCENARIO_TOOL:-$root/profiler/control/scenario-run.py}"
quit_tool="${ABLETON_BENCH_QUIT_TOOL:-$root/profiler/bin/live-trial-dialog}"
session_env_tool="${ABLETON_BENCH_SESSION_ENV:-$root/profiler/bin/with-session-env}"
state_tool="${ABLETON_BENCH_STATE_TOOL:-$root/profiler/bin/state}"
privilege=none
dry_run=0
skip_vst_check=0
declare -A crackle=()

usage()
{
    cat <<'EOF'
usage: scripts/bench-suite.sh [options]

  --tag LABEL                 report and comparison label (default manual)
  --output DIR                new report directory (default bench/reports/<UTC>-LABEL)
  --duration SECONDS          measurement time for every set (default 30; minimum 10)
  --launch-timeout SECONDS    maximum wait for Live and the control device (default 180)
  --settle SECONDS            stabilisation time before measurement (default 5)
  --crackle SET=STATE         listener report: heard, not-heard, or unknown
  --launcher PATH             Live launcher path
  --trace MODE                off, interface, or drilldown: run the interface
                              tracer during every measurement (default off)
  --scenario NAME             drive Live with profiler/scenarios/NAME.json during
                              every measurement
  --sets A,B,C                sets to run, in this order (default the five
                              standard sets; names may omit Benchmark_)
  --skip-vst-check            accept a VST set prepared for plug-in tests
  --dry-run                   check the run and print its plan; Live stays closed

The suite runs Zero, Empty, Inbuilts, Max4Live, and VSTs in that order. Zero
measures Live while it is idle. The other sets use their control device for
playback. The suite writes source data, report.json, and report.md. The command
also writes one <machine-id>-<YYYYMMDDTHHMMSSffffffZ>_cpu-benchmark.csv file
with system resource readings. The command quits each started Live through its
UI (profiler/bin/live-trial-dialog quit-live) and falls back to TERM and KILL by
its exact process ID, followed by profiler/bin/state clean-crash (also run
when Live crashed before the stop). Other Wine
sessions continue. ABLETON_BENCH_QUIT_TOOL, ABLETON_BENCH_SESSION_ENV, and
ABLETON_BENCH_STATE_TOOL replace those helpers.

A run with --sets or --scenario has the diagnostic structure: compare accepts
it only with --structure diagnostic. Tracing runs the tracer as root through
profiler-root-helper on PATH (through sudo -n; it runs its own installed or
allowlisted wine-trace, not ABLETON_BENCH_TRACER, and the suite waits up to
ABLETON_BENCH_TRACE_START_TIMEOUT seconds, default 180, for it to attach) or
passwordless sudo. ABLETON_BENCH_TRACE,
ABLETON_BENCH_SCENARIO, ABLETON_BENCH_TRACER, ABLETON_BENCH_ROOT_HELPER,
ABLETON_BENCH_SUDO, and ABLETON_BENCH_SCENARIO_TOOL set the defaults.

OSC ports: ABL_BENCH_OSC_SEND (commands to Live) and ABL_BENCH_OSC_RECV
(reports from Live) apply to every OSC use of the run: the probe, the
measurement, the stop and the scenario driver. A run without a scenario
defaults to 19001/19002 (the M4L device in the standard sets). A scenario run
defaults to 11000/11001 (the AbletonOSC Control Surface with the bench
handler, the only endpoint that serves scenario markers); profiler/bin/bench
exports the same pair for every run.
EOF
}

fail()
{
    printf 'bench-suite: %s\n' "$*" >&2
    exit 1
}

whole_seconds()
{
    local value="$1" name="$2" maximum="$3" minimum="${4:-1}"
    case "$value" in ''|*[!0-9]*) fail "$name must be a whole number of seconds" ;; esac
    [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] \
        || fail "$name must be between $minimum and $maximum seconds"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) shift; tag="${1:-}" ;;
        --output) shift; output="${1:-}" ;;
        --duration) shift; duration="${1:-}" ;;
        --launch-timeout) shift; launch_timeout="${1:-}" ;;
        --settle) shift; settle="${1:-}" ;;
        --launcher) shift; launcher="${1:-}" ;;
        --crackle)
            shift
            observation="${1:-}"
            case "$observation" in *=*) ;;
                *) fail "--crackle wants SET=heard, SET=not-heard, or SET=unknown" ;;
            esac
            observation_set="${observation%%=*}"
            observation_state="${observation#*=}"
            case "$observation_set" in
                Zero|Empty|Inbuilts|Max4Live|VSTs) observation_set="Benchmark_$observation_set" ;;
            esac
            case "$observation_state" in heard|not-heard|unknown) ;;
                *) fail "invalid crackle observation: $observation_state" ;;
            esac
            crackle["$observation_set"]="$observation_state"
            ;;
        --trace) shift; trace="${1:-}" ;;
        --scenario) shift; scenario="${1:-}" ;;
        --sets)
            shift
            sets=()
            IFS=, read -r -a chosen <<< "${1:-}"
            for chosen_set in "${chosen[@]}"; do
                case "$chosen_set" in
                    Zero|Empty|Inbuilts|Max4Live|VSTs) chosen_set="Benchmark_$chosen_set" ;;
                esac
                case "$chosen_set" in ''|*[!A-Za-z0-9_.-]*) fail "invalid set name in --sets: '$chosen_set'" ;; esac
                case " ${sets[*]} " in *" $chosen_set "*) fail "duplicate set in --sets: $chosen_set" ;; esac
                sets+=("$chosen_set")
            done
            [ "${#sets[@]}" -gt 0 ] || fail "--sets wants a comma-separated list of set names"
            ;;
        --skip-vst-check) skip_vst_check=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

whole_seconds "$duration" duration 3600 10
whole_seconds "$launch_timeout" launch-timeout 3600
whole_seconds "$settle" settle 120
case "$trace" in off|interface|drilldown) ;; *) fail "--trace must be off, interface, or drilldown" ;; esac
case "$scenario" in *[!A-Za-z0-9_.-]*) fail "scenario name may use letters, digits, '_', '.', and '-' only: $scenario" ;; esac
# A crackle report must name a set of this run. The list is final here.
for observation_set in "${!crackle[@]}"; do
    case " ${sets[*]} " in *" $observation_set "*) ;;
        *) fail "unknown crackle set: $observation_set" ;;
    esac
done
# Only the five standard sets in their order, without a scenario, form a
# benchmark. Everything else is a diagnostic run.
structure=diagnostic
[ -n "$scenario" ] || [ "${sets[*]}" != "${canonical_sets[*]}" ] || structure=benchmark
# One OSC endpoint per run: bench-osc.py (probe, measurement, stop) defaults to
# the M4L device ports and scenario-run.py to the AbletonOSC ports, so the suite
# fixes both for its children. Only AbletonOSC serves scenario markers.
control=m4l
osc_default_send=19001
osc_default_recv=19002
if [ -n "$scenario" ]; then control=abletonosc; osc_default_send=11000; osc_default_recv=11001; fi
export ABL_BENCH_OSC_SEND="${ABL_BENCH_OSC_SEND:-$osc_default_send}"
export ABL_BENCH_OSC_RECV="${ABL_BENCH_OSC_RECV:-$osc_default_recv}"
case "$ABL_BENCH_OSC_SEND:$ABL_BENCH_OSC_RECV" in
    *[!0-9:]*|:*|*:) fail "ABL_BENCH_OSC_SEND and ABL_BENCH_OSC_RECV must be UDP port numbers" ;;
esac
[ "$ABL_BENCH_OSC_SEND" != "$ABL_BENCH_OSC_RECV" ] || fail "ABL_BENCH_OSC_SEND and ABL_BENCH_OSC_RECV must differ"
if [ "$control" = abletonosc ]; then
    control_hint="the AbletonOSC Control Surface with the bench handler must be active (profiler/control/install.sh)"
else
    control_hint="the set's M4L device or the AbletonOSC Control Surface must be active"
fi
trace_tool_mode=summary
[ "$trace" != drilldown ] || trace_tool_mode=drilldown
case "$tag" in ''|*$'\n'*|*$'\r'*) fail "tag must be one non-empty line" ;; esac
safe_tag="$(printf '%s' "$tag" | tr -cs '[:alnum:]_.-' '-')"
safe_tag="${safe_tag#-}"; safe_tag="${safe_tag%-}"
[ -n "$safe_tag" ] || safe_tag=run
[ -n "$output" ] || output="$root/bench/reports/$(date -u +%Y%m%dT%H%M%SZ)-$safe_tag"
output="$(ableton_realpath_m "$output")"
proc_root=/proc
if [ "$dry_run" -eq 1 ] && [ "${ABLETON_BENCH_TESTING:-0}" = 1 ]; then
    proc_root="${ABLETON_BENCH_PROC_ROOT:-/proc}"
fi

global_live_pids()
{
    local process pid cmd
    for process in "$proc_root"/[0-9]*; do
        [ -d "$process" ] || continue
        pid="${process##*/}"
        cmd="$(tr '\0' ' ' < "$process/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "$pid" ;; esac
    done
    return 0
}

find_vst()
{
    local name="$1" candidate
    for candidate in \
        "$ABLETON_WINEPREFIX/drive_c/Program Files/Common Files/VST3/$name" \
        "$ABLETON_WINEPREFIX/drive_c/Program Files/VSTPlugins/$name"; do
        [ -e "$candidate" ] && return 0
    done
    return 1
}

# The standard sets live in bench; every other set is a profiler/sets file.
set_file_for()
{
    case " ${canonical_sets[*]} " in
        *" $1 "*) printf '%s\n' "$root/bench/BenchmarkSets Project/$1.als" ;;
        *) printf '%s\n' "$root/profiler/sets/$1.als" ;;
    esac
}

preflight()
{
    local set_name set_file live_pids prefix_pids live_exes=() profiler_sets=0
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
    command -v setsid >/dev/null 2>&1 || fail "setsid is required for a supervised launcher"
    command -v tee >/dev/null 2>&1 || fail "tee is required to retain the suite log"
    [ -x "$launcher" ] || fail "launcher is not executable: $launcher"
    [ -x "$ABLETON_WINE_ROOT/bin/wine" ] || fail "Wine is missing at $ABLETON_WINE_ROOT/bin/wine"
    [ -x "$ABLETON_WINE_ROOT/bin/wineserver" ] || fail "wineserver is missing at $ABLETON_WINE_ROOT/bin/wineserver"
    [ -f "$ABLETON_WINEPREFIX/system.reg" ] || fail "prefix is incomplete: $ABLETON_WINEPREFIX"
    for set_name in "${canonical_sets[@]}" "${sets[@]}"; do
        set_file="$(set_file_for "$set_name")"
        [ -s "$set_file" ] || fail "benchmark set is missing: $set_file"
        case "$set_file" in "$root/profiler/sets/"*) profiler_sets=1 ;; esac
    done
    ( cd "$root" && sha256sum -c bench/SHA256SUMS >/dev/null ) \
        || fail "a canonical benchmark asset differs from bench/SHA256SUMS"
    if find "$root/bench" -type d -name Backup -print -quit | grep -q .; then
        fail "a Live Backup directory is present under bench; canonical assets must remain clean"
    fi
    if [ "$profiler_sets" -eq 1 ]; then
        [ -s "$root/profiler/sets/SHA256SUMS" ] \
            || fail "profiler/sets/SHA256SUMS is missing; run profiler/bin/sets freeze"
        ( cd "$root" && sha256sum -c profiler/sets/SHA256SUMS >/dev/null ) \
            || fail "a profiler set differs from profiler/sets/SHA256SUMS"
    fi
    mapfile -t live_exes < <(find "$ABLETON_WINEPREFIX/drive_c/ProgramData/Ableton" \
        -path '*/Program/Ableton Live*.exe' -type f -print 2>/dev/null | sort -V)
    [ "${#live_exes[@]}" -gt 0 ] || fail "no Ableton Live executable was found in the configured prefix"
    if [ "$skip_vst_check" -ne 1 ]; then
        find_vst Dexed.vst3 || fail "Benchmark_VSTs requires Dexed.vst3 (use --skip-vst-check only for a deliberate fixture)"
        find_vst K1v_x64.vst3 || fail "Benchmark_VSTs requires K1v_x64.vst3 (use --skip-vst-check only for a deliberate fixture)"
    fi
    live_pids="$(global_live_pids)"
    [ -z "$live_pids" ] || fail "an Ableton Live session already exists (pid(s): $(printf '%s' "$live_pids" | tr '\n' ' ')); close it first"
    prefix_pids="$(ableton_prefix_pids)"
    [ -z "$prefix_pids" ] || fail "the configured Wine prefix is already active (pid(s): $(printf '%s' "$prefix_pids" | tr '\n' ' ')); close it first"
    if [ "$dry_run" -ne 1 ] || [ "${ABLETON_BENCH_TESTING:-0}" != 1 ]; then
        python3 "$here/bench-report.py" check-udp --port "$ABL_BENCH_OSC_RECV" \
            || fail "the benchmark OSC receive port is already in use"
        python3 "$here/bench-report.py" check-udp --port "$ABL_BENCH_OSC_SEND" \
            || fail "the Live control port is already in use; the control device could not listen"
    fi
    if [ "$trace" != off ]; then
        [ -x "$tracer" ] || fail "tracer is not executable: $tracer"
        # The tracer needs root. The helper is the bare-metal route; sudo -n
        # is the VM route. Neither may ask for a password.
        if command -v "$root_helper" >/dev/null 2>&1; then
            privilege=root-helper
        elif "$sudo" -n true >/dev/null 2>&1; then
            privilege=sudo
        else
            fail "tracing needs profiler-root-helper or passwordless sudo"
        fi
    fi
    if [ -n "$scenario" ]; then
        [ -f "$scenario_tool" ] || fail "scenario tool is missing: $scenario_tool"
        python3 "$scenario_tool" --validate "$scenario" || fail "unknown or invalid scenario: $scenario"
    fi
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || fail "a desktop session is required (DISPLAY and WAYLAND_DISPLAY are unset)"
    case "$output" in
        "$ABLETON_WINE_ROOT"|"$ABLETON_WINE_ROOT"/*|"$ABLETON_WINEPREFIX"|"$ABLETON_WINEPREFIX"/*|\
        "$root/bench/BenchmarkSets Project"|"$root/bench/BenchmarkSets Project"/*)
            fail "output must not overlap the runtime, prefix, or immutable set project: $output" ;;
    esac
    [ ! -e "$output" ] || fail "output already exists; refusing to overwrite: $output"
}

preflight

if [ "$dry_run" -eq 1 ]; then
    printf 'benchmark plan: duration=%ss output=%s\n' "$duration" "$output"
    printf 'trace=%s privilege=%s structure=%s scenario=%s\n' "$trace" "$privilege" "$structure" "${scenario:-none}"
    printf 'osc send=%s recv=%s control=%s\n' "$ABL_BENCH_OSC_SEND" "$ABL_BENCH_OSC_RECV" "$control"
    for index in "${!sets[@]}"; do
        set_name="${sets[index]}"
        mode=playback
        [ "$set_name" != Benchmark_Zero ] || mode=idle-no-controller
        [ -z "$scenario" ] || mode=scenario
        printf '%d\t%s\t%s\t%ss\n' "$((index + 1))" "$set_name" "$mode" "$duration"
    done
    exit 0
fi

mkdir -p -- "$output/sets"
exec > >(tee -a "$output/suite.log") 2>&1
run_id="bench-$(date -u +%Y%m%dT%H%M%SZ)-$$"
init_args=(init-run --output "$output/run.json" --tag "$tag" --duration "$duration"
    --structure "$structure" --trace-mode "$trace" --privilege "$privilege")
[ "$trace" = off ] || init_args+=(--tracer "$tracer")
[ -z "$scenario" ] || init_args+=(--scenario "$scenario")
for set_name in "${sets[@]}"; do init_args+=(--set "$set_name"); done
python3 "$here/bench-report.py" "${init_args[@]}"
python3 "$here/bench-report.py" profile \
    --output "$output/profile" \
    --prefix "$ABLETON_WINEPREFIX" \
    --wine-root "$ABLETON_WINE_ROOT" \
    --config-file "$ABLETON_CONFIG_FILE" \
    --run-file "$output/run.json"

active_token=""
launcher_pid=""
finalized=0

owned_live_pids()
{
    local pid
    [ -n "$active_token" ] || return 0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        printf '%s\n' "$pid"
    done < <(ableton_live_pids)
    return 0
}

wait_for_owned_live()
{
    local deadline=$((SECONDS + launch_timeout)) pids foreign pid
    while [ "$SECONDS" -lt "$deadline" ]; do
        pids="$(owned_live_pids)"
        [ -z "$pids" ] || { printf '%s\n' "$pids"; return 0; }
        foreign=""
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || foreign="${foreign:+$foreign }$pid"
        done < <(ableton_live_pids)
        [ -z "$foreign" ] || fail "a non-runner Live appeared in the benchmark prefix (pid(s): $foreign)"
        [ -z "$launcher_pid" ] || kill -0 "$launcher_pid" 2>/dev/null \
            || fail "launcher exited before runner-owned Live appeared"
        sleep 0.2
    done
    fail "runner-owned Live did not appear within ${launch_timeout}s"
}

latest_live_log()
{
    local path newest="" newest_time=0 stamp
    for path in "$ABLETON_WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/Live\ */Preferences/Log.txt; do
        [ -f "$path" ] || continue
        stamp="$(stat -c %Y -- "$path" 2>/dev/null || printf 0)"
        if [ "$stamp" -ge "$newest_time" ]; then newest="$path"; newest_time="$stamp"; fi
    done
    [ -n "$newest" ] && printf '%s\n' "$newest"
}

wait_log_quiet()
{
    local deadline=$((SECONDS + launch_timeout)) quiet_since=$SECONDS log signature="" previous=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        log="$(latest_live_log || true)"
        if [ -n "$log" ]; then
            signature="$(stat -c '%s:%Y' -- "$log" 2>/dev/null || true)"
            if [ "$signature" != "$previous" ]; then
                previous="$signature"
                quiet_since=$SECONDS
            elif [ $((SECONDS - quiet_since)) -ge "$settle" ]; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

# Live quits through its own UI first: live-trial-dialog quit-live (Ctrl+Q, the quit-time trial
# dialog, WM_CLOSE) leaves no crash-recovery state behind. It acts on the one Live of the machine,
# so it runs only while every Live process is runner-owned. TERM and then KILL by exact pid remain
# the fallback; after a signal, `state clean-crash` removes the crash-recovery files the next
# launch would otherwise offer to restore.
quit_owned_live()
{
    local pids="$1" foreign
    [ -n "$pids" ] || return 0
    [ -x "$quit_tool" ] || return 1
    foreign="$(global_live_pids | grep -vxF -f <(printf '%s\n' "$pids") || true)"
    if [ -n "$foreign" ]; then
        printf 'bench-suite: another Live session is running (pid(s): %s); not quitting through the UI\n' \
            "$(printf '%s' "$foreign" | tr '\n' ' ')" >&2
        return 1
    fi
    "$session_env_tool" "$quit_tool" quit-live --timeout 60 >&2 || return 1
    [ -z "$(owned_live_pids)" ]
}

stop_owned_session()
{
    local pids pid deadline remaining="" rc=0 quit=0
    [ -n "$active_token" ] || return 0
    pids="$(owned_live_pids)"
    if [ -n "$pids" ]; then
        if quit_owned_live "$pids"; then
            quit=1
        else
            printf 'bench-suite: Live did not quit through its UI; sending TERM to the owned pid(s)\n' >&2
        fi
    fi
    pids="$(owned_live_pids)"
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"
    deadline=$((SECONDS + 15))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining="$(owned_live_pids)"
        [ -z "$remaining" ] && break
        sleep 0.2
    done
    # Live can remain active after TERM. Check the run value again before KILL.
    # Send KILL to the exact process ID.
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        kill -KILL "$pid" 2>/dev/null || true
    done <<< "$remaining"
    if [ -n "$launcher_pid" ]; then
        deadline=$((SECONDS + 20))
        while kill -0 "$launcher_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
        if kill -0 "$launcher_pid" 2>/dev/null; then
            if ableton_pid_has_env "$launcher_pid" "ABLETON_BENCH_RUN_ID=$active_token"; then
                kill -TERM "$launcher_pid" 2>/dev/null || true
                deadline=$((SECONDS + 5))
                while kill -0 "$launcher_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
                if kill -0 "$launcher_pid" 2>/dev/null \
                   && ableton_pid_has_env "$launcher_pid" "ABLETON_BENCH_RUN_ID=$active_token"; then
                    kill -KILL "$launcher_pid" 2>/dev/null || true
                fi
            else
                printf 'bench-suite: refusing to signal reused/unowned launcher pid %s\n' "$launcher_pid" >&2
                rc=1
            fi
        fi
        wait "$launcher_pid" 2>/dev/null || true
    fi
    # Signalled, or already gone (crashed) before the stop: either way Live left
    # its crash-recovery files behind.
    if [ "$quit" -ne 1 ] && [ -x "$state_tool" ]; then
        "$state_tool" clean-crash >&2 \
            || printf 'bench-suite: state clean-crash failed after Live ended without a UI quit\n' >&2
    fi
    active_token=""
    launcher_pid=""
    return "$rc"
}

# The tracer runs as root. The helper (root-only, reached through its sudoers
# rule with sudo -n) finds its own copy of the tool and takes the tool
# arguments after --; sudo runs the configured tracer directly.
trace_run()
{
    local verb="$1"
    shift
    case "$privilege" in
        root-helper)
            if [ "$verb" = start ]; then
                helper_trace_start "$@"
            else
                "$sudo" -n -- "$root_helper" trace "$verb" --tool wine-trace --run-dir "$output" -- "$@"
            fi
            ;;
        sudo) "$sudo" -n -- "$tracer" "$verb" "$@" ;;
        *) return 1 ;;
    esac
}

# The helper's `trace start` returns once the tool runs in the background, but
# wine-trace start needs seconds to attach. Wait for its own verdict, the
# "wine-trace: started:" or "wine-trace: error:" line it appends to the
# helper's trace/wine-trace.err, so the measurement window opens only on an
# attached tracer and a failed start fails the run.
helper_trace_start()
{
    local err="$output/trace/wine-trace.err" seen=0 deadline line
    [ ! -f "$err" ] || seen="$(wc -l < "$err")"
    "$sudo" -n -- "$root_helper" trace start --tool wine-trace --run-dir "$output" -- "$@" || return 1
    deadline=$((SECONDS + ${ABLETON_BENCH_TRACE_START_TIMEOUT:-180}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        line="$(tail -n +"$((seen + 1))" "$err" 2>/dev/null | grep -E '^wine-trace: (started|error):' | head -n 1 || true)"
        case "$line" in
            "wine-trace: started:"*) return 0 ;;
            "wine-trace: error:"*) printf 'bench-suite: %s\n' "$line" >&2; return 1 ;;
        esac
        sleep 0.5
    done
    printf 'bench-suite: the tracer reported no start within %ss (%s)\n' \
        "${ABLETON_BENCH_TRACE_START_TIMEOUT:-180}" "$err" >&2
    return 1
}

# The output directory is created as the user so the files stay readable
# after the run. Every owned Live process is attached.
trace_active=""
trace_start()
{
    local pid args=()
    [ "$trace" != off ] || return 0
    mkdir -p -- "$set_dir/raw/interface"
    args=(--out "$set_dir/raw/interface" --run-id "$active_token")
    for pid in "${current_live[@]}"; do args+=(--pid "$pid"); done
    args+=(--mode "$trace_tool_mode")
    trace_run start "${args[@]}" || fail "tracer did not start for $set_name"
    trace_active="$set_dir/raw/interface"
}

trace_stop()
{
    local out="$trace_active"
    [ -n "$out" ] || return 0
    trace_active=""
    trace_run stop --out "$out"
}

finish()
{
    local rc=$? status=failed
    trap - EXIT HUP INT TERM
    trace_stop || true
    stop_owned_session || true
    if [ "$finalized" -ne 1 ]; then
        [ "$rc" -lt 128 ] || status=interrupted
        python3 "$here/bench-report.py" update-run --output "$output/run.json" --status "$status" 2>/dev/null || true
        python3 "$here/bench-report.py" render --run-dir "$output" 2>/dev/null || true
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for index in "${!sets[@]}"; do
    set_name="${sets[index]}"
    existing_live="$(global_live_pids)"
    [ -z "$existing_live" ] \
        || fail "another Live session appeared before $set_name (pid(s): $(printf '%s' "$existing_live" | tr '\n' ' '))"
    set_file="$(set_file_for "$set_name")"
    set_dir="$output/sets/$(printf '%02d' "$((index + 1))")-$set_name"
    mkdir -p -- "$set_dir/raw"
    mode=playback
    osc=on
    if [ "$set_name" = Benchmark_Zero ]; then mode=idle-no-controller; osc=off; fi
    if [ -n "$scenario" ]; then mode=scenario; osc=on; fi
    active_token="$run_id:$set_name"
    printf '== %d/%d %s: start Live ==\n' "$((index + 1))" "${#sets[@]}" "$set_name"
    ABLETON_BENCH_RUN_ID="$active_token" setsid -- "$launcher" "$set_file" \
        > "$set_dir/raw/launcher.log" 2>&1 &
    launcher_pid=$!
    mapfile -t current_live < <(wait_for_owned_live)
    [ "${#current_live[@]}" -gt 0 ] || fail "no owned Live pid was returned"
    if [ "$index" -eq 0 ]; then
        python3 "$here/bench-report.py" refresh-live \
            --profile "$output/profile/profile.json" \
            --prefix "$ABLETON_WINEPREFIX"
    fi

    # The tracer starts before the settle time so attaching does not disturb
    # the measurement. A scenario prepares the set itself instead of playing.
    if [ "$osc" = on ]; then
        python3 "$here/bench-osc.py" probe --timeout "$launch_timeout" \
            > "$set_dir/raw/osc-probe.txt" 2> "$set_dir/raw/osc-probe.stderr.txt" \
            || fail "$set_name control device did not answer (no /abl/bench/pong on UDP $ABL_BENCH_OSC_RECV within ${launch_timeout}s; $control_hint)"
        wait_log_quiet || fail "$set_name log did not settle within ${launch_timeout}s"
        if [ "$mode" = scenario ]; then
            python3 "$scenario_tool" setup --scenario "$scenario" \
                || fail "$set_name scenario setup failed: $scenario"
        else
            python3 "$here/bench-osc.py" send /abl/bench/rewind
            python3 "$here/bench-osc.py" send /abl/bench/play
        fi
        trace_start
        sleep "$settle"
    else
        wait_log_quiet || fail "$set_name log did not settle within ${launch_timeout}s"
        if [ "$trace" != off ]; then trace_start; sleep "$settle"; fi
    fi

    printf '== %d/%d %s: measure for %ss ==\n' "$((index + 1))" "${#sets[@]}" "$set_name" "$duration"
    set_sha256="$(sha256sum -- "$set_file")"
    capture_args=(
        --duration "$duration"
        --output-dir "$set_dir"
        --set-name "$set_name"
        --mode "$mode"
        --run-id "$active_token"
        --osc "$osc"
        --manual-crackle "${crackle[$set_name]:-not-provided}"
        --log "$set_dir/raw/launcher.log"
        --set-sha256 "${set_sha256%% *}"
        --trace-mode "$trace"
    )
    [ -z "$scenario" ] || capture_args+=(--scenario "$scenario" --scenario-tool "$scenario_tool")
    for pid in "${current_live[@]}"; do capture_args+=(--live-pid "$pid"); done
    "$here/bench-run.sh" "${capture_args[@]}"
    if [ "$trace" != off ]; then
        trace_stop || fail "tracer did not stop for $set_name"
        # Exit 2 means the tracer left no usable output. The measurement keeps
        # its confounder and the run continues.
        interface_rc=0
        python3 "$here/bench-report.py" interface --set-dir "$set_dir" || interface_rc=$?
        [ "$interface_rc" -eq 0 ] || [ "$interface_rc" -eq 2 ] \
            || fail "interface post-processing failed for $set_name"
    fi
    [ "$osc" = off ] || python3 "$here/bench-osc.py" send /abl/bench/stop || true
    stop_owned_session || fail "could not end only the runner-owned $set_name session"

    # The launcher closes its agents. Wait up to 30 seconds for Max and helper
    # clients to leave the prefix before the next set.
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        holders="$(ableton_prefix_unknown_holders)"
        [ -z "$holders" ] && break
        sleep 0.5
    done
    [ -z "${holders:-}" ] || fail "unknown clients still hold the prefix after $set_name: $(printf '%s' "$holders" | tr '\n' ' ')"
done

python3 "$here/bench-report.py" update-run --output "$output/run.json" --status complete
python3 "$here/bench-report.py" render --run-dir "$output"
csv_path=""
for candidate in "$output"/*_cpu-benchmark.csv; do
    [ -f "$candidate" ] || continue
    [ -z "$csv_path" ] || fail "the report contains more than one CPU benchmark CSV"
    csv_path="$candidate"
done
[ -n "$csv_path" ] || fail "the report CSV is missing"
finalized=1
printf 'report: %s\n' "$output/report.md"
printf 'csv: %s\n' "$csv_path"
