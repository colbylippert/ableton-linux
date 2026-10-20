#!/usr/bin/env bash
# D0008, the audio cores' sleep depth and clock (profiler/plans/kernel-plan.md), in the kept configuration.
# Usage: profiler/kernel/clock/d0008.sh       (run like a trial driver, profiler/trials/README.md)
# Three bench runs in one session with clock-capture as the bench's tracer, the three Sets for 120 s each:
#   A  as is
#   B  C2_ACPI and C3_ACPI (state2, state3) disabled on every P-core CPU through the root helper (T0028's B)
#   C  B plus D0007's clock floor (scaling_min_freq = cpuinfo_max_freq on every P-core CPU)
# Everything is restored after each run and on any exit. Then the summary
# (~/.local/share/profiler/runs/d0008.summary.txt).
set -u
TRIAL=D0008
source "$(dirname "${BASH_SOURCE[0]}")/../../trials/trial-lib.sh"
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KEPT_LAYOUT=physcore KEPT_WORKERS=5 ABLETON_MAX_AUDIO_THREADS=5
P_CORE_CPUS=$(awk -F- '{ for (i = $1; i <= $2; i++) printf "%d ", i }' /sys/devices/cpu_core/cpus)
MINS=$R/d0008-min-freq.saved

cstates() {  # 0|1: the disable flag of state2 and state3 on every P-core CPU
  local c s
  for c in $P_CORE_CPUS; do
    for s in 2 3; do sudo -n "$HELPER" knob set "cpuidle.$c.$s" "$1" > /dev/null || echo "cpuidle.$c.$s: failed"; done
  done
}
floor_on() {
  local c f
  for c in $P_CORE_CPUS; do
    f=/sys/devices/system/cpu/cpu$c/cpufreq
    cat "$f/cpuinfo_max_freq" | sudo -n tee "$f/scaling_min_freq" > /dev/null
  done
}
floor_off() {
  local c v
  [ -s "$MINS" ] || return 0
  while read -r c v; do echo "$v" | sudo -n tee "/sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq" > /dev/null; done < "$MINS"
}
restore_all() { cstates 0; floor_off; }
arm_env() { export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6; }
arm_setup() {
  case $1 in
    B) cstates 1 ;;
    C) cstates 1; floor_on ;;
  esac
  return 0
}
arm_teardown() { restore_all; return 0; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() {
  case $1 in
    A) echo "as is" ;;
    B) echo "C2/C3 off on CPUs $P_CORE_CPUS" ;;
    C) echo "C2/C3 off and the clock floor on CPUs $P_CORE_CPUS" ;;
  esac
}
arm_record() { echo "layout=$KEPT_LAYOUT workers=$KEPT_WORKERS"; }

for c in $P_CORE_CPUS; do echo "$c $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq)"; done > "$MINS"
trap restore_all EXIT
campaign_setup
traced_one d0008-A A Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0008-B B Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0008-C C Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
restore_all
echo "after: min_freq $(for c in $P_CORE_CPUS; do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq; done | sort -u | tr '\n' ' ')" \
  "state2/3 disabled $(cat /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[23]/disable | sort | uniq -c | tr -s ' \n' ' ')"
profiler/bin/state restore --name golden > /dev/null 2>&1
python3 "$C/clock_summary.py" A="$R/d0008-A/bench" B="$R/d0008-B/bench" C="$R/d0008-C/bench" > "$R/d0008.summary.txt" 2>&1
echo "D0008_DONE $(date +%T)"
