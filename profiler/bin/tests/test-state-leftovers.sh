#!/usr/bin/env bash
# Tests for profiler/bin/state's busy-prefix handling: before snapshot and
# restore refuse a busy prefix they end what a finished session left there
# (scripts/lib/lifecycle.sh ableton_prefix_settle: Live's agents and
# learnheal.exe, by exact image name), never Live or another program, and
# --dry-run only says what it would end. Everything runs in a throwaway HOME
# with stand-in Windows processes (sleep under an exec -a image name) and a stub
# wine whose "taskkill /f /im NAME" ends this prefix's stand-ins named NAME; no
# Wine, Live or snapshot of the real machine is involved.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$(cd "$here/.." && pwd)/state"
work="$(mktemp -d "${TMPDIR:-/tmp}/profiler-state-test.XXXXXX")"
declare -a standins=()
cleanup() {
    local pid
    for pid in "${standins[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$work"
}
trap cleanup EXIT
pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
for tool in rsync timeout; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is installed"; done

new_case() {   # NAME → a fresh HOME with a prefix, a stub runtime and a 'golden' snapshot of the prefix
    local base="$work/$1" snap
    mkdir -p "$base/home/.wine-ableton/drive_c" "$base/runtime/bin" "$base/data" "$base/config" "$base/state" "$base/run" "$base/tmp"
    printf 'WINE REGISTRY Version 2\n' > "$base/home/.wine-ableton/system.reg"
    cp /bin/sleep "$base/runtime/bin/wine-client"
    cat > "$base/runtime/bin/wine" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STATE_TEST_LOG:?}"
[ "${1:-}" = taskkill ] || exit 0
shift
images=()
while [ $# -gt 0 ]; do
    case "$1" in /im) images+=("$2"); shift 2 ;; *) shift ;; esac
done
for proc in /proc/[0-9]*; do
    tr '\0' '\n' < "$proc/environ" 2>/dev/null | grep -Fxq "WINEPREFIX=$WINEPREFIX" || continue
    a0="$(tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | head -n 1)"
    a0="${a0##*\\}"; a0="${a0##*/}"
    for image in "${images[@]}"; do
        if [ "$a0" = "$image" ]; then kill "${proc#/proc/}" 2>/dev/null || true; fi
    done
done
exit 0
EOF
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
    chmod +x "$base/runtime/bin/"*
    : > "$base/wine.log"
    # a snapshot named golden holding only the prefix (built by hand: this test
    # never runs a real `state snapshot`)
    snap="$base/data/profiler/golden/golden"
    mkdir -p "$snap"
    cp -a "$base/home/.wine-ableton" "$snap/prefix"
    printf 'prefix\t%s\tprefix\tdir\t1\n' "$base/home/.wine-ableton" > "$snap/items.tsv"
    printf '{\n  "schema": "ableton-linux-profiler-state/v2",\n  "name": "golden",\n  "created": "2026-10-17T00:00:00Z"\n}\n' > "$snap/MANIFEST.json"
    printf '%s\n' "$base"
}
standin() {   # BASE IMAGE: start a stand-in Windows process in BASE's prefix
    env WINEPREFIX="$1/home/.wine-ableton" bash -c 'exec -a "$1" "$2" 600' _ "$2" \
        "$1/runtime/bin/wine-client" >/dev/null 2>&1 &
    standins+=("$!")
    last_standin=$!
}
alive() {
    local s
    s="$(sed -n 's/^.*) \(.\).*/\1/p' "/proc/$1/stat" 2>/dev/null || true)"
    [ -n "$s" ] && [ "$s" != Z ]
}
# restore resets clock.force-quantum and reads wpctl: stubs keep a test away from
# the machine's real PipeWire
mkdir -p "$work/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin/pw-metadata"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin/wpctl"
chmod +x "$work/fakebin/"*
run_state() {   # BASE ARGS… → the state tool in BASE's HOME (exit status kept in $rc)
    local base="$1"; shift
    rc=0
    env -u ABLETON_WINEPREFIX -u ABLETON_WINE_ROOT PATH="$work/fakebin:$PATH" HOME="$base/home" XDG_DATA_HOME="$base/data" \
        XDG_CONFIG_HOME="$base/config" XDG_STATE_HOME="$base/state" XDG_RUNTIME_DIR="$base/run" \
        TMPDIR="$base/tmp" PROFILER_SHARE_DIR="$base/data/profiler" PROFILER_STATE_DIR="$base/state/profiler" \
        PROFILER_SETUP_CONF="$base/config/profiler/setup.conf" ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/home/.wine-ableton" STATE_TEST_LOG="$base/wine.log" NO_COLOR=1 \
        PROFILER_STATE_SETTLE="${SETTLE:-10}" \
        "$state" "$@" >"$base/out" 2>&1 || rc=$?
}
learnheal='C:\learnheal.exe'
connector='C:\ProgramData\Ableton\Live 12 Suite\Resources\Extensions\WebConnector\Ableton Web Connector.exe'
live='C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'

