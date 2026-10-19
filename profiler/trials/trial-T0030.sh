#!/usr/bin/env bash
# Trial T0030: the P-cores' frequency policy (kernel plan K10, from T0024; pre-registered in profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/trials/trial-T0030.sh
# T0024 found the audio workers averaging 3.2-3.5 GHz of the 4.7 GHz turbo: under intel_pstate's powersave governor
# with EPP balance_performance the hardware clocks bursty, mostly idle cores down.
# A: EPP as is (balance_performance on every CPU). B, applied before and undone after each B run: EPP performance on
# every CPU through the root helper (knob epp; it applies to all CPUs). Rule D (G4: audio-thread CPU at most +5 %);
# rule H reported. Mechanism: the EPP read back during each run, and the mean P-core clock (the power sampler) higher in
# every B run than in its paired A run. Reported: package power and temperature (the cost).
set -u
TRIAL=T0030
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
EPP_A=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
[ "$EPP_A" = performance ] && { echo "EPP is already performance; A would equal B"; exit 2; }
epp() { sudo -n "$HELPER" knob set epp "$1" >/dev/null || echo "epp $1: failed"; }
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  if [ "$1" = B ]; then epp performance; else epp "$EPP_A"; fi
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  EPP_RUN="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)/$(cat /sys/devices/system/cpu/cpu12/cpufreq/energy_performance_preference)"
  epp "$EPP_A"
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "epp=performance"; else echo "epp=$EPP_A"; fi; }
arm_record() { echo "epp_during_run(p/e)=$EPP_RUN $(power_summary "$R/$2.power.tsv")"; }
campaign_main
