#!/usr/bin/env bash
# profiler/setup/lib/log.sh — colour, logging and summary library for the
# profiler setup scripts. Sourced, never executed. Needs bash >= 4.4.
#
# Public API
#   log_colors_init            (re)compute the colour/glyph variables. Colour only
#                              when fd 3 (the terminal) is a tty, NO_COLOR is unset
#                              and TERM is not "dumb"; the driver sets NO_COLOR=1
#                              for --no-color. Glyphs are UTF-8 when the locale
#                              (LC_ALL/LC_CTYPE/LANG) is UTF-8, ASCII otherwise.
#                              Exports C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW
#                              C_BLUE C_CYAN and G_STEP G_OK G_WARN G_FAIL G_SKIP
#                              G_INFO G_BAR G_RULE.
#   log_init [LOGFILE]         `exec 3>&1` keeps the terminal on fd 3, creates
#                              ~/.local/state/profiler, opens LOGFILE (default
#                              setup-<UTC ts>.log there) and refreshes the
#                              setup-latest.log symlink. Every message goes
#                              coloured to fd 3 and ANSI-free to the file.
#   section N TOTAL NAME       bold cyan rule: "══ [03/18] packages ═══…"
#   step MSG                   "→ MSG"
#   ok MSG                     green "✓ MSG"
#   warn MSG                   yellow "⚠ MSG"; WARN_COUNT++ and recorded for the summary
#   fail MSG                   red "✗ MSG"; FAIL_COUNT++, recorded; RETURNS 1 so that
#                              callers can write `fail "…" || return 1`
#   skip MSG                   dim "↷ MSG"
#   info MSG                   blue "i MSG"
#   kv KEY VALUE               aligned detail line "      key ............ value"
#   die MSG [CODE]             fail-styled message, then exit CODE (default 1)
#   action_required TEXT       add a line to the ACTIONS REQUIRED block of the summary
#   run [--quiet] [--sudo] [--timeout S] [--allow-fail] -- CMD ARGS…
#                              prints the command dimmed ("  $ …"). DRY_RUN=1 →
#                              prints "[dry-run]" and returns 0 without executing.
#                              Otherwise streams stdout+stderr into the log file and,
#                              unless --quiet, to the terminal indented "    │ ".
#                              --sudo prefixes `sudo -n --` (never prompts itself;
#                              when lib/phase.sh is loaded, the first --sudo use of a
#                              run calls sudo_keepalive_start, which asks for the
#                              password once unless NOPASSWD is in force);
#                              --timeout wraps the command in `timeout -k 10 S`.
#                              On a non-zero exit it calls `fail` with the exit code
#                              and shows the last 20 output lines, and returns 1 —
#                              unless --allow-fail, which returns the command's own
#                              exit code silently (RUN_STATUS holds it either way).
#                              Use it in a condition: `if run --allow-fail -- …; then`.
#   summary_add NAME STATUS SECONDS NOTE
#                              record one row (status ∈ ok|skipped|warn|failed|
#                              not-run|dry-run)
#   summary_table              print the table, WARNINGS, FAILURES, ACTIONS REQUIRED
#                              and the log path (guarded: prints at most once)
#   strip_ansi STRING          pure-bash ANSI stripper (prints the result)
#   now_hms                    prints HH:MM:SS
#
# Every terminal line carries "[HH:MM:SS]". Messages never go to stdout/stderr
# directly: fd 3 is the terminal, so command-output capture (`$(…)`) around a
# phase function cannot swallow them.
#
# Variables read: NO_COLOR, TERM, DRY_RUN, LC_ALL/LC_CTYPE/LANG, COLUMNS,
# PROFILER_STATE_DIR (default ~/.local/state/profiler).
# Variables owned: LOGFILE LOG_FD WARN_COUNT FAIL_COUNT WARN_MSGS[] FAIL_MSGS[]
# ACTIONS[] RUN_STATUS SUMMARY_* .

