#!/usr/bin/env bash
# Install the vendored AbletonOSC plus the bench overlay into a Wine prefix's
# User Library: "<User Library>/Remote Scripts/AbletonOSC". Live enumerates
# control surfaces when it starts, so the copy happens while Live is closed and
# the script is selected once in Preferences > Link, Tempo & MIDI. INSTALLED.txt
# records the vendored commit and the sha256 of every overlay file. Live's own
# ProgramData/.../Resources/MIDI Remote Scripts is never touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor="$here/vendor/AbletonOSC"
overlay="$here/overlay"
record="$here/VENDOR.txt"
prefix="${ABLETON_WINEPREFIX:-}"
wine_user=""
library="${ABLETON_LIBRARY_PATH:-}"
dry_run=0
# Test hook, as in scripts/bench-suite.sh: a fake /proc for the Live check.
proc_root=/proc
[ "${ABLETON_BENCH_TESTING:-0}" != 1 ] || proc_root="${ABLETON_BENCH_PROC_ROOT:-/proc}"

usage()
{
    cat <<'EOF'
usage: profiler/control/install.sh --prefix DIR [--user NAME] [--library-path PATH] [--dry-run]

  --prefix DIR          Wine prefix (default: $ABLETON_WINEPREFIX)
  --user NAME           Wine user under drive_c/users (default: $USER, else the first with AppData)
  --library-path PATH   the User Library itself (default: $ABLETON_LIBRARY_PATH, else
                        drive_c/users/NAME/{Documents,My Documents}/Ableton/User Library)
  --dry-run             print the plan; nothing is written

Copies vendor/AbletonOSC/ and overlay/ to "<User Library>/Remote Scripts/AbletonOSC"
(rsync when present, else cp -a into a clean target; logs/ survives) and writes
INSTALLED.txt there. Refuses while Live runs from the prefix.
EOF
}

fail()
{
    printf 'install: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix|--user|--library-path)
            [ $# -ge 2 ] || fail "$1 needs a value"
            case "$1" in
                --prefix) prefix="$2" ;;
                --user) wine_user="$2" ;;
                --library-path) library="$2" ;;
            esac
            shift 2
            ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
done

[ -n "$prefix" ] || { usage >&2; fail "--prefix DIR is required (or export ABLETON_WINEPREFIX)"; }
prefix="$(readlink -f -- "$prefix" 2>/dev/null)" || fail "prefix does not exist: $prefix"
[ -f "$prefix/system.reg" ] || fail "not a Wine prefix (no system.reg): $prefix"
[ -f "$overlay/manager.py" ] && [ -f "$overlay/abletonosc/bench.py" ] || fail "overlay is incomplete under $overlay"
grep -q BenchHandler "$overlay/manager.py" || fail "$overlay/manager.py does not register BenchHandler"
"$here/vendor.sh" --check >/dev/null || fail "vendor/AbletonOSC does not match VENDOR.txt; run profiler/control/vendor.sh"
commit="$(sed -n 's/^commit: //p' "$record")"
[ -n "$commit" ] || fail "$record has no commit line"

# Live sessions on this prefix: the command-line match of bench-suite.sh plus
# the WINEPREFIX from the environment. A Live whose environment is unreadable
# counts, since it cannot be ruled out.
live_pids()
{
    local process pid cmd env_prefix
    for process in "$proc_root"/[0-9]*; do
        [ -d "$process" ] || continue
        cmd="$(tr '\0' ' ' < "$process/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) ;; *) continue ;; esac
        pid="${process##*/}"
        env_prefix="$(tr '\0' '\n' < "$process/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p' | sed -n '1p' || true)"
        if [ -n "$env_prefix" ]; then
            env_prefix="$(readlink -f -- "$env_prefix" 2>/dev/null || printf '%s' "$env_prefix")"
            [ "$env_prefix" = "$prefix" ] || continue
        fi
        printf '%s\n' "$pid"
    done
    return 0
}

users_dir="$prefix/drive_c/users"
if [ -z "$wine_user" ]; then
    if [ -n "${USER:-}" ] && [ -d "$users_dir/$USER/AppData" ]; then
        wine_user="$USER"
    else
        for candidate in "$users_dir"/*; do
            [ -d "$candidate/AppData" ] || continue
            wine_user="${candidate##*/}"
            break
        done
    fi
fi
[ -n "$wine_user" ] && [ -d "$users_dir/$wine_user" ] \
    || fail "no Wine user directory under $users_dir (pass --user NAME)"

