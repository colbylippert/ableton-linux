#!/usr/bin/env bash
# worker-smoke.sh ID COUNT...: a smoke test of Live's audio worker count (profiler/plans/kernel-plan.md; D0013 is the
# first, 1 to 5; D0012's own driver is d0012.sh). One bench run per count (Inbuilts, Max4Live, VSTs at 120 s), in the
# order given, named $R/id-r1-wN (id = ID in lower case):
#   ABLETON_MAX_AUDIO_THREADS=N; pipeasio-rt on CPU 0 and each AudioCalc thread on a CPU of its own, in the order the
#   P-cores' first threads (2 4 6 8 10), their siblings (3 5 7 9 11), then the E-cores (12 13 14 15)
# Everything else as kept (posix_spawn, PipeASIO realtime, the new display, every-boot shallow idle, chrt -r 10 for all
# of Live). Then profiler/trials/d0012_summary.py --id id. About 8 minutes a count; ID_DONE at the end.
set -u
ID=${1:?usage: worker-smoke.sh ID COUNT...}
shift
[ $# -ge 1 ] || { echo "usage: worker-smoke.sh ID COUNT..."; exit 2; }
for n in "$@"; do
  case $n in [1-9]|1[0-4]) ;; *) echo "worker-smoke.sh: counts are 1 to 14 (one CPU each), not $n"; exit 2 ;; esac
done
TRIAL=$ID
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
FILL="2 4 6 8 10 3 5 7 9 11 12 13 14 15"
id=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
campaign_setup

golden_for() { echo golden; }
arm_env() {
  export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  unset WINE_MMCSS ABLETON_RT
  export ABLETON_MAX_AUDIO_THREADS=${1#w}
}
arm_setup() { sampler_start "$R/$tag.power.tsv"; }   # $tag: run_one's
arm_teardown() { sampler_stop; return 0; }
pin_for() { PIN_RT_CPU=0; PIN_WORKER_CPUS=$FILL; pin_loop_1to1; }
arm_describe() { echo "${1#w} workers, one per CPU: $(echo $FILL | cut -d' ' -f1-"${1#w}")"; }
arm_record() { power_summary "$R/$2.power.tsv"; }

for n in "$@"; do
  run_one "$id-r1-w$n" "w$n" || echo "$ID w$n failed (exit $?)"
done
python3 profiler/trials/d0012_summary.py --id "$id" | tee "$R/$id.summary.txt"
python3 profiler/trials/d0012_summary.py --id "$id" --json > "$R/$id.summary.json"
echo "${ID}_DONE $(date +%T)"
