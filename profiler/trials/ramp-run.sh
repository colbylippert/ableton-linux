#!/usr/bin/env bash
# ramp-run.sh TAG [CONFIG] [SETS] [PASSES]: one load ramp on Linux in the kept configuration
# (profiler/scenarios/ramp-duplicate-all.json; profiler/plans/kernel-plan.md, "Load ramp").
#   CONFIG  kept (default): as the campaign runs Live (chrt -r 10 for all of it); mmcss: WINE_MMCSS=1 ABLETON_RT=off
#   SETS    comma list (default Inbuilts,Max4Live,VSTs)
#   PASSES  periods in each Set's window (default 10: the Set played 1 to 10 times)
# Takes the session lock, restores golden, installs the checkout's AbletonOSC overlay into Live's prefix (the bench
# handler with /abl/bench/duplicate-all; golden may predate it), runs the bench with the scenario for PASSES periods
# of 51.4286 s per Set with the kept pinning, restores golden, and prints profiler/control/ramp-report.py's table
# (also kept as $R/ramp-TAG.report.txt and .report.json). While the bench runs it samples Live's threads' scheduling
# every 30 s ($R/ramp-TAG.sched.tsv, as trial-T0032.sh) and the package power every 5 s ($R/ramp-TAG.power.tsv), and
# prints their summaries. Exits with the bench's status. Run it like a trial driver (profiler/trials/README.md).
set -u
TAG=${1:?usage: ramp-run.sh TAG [kept|mmcss] [SETS] [PASSES]}
CONFIG=${2:-kept}
RAMP_SETS=${3:-Inbuilts,Max4Live,VSTs}
PASSES=${4:-10}
TRIAL=RAMP
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
sched_loop() {  # OUT: every 30 s, each Live thread's name, policy and rt priority, and whether it is the UI thread
  local out=$1 p t c st
  while :; do
    sleep 30
    for p in $(pgrep -f '[L]ive 12 Trial.exe'); do
      for t in /proc/$p/task/[0-9]*; do
        { read -r c < "$t/comm"; st=$(< "$t/stat"); } 2> /dev/null || continue
        st=${st##*) }
        set -- $st
        printf '%s\t%s\t%s\t%s\n' "$([ "${t##*/}" = "$p" ] && echo ui || echo -)" "${39}" "${38}" "$c"
      done
    done >> "$out"
  done
}
sched_summary() {  # OUT: the policies seen, per kind of thread
  awk -F'\t' '
    { pol = ($2 == 0 ? "OTHER" : $2 == 1 ? "FIFO" : $2 == 2 ? "RR" : $2 == 3 ? "BATCH" : $2 == 5 ? "IDLE" : "P" $2) ($3 > 0 ? $3 : "") }
    $4 == "AudioCalc" { a[pol]++; next }
    $4 == "pipeasio-rt" { r[pol]++; next }
    $1 == "ui" { u[pol]++; next }
    { if ($2 == 1 || $2 == 2) rt++; o++ }
    END {
      printf "audiocalc="; for (k in a) printf "%s:%d,", k, a[k]
      printf " pipeasio-rt="; for (k in r) printf "%s:%d,", k, r[k]
      printf " ui="; for (k in u) printf "%s:%d,", k, u[k]
      printf " other_rt=%d/%d\n", rt, o
    }' "$1" 2> /dev/null
}
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
: > "$out.sched.tsv"; sched_loop "$out.sched.tsv" & sched=$!
sampler_start "$out.power.tsv"
echo "RAMP $TAG $(date +%T) config=$CONFIG sets=$RAMP_SETS passes=$PASSES duration=${duration}s"
profiler/bin/bench --tag "ramp-$TAG" --sets "$RAMP_SETS" --duration "$duration" --scenario ramp-duplicate-all \
  --output "$out/bench" > "$out.bench.log" 2>&1
rc=$?
kill "$pinner" "$sched" 2> /dev/null; wait "$pinner" "$sched" 2> /dev/null
sampler_stop
echo "RAMP $TAG $(date +%T) exit=$rc pins=$(grep -c ' pinned ' "$PIN_LOG")"
echo "RAMP $TAG threads: $(sched_summary "$out.sched.tsv")"
echo "RAMP $TAG power: $(power_summary "$out.power.tsv")"
profiler/bin/state restore --name golden > /dev/null 2>&1
python3 profiler/control/ramp-report.py "$out/bench" | tee "$out.report.txt"
python3 profiler/control/ramp-report.py --json "$out/bench" > "$out.report.json"
echo "RAMP_DONE $(date +%T)"
exit "$rc"