if [ -z "$library" ]; then
    for candidate in "$users_dir/$wine_user/Documents/Ableton/User Library" \
                     "$users_dir/$wine_user/My Documents/Ableton/User Library"; do
        [ -d "$candidate" ] || continue
        library="$candidate"
        break
    done
fi
[ -n "$library" ] || fail "no User Library under $users_dir/$wine_user/{Documents,My Documents}/Ableton: start Live once so it creates it, or pass --library-path PATH (or export ABLETON_LIBRARY_PATH)"
# Documents is usually a symlink out of the prefix; the record keeps the real path.
resolved="$(readlink -f -- "$library" 2>/dev/null)" || fail "User Library does not exist: $library"
library="$resolved"
[ -d "$library" ] || fail "User Library is not a directory: $library"
case "$library" in
    */ProgramData/Ableton/*|*"/Resources/MIDI Remote Scripts"*)
        fail "refusing to install into Live's own scripts directory: $library" ;;
esac
target="$library/Remote Scripts/AbletonOSC"

pids="$(live_pids | tr '\n' ' ')"
[ -z "${pids// /}" ] || fail "Live is running from $prefix (pid(s): ${pids% }); quit it with Ctrl+Q first (control surfaces are enumerated at start)"

method=cp
command -v rsync >/dev/null 2>&1 && method=rsync
# "hash  relative/path" for every overlay file in a stable order.
overlay_sums="$( (cd "$overlay" && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print0 \
    | LC_ALL=C sort -z | xargs -0 -r sha256sum --) \
    | sed 's/^\([0-9a-f]\{64\}\) [ *]\.\//\1  /')"
vendor_count="$(find "$vendor" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' ! -path '*/logs/*' | wc -l)"

printf 'install plan: prefix=%s user=%s method=%s\n' "$prefix" "$wine_user" "$method"
printf '  library: %s\n' "$library"
printf '  target:  %s\n' "$target"
printf '  vendor:  AbletonOSC@%s, %d files\n' "${commit:0:7}" "$vendor_count"
printf '  overlay: %s\n' "$(printf '%s\n' "$overlay_sums" | awk '{print $2}' | paste -sd' ' -)"
if [ "$dry_run" -eq 1 ]; then
    echo "nothing written (--dry-run)"
    exit 0
fi

mkdir -p -- "$library/Remote Scripts"
if [ "$method" = rsync ]; then
    # Two passes: the vendored tree with --delete clears a stale install, the
    # overlay goes on top. logs/ and INSTALLED.txt are the script's own.
    rsync -a --delete --exclude=/logs/ --exclude=/INSTALLED.txt --exclude=__pycache__/ --exclude='*.pyc' \
        -- "$vendor/" "$target/"
    rsync -a --exclude=__pycache__/ --exclude='*.pyc' -- "$overlay/" "$target/"
else
    staging="$library/Remote Scripts/.AbletonOSC.new.$$"
    rm -rf -- "$staging"
    cp -a -- "$vendor" "$staging"
    cp -a -- "$overlay/." "$staging/"
    find "$staging" -type d -name __pycache__ -prune -exec rm -rf -- {} +
    find "$staging" -type f -name '*.pyc' -delete
    [ ! -d "$target/logs" ] || mv -- "$target/logs" "$staging/logs"
    rm -rf -- "$target"
    mv -- "$staging" "$target"
fi

[ -f "$target/LICENSE.md" ] && [ -f "$target/abletonosc/bench.py" ] && grep -q BenchHandler "$target/manager.py" \
    || fail "verification failed: $target is incomplete"
( cd "$target" && printf '%s\n' "$overlay_sums" | sha256sum -c --quiet -- ) \
    || fail "verification failed: overlay files differ in $target"

{
    printf '# Written by profiler/control/install.sh; the vendored tree is described by VENDOR.txt\n'
    printf 'upstream: %s\n' "$(sed -n 's/^upstream: //p' "$record")"
    printf 'commit: %s\n' "$commit"
    printf 'installed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source: %s\n' "$here"
    printf 'prefix: %s\n' "$prefix"
    printf 'library: %s\n' "$library"
    printf 'overlay:\n'
    printf '%s\n' "$overlay_sums"
} > "$target/INSTALLED.txt"

cat <<EOF
installed AbletonOSC@${commit:0:7} + bench overlay at
  $target
One-time step (Live enumerates control surfaces when it starts):
  1. start Live from this prefix
  2. Preferences > Link, Tempo & MIDI: Control Surface "AbletonOSC", Input "None", Output "None"
  3. close Preferences (that writes Preferences.cfg), then quit Live with Ctrl+Q
  4. take the golden snapshot, start Live again and run profiler/control/smoke-test.sh
Script log: $target/logs/abletonosc.log
EOF
