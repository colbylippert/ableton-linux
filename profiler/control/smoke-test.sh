#!/usr/bin/env bash
# Exercise the /abl/bench/* protocol of a running Live through
# scripts/bench-osc.py on AbletonOSC's ports (11000 in, 11001 out): probe, info,
# views, rewind/play (expects "playing 1" and periodic cpu reports), stop. One
# PASS/FAIL/SKIP line per check; the exit code is the number of FAIL lines.
# Without a pong the diagnosis says whether AbletonOSC is installed for the
# prefix Live runs from and whether its log moved after Live started, which
# separates "not selected as a Control Surface" from "installed after launch".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
osc="$root/scripts/bench-osc.py"
report="$root/scripts/bench-report.py"
export ABL_BENCH_OSC_SEND="${ABL_BENCH_OSC_SEND:-11000}"
export ABL_BENCH_OSC_RECV="${ABL_BENCH_OSC_RECV:-11001}"
timeout=20
listen=2
prefix="${ABLETON_WINEPREFIX:-}"
library="${ABLETON_LIBRARY_PATH:-}"
passed=0
failed=0
skipped=0
# Test hook, as in scripts/bench-suite.sh: a fake /proc for the Live check.
proc_root=/proc
[ "${ABLETON_BENCH_TESTING:-0}" != 1 ] || proc_root="${ABLETON_BENCH_PROC_ROOT:-/proc}"

usage()
{
    cat <<'EOF'
usage: profiler/control/smoke-test.sh [--timeout SECONDS] [--listen SECONDS] [--prefix DIR] [--library-path PATH]

  --timeout SECONDS     wait for the first /abl/bench/pong (default 20)
  --listen SECONDS      report window after play and after stop (default 2)
  --prefix DIR          Wine prefix (default: the running Live's WINEPREFIX, else $ABLETON_WINEPREFIX)
  --library-path PATH   the User Library (default: drive_c/users/<user>/{Documents,My Documents}/Ableton/User Library)

Live must be running with AbletonOSC installed (profiler/control/install.sh) and
selected as a Control Surface. Ports come from ABL_BENCH_OSC_SEND/RECV (11000/11001).
EOF
}

fail()
{
    printf 'smoke-test: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout|--listen|--prefix|--library-path)
            [ $# -ge 2 ] || fail "$1 needs a value"
            case "$1" in
                --timeout) timeout="$2" ;;
                --listen) listen="$2" ;;
                --prefix) prefix="$2" ;;
                --library-path) library="$2" ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
done
case "$timeout$listen" in *[!0-9]*) fail "--timeout and --listen take whole seconds" ;; esac
[ "$timeout" -ge 1 ] && [ "$listen" -ge 1 ] || fail "--timeout and --listen must be at least 1"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[ -f "$osc" ] || fail "missing $osc"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

result()
{
    local status="$1" name="$2"
    shift 2
    case "$status" in
        PASS) passed=$((passed + 1)) ;;
        FAIL) failed=$((failed + 1)) ;;
        SKIP) skipped=$((skipped + 1)) ;;
    esac
    printf '%s %s%s\n' "$status" "$name" "${*:+: $*}"
}

summary()
{
    printf 'summary: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
    exit "$failed"
}

live_pids()
{
    local process cmd
    for process in "$proc_root"/[0-9]*; do
        [ -d "$process" ] || continue
        cmd="$(tr '\0' ' ' < "$process/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "${process##*/}" ;; esac
    done
    return 0
}

# Epoch seconds at which a process started: boot time plus its start offset
# (/proc/PID/stat field 22, in clock ticks). The comm field may hold spaces, so
# the fields after the closing parenthesis are what gets split.
process_start_epoch()
{
    local stat_line rest btime hz
    local -a fields
    stat_line="$(cat "$proc_root/$1/stat" 2>/dev/null)" || return 1
    rest="${stat_line##*) }"
    read -r -a fields <<< "$rest"
    [ "${#fields[@]}" -ge 20 ] || return 1
    btime="$(awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null)" || return 1
    hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    [ -n "$btime" ] && [ -n "${fields[19]}" ] || return 1
    printf '%s\n' "$((btime + fields[19] / hz))"
}

