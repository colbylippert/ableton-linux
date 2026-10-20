#!/usr/bin/env bash
# d0012.sh: smoke test of the audio worker count from 8 to 12 (profiler/plans/kernel-plan.md, D0012; user: "Lets do
# only a run of 8 to 12", "a quick smoke test to see what is better. We can do a full run later"). One bench run per
# configuration (Inbuilts, Max4Live, VSTs at 120 s), in the order below:
#   w8 ... w12  ABLETON_MAX_AUDIO_THREADS=N; pipeasio-rt on CPU 0 and each AudioCalc thread on a CPU of its own, in the
#               order the P-cores' first threads (2 4 6 8 10), their siblings (3 5 7 9 11), then the E-cores (12 13)
# Everything else as kept (posix_spawn, PipeASIO realtime, the new display, every-boot shallow idle, chrt -r 10 for all
# of Live). Then profiler/trials/d0012_summary.py, with today's T0032 A runs (the kept 5 workers) for reference.
# About 40 minutes; D0012_DONE at the end.
set -u
TRIAL=D0012
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
ORDER="w10 w8 w12 w9 w11"
FILL="2 4 6 8 10 3 5 7 9 11 12 13 14 15"
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

for cfg in $ORDER; do
  run_one "d0012-r1-$cfg" "$cfg" || echo "D0012 $cfg failed (exit $?)"
done
python3 profiler/trials/d0012_summary.py | tee "$R/d0012.summary.txt"
python3 profiler/trials/d0012_summary.py --json > "$R/d0012.summary.json"
echo "D0012_DONE $(date +%T)"
