#!/usr/bin/env bash
# Trial T0029: boot-time isolation of the audio cores (kernel plan K6; pre-registered in profiler/plans/kernel-plan.md).
# On the laptop, one step per boot (profiler/trials/reboot-lib.sh), driven by profiler/trials/reboot-waiter.sh T0029:
#   KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new KEPT_BOOT=normal|mitigations-off profiler/trials/trial-T0029.sh start
# A: KEPT_BOOT (the normal entry, or mitigations-off if T0027 kept it). B: the matching isolated entry
# (profiler/kernel/grub/variants: nohz_full, rcu_nocbs and isolcpus=managed_irq on CPUs 0,2,4,6,8,10, irqaffinity=12-15;
# no domain flag, so Live's other threads still use the P-cores), with the unbound-workqueue cpumask on CPUs 12-15.
# Order A1 B1 A2 B2 A3 B3, every run from a fresh boot. Rule D. Mechanism: /sys/devices/system/cpu/nohz_full lists the
# audio CPUs and the default IRQ affinity is 12-15 in every B run (neither in A); package power reported.
set -u
TRIAL=T0029
ORDER="A1 B1 A2 B2 A3 B3"
REBOOT_KEEP=KEPT_BOOT   # restored on every step (reboot-lib.sh)
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/reboot-lib.sh"
: "${KEPT_BOOT:=normal}"
variant_of() {
  case $1 in
    A*) echo "$KEPT_BOOT" ;;
    B*) if [ "$KEPT_BOOT" = mitigations-off ]; then echo isolated-mitigations-off; else echo isolated; fi ;;
  esac
}
arm_env() {
  if [ "${KEPT_DISPLAY:-new}" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  if [ "$1" = B ]; then echo f000 | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null; fi
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  NOHZ=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null); DEFAFF=$(cat /proc/irq/default_smp_affinity 2>/dev/null)
  WQ=$(cat /sys/devices/virtual/workqueue/cpumask)
  echo ffff | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { echo "variant=$(boot_variant) display=${KEPT_DISPLAY:-new}"; }
arm_record() { echo "nohz_full=${NOHZ:-none} irq_default=$DEFAFF wq=$WQ $(power_summary "$R/$2.power.tsv")"; }
reboot_main "$@"
