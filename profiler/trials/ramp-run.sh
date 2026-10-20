#!/usr/bin/env bash
# ramp-run.sh TAG [CONFIG] [SETS] [PASSES]: one load ramp on Linux in the kept configuration
# (profiler/scenarios/ramp-duplicate-all.json; profiler/plans/kernel-plan.md, "Load ramp").
#   CONFIG  kept (default): as the campaign runs Live (chrt -r 10 for all of it); mmcss: WINE_MMCSS=1 ABLETON_RT=off
#   SETS    comma list (default Inbuilts,Max4Live,VSTs)
#   PASSES  periods in each Set's window (default 10: the Set played 1 to 10 times)
# Takes the session lock, restores golden, installs the checkout's AbletonOSC overlay into Live's prefix (the bench
# handler with /abl/bench/duplicate-all; golden may predate it), runs the bench with the scenario for PASSES periods
# of 51.4286 s per Set with the kept pinning, restores golden, and prints profiler/control/ramp-report.py's table
# (also kept as $R/ramp-TAG.report.txt and .report.json). Run it like a trial driver (profiler/trials/README.md).
set -u
TAG=${1:?usage: ramp-run.sh TAG [kept|mmcss] [SETS] [PASSES]}
CONFIG=${2:-kept}
RAMP_SETS=${3:-Inbuilts,Max4Live,VSTs}
PASSES=${4:-10}
TRIAL=RAMP
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
export KEPT_LAYOUT=physcore KEPT_WORKERS=5 ABLETON_MAX_AUDIO_THREADS=5
campaign_setup
export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
case $CONFIG in
  kept) unset WINE_MMCSS ABLETON_RT ;;
  mmcss) export WINE_MMCSS=1 ABLETON_RT=off ;;
  *) echo "ramp-run.sh: CONFIG is kept or mmcss"; exit 2 ;;
esac
prefix=$(sed -n 's/^prefix=//p' ~/.config/ableton-wine/config 2> /dev/null | head -n 1)
[ -d "$prefix" ] || { echo "ramp-run.sh: no Live prefix (prefix= in ~/.config/ableton-wine/config)"; exit 2; }
out=$R/ramp-$TAG
rm -rf "${out:?}"
profiler/bin/state restore --name golden > /dev/null 2>&1
profiler/control/install.sh --prefix "$prefix" > "$out.install.log" 2>&1 \
  || { echo "ramp-run.sh: the overlay install failed (see $out.install.log)"; exit 1; }
duration=$(awk -v n="$PASSES" 'BEGIN { printf "%d", n * 51.4286 + 1 }')
PIN_LOG=$out.pin.log; : > "$PIN_LOG"
pin_kept & pinner=$!
echo "RAMP $TAG $(date +%T) config=$CONFIG sets=$RAMP_SETS passes=$PASSES duration=${duration}s"
profiler/bin/bench --tag "ramp-$TAG" --sets "$RAMP_SETS" --duration "$duration" --scenario ramp-duplicate-all \
  --output "$out/bench" > "$out.bench.log" 2>&1
rc=$?
kill "$pinner" 2> /dev/null; wait "$pinner" 2> /dev/null
echo "RAMP $TAG $(date +%T) exit=$rc pins=$(grep -c ' pinned ' "$PIN_LOG")"
profiler/bin/state restore --name golden > /dev/null 2>&1
python3 profiler/control/ramp-report.py "$out/bench" | tee "$out.report.txt"
python3 profiler/control/ramp-report.py --json "$out/bench" > "$out.report.json"
echo "RAMP_DONE $(date +%T)"
