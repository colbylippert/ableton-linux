#!/usr/bin/env bash
# Build tools/presentskipprobe.exe, the probe for Direct3D 11 presents and the present skipping of
# patch 0110 (WINED3D_PRESENT_SKIP=N). Run it the way the suite runs Wine tools:
#   WINED3D_PRESENT_SKIP=6 tools/run_in_prefix.sh presentskipprobe.exe   (exit status = number of failed checks)
# Set WINEDLLOVERRIDES="mscoree,mshtml=" as the launcher does: the first Wine start after a runtime install
# updates the prefix, and without the override that update waits on Wine's Mono installer dialog.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_presentskipprobe.sh   (builds tools/presentskipprobe.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -o presentskipprobe.exe presentskipprobe.c -ld3d11 -ldxgi -luser32
echo "Built presentskipprobe.exe"