[ -n "${BASH_VERSION:-}" ] || { echo "log.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }

: "${WARN_COUNT:=0}"
: "${FAIL_COUNT:=0}"
: "${LOGFILE:=}"
: "${LOG_FD:=1}"
: "${RUN_STATUS:=0}"
: "${SUMMARY_PRINTED:=0}"
declare -a WARN_MSGS=() FAIL_MSGS=() ACTIONS=()
declare -a SUMMARY_NAMES=() SUMMARY_STATUS=() SUMMARY_SECS=() SUMMARY_NOTES=()

# ---------------------------------------------------------------- colours ----
log_colors_init() {
    local use_color=1 utf8=0 loc
    [ -z "${NO_COLOR:-}" ] || use_color=0
    [ "${TERM:-}" != "dumb" ] || use_color=0
    if [ "$use_color" -eq 1 ]; then
        if [ -t "$LOG_FD" ]; then :; elif [ "$LOG_FD" -ne 1 ] && [ -t 1 ]; then :; else use_color=0; fi
    fi
    if [ "$use_color" -eq 1 ]; then
        C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
        C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m' C_CYAN=$'\033[36m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    fi
    loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "${loc,,}" in *utf-8*|*utf8*) utf8=1 ;; esac
    if [ "$utf8" -eq 1 ]; then
        G_STEP='→' G_OK='✓' G_WARN='⚠' G_FAIL='✗' G_SKIP='↷' G_INFO='i' G_BAR='│' G_RULE='═'
    else
        G_STEP='>' G_OK='OK' G_WARN='!!' G_FAIL='XX' G_SKIP='~' G_INFO='i' G_BAR='|' G_RULE='='
    fi
    LOG_COLOR="$use_color"
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_CYAN
    export G_STEP G_OK G_WARN G_FAIL G_SKIP G_INFO G_BAR G_RULE LOG_COLOR
}
log_colors_init

now_hms() { printf '%(%H:%M:%S)T\n' -1; }

strip_ansi() {
    local s="$1" re=$'\033''\[[0-9;?]*[A-Za-z]'
    while [[ $s =~ $re ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
    printf '%s\n' "$s"
}

# ------------------------------------------------------------------- init ----
log_init() {
    local dir ts
    exec 3>&1
    LOG_FD=3
    log_colors_init
    dir="${PROFILER_STATE_DIR:-$HOME/.local/state/profiler}"
    if [ -n "${1:-}" ]; then
        LOGFILE="$1"; dir="$(dirname -- "$LOGFILE")"
    else
        ts="$(date -u +%Y%m%dT%H%M%SZ)"
        LOGFILE="$dir/setup-$ts.log"
    fi
    mkdir -p -- "$dir" 2>/dev/null || { LOGFILE=""; warn "cannot create $dir; continuing without a log file"; return 0; }
    if : >> "$LOGFILE" 2>/dev/null; then
        ln -sfn -- "$(basename -- "$LOGFILE")" "$dir/setup-latest.log" 2>/dev/null || true
        printf '# profiler setup log — %s — %s (pid %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${0##*/}" "$$" >> "$LOGFILE"
    else
        LOGFILE=""
        warn "cannot write $LOGFILE; continuing without a log file"
    fi
    export LOGFILE LOG_FD
}

# write one plain (ANSI-free) line to the log file
_log_file() {
    [ -n "$LOGFILE" ] || return 0
    printf '%s\n' "$(strip_ansi "$1")" >> "$LOGFILE" 2>/dev/null || true
}

# _emit COLOR GLYPH INDENT MSG  — coloured to the terminal, plain to the file
_emit() {
    local color="$1" glyph="$2" indent="$3" msg="$4" ts
    ts="$(now_hms)"
    printf '%s[%s]%s %s%s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$indent" "$color" "$glyph" "$C_RESET" "$msg" >&"$LOG_FD"
    _log_file "[$ts] $indent$glyph $msg"
}

# ------------------------------------------------------------- messages ----
_term_width() {
    local w="${COLUMNS:-}"
    if [ -z "$w" ] && [ -t "$LOG_FD" ] && command -v tput >/dev/null 2>&1; then
        w="$(tput cols 2>/dev/null || true)"
    fi
    [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -ge 40 ] || w=80
    [ "$w" -le 110 ] || w=110
    printf '%s\n' "$w"
}

section() {
    local n="$1" total="$2" name="$3" ts head rule width i
    ts="$(now_hms)"
    head="$G_RULE$G_RULE [$n/$total] $name "
    width="$(_term_width)"
    rule=""
    for (( i = ${#head} + 11; i < width; i++ )); do rule+="$G_RULE"; done
    printf '\n' >&"$LOG_FD"
    printf '%s[%s]%s %s%s%s%s%s\n' "$C_DIM" "$ts" "$C_RESET" "$C_BOLD" "$C_CYAN" "$head" "$rule" "$C_RESET" >&"$LOG_FD"
    _log_file ""
    _log_file "[$ts] $head$rule"
}

step() { _emit "$C_BOLD"   "$G_STEP" "  " "$*"; }
ok()   { _emit "$C_GREEN"  "$G_OK"   "  " "$*"; }
skip() { _emit "$C_DIM"    "$G_SKIP" "  " "$C_DIM$*$C_RESET"; }
info() { _emit "$C_BLUE"   "$G_INFO" "  " "$*"; }
warn() {
    WARN_COUNT=$(( WARN_COUNT + 1 ))
    WARN_MSGS+=("${CURRENT_PHASE:+[$CURRENT_PHASE] }$*")
    _emit "$C_YELLOW" "$G_WARN" "  " "$C_YELLOW$*$C_RESET"
}
fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    FAIL_MSGS+=("${CURRENT_PHASE:+[$CURRENT_PHASE] }$*")
    _emit "$C_RED" "$G_FAIL" "  " "$C_RED$*$C_RESET"
    return 1
}
kv() {
    local key="$1" value="${2:-}" dots pad
    pad=$(( 22 - ${#key} )); [ "$pad" -gt 1 ] || pad=1
    printf -v dots '%*s' "$pad" ''
    dots="${dots// /.}"
    _emit "$C_DIM" "$key $dots" "      " "$value"
}
die() {
    local msg="$1" code="${2:-1}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    FAIL_MSGS+=("${CURRENT_PHASE:+[$CURRENT_PHASE] }$msg")
    _emit "$C_RED" "$G_FAIL" "" "$C_BOLD$C_RED$msg$C_RESET"
    exit "$code"
}
action_required() { ACTIONS+=("$*"); }

# ---------------------------------------------------------------- run ----
# shell-safe rendering of a command line for display
_fmt_cmd() {
    local a out=""
    for a in "$@"; do
        if [[ "$a" =~ ^[A-Za-z0-9_./=:,@+%^-]+$ ]]; then out+="$a "; else out+="$(printf '%q' "$a") "; fi
    done
    printf '%s\n' "${out% }"
}

# reads the command's output on stdin: terminal (unless quiet), log file, tail file
_run_stream() {
    local quiet="$1" tailf="$2" line ts
    while IFS= read -r line || [ -n "$line" ]; do
        ts="$(now_hms)"
        printf '%s\n' "$line" >> "$tailf"
        if [ "$quiet" -eq 0 ]; then
            printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        fi
        _log_file "[$ts]     $G_BAR $line"
    done
}

run() {
    local quiet=0 use_sudo=0 tmo="" allow_fail=0 errexit=0 rc tailf shown
    local -a cmd=() wrapped=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet) quiet=1 ;;
            --sudo) use_sudo=1 ;;
            --timeout) tmo="$2"; shift ;;
            --timeout=*) tmo="${1#*=}" ;;
            --allow-fail) allow_fail=1 ;;
            --) shift; break ;;
            *) fail "run: unknown option $1 (options go before --)"; return 1 ;;
        esac
        shift
    done
    cmd=("$@")
    [ "${#cmd[@]}" -gt 0 ] || { fail "run: no command given"; return 1; }
    wrapped=("${cmd[@]}")
    [ "$use_sudo" -eq 0 ] || wrapped=(sudo -n -- "${wrapped[@]}")
    [ -z "$tmo" ] || wrapped=(timeout -k 10 "$tmo" "${wrapped[@]}")
    shown="$(_fmt_cmd "${wrapped[@]}")"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        _emit "$C_CYAN" "[dry-run]" "  " "$C_DIM\$ $shown$C_RESET"
        RUN_STATUS=0
        return 0
    fi
    if [ "$use_sudo" -eq 1 ] && declare -F sudo_keepalive_start >/dev/null 2>&1; then
        sudo_keepalive_start || true     # lib/phase.sh: first use prompts once / starts the refresher; a failure surfaces below
    fi
    _emit "$C_DIM" "\$" "  " "$C_DIM$shown$C_RESET"
    tailf="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/profiler-run.XXXXXX")" || { fail "run: mktemp failed"; return 1; }
    [[ $- == *e* ]] && errexit=1
    set +e
    "${wrapped[@]}" 2>&1 < /dev/null | _run_stream "$quiet" "$tailf"
    rc="${PIPESTATUS[0]}"
    [ "$errexit" -eq 0 ] || set -e
    RUN_STATUS="$rc"
    if [ "$rc" -ne 0 ]; then
        if [ "$allow_fail" -eq 1 ]; then
            rm -f -- "$tailf"
            return "$rc"
        fi
        if [ "$rc" -eq 124 ] && [ -n "$tmo" ]; then
            fail "command timed out after ${tmo}s: $shown" || true
        else
            fail "command failed (exit $rc): $shown" || true
        fi
        if [ -s "$tailf" ]; then
            info "last 20 output lines:"
            while IFS= read -r line; do
                printf '%s     %s%s%s %s\n' "$C_DIM" "$C_RED" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
            done < <(tail -n 20 -- "$tailf")
        fi
        rm -f -- "$tailf"
        return 1
    fi
    rm -f -- "$tailf"
    return 0
}

