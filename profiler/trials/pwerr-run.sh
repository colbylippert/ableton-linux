#!/usr/bin/env bash
# pwerr-run.sh TAG [WORKERS] [SETS] [DURATION]: one bench run in the kept configuration with WORKERS audio workers (2 by
# default, one per physical P-core from CPU 2, as D0014) and profiler/trials/pwerr-capture as the bench's tracer, then
# profiler/trials/pwerr_analyze.py over it ($R/pwerr-TAG.analysis.txt). SETS default Inbuilts,Max4Live,VSTs; DURATION
# 120 s. Run it like a trial driver (profiler/trials/README.md); PWERR_DONE at the end.
set -u
TAG=${1:?usage: pwerr-run.sh TAG [WORKERS] [SETS] [DURATION]}
WORKERS=${2:-2}
RUN_SETS=${3:-Inbuilts,Max4Live,VSTs}
DURATION=${4:-120}
TRIAL=PWERR
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
export KEPT_LAYOUT=physcore KEPT_WORKERS=$WORKERS KEPT_DISPLAY=new ABLETON_MAX_AUDIO_THREADS=$WORKERS
campaign_setup
golden_for() { echo golden; }
arm_env() { export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6; unset WINE_MMCSS ABLETON_RT; }
arm_setup() { :; }
arm_teardown() { :; }
pin_for() { pin_kept; }
arm_record() { echo "workers=$WORKERS"; }
traced_one "pwerr-$TAG" A "$RUN_SETS" "$DURATION" "$T/pwerr-capture"
python3 profiler/trials/pwerr_analyze.py "$R/pwerr-$TAG/bench" | tee "$R/pwerr-$TAG.analysis.txt"
echo "PWERR_DONE $(date +%T)"
