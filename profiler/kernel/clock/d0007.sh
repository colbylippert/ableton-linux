#!/usr/bin/env bash
# D0007, the audio cores' clock check (profiler/plans/kernel-plan.md), in the kept configuration.
# Usage: profiler/kernel/clock/d0007.sh       (run like a trial driver, profiler/trials/README.md)
# Two bench runs in one session with clock-capture as the bench's tracer, the three Sets for 120 s each:
#   A  as is (the bench's power hold sets EPP performance; scaling_min_freq at its default)
#   B  a clock floor on the P-cores: scaling_min_freq = cpuinfo_max_freq on every P-core CPU, i.e. the HWP minimum
#      at the top (the counterpart of Windows' "minimum processor state 100 %"); the saved values are restored after B
#      and on any exit
# Then the summary (~/.local/share/profiler/runs/d0007.summary.txt).
set -u
TRIAL=D0007
source "$(dirname "${BASH_SOURCE[0]}")/../../trials/trial-lib.sh"
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KEPT_LAYOUT=physcore KEPT_WORKERS=5 ABLETON_MAX_AUDIO_THREADS=5
P_CORE_CPUS=$(awk -F- '{ for (i = $1; i <= $2; i++) printf "%d ", i }' /sys/devices/cpu_core/cpus)
MINS=$R/d0007-min-freq.saved

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
arm_env() { export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6; }
arm_setup() { if [ "$1" = B ]; then floor_on; fi; }
arm_teardown() { if [ "$1" = B ]; then floor_off; fi; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "clock floor on CPUs $P_CORE_CPUS"; else echo "as is"; fi; }
arm_record() { echo "layout=$KEPT_LAYOUT workers=$KEPT_WORKERS"; }

for c in $P_CORE_CPUS; do echo "$c $(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq)"; done > "$MINS"
trap floor_off EXIT
campaign_setup
traced_one d0007-A A Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0007-B B Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
floor_off
echo "min_freq after: $(for c in $P_CORE_CPUS; do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq; done | sort -u | tr '\n' ' ')"
profiler/bin/state restore --name golden > /dev/null 2>&1
python3 "$C/d0007_summary.py" "$R/d0007-A/bench" "$R/d0007-B/bench" > "$R/d0007.summary.txt" 2>&1
echo "D0007_DONE $(date +%T)"
