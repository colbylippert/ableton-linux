#!/usr/bin/env bash
# Trial T0028: no C2/C3 on the P-cores (kernel plan K4, gated by D0004; pre-registered in profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new KEPT_CLEAR=0|1 KEPT_SMT=on|off profiler/trials/trial-T0028.sh
# A: every idle state allowed. B, applied before and undone after each B run: C2_ACPI (state2, 127 us) and C3_ACPI
# (state3, 1048 us) disabled through the root helper (knob cpuidle.<cpu>.<state>) on CPUs 0-11. A core sleeps only as
# deep as both its threads allow, so the siblings are limited too; KEPT_SMT=off (if T0026 kept it) has the siblings
# offline in both arms and limits the six audio CPUs. The E-cores are untouched. KEPT_CLEAR=1 if T0024 kept it.
# Rule D (G4: audio-thread CPU at most +5 %). Mechanism: the audio CPUs' state2/state3 usage counters do not move
# during B runs. Reported: package power and temperature (the cost of shallower idle).
set -u
TRIAL=T0028
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}" "${KEPT_CLEAR:?}" "${KEPT_SMT:?}"
[ "$KEPT_LAYOUT" = physcore ] || { echo "T0028 needs KEPT_LAYOUT=physcore"; exit 2; }
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
AUDIO_CPUS="0 2 4 6 8 10"
if [ "$KEPT_SMT" = off ]; then LIMIT_CPUS=$AUDIO_CPUS; else LIMIT_CPUS="0 1 2 3 4 5 6 7 8 9 10 11"; fi
cstates() {  # 0|1: the disable flag of state2 and state3 on LIMIT_CPUS
  local c s
  for c in $LIMIT_CPUS; do for s in 2 3; do sudo -n "$HELPER" knob set "cpuidle.$c.$s" "$1" >/dev/null || echo "cpuidle.$c.$s: failed"; done; done
}
deep_usage() {  # the audio CPUs' state2 + state3 entries so far
  local c n=0
  for c in $AUDIO_CPUS; do n=$((n + $(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/usage) + $(cat /sys/devices/system/cpu/cpu$c/cpuidle/state3/usage))); done
  echo $n
}
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_on
  [ "$KEPT_SMT" = off ] && smt_siblings_off
  if [ "$1" = B ]; then cstates 1; else cstates 0; fi
  D0=$(deep_usage)
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  DEEP=$(( $(deep_usage) - D0 ))
  cstates 0
  [ "$KEPT_SMT" = off ] && smt_siblings_on
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_off
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "cstates=C1-max on $LIMIT_CPUS"; else echo "cstates=all"; fi; }
arm_record() { echo "audio_c2c3_entries=$DEEP $(power_summary "$R/$2.power.tsv")"; }
campaign_main