# ------------------------------------------------------------ summary ----
summary_add() {
    SUMMARY_NAMES+=("$1"); SUMMARY_STATUS+=("$2"); SUMMARY_SECS+=("${3:-0}"); SUMMARY_NOTES+=("${4:-}")
}

_fmt_secs() {
    local s="${1%%.*}" m
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    if [ "$s" -ge 3600 ]; then printf '%dh%02dm\n' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif [ "$s" -ge 60 ]; then printf '%dm%02ds\n' $(( s / 60 )) $(( s % 60 ))
    else printf '%ss\n' "$s"; fi
}

_status_color() {
    case "$1" in
        ok) printf '%s' "$C_GREEN" ;;
        warn) printf '%s' "$C_YELLOW" ;;
        failed) printf '%s' "$C_RED" ;;
        dry-run) printf '%s' "$C_CYAN" ;;
        *) printf '%s' "$C_DIM" ;;
    esac
}

summary_table() {
    [ "$SUMMARY_PRINTED" -eq 0 ] || return 0
    SUMMARY_PRINTED=1
    local i n w1=5 w2=7 w3=4 line plain color m
    n="${#SUMMARY_NAMES[@]}"
    for (( i = 0; i < n; i++ )); do
        [ "${#SUMMARY_NAMES[i]}" -le "$w1" ] || w1="${#SUMMARY_NAMES[i]}"
        [ "${#SUMMARY_STATUS[i]}" -le "$w2" ] || w2="${#SUMMARY_STATUS[i]}"
    done
    printf '\n' >&"$LOG_FD"; _log_file ""
    printf -v line '  %s%-*s  %-*s  %*s  %s%s' "$C_BOLD" "$w1" "phase" "$w2" "status" "$w3" "time" "note" "$C_RESET"
    printf '%s\n' "$line" >&"$LOG_FD"; _log_file "$line"
    printf -v plain '  %-*s  %-*s  %*s  %s' "$w1" "-----" "$w2" "------" "$w3" "----" "----"
    printf '%s%s%s\n' "$C_DIM" "$plain" "$C_RESET" >&"$LOG_FD"; _log_file "$plain"
    for (( i = 0; i < n; i++ )); do
        color="$(_status_color "${SUMMARY_STATUS[i]}")"
        printf -v plain '  %-*s  %-*s  %*s  %s' "$w1" "${SUMMARY_NAMES[i]}" "$w2" "${SUMMARY_STATUS[i]}" "$w3" "$(_fmt_secs "${SUMMARY_SECS[i]}")" "${SUMMARY_NOTES[i]}"
        printf '  %-*s  %s%-*s%s  %*s  %s\n' "$w1" "${SUMMARY_NAMES[i]}" "$color" "$w2" "${SUMMARY_STATUS[i]}" "$C_RESET" "$w3" "$(_fmt_secs "${SUMMARY_SECS[i]}")" "${SUMMARY_NOTES[i]}" >&"$LOG_FD"
        _log_file "$plain"
    done
    if [ "${#WARN_MSGS[@]}" -gt 0 ]; then
        printf '\n  %s%sWARNINGS (%d)%s\n' "$C_BOLD" "$C_YELLOW" "${#WARN_MSGS[@]}" "$C_RESET" >&"$LOG_FD"; _log_file ""; _log_file "  WARNINGS (${#WARN_MSGS[@]})"
        for m in "${WARN_MSGS[@]}"; do printf '    %s%s%s %s\n' "$C_YELLOW" "$G_WARN" "$C_RESET" "$m" >&"$LOG_FD"; _log_file "    $G_WARN $m"; done
    fi
    if [ "${#FAIL_MSGS[@]}" -gt 0 ]; then
        printf '\n  %s%sFAILURES (%d)%s\n' "$C_BOLD" "$C_RED" "${#FAIL_MSGS[@]}" "$C_RESET" >&"$LOG_FD"; _log_file ""; _log_file "  FAILURES (${#FAIL_MSGS[@]})"
        for m in "${FAIL_MSGS[@]}"; do printf '    %s%s%s %s\n' "$C_RED" "$G_FAIL" "$C_RESET" "$m" >&"$LOG_FD"; _log_file "    $G_FAIL $m"; done
    fi
    if [ "${#ACTIONS[@]}" -gt 0 ]; then
        printf '\n  %s%sACTIONS REQUIRED%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&"$LOG_FD"; _log_file ""; _log_file "  ACTIONS REQUIRED"
        for m in "${ACTIONS[@]}"; do printf '    %s%s%s %s\n' "$C_CYAN" "$G_STEP" "$C_RESET" "$m" >&"$LOG_FD"; _log_file "    $G_STEP $m"; done
    fi
    if [ -n "$LOGFILE" ]; then
        printf '\n  %slog:%s %s\n' "$C_DIM" "$C_RESET" "$LOGFILE" >&"$LOG_FD"; _log_file ""; _log_file "  log: $LOGFILE"
    fi
    printf '\n' >&"$LOG_FD"
}
