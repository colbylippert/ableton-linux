#!/usr/bin/env bash
# push.sh HOST...: send this checkout's committed Mac bench files to each Mac over ssh (HOST as ssh takes it, e.g.
# colby@osxm1) and install the control surface there. The tree goes to ~/AbletonBench/src (replaced each time) from
# `git archive HEAD`, so a push carries committed content only: profiler/control/{vendor/AbletonOSC,overlay,VENDOR.txt},
# profiler/control/ramp-{report,beats}.py, profiler/scenarios, profiler/mac and scripts/bench-osc.py. Then profiler/mac/install-control.sh runs there
# (it refuses while Live runs). The bench Sets are not part of it: they are local-only and copied separately.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: profiler/mac/push.sh HOST..." >&2; exit 2; }
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
paths=(profiler/control/vendor/AbletonOSC profiler/control/overlay profiler/control/VENDOR.txt
       profiler/control/ramp-report.py profiler/control/ramp-beats.py profiler/scenarios profiler/mac
       scripts/bench-osc.py)
for host in "$@"; do
  git -c core.autocrlf=false archive --format=tar HEAD -- "${paths[@]}" \
    | ssh -o BatchMode=yes "$host" 'rm -rf ~/AbletonBench/src && mkdir -p ~/AbletonBench/src && tar -C ~/AbletonBench/src -xf -'
  ssh -o BatchMode=yes "$host" 'bash ~/AbletonBench/src/profiler/mac/install-control.sh'
  echo "$host: pushed $(git log --oneline -1 | cut -c1-60)"
done
