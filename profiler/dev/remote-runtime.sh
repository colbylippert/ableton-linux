#!/usr/bin/env bash
# profiler/dev/remote-runtime.sh — the runtime host's half of "build on one
# machine, run on another" (wine-dev.sh sync --remote HOST, build-official.sh
# --remote HOST). It is never run in place: the build host pipes it over ssh,
#
#     ssh HOST "printf %s <base64 of this file> | base64 -d | bash -s -- SUBCOMMAND ARGS..."
#
# so the runtime host needs no checkout at a matching commit (only bash,
# coreutils, flock and rsync), and its login shell (the laptop's is fish) only
# ever parses one plain pipeline.
#
# Every subcommand that replaces runtime files holds the shared session lock
# ~/.local/state/profiler/live-session.lock, the lock every Live session, trace
# and bench run holds, so nothing is replaced in the middle of a trial, not even
# in the seconds between two of its runs.
#
#   probe                         key=value facts about this host; creates nothing
#                                 but ~/.local/state/profiler
#   seed-dev [--lock-wait S]      first sync: cp -a --reflink=auto the official
#                                 runtime to the dev runtime (instant on btrfs)
#   install KIT [--runtime-root DIR] [--lock-wait S]
#                                 KIT/scripts/installer.sh runtime install --yes, then
#                                 check the installed BUILD-INFO against KIT/dist/
#                                 (KIT = the build's source snapshot + its dist/ outputs)
#   prune-kits KEEP               keep the newest KEEP kits in ~/.local/share/profiler/kits
#
# --lock-wait S: wait up to S seconds for the session lock (default 0: refuse at
# once). Exit: 0 ok · 1 failed · 2 usage · 3 session lock held · 4 a process runs
# from a runtime.

set -euo pipefail
export LC_ALL=C.UTF-8

RUNTIME_NAME="wine-d2d1-nspa-11.13"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/profiler"
SESSION_LOCK="$STATE_DIR/live-session.lock"
ABLETON_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config"
KITS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/profiler/kits"
DEV_ROOT="$HOME/.local/opt/$RUNTIME_NAME-dev"

die() { printf '!! %s\n' "$1" >&2; exit "${2:-1}"; }

_kv_file_get() {   # _kv_file_get FILE KEY [DEFAULT] — last key=value line wins
    local file="$1" key="$2" default="${3:-}" line value found=0
    if [ -r "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$key="*) value="${line#*=}"; found=1 ;; esac
        done < "$file"
    fi
    if [ "$found" -eq 1 ]; then printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
}
_official_root() { _kv_file_get "$ABLETON_CONF" runtime_root "$HOME/.local/opt/$RUNTIME_NAME"; }
OFFICIAL_ROOT="$(_official_root)"

_runtime_pids() {   # _runtime_pids ROOT... → "pid<TAB>exe" for processes whose exe lives under a root
    local root proc pid exe r
    local -a roots=()
    for root in "$@"; do
        [ -n "$root" ] && [ -e "$root" ] || continue
        roots+=("$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")")
    done
    [ "${#roots[@]}" -gt 0 ] || return 0
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        exe="$(readlink -f -- "$proc/exe" 2>/dev/null)" || continue
        [ -n "$exe" ] || continue
        for r in "${roots[@]}"; do
            case "$exe" in "$r"/*) printf '%s\t%s\n' "$pid" "$exe"; break ;; esac
        done
    done
    return 0
}

_lock() {   # _lock WAIT — hold the session lock on fd 9 until this script exits
    [[ "$1" =~ ^[0-9]+$ ]] || die "--lock-wait needs whole seconds (got '$1')" 2
    command -v flock >/dev/null 2>&1 || die "flock is missing on $(uname -n)"
    mkdir -p -- "$STATE_DIR"
    exec 9>>"$SESSION_LOCK"
    if [ "$1" -gt 0 ]; then flock -w "$1" 9; else flock -n 9; fi \
        || die "the session lock $SESSION_LOCK on $(uname -n) is held (a trial, bench run or Live session is in progress); retry when it is free, or pass --lock-wait SECONDS" 3
}

# Called with the session lock held, so no new session can start: whatever still
# runs is the tail of one that just ended (wineserver lingers a few seconds after
# its last client), so give it up to 30 s before refusing.
_refuse_if_busy() {
    local busy i
    for i in $(seq 1 30); do
        busy="$(_runtime_pids "$OFFICIAL_ROOT" "$DEV_ROOT")"
        [ -n "$busy" ] || return 0
        [ "$i" -gt 1 ] || printf 'waiting up to 30 s for processes from the runtime(s) to exit\n'
        sleep 1
    done
    printf '%s\n' "$busy" | sed 's/^/   pid /' >&2
    die "processes still run from the runtime(s) on $(uname -n) after 30 s; quit Live (File > Quit) and wait for wineserver" 4
}

cmd_probe() {
    local lock=free pw
    mkdir -p -- "$STATE_DIR"
    if [ -e "$SESSION_LOCK" ] && ! ( exec 8>>"$SESSION_LOCK" && flock -n 8 ) 2>/dev/null; then lock=held; fi
    pw="$(systemctl --user is-active pipewire.service 2>/dev/null || true)"
    printf 'host=%s\n' "$(uname -n)"
    printf 'home=%s\n' "$HOME"
    printf 'session_lock=%s\n' "$SESSION_LOCK"
    printf 'lock=%s\n' "$lock"
    printf 'official_root=%s\n' "$OFFICIAL_ROOT"
    printf 'official_present=%s\n' "$([ -x "$OFFICIAL_ROOT/bin/wine" ] && echo yes || echo no)"
    printf 'official_version=%s\n' "$(sed -n 's/^dist-version: *//p' "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null | head -n1 || true)"
    printf 'dev_root=%s\n' "$DEV_ROOT"
    printf 'dev_present=%s\n' "$([ -d "$DEV_ROOT" ] && echo yes || echo no)"
    printf 'dev_complete=%s\n' "$([ -x "$DEV_ROOT/bin/wine" ] && [ -x "$DEV_ROOT/bin/wineserver" ] && echo yes || echo no)"
    printf 'busy=%s\n' "$(_runtime_pids "$OFFICIAL_ROOT" "$DEV_ROOT" | cut -f1 | tr '\n' ' ' || true)"
    printf 'pipewire=%s\n' "${pw:-unknown}"
    printf 'rsync=%s\n' "$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)"
    printf 'kits_dir=%s\n' "$KITS_DIR"
}

