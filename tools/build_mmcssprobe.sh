#!/usr/bin/env bash
# Build tools/mmcssprobe.exe, the probe for patch 0113 (WINE_MMCSS: MMCSS "Pro Audio" threads as Linux SCHED_FIFO
# threads). Run it the way the suite runs Wine tools, with and without the switch:
#   tools/run_in_prefix.sh mmcssprobe.exe                (stub: nothing changes)
#   WINE_MMCSS=1 tools/run_in_prefix.sh mmcssprobe.exe   (FIFO base, +2, -1, child normal, revert)
# Exit status 0 = PASS. Set WINEDLLOVERRIDES="mscoree,mshtml=" as the launcher does: the first Wine start after a
# runtime install updates the prefix, and without the override that update waits on Wine's Mono installer dialog.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_mmcssprobe.sh   (builds tools/mmcssprobe.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -o mmcssprobe.exe mmcssprobe.c
echo "Built mmcssprobe.exe"
