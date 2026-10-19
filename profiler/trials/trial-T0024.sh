#!/usr/bin/env bash
# Trial T0024: audio cores kept clear (headroom campaign item 5; pre-registered in profiler/plans/resume-plan.md).
# Usage: KEPT_LAYOUT=shared|1to1|physcore KEPT_WORKERS=9|5 KEPT_DISPLAY=old|new trial-T0024.sh
# A: as is. B, applied before and undone after each B run: every IRQ whose affinity can change on CPUs 12-15
# except the Focusrite's xhci controller (CPU 11 when KEPT_LAYOUT=1to1, else CPU 12); system.slice, init.scope and,
# in the user manager, app.slice, background.slice and every session.slice unit except pipewire.service on
# AllowedCPUs=12-15; the unbound-workqueue cpumask on CPUs 12-15. Live (the driver's session scope) and PipeWire
# stay unrestricted. Rule H. Traced: one 60 s Inbuilts run per arm with d0003-capture (IRQs, preemptions).
set -u
TRIAL=T0024
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
GPU_GOLDEN=golden.20261019T011657Z
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
XHCI_IRQ=$(awk -F: '/xhci_hcd/ {gsub(/ /, "", $1); print $1; exit}' /proc/interrupts)
if [ "$KEPT_LAYOUT" = 1to1 ]; then XHCI_CPU=11; else XHCI_CPU=12; fi
SAVED=$R/t0024-irq-affinity.saved
[ -s "$SAVED" ] || for d in /proc/irq/[0-9]*; do echo "${d##*/} $(cat "$d/smp_affinity_list" 2>/dev/null)"; done > "$SAVED"
UNITS_FILE=$R/t0024-units.changed
SESSION_CG=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/session.slice

clear_on() {
  local d i unit
  for d in /proc/irq/[0-9]*; do
    i=${d##*/}
    if [ "$i" = "$XHCI_IRQ" ]; then echo "$XHCI_CPU" | sudo -n tee "$d/smp_affinity_list" >/dev/null 2>&1
    else echo 12-15 | sudo -n tee "$d/smp_affinity_list" >/dev/null 2>&1; fi
  done
  : > "$UNITS_FILE"
  for unit in system.slice init.scope; do
    sudo -n systemctl set-property --runtime "$unit" AllowedCPUs=12-15 && echo "system $unit" >> "$UNITS_FILE"
  done
  for unit in app.slice background.slice $(ls "$SESSION_CG" | grep -E '\.(service|scope)$' | grep -vx pipewire.service); do
    systemctl --user set-property --runtime "$unit" AllowedCPUs=12-15 2>/dev/null && echo "user $unit" >> "$UNITS_FILE"
  done
  echo f000 | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null
}
clear_off() {
  local i aff kind unit
  while read -r i aff; do
    [ -n "$aff" ] && echo "$aff" | sudo -n tee "/proc/irq/$i/smp_affinity_list" >/dev/null 2>&1
  done < "$SAVED"
  if [ -f "$UNITS_FILE" ]; then
    while read -r kind unit; do
      if [ "$kind" = system ]; then sudo -n systemctl set-property --runtime "$unit" AllowedCPUs=
      else systemctl --user set-property --runtime "$unit" AllowedCPUs= 2>/dev/null; fi
    done < "$UNITS_FILE"
    rm -f "$UNITS_FILE"
  fi
  echo ffff | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null
}
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() { if [ "$1" = B ]; then clear_on; else clear_off; fi; }
arm_teardown() { clear_off; }
golden_for() { if [ "$KEPT_DISPLAY" = new ]; then echo "$GPU_GOLDEN"; else echo golden; fi; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "cores=cleared xhci_irq=$XHCI_IRQ->$XHCI_CPU"; else echo "cores=as-is"; fi; }
arm_record() {  # ARM TAG: the masks in force at the end of the run (B is undone only after this record)
  local kw jd
  kw=$(pgrep -xo kwin_wayland); jd=$(pgrep -xo systemd-journal)
  echo "kwin_cpus=$(awk '/Cpus_allowed_list/ {print $2}' /proc/$kw/status 2>/dev/null) journald_cpus=$(awk '/Cpus_allowed_list/ {print $2}' /proc/$jd/status 2>/dev/null) xhci_effective=$(cat /proc/irq/$XHCI_IRQ/effective_affinity_list 2>/dev/null) wq=$(cat /sys/devices/virtual/workqueue/cpumask)"
}
traced_runs() {
  local arm
  for arm in A B; do
    traced_one "t0024-traced-$arm" "$arm" Inbuilts 60 "$T/d0003-capture"
  done
}
campaign_main