# --dry-run says what it would end and ends nothing
base="$(new_case dry-run)"
standin "$base" "$learnheal"; helper=$last_standin
standin "$base" "$connector"; agent=$last_standin
sleep 0.3
run_state "$base" restore --dry-run
[ "$rc" -eq 0 ] || fail "restore --dry-run refuses a prefix held only by leftovers (exit $rc): $(cat "$base/out")"
grep -q 'dry run: would end learnheal.exe, Ableton Web Connector.exe and wait' "$base/out" \
    || grep -q 'dry run: would end Ableton Web Connector.exe, learnheal.exe and wait' "$base/out" \
    || fail "restore --dry-run does not say what it would end: $(cat "$base/out")"
alive "$helper" && alive "$agent" || fail "restore --dry-run ended a process"
[ ! -s "$base/wine.log" ] || fail "restore --dry-run started wine: $(cat "$base/wine.log")"
run_state "$base" snapshot --name trial-dry --dry-run
[ "$rc" -eq 0 ] || fail "snapshot --dry-run refuses a prefix held only by leftovers (exit $rc): $(cat "$base/out")"
grep -q 'dry run: would end' "$base/out" || fail "snapshot --dry-run does not say what it would end"
[ ! -e "$base/data/profiler/golden/trial-dry" ] || fail "snapshot --dry-run wrote a snapshot"
alive "$helper" && alive "$agent" || fail "snapshot --dry-run ended a process"
ok "--dry-run names the leftovers it would end and touches nothing"

# a real restore ends them by name, waits for the prefix, then restores
run_state "$base" restore
[ "$rc" -eq 0 ] || fail "restore fails on a prefix held only by leftovers (exit $rc): $(cat "$base/out")"
alive "$helper" && fail "restore leaves learnheal.exe running"
alive "$agent" && fail "restore leaves the Web Connector running"
grep -qF '/im learnheal.exe' "$base/wine.log" && grep -qF '/im Ableton Web Connector.exe' "$base/wine.log" \
    || fail "restore does not end the leftovers by exact image name: $(cat "$base/wine.log")"
grep -q 'prefix idle' "$base/out" && grep -q "restored 'golden'" "$base/out" \
    || fail "restore does not report the settle and the restore: $(cat "$base/out")"
ok "restore ends Live's agents and learnheal.exe by exact name, then restores"

# a running Live is never ended: restore refuses at once and names it
base="$(new_case live-running)"
standin "$base" "$live"; live_pid=$last_standin
standin "$base" "$learnheal"; helper=$last_standin
sleep 0.3
start=$SECONDS
run_state "$base" restore
[ "$rc" -eq 1 ] || fail "restore does not refuse while Live runs (exit $rc): $(cat "$base/out")"
grep -q 'refusing to restore' "$base/out" && grep -q 'Ableton Live 12 Suite.exe' "$base/out" \
    || fail "the refusal does not name Live by its image: $(cat "$base/out")"
alive "$live_pid" && alive "$helper" || fail "restore ended something while Live was running"
[ ! -s "$base/wine.log" ] || fail "restore started taskkill while Live was running: $(cat "$base/wine.log")"
[ $((SECONDS - start)) -le 5 ] || fail "restore waited $((SECONDS - start))s before refusing a running Live"
ok "a running Live makes restore refuse at once, with nothing ended"

# another program: the leftovers go, the program stays and is named
base="$(new_case unknown-holder)"
standin "$base" 'C:\some-daw.exe'; other=$last_standin
standin "$base" "$learnheal"; helper=$last_standin
sleep 0.3
SETTLE=2 run_state "$base" restore
[ "$rc" -eq 1 ] || fail "restore does not refuse a prefix another program holds (exit $rc): $(cat "$base/out")"
grep -q 'refusing to restore' "$base/out" && grep -q 'some-daw.exe' "$base/out" \
    || fail "the refusal does not name the program: $(cat "$base/out")"
alive "$other" || fail "restore ended a program it does not know"
alive "$helper" && fail "restore leaves learnheal.exe beside another program"
ok "another program is named in the refusal and never ended; the leftovers still go"

printf 'PASS: %s state leftover checks\n' "$pass"
