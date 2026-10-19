#!/usr/bin/env bash
# Trial T0027: the mitigations=off boot entry (kernel plan K2; pre-registered in profiler/plans/kernel-plan.md).
# On the laptop, one step per boot (profiler/trials/reboot-lib.sh), driven by profiler/trials/reboot-waiter.sh T0027:
#   KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/trials/trial-T0027.sh start
# A: the normal boot entry. B: "(profiler: mitigations-off)", the normal command line plus mitigations=off.
# Order A1 B1 A2 B2 A3 B3, every run from a fresh boot into its arm's entry, settled as T0015 was; the kept
# configuration otherwise. Rule H; the DSP average, package power and temperature are reported.
set -u
TRIAL=T0027
ORDER="A1 B1 A2 B2 A3 B3"
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/reboot-lib.sh"
variant_of() { case $1 in A*) echo normal ;; B*) echo mitigations-off ;; esac; }
arm_env() {
  if [ "${KEPT_DISPLAY:-new}" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() { sampler_start "$R/$tag.power.tsv"; }   # $tag: run_one's
arm_teardown() { sampler_stop; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { echo "variant=$(boot_variant) display=${KEPT_DISPLAY:-new}"; }
arm_record() {  # ARM TAG: the mechanism (vulnerability files) and the run's power
  local v=/sys/devices/system/cpu/vulnerabilities
  echo "mitigated=$(grep -l '^Mitigation' $v/* 2>/dev/null | wc -l) vulnerable=$(grep -l '^Vulnerable' $v/* 2>/dev/null | wc -l) $(power_summary "$R/$2.power.tsv")"
}
reboot_main "$@"
