#!/usr/bin/env bash
# Trial T0023: the display setup again (headroom campaign item 4; pre-registered in profiler/plans/resume-plan.md).
# Usage: KEPT_LAYOUT=shared|1to1|physcore KEPT_WORKERS=9|5 trial-T0023.sh   (the configuration T0021/T0022 kept)
# A: the current display: OpenGL (the launcher's default WINE_D3D_CONFIG), Live's GPU renderer off (golden),
#    every frame shown.
# B: wined3d's Vulkan back end, the GPU renderer on (golden.20261019T011657Z), WINED3D_PRESENT_SKIP=6.
# Both: the kept configuration; heavy Sets, 120 s; T0018's non-inferiority rule (rule H's guards G1-G3).
set -u
TRIAL=T0023
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}"
GPU_GOLDEN=golden.20261019T011657Z
profiler_state_has() { (cd ~/Projects/ableton-linux && profiler/bin/state list --names | grep -qx "$1"); }
profiler_state_has "$GPU_GOLDEN" || { echo "no snapshot $GPU_GOLDEN"; exit 2; }
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
arm_env() {
  if [ "$1" = B ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
ticks() { local p; p=$(pgrep -xo "$1") || { echo 0; return; }; awk '{print $14 + $15}' "/proc/$p/stat"; }
arm_setup() { K0=$(ticks kwin_wayland); X0=$(ticks Xwayland); T0=$(date +%s.%N); }   # compositor CPU baseline
arm_teardown() { :; }
golden_for() { if [ "$1" = B ]; then echo "$GPU_GOLDEN"; else echo golden; fi; }
pin_for() { pin_kept; }
arm_describe() {
  if [ "$1" = B ]; then echo "display=new d3d=$WINE_D3D_CONFIG skip=$WINED3D_PRESENT_SKIP"; else echo "display=old"; fi
}
arm_record() {  # ARM TAG: GPU-renderer line per Set, Wine's Vulkan and skip lines, compositor CPU over the run
  local gpu vk sk k1 x1 t1 d
  k1=$(ticks kwin_wayland); x1=$(ticks Xwayland); t1=$(date +%s.%N)
  gpu=$(for d in "$R/$2"/bench/sets/*/raw; do grep -a -h 'GPU Renderer:' "$d"/log-*.txt 2>/dev/null | sort | tail -n 1 | sed 's/.*GPU Renderer: //'; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
  vk=$(cat "$LOGS/live.log" "$LOGS/live.log.1" 2>/dev/null | grep -a -c 'Using the Vulkan renderer')
  sk=$(cat "$LOGS/live.log" "$LOGS/live.log.1" 2>/dev/null | grep -a -c 'Showing every 6. present')
  echo "gpu_renderer=[$gpu] vulkan_lines=$vk skip_lines=$sk $(awk -v k0="$K0" -v k1="$k1" -v x0="$X0" -v x1="$x1" -v t0="$T0" -v t1="$t1" -v hz="$(getconf CLK_TCK)" 'BEGIN { printf "kwin_pct=%.1f xwayland_pct=%.1f", (k1-k0)/hz/(t1-t0)*100, (x1-x0)/hz/(t1-t0)*100 }')"
}
campaign_main
