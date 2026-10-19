#!/usr/bin/env bash
# Trial T0021: one CPU per audio thread (headroom campaign item 1; pre-registered in profiler/plans/resume-plan.md).
# A: the kept pinning (pipeasio-rt and every AudioCalc thread on CPUs 0-11).
# B: pipeasio-rt on CPU 0, each AudioCalc thread on a CPU of its own from 2-10.
# Both: the kept configuration (WINE_POSIX_SPAWN=1, PIPEASIO_REALTIME=1, nine workers, golden, 64 frames, normal window),
# normal kernel, RT throttling off; heavy Sets, 120 s; rule H. Traced: one 60 s Inbuilts run per arm with
# d0003-capture (perf), for the RT-balancing share of audio-thread cycles.
set -u
TRIAL=T0021
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
export ABLETON_MAX_AUDIO_THREADS=9
PIN_RT_CPU=0
PIN_WORKER_CPUS="2 3 4 5 6 7 8 9 10"
arm_env() { :; }
arm_setup() { :; }
arm_teardown() { :; }
golden_for() { echo golden; }
pin_for() { if [ "$1" = B ]; then pin_loop_1to1; else pin_loop_shared; fi; }
arm_describe() { if [ "$1" = B ]; then echo "pinning=1to1 rt=$PIN_RT_CPU workers=${PIN_WORKER_CPUS// /,}"; else echo "pinning=shared $P_CPUS"; fi; }
arm_record() { :; }
traced_runs() {
  local arm
  for arm in A B; do
    traced_one "t0021-traced-$arm" "$arm" Inbuilts 60 "$T/d0003-capture"
    echo "  breakdown: $($TOOLS breakdown "$(ls -d "$R/t0021-traced-$arm"/bench/sets/*/raw/interface)" 2>&1)"
  done
}
campaign_main
