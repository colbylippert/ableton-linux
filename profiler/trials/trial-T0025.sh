#!/usr/bin/env bash
# Trial T0025: ntsync-live's in-kernel optimistic spin (kernel plan K3; pre-registered in profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new KEPT_CLEAR=0|1 NTSL_S8=<series8> NTSL_SPIN_NS=<G3's S*> \
#          NTSL_ADAPTIVE=<G3's P*: 0|1> KEPT_SMT=on|off profiler/trials/trial-T0025.sh   (KEPT_SMT=off: T0026 kept)
# Both arms run the same module, live-$NTSL_S8, loaded once before the first run through the root helper (installed by
# ntsync-live verify or g3) with spin_comm=AudioCalc,pipeasio-rt, spin_rt=1 and spin_adaptive=$NTSL_ADAPTIVE; the stock
# module comes back when the driver exits. A: spin_ns=0 (no wait spins, whatever spin_adaptive says).
# B: spin_ns=$NTSL_SPIN_NS. The parameter changes between runs, while Live is not running.
# Rule D with G4 at +15 points of one core (campaign_tools.py rule-d T0025 15).
# Mechanism, per run: the module's counters (gated waits, spins, hits, misses, aborts, spin time); the audio threads'
# voluntary context switches (campaign_tools.py vcs); traced, one 60 s Inbuilts run per arm with d0003-capture (perf),
# for the scheduler's share of the audio threads' cycles.
set -u
TRIAL=T0025
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}" "${KEPT_CLEAR:?}" "${NTSL_S8:?}" "${NTSL_SPIN_NS:?}" "${NTSL_ADAPTIVE:?}" "${KEPT_SMT:?}"
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
H=/usr/local/sbin/profiler-root-helper
P=/sys/module/ntsync/parameters
pgrep -f 'Live 12 Trial.exe' >/dev/null && { echo "Live is running"; exit 2; }
sudo -n "$H" ntsync load "$NTSL_S8" spin_comm=AudioCalc,pipeasio-rt spin_rt=1 spin_adaptive="$NTSL_ADAPTIVE" \
  || { echo "ntsync load $NTSL_S8 failed"; exit 2; }
trap 'sudo -n "$H" ntsync restore-stock >/dev/null || echo "could not restore the stock ntsync (reboot restores it)"' EXIT
spin_for() { if [ "$1" = B ]; then echo "$NTSL_SPIN_NS"; else echo 0; fi; }
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_on
  [ "$KEPT_SMT" = off ] && smt_siblings_off
  sudo -n "$H" knob set ntsync.spin_ns "$(spin_for "$1")" >/dev/null && sudo -n "$H" knob set ntsync.stats_reset 1 >/dev/null \
    || echo "ntsync parameters not set for $1"
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  STATS=$(cat $P/stats 2>/dev/null); MODULE="$(cat /sys/module/ntsync/version 2>/dev/null) spin_ns=$(cat $P/spin_ns 2>/dev/null) spin_comm=$(cat $P/spin_comm 2>/dev/null) spin_rt=$(cat $P/spin_rt 2>/dev/null) spin_adaptive=$(cat $P/spin_adaptive 2>/dev/null)"
  [ "$KEPT_SMT" = off ] && smt_siblings_on
  [ "$KEPT_CLEAR" = 1 ] && cores_clear_off
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { echo "spin_ns=$(spin_for "$1") module=live-$NTSL_S8 clear=$KEPT_CLEAR"; }
arm_record() { echo "module=[$MODULE] stats=[$STATS] $(power_summary "$R/$2.power.tsv")"; }
traced_runs() {
  local arm
  for arm in A B; do traced_one "t0025-traced-$arm" "$arm" Inbuilts 60 "$T/d0003-capture"; done
}
campaign_main
