#!/usr/bin/env bash
# Build the x86-64 Windows tracer validation probe for the selected Wine source and build.
# Run it from the repository root: tools/run_in_prefix.sh traceprobe.exe [--settle 3000]
#
# Without ABLETON_WINE_SOURCE the probe is built with x86_64-w64-mingw32-gcc.
# With ABLETON_WINE_SOURCE (and optionally ABLETON_WINE_BUILD, default
# $ABLETON_WINE_SOURCE/build-wow64) it is built with clang against the Wine
# headers and the import libraries of that build, exactly as build_apcprobe.sh
# does. The probe needs no CRT and no generated Wine header (it defines
# WIN32_LEAN_AND_MEAN and declares its own DirectWrite vtable prefixes).
set -euo pipefail
case "${1:-}" in
  -h|--help)
    cat <<'EOF'
usage: tools/build_traceprobe.sh [--help]
  Builds tools/traceprobe.exe next to this script.
  environment:
    ABLETON_WINE_SOURCE   Wine source tree; selects the clang route (unset: mingw-w64 gcc)
    ABLETON_WINE_BUILD    Wine build tree (default $ABLETON_WINE_SOURCE/build-wow64)
  run: tools/run_in_prefix.sh traceprobe.exe [--settle MS] [--only N] [--scale K] [--sleep-ms N] [--no-procscan]
EOF
    exit 0 ;;
esac
cd "$(dirname "$0")"
[ -n "${ABLETON_WINE_SOURCE:-}" ] || exec x86_64-w64-mingw32-gcc -Wall -Wextra -O1 \
  -nostartfiles -Wl,-e,mainCRTStartup -o traceprobe.exe traceprobe.c \
  -lkernel32 -luser32 -lntdll
SRC="${ABLETON_WINE_SOURCE:-}"
BLD=${ABLETON_WINE_BUILD:-$SRC/build-wow64}
INC=$SRC/include
K=$BLD/dlls/kernel32/x86_64-windows
U=$BLD/dlls/user32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows

for dir in "$INC" "$K" "$U" "$N"; do
  [ -d "$dir" ] || { echo "!! Provide the Wine source or build directory: $dir" >&2; exit 1; }
done

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -Wextra -O2 \
  -isystem "$RES/include" -I "$INC" -I "$INC/msvcrt" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o traceprobe.exe traceprobe.c \
  -L "$K" -L "$U" -L "$N" \
  -lkernel32 -luser32 -lntdll
echo "Built traceprobe.exe"