# Send ADDRESS [ARGS] and keep the reports of the next SECONDS in FILE. The
# listener binds the response port before the command goes out, since replies
# arrive within a tick.
exchange()
{
    local file="$1" seconds="$2" address="$3" pid
    shift 3
    python3 "$osc" dump --duration "$seconds" > "$file" 2> "$file.err" &
    pid=$!
    sleep 0.3
    python3 "$osc" send "$address" "$@"
    wait "$pid" || true
}

find_library()
{
    local users_dir="$prefix/drive_c/users" wine_user="" candidate
    [ -n "$library" ] || {
        if [ -n "${USER:-}" ] && [ -d "$users_dir/$USER/AppData" ]; then
            wine_user="$USER"
        else
            for candidate in "$users_dir"/*; do
                [ -d "$candidate/AppData" ] || continue
                wine_user="${candidate##*/}"
                break
            done
        fi
        for candidate in "$users_dir/$wine_user/Documents/Ableton/User Library" \
                         "$users_dir/$wine_user/My Documents/Ableton/User Library"; do
            [ -n "$wine_user" ] && [ -d "$candidate" ] || continue
            library="$candidate"
            break
        done
    }
    [ -z "$library" ] || library="$(readlink -f -- "$library" 2>/dev/null || printf '%s' "$library")"
}

no_pong_diagnosis()
{
    local target log live_start log_mtime
    printf 'no /abl/bench/pong within %ss on UDP %s: ' "$timeout" "$ABL_BENCH_OSC_RECV"
    if [ -z "$library" ]; then
        printf 'no User Library found under %s; install with profiler/control/install.sh --prefix %s\n' "$prefix" "$prefix"
        return
    fi
    target="$library/Remote Scripts/AbletonOSC"
    if [ ! -f "$target/manager.py" ] || [ ! -f "$target/abletonosc/bench.py" ]; then
        printf 'AbletonOSC is not installed at %s; run profiler/control/install.sh --prefix %s\n' "$target" "$prefix"
        return
    fi
    printf 'AbletonOSC is installed at %s but not selected as a Control Surface (Preferences > Link, Tempo & MIDI), or Live was started before install. ' "$target"
    log="$target/logs/abletonosc.log"
    if [ ! -f "$log" ]; then
        printf 'No script log at %s: the script has never loaded in this prefix.\n' "$log"
        return
    fi
    log_mtime="$(stat -c %Y -- "$log" 2>/dev/null || echo 0)"
    live_start="$(process_start_epoch "$live_pid" || echo 0)"
    if [ "$live_start" -gt 0 ] && [ "$log_mtime" -ge "$live_start" ]; then
        printf 'The script log was written after Live started (%s >= %s), so the script loaded this session: check the ports (%s/%s) and the log tail:\n' \
            "$(date -d "@$log_mtime" +%H:%M:%S)" "$(date -d "@$live_start" +%H:%M:%S)" "$ABL_BENCH_OSC_SEND" "$ABL_BENCH_OSC_RECV"
        tail -n 3 -- "$log" | sed 's/^/    /'
    else
        printf 'The script log was last written before Live started (%s < %s), so the script did not load this session.\n' \
            "$(date -d "@$log_mtime" +%H:%M:%S)" "$(date -d "@$live_start" +%H:%M:%S)"
    fi
}

live_pid="$(live_pids | sed -n '1p')"
if [ -z "$live_pid" ]; then
    result FAIL live-running "no Ableton Live process; start Live from the prefix with AbletonOSC installed"
    summary
fi
result PASS live-running "pid $live_pid"
if [ -z "$prefix" ]; then
    prefix="$(tr '\0' '\n' < "$proc_root/$live_pid/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p' | sed -n '1p' || true)"
    [ -n "$prefix" ] || prefix="$HOME/.wine-ableton"
fi
prefix="$(readlink -f -- "$prefix" 2>/dev/null || printf '%s' "$prefix")"
find_library

if python3 "$report" check-udp --port "$ABL_BENCH_OSC_RECV" 2> "$tmp/udp.err"; then
    result PASS udp-recv-free "127.0.0.1:$ABL_BENCH_OSC_RECV"
