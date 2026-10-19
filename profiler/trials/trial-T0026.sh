#!/usr/bin/env bash
# Trial T0026: the audio cores' SMT siblings offline (kernel plan K1; pre-registered in profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new KEPT_CLEAR=0|1 profiler/trials/trial-T0026.sh
# A: CPUs 0-15 online. B, applied before and undone after each B run: CPUs 1, 3, 5, 7, 9 and 11 offline through the
# root helper (knob cpu-online.N), so each audio core (CPUs 0, 2, 4, 6, 8, 10) runs one hardware thread and nothing
# shares its execution resources; the rest of the system has those six threads' spare time and the E-cores 12-15.
# KEPT_CLEAR=1 when T0024 kept the clearing: the audio cores are kept clear in both arms (cores_clear_on/off).
# Rule H. Mechanism: /sys/devices/system/cpu/online is 0,2,4,6,8,10,12-15 in every B run and 0-15 in every A run,
# with the physcore affinities. Reported: DSP average and peaks, package power and temperature, kwin and Xwayland CPU.
set -u
TRIAL=T0026
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}" "${KEPT_CLEAR:?}"
[ "$KEPT_LAYOUT" = physcore ] || { echo "T0026 needs KEPT_LAYOUT=physcore (audio threads on CPUs 0, 2, 4, 6, 8, 10)"; exit 2; }
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
ticks() { local p; p=$(pgrep -xo "$1") || { echo 0; return; }; awk '{print $14 + $15}' "/proc/$p/stat"; }
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_on
  if [ "$1" = B ]; then smt_siblings_off; else smt_siblings_on; fi
  K0=$(ticks kwin_wayland); X0=$(ticks Xwayland); T0=$(date +%s.%N)
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  ONLINE=$(cat /sys/devices/system/cpu/online)
  K1=$(ticks kwin_wayland); X1=$(ticks Xwayland); T1=$(date +%s.%N)
  smt_siblings_on
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_off
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "smt=siblings-offline clear=$KEPT_CLEAR"; else echo "smt=on clear=$KEPT_CLEAR"; fi; }
arm_record() {  # ARM TAG: the CPUs online during the run, the compositor's CPU over it, its power
  echo "online=$ONLINE $(awk -v k0="$K0" -v k1="$K1" -v x0="$X0" -v x1="$X1" -v t0="$T0" -v t1="$T1" -v hz="$(getconf CLK_TCK)" \
    'BEGIN { printf "kwin_pct=%.1f xwayland_pct=%.1f", (k1-k0)/hz/(t1-t0)*100, (x1-x0)/hz/(t1-t0)*100 }') $(power_summary "$R/$2.power.tsv")"
}
campaign_main