cmd_seed_dev() {
    local wait=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --lock-wait) [ $# -ge 2 ] || die "--lock-wait needs a value" 2; wait="$2"; shift ;;
            *) die "seed-dev: unknown option $1" 2 ;;
        esac
        shift
    done
    _lock "$wait"
    _refuse_if_busy
    if [ -d "$DEV_ROOT" ]; then printf 'dev runtime exists: %s\n' "$DEV_ROOT"; return 0; fi
    [ -x "$OFFICIAL_ROOT/bin/wine" ] || die "no official runtime at $OFFICIAL_ROOT to seed $DEV_ROOT from"
    mkdir -p -- "$(dirname -- "$DEV_ROOT")"
    cp -a --reflink=auto -- "$OFFICIAL_ROOT" "$DEV_ROOT"
    printf 'seeded %s from %s\n' "$DEV_ROOT" "$OFFICIAL_ROOT"
}

cmd_install() {
    local kit="${1:-}" wait=0 rr="" version root
    local -a args=(runtime install --yes)
    [ -n "$kit" ] || die "install needs a KIT directory" 2
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --lock-wait) [ $# -ge 2 ] || die "--lock-wait needs a value" 2; wait="$2"; shift ;;
            --runtime-root) [ $# -ge 2 ] || die "--runtime-root needs a value" 2; rr="$2"; shift ;;
            *) die "install: unknown option $1" 2 ;;
        esac
        shift
    done
    [ -x "$kit/scripts/installer.sh" ] && [ -r "$kit/VERSION" ] || die "$kit is not an installer kit (scripts/installer.sh, VERSION)" 2
    version="$(sed -n '1p' "$kit/VERSION")"
    [ -s "$kit/dist/BUILD-INFO-$version.txt" ] || die "$kit has no dist/BUILD-INFO-$version.txt" 2
    _lock "$wait"
    _refuse_if_busy
    [ -z "$rr" ] || args+=(--runtime-root "$rr")
    printf 'installing from %s on %s (session lock held)\n' "$kit" "$(uname -n)"
    ( cd -- "$kit" && unset ABLETON_WINE_ROOT && ./scripts/installer.sh "${args[@]}" ) < /dev/null
    root="${rr:-$(_official_root)}"
    cmp -s -- "$kit/dist/BUILD-INFO-$version.txt" "$root/ABLETON-WINE-BUILD-INFO.txt" \
        || die "the BUILD-INFO installed at $root differs from $kit/dist/BUILD-INFO-$version.txt"
    printf 'installed: %s is this build (%s)\n' "$root" "$("$root/bin/wine" --version < /dev/null 2>/dev/null || echo 'wine --version failed')"
}

cmd_prune_kits() {
    local keep="${1:-3}" k n=0
    [[ "$keep" =~ ^[1-9][0-9]*$ ]] || die "prune-kits needs a positive count" 2
    [ -d "$KITS_DIR" ] || return 0
    while IFS= read -r k; do
        n=$(( n + 1 ))
        [ "$n" -gt "$keep" ] || continue
        case "${k##*/}" in [0-9]*-[0-9a-f]*) rm -rf -- "$k"; printf 'removed old kit %s\n' "$k" ;; esac
    done < <(ls -1dt -- "$KITS_DIR"/*/ 2>/dev/null | sed 's:/$::')
}

main() {
    [ $# -gt 0 ] || die "usage: remote-runtime.sh probe | seed-dev | install KIT | prune-kits KEEP" 2
    local sub="$1"
    shift
    case "$sub" in
        probe) cmd_probe "$@" ;;
        seed-dev) cmd_seed_dev "$@" ;;
        install) cmd_install "$@" ;;
        prune-kits) cmd_prune_kits "$@" ;;
        *) die "unknown subcommand: $sub" 2 ;;
    esac
}
# Last line on purpose: under `bash -s` the whole script has been read before
# anything runs, so no child can swallow the rest of it from stdin.
main "$@"
