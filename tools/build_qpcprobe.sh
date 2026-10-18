#!/usr/bin/env bash
# Build tools/qpcprobe.exe, the probe for QueryPerformanceCounter and the user-mode route of
# patch 0109 (WINE_QPC_TSC=1). No CRT; kernel32 + user32 (wsprintfA). Run it the way the suite runs Wine tools:
#   tools/run_in_prefix.sh qpcprobe.exe        (exit status = number of failed checks)
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_qpcprobe.sh   (builds tools/qpcprobe.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -nostartfiles -Wl,-e,mainCRTStartup \
  -o qpcprobe.exe qpcprobe.c -luser32 -lkernel32
echo "Built qpcprobe.exe"
