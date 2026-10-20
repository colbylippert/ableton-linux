#!/usr/bin/env bash
# d0011.sh: MMCSS under load (profiler/plans/kernel-plan.md, "Load ramp", D0011). A1 B1 A2 B2 load ramps with
# ramp-run.sh on Inbuilts, Max4Live and VSTs, 10 passes each; A = kept (chrt -r 10 for all of Live), B = mmcss
# (WINE_MMCSS=1 ABLETON_RT=off). A run whose bench fails is rerun once in place. Then the pre-stated comparison
# (profiler/control/ramp-compare.py), kept as $R/d0011.compare.txt and .json. About 2 hours.
set -u
cd ~/Projects/ableton-linux || exit 1
R=~/.local/share/profiler/runs
for run in A1 B1 A2 B2; do
  case $run in A*) config=kept ;; *) config=mmcss ;; esac
  profiler/trials/ramp-run.sh "d0011-$run" "$config" \
    || { echo "D0011 $run failed (exit $?); rerunning once"; profiler/trials/ramp-run.sh "d0011-$run" "$config"; } \
    || echo "D0011 $run failed again (exit $?)"
done
reports() { local run; for run in "$@"; do echo "$R/ramp-d0011-$run.report.json"; done; }
python3 profiler/control/ramp-compare.py --a $(reports A1 A2) --b $(reports B1 B2) | tee "$R/d0011.compare.txt"
python3 profiler/control/ramp-compare.py --json --a $(reports A1 A2) --b $(reports B1 B2) > "$R/d0011.compare.json"
echo "D0011_DONE $(date +%T)"
