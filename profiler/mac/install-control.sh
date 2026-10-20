#!/bin/bash
# install-control.sh [SRC]: on a Mac, install the vendored AbletonOSC plus the bench overlay into the User Library,
# "<User Library>/Remote Scripts/AbletonOSC", as profiler/control/install.sh does for a Wine prefix.
#   SRC   a tree holding profiler/control/{vendor/AbletonOSC,overlay,VENDOR.txt} (default ~/AbletonBench/src, which
#         profiler/mac/push.sh fills from `git archive` of the checkout)
# The User Library is $ABLETON_LIBRARY_PATH, else ~/Music/Ableton/User Library. Refuses while Live runs (Live
# enumerates control surfaces when it starts). INSTALLED.txt records the vendored commit and the sha256 of every overlay
# file. One-time step afterwards: Live's Preferences > Link, Tempo & MIDI, Control Surface "AbletonOSC", Input and Output
# "None". Live's own MIDI Remote Scripts inside the app are never touched. macOS tools only (bash 3.2, ditto, shasum).
set -eu
src=${1:-$HOME/AbletonBench/src}/profiler/control
vendor=$src/vendor/AbletonOSC
overlay=$src/overlay
record=$src/VENDOR.txt
library="${ABLETON_LIBRARY_PATH:-$HOME/Music/Ableton/User Library}"
target="$library/Remote Scripts/AbletonOSC"

fail() { echo "install-control: $*" >&2; exit 1; }

[ -f "$overlay/manager.py" ] && [ -f "$overlay/abletonosc/bench.py" ] || fail "overlay is incomplete under $overlay"
grep -q BenchHandler "$overlay/manager.py" || fail "$overlay/manager.py does not register BenchHandler"
[ -f "$vendor/manager.py" ] || fail "no vendored AbletonOSC under $vendor"
commit=$(sed -n 's/^commit: //p' "$record")
[ -n "$commit" ] || fail "$record has no commit line"
[ -d "$library" ] || fail "no User Library at $library: start Live once, or set ABLETON_LIBRARY_PATH"
case $library in */Contents/App-Resources/*) fail "refusing to install into Live's own scripts: $library" ;; esac
if pgrep -x Live > /dev/null; then fail "Live is running; quit it first (control surfaces are enumerated at start)"; fi

# "hash  relative/path" for every overlay file, in a stable order
overlay_sums=$(cd "$overlay" && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' | LC_ALL=C sort \
  | while IFS= read -r f; do shasum -a 256 "$f"; done | sed 's/^\([0-9a-f]\{64\}\)  \.\//\1  /')

mkdir -p "$library/Remote Scripts"
staging="$library/Remote Scripts/.AbletonOSC.new.$$"
rm -rf "$staging"
ditto "$vendor" "$staging"
ditto "$overlay" "$staging"
find "$staging" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$staging" -type f -name '*.pyc' -delete
if [ -d "$target/logs" ]; then mv "$target/logs" "$staging/logs"; fi
rm -rf "$target"
mv "$staging" "$target"

[ -f "$target/abletonosc/bench.py" ] && grep -q BenchHandler "$target/manager.py" \
  || fail "verification failed: $target is incomplete"
(cd "$target" && printf '%s\n' "$overlay_sums" | shasum -a 256 -c > /dev/null) \
  || fail "verification failed: overlay files differ in $target"
{
  printf '# Written by profiler/mac/install-control.sh; the vendored tree is described by VENDOR.txt\n'
  printf 'upstream: %s\n' "$(sed -n 's/^upstream: //p' "$record")"
  printf 'commit: %s\n' "$commit"
  printf 'installed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source: %s\n' "$src"
  printf 'library: %s\n' "$library"
  printf 'overlay:\n'
  printf '%s\n' "$overlay_sums"
} > "$target/INSTALLED.txt"
echo "installed AbletonOSC@$(echo "$commit" | cut -c1-7) + bench overlay at $target"
