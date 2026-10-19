#!/usr/bin/env bash
# Build tools/spawncowprobe.exe, the probe for page faults after process creation and for patch 0112
# (WINE_POSIX_SPAWN=1). Run it the way the suite runs Wine tools:
#   WINE_POSIX_SPAWN=1 tools/run_in_prefix.sh spawncowprobe.exe   (exit status = number of failed checks)
# Set WINEDLLOVERRIDES="mscoree,mshtml=" as the launcher does: the first Wine start after a runtime install
# updates the prefix, and without the override that update waits on Wine's Mono installer dialog.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_spawncowprobe.sh   (builds tools/spawncowprobe.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -o spawncowprobe.exe spawncowprobe.c
echo "Built spawncowprobe.exe"
