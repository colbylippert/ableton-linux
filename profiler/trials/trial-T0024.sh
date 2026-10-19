#!/usr/bin/env bash
# Trial T0024: audio cores kept clear (headroom campaign item 5; pre-registered in profiler/plans/resume-plan.md).
# Usage: KEPT_LAYOUT=shared|1to1|physcore KEPT_WORKERS=9|5 KEPT_DISPLAY=old|new profiler/trials/trial-T0024.sh
# A: as is. B, applied before and undone after each B run (trial-lib.sh cores_clear_on/off): every IRQ whose affinity
# can change on CPUs 12-15 except the Focusrite's xhci controller (CPU 11 when KEPT_LAYOUT=1to1, else CPU 12);
# system.slice, init.scope and, in the user manager, app.slice, background.slice and every session.slice unit except
# pipewire.service on AllowedCPUs=12-15; the unbound-workqueue cpumask on CPUs 12-15. Live (the driver's session
# scope) and PipeWire stay unrestricted. Rule H. Traced: one 60 s Inbuilts run per arm with d0003-capture (IRQs,
# preemptions).
# Second attempt (2026-10-19). The first was aborted during A2: restoring only the IRQ masks left every IRQ on
# CPUs 12-15 (the kernel keeps an IRQ where it is while that CPU is in its mask), so the A runs after B1 were not
# as-is, and its record read the masks after the restore. cores_clear_off now puts each IRQ back on its own CPU;
# the record has the masks in force before the restore and the IRQs not back afterwards as N/M, M those on or from
# an audio CPU (must be 0; rare IRQs on other CPUs may move back only when they next fire).
set -u
TRIAL=T0024
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() { if [ "$1" = B ]; then cores_clear_on; else cores_clear_off; fi; }
arm_teardown() { MASKS=$(cores_masks); cores_clear_off; NOT_BACK=$(cores_restore_check); return 0; }
golden_for() { echo golden; }   # golden has the GPU renderer on since T0023
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "cores=cleared"; else echo "cores=as-is"; fi; }
arm_record() { echo "$MASKS irqs_not_back=$NOT_BACK"; }   # ARM TAG: what was in force during the run
traced_runs() {
  local arm
  for arm in A B; do
    traced_one "t0024-traced-$arm" "$arm" Inbuilts 60 "$T/d0003-capture"
  done
}
campaign_main
