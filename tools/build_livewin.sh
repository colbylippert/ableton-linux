#!/usr/bin/env bash
# Build tools/livewin.exe, which minimises or restores Live's main window from inside
# its Wine prefix (scripts/bench-suite.sh uses it for ABLETON_BENCH_LIVE_WINDOW=minimized).
# No CRT; kernel32 + user32 only. Run it the way the suite does:
#   profiler/bin/with-session-env tools/run_in_prefix.sh livewin.exe state|minimize|restore
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_livewin.sh   (builds tools/livewin.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -nostartfiles -Wl,-e,mainCRTStartup \
  -o livewin.exe livewin.c -luser32 -lkernel32
echo "Built livewin.exe"
