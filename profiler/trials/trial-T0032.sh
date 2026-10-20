#!/usr/bin/env bash
# Trial T0032: MMCSS "Pro Audio" threads realtime, the rest of Live at normal priority (patch 0113; pre-registered in
# profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/trials/trial-T0032.sh
# A: as kept: the launcher runs the whole of Live with chrt -r 10 (every thread SCHED_RR 10) and Wine's avrt is the stub.
# B: WINE_MMCSS=1 ABLETON_RT=off: no blanket realtime; the threads Live registers for "Pro Audio" run SCHED_FIFO
#    (AudioCalc at 12, critical; the timers at 10), pipeasio-rt keeps its own FIFO 15, every other Live thread runs
#    at normal priority.
# Rule D (G4: audio-thread CPU at most +5 %). Mechanism, from a 10 s sampler of Live's threads during each run: in B the
# AudioCalc threads are FIFO 12 and the UI thread (tid = pid) normal; in A both are RR 10. Reported: power, temperature.
set -u
TRIAL=T0032
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
[ "$KEPT_LAYOUT" = physcore ] || { echo "T0032 needs KEPT_LAYOUT=physcore"; exit 2; }
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
grep -q WINE_MMCSS ~/.local/opt/wine-d2d1-nspa-11.13/lib/wine/x86_64-unix/avrt.so 2> /dev/null \
  || { echo "the official runtime has no 0113 (WINE_MMCSS in avrt.so)"; exit 2; }

sched_loop() {  # OUT: every 10 s, each Live thread's name, policy and rt priority, and whether it is the UI thread
  local out=$1 p t c st
  while :; do
    sleep 10
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
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
  if [ "$1" = B ]; then export WINE_MMCSS=1 ABLETON_RT=off; else unset WINE_MMCSS ABLETON_RT; fi
}
arm_setup() {  # $tag: run_one's
  SCHED_OUT=$R/$tag.sched.tsv; : > "$SCHED_OUT"
  sched_loop "$SCHED_OUT" & SCHED_PID=$!
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  kill "$SCHED_PID" 2> /dev/null; wait "$SCHED_PID" 2> /dev/null
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "WINE_MMCSS=1 ABLETON_RT=off"; else echo "as kept (chrt -r 10)"; fi; }
arm_record() { echo "$(sched_summary "$R/$2.sched.tsv") $(power_summary "$R/$2.power.tsv")"; }
campaign_main
