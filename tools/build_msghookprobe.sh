#!/usr/bin/env bash
# Build tools/msghookprobe.exe, the probe for window-message delivery on a thread that owns a Direct3D 11
# swap chain and for patch 0111 (WINED3D_NO_ALT_ENTER_HOOK=1). Run it the way the suite runs Wine tools:
#   WINED3D_NO_ALT_ENTER_HOOK=1 tools/run_in_prefix.sh msghookprobe.exe   (exit status = number of failed checks)
# Set WINEDLLOVERRIDES="mscoree,mshtml=" as the launcher does: the first Wine start after a runtime install
# updates the prefix, and without the override that update waits on Wine's Mono installer dialog.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "usage: tools/build_msghookprobe.sh   (builds tools/msghookprobe.exe with x86_64-w64-mingw32-gcc)"
    exit 0 ;;
esac
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -Wall -Wextra -O2 -o msghookprobe.exe msghookprobe.c -ld3d11 -ldxgi -luser32
echo "Built msghookprobe.exe"
