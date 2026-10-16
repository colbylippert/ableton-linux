#!/usr/bin/env bash
# Measure one Live set that is already open. The full suite normally calls the
# command. You can also open a set and run the command by hand.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib/config.sh"
ableton_config_init
. "$here/lib/lifecycle.sh"

duration="${ABLETON_BENCH_DURATION:-30}"
output=""
set_name="manual"
mode="playback"
run_id="manual-$$"
osc=on
manual_crackle=not-provided
node_pattern="${BENCH_PW_NODE_RE:-Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]}"
scenario=""
scenario_tool="${ABLETON_BENCH_SCENARIO_TOOL:-$here/../profiler/control/scenario-run.py}"
set_sha256=""
trace_mode=""
live_pids=()
logs=()

usage()
{
    cat <<'EOF'
usage: scripts/bench-run.sh --output-dir DIR [options]

  --duration SECONDS       measurement time for CPU, Live, and PipeWire (default 30; minimum 10)
  --set-name NAME          set name stored in measurement.json
  --mode MODE              playback, idle-no-controller, or scenario
  --run-id ID              suite run label
  --live-pid PID           Live process ID; repeat for each process
  --log PATH               extra log file; repeat for each file
  --osc on|off             control messages; Benchmark_Zero uses off
  --manual-crackle STATE   heard, not-heard, not-provided, or unknown
  --node-pattern REGEX     PipeWire node name pattern
  --scenario NAME          scenario the driver runs during the window (mode scenario)
  --scenario-tool PATH     scenario driver (default profiler/control/scenario-run.py)
  --set-sha256 HEX         SHA-256 of the open set, stored in measurement.json
  --trace-mode MODE        off, interface, or drilldown, stored in measurement.json

The command writes source data and measurement.json. Open Live before you run
it. The command reads Wine and PipeWire state while Live remains open.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --duration) shift; duration="${1:-}" ;;
        --output-dir) shift; output="${1:-}" ;;
        --set-name) shift; set_name="${1:-}" ;;
        --mode) shift; mode="${1:-}" ;;
        --run-id) shift; run_id="${1:-}" ;;
        --live-pid) shift; live_pids+=("${1:-}") ;;
        --log) shift; logs+=("${1:-}") ;;
        --osc) shift; osc="${1:-}" ;;
        --manual-crackle) shift; manual_crackle="${1:-}" ;;
        --node-pattern) shift; node_pattern="${1:-}" ;;
        --scenario) shift; scenario="${1:-}" ;;
        --scenario-tool) shift; scenario_tool="${1:-}" ;;
        --set-sha256) shift; set_sha256="${1:-}" ;;
        --trace-mode) shift; trace_mode="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "bench-run: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$duration" in ''|*[!0-9]*) echo "bench-run: duration must be a whole number of seconds" >&2; exit 2 ;; esac
[ "$duration" -ge 10 ] && [ "$duration" -le 3600 ] \
    || { echo "bench-run: duration must be between 10 and 3600 seconds" >&2; exit 2; }
[ -n "$output" ] || { echo "bench-run: --output-dir is required" >&2; exit 2; }
case "$mode" in playback|idle-no-controller|scenario) ;; *) echo "bench-run: invalid mode: $mode" >&2; exit 2 ;; esac
[ "$mode" != scenario ] || [ -n "$scenario" ] || { echo "bench-run: mode scenario needs --scenario NAME" >&2; exit 2; }
case "$osc" in on|off) ;; *) echo "bench-run: --osc must be on or off" >&2; exit 2 ;; esac
case "$manual_crackle" in heard|not-heard|not-provided|unknown) ;;
    *) echo "bench-run: invalid manual crackle state: $manual_crackle" >&2; exit 2 ;;
esac
[ -z "$set_sha256" ] || [[ "$set_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "bench-run: --set-sha256 wants 64 hex digits" >&2; exit 2; }
case "$trace_mode" in ''|off|interface|drilldown) ;;
    *) echo "bench-run: --trace-mode must be off, interface, or drilldown" >&2; exit 2 ;;
esac

if [ "${#live_pids[@]}" -eq 0 ]; then
    mapfile -t live_pids < <(ableton_live_pids)
fi
[ "${#live_pids[@]}" -gt 0 ] || {
    echo "bench-run: no Live process matches the configured runtime and prefix" >&2
    exit 1
}

args=(
    capture
    --output "$output"
    --set-name "$set_name"
    --mode "$mode"
    --run-id "$run_id"
    --duration "$duration"
    --prefix "$ABLETON_WINEPREFIX"
    --wine-root "$ABLETON_WINE_ROOT"
    --osc "$osc"
    --osc-tool "$here/bench-osc.py"
    --manual-crackle "$manual_crackle"
    --node-pattern "$node_pattern"
)
for pid in "${live_pids[@]}"; do args+=(--live-pid "$pid"); done
for log in "${logs[@]}"; do args+=(--log "$log"); done
[ -z "$scenario" ] || args+=(--scenario "$scenario" --scenario-tool "$scenario_tool")
[ -z "$set_sha256" ] || args+=(--set-sha256 "$set_sha256")
[ -z "$trace_mode" ] || args+=(--trace-mode "$trace_mode")

exec python3 "$here/bench-report.py" "${args[@]}"
