#!/usr/bin/env bash
# build.sh: cross-compile live-idle-guard.exe with mingw-w64 (the WSL build distro has it: Wine's PE build uses it).
# Usage: profiler/windows/live-idle-guard/build.sh [OUT_DIR]      (default: this directory; the .exe is not tracked)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
x86_64-w64-mingw32-g++ -O2 -Wall -Wextra -municode -static -static-libgcc -static-libstdc++ \
    -o "$out/live-idle-guard.exe" "$here/live-idle-guard.cpp" -lpowrprof -ladvapi32
x86_64-w64-mingw32-strip "$out/live-idle-guard.exe"
echo "built $out/live-idle-guard.exe ($(stat -c %s "$out/live-idle-guard.exe") bytes)"