else
    result FAIL udp-recv-free "$(cat "$tmp/udp.err"); another client owns the report port (a suite run, liveosc.py listen)"
    summary
fi

if python3 "$osc" probe --timeout "$timeout" > "$tmp/probe.txt" 2> "$tmp/probe.err"; then
    result PASS probe "$(sed -n '1p' "$tmp/probe.txt")"
else
    result FAIL probe "$(no_pong_diagnosis)"
    for name in info views playing cpu-reports cpu-values stop; do
        result SKIP "$name" "no control surface reply"
    done
    summary
fi

exchange "$tmp/info.txt" 1 /abl/bench/info
line="$(grep ' /abl/bench/info ' "$tmp/info.txt" | sed -n '1p' || true)"
if [ -n "$line" ]; then
    result PASS info "${line#* /abl/bench/info }"
    cpu_attribute_ok="$(printf '%s\n' "$line" | awk '{print $5}')"
    [ "$cpu_attribute_ok" = 1 ] \
        || result FAIL cpu-attribute "Application.average_process_usage is unavailable inside Live (info reports CPU_ATTR_OK=$cpu_attribute_ok)"
else
    result FAIL info "no /abl/bench/info reply within 1s"
fi

exchange "$tmp/views.txt" 1 /abl/bench/views
line="$(grep ' /abl/bench/views ' "$tmp/views.txt" | sed -n '1p' || true)"
if [ -n "$line" ] && [ "$(printf '%s\n' "$line" | awk '{print NF - 2}')" -ge 1 ]; then
    result PASS views "${line#* /abl/bench/views }"
else
    result FAIL views "no /abl/bench/views reply with at least one view name"
fi

# A known state first: "playing 1" is reported on the transition.
python3 "$osc" send /abl/bench/stop
sleep 0.5
python3 "$osc" dump --duration "$listen" > "$tmp/play.txt" 2> "$tmp/play.err" &
dump_pid=$!
sleep 0.3
python3 "$osc" send /abl/bench/rewind
python3 "$osc" send /abl/bench/play
wait "$dump_pid" || true
if grep -q ' /abl/bench/playing 1$' "$tmp/play.txt"; then
    result PASS playing "playing 1 after /abl/bench/play"
else
    result FAIL playing "no '/abl/bench/playing 1' within ${listen}s of /abl/bench/play"
fi
cpu_lines="$(grep -c ' /abl/bench/cpu ' "$tmp/play.txt" || true)"
period_ms="$(awk '$2 == "/abl/bench/cpu" {if (last) {sum += $1 - last; n++}; last = $1} END {if (n) printf "%d", sum / n * 1000}' "$tmp/play.txt")"
if [ "$cpu_lines" -ge 2 ]; then
    result PASS cpu-reports "$cpu_lines reports in ${listen}s, period ${period_ms:-?} ms"
else
    result FAIL cpu-reports "$cpu_lines cpu report(s) in ${listen}s; the handler reports every 500 ms by default"
fi
negative="$(awk '$2 == "/abl/bench/cpu" && ($3 < 0 || $4 < 0)' "$tmp/play.txt" | wc -l)"
last_cpu="$(grep ' /abl/bench/cpu ' "$tmp/play.txt" | tail -n 1 | awk '{print $3 " / " $4}')"
if [ "$cpu_lines" -ge 1 ] && [ "$negative" -eq 0 ]; then
    result PASS cpu-values "average / peak $last_cpu; compare with Live's CPU meter to settle CPU_SCALE in overlay/abletonosc/bench.py"
elif [ "$cpu_lines" -ge 1 ]; then
    result FAIL cpu-values "$negative report(s) carry -1: Application.average_process_usage/peak_process_usage unavailable"
else
    result SKIP cpu-values "no cpu report"
fi

exchange "$tmp/stop.txt" 1 /abl/bench/stop
if grep -q ' /abl/bench/playing 0$' "$tmp/stop.txt"; then
    result PASS stop "playing 0 after /abl/bench/stop"
else
    result FAIL stop "no '/abl/bench/playing 0' within 1s of /abl/bench/stop"
fi
summary
