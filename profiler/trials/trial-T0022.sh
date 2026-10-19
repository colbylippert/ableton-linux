#!/usr/bin/env bash
# Trial T0022: one audio thread per physical P-core (headroom campaign item 2; re-registered in
# profiler/plans/resume-plan.md). Usage: KEPT_LAYOUT=shared|1to1 trial-T0022.sh   (the layout T0021 kept)
# A: the kept configuration after T0021: nine workers, pinned per KEPT_LAYOUT.
# B: ABLETON_MAX_AUDIO_THREADS=5: pipeasio-rt alone on core 0 (CPU 0), the five AudioCalc threads alone on cores 1-5
#    (CPUs 2,4,6,8,10); the sibling hyperthreads (1,3,5,7,9,11) carry no audio thread.
# Both: WINE_POSIX_SPAWN=1, PIPEASIO_REALTIME=1, golden, 64 frames, normal window, normal kernel, RT throttling off;
# heavy Sets, 120 s; rule H.
set -u
TRIAL=T0022
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?set KEPT_LAYOUT to the layout T0021 kept: shared or 1to1}"
arm_env() { if [ "$1" = B ]; then export ABLETON_MAX_AUDIO_THREADS=5; else export ABLETON_MAX_AUDIO_THREADS=9; fi; }
arm_setup() { :; }
arm_teardown() { :; }
golden_for() { echo golden; }
pin_for() {
  if [ "$1" = B ]; then PIN_RT_CPU=0; PIN_WORKER_CPUS="2 4 6 8 10"; pin_loop_1to1; else pin_kept; fi
}
arm_describe() {
  if [ "$1" = B ]; then echo "workers=5 pinning=physcore rt=0 workers_on=2,4,6,8,10"; else echo "workers=9 pinning=$KEPT_LAYOUT"; fi
}
arm_record() { :; }
campaign_main
