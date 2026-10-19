#!/usr/bin/env bash
# D0004, the K0 ntsync and wake census (profiler/plans/kernel-plan.md), in the kept configuration.
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/kernel/census/d0004.sh
# One bench run with census-capture as the bench's tracer, Inbuilts and Max4Live for 60 s each; then the analysis
# (~/.local/share/profiler/runs/d0004-census.analysis.txt). Run it like a trial driver (profiler/trials/README.md).
# KEPT_DISPLAY=new (T0023): wined3d's Vulkan back end and WINED3D_PRESENT_SKIP=6; golden has the GPU renderer on.
set -u
TRIAL=D0004
source "$(dirname "${BASH_SOURCE[0]}")/../../trials/trial-lib.sh"
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() { :; }
arm_teardown() { :; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_record() { echo "layout=$KEPT_LAYOUT workers=$KEPT_WORKERS"; }
campaign_setup
traced_one d0004-census A Inbuilts,Max4Live 60 "$C/census-capture"
profiler/bin/state restore --name golden >/dev/null 2>&1
python3 "$C/analyze.py" "$R/d0004-census/bench" > "$R/d0004-census.analysis.txt" 2>&1
echo "D0004_DONE $(date +%T)"
