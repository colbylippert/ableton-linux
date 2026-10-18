#!/usr/bin/env bash
# Build tools/syncbench.exe, the microbenchmark for the Wine calls on Live's audio hot
# path (QueryPerformanceCounter, SetEvent, ResetEvent, WaitForSingleObject, a two-thread
# ping-pong and Live's worker fan-out). No CRT; kernel32 only.
# Run it from the repository root the way the launcher runs Live:
#   chrt -r 10 taskset -c 0-11 tools/run_in_prefix.sh syncbench.exe [--only NAME] [--workers K]
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_syncbench.sh   (builds tools/syncbench.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -nostartfiles -Wl,-e,mainCRTStartup \
  -o syncbench.exe syncbench.c -lkernel32
echo "Built syncbench.exe"
