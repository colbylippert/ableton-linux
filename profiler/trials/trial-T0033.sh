#!/usr/bin/env bash
# Trial T0033: two audio workers (pre-registered in profiler/plans/kernel-plan.md, after the D0012 and D0013 smoke
# tests). Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/trials/trial-T0033.sh
# A: as kept: ABLETON_MAX_AUDIO_THREADS=5, pipeasio-rt on CPU 0, the five AudioCalc threads on CPUs 2,4,6,8,10.
# B: ABLETON_MAX_AUDIO_THREADS=2, pipeasio-rt on CPU 0, the two AudioCalc threads on CPUs 2 and 4.
# Both: the kept configuration otherwise (posix_spawn, PipeASIO realtime, the new display, every-boot shallow idle,
# chrt -r 10 for all of Live); Inbuilts, Max4Live, VSTs at 120 s, ABAB x 3; rule H (the audio-thread CPU; G3 bounds
# each Set's DSP average). Reported: power and temperature.
set -u
TRIAL=T0033
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
[ "$KEPT_LAYOUT" = physcore ] && [ "$KEPT_WORKERS" = 5 ] || { echo "T0033 compares against physcore with 5 workers"; exit 2; }
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
  unset WINE_MMCSS ABLETON_RT
  if [ "$1" = B ]; then export ABLETON_MAX_AUDIO_THREADS=2; else export ABLETON_MAX_AUDIO_THREADS=5; fi
}
arm_setup() { sampler_start "$R/$tag.power.tsv"; }   # $tag: run_one's
arm_teardown() { sampler_stop; return 0; }
golden_for() { echo golden; }
pin_for() { if [ "$1" = B ]; then PIN_RT_CPU=0; PIN_WORKER_CPUS="2 4"; pin_loop_1to1; else pin_kept; fi; }
arm_describe() {
  if [ "$1" = B ]; then echo "workers=2 rt=0 workers_on=2,4"; else echo "workers=5 pinning=physcore rt=0 workers_on=2,4,6,8,10"; fi
}
arm_record() { power_summary "$R/$2.power.tsv"; }
campaign_main
