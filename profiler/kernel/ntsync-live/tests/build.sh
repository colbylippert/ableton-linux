#!/usr/bin/env bash
# build.sh: build ntsync-live's tests into DIR (default ~/.local/opt/ntsync-live/tests): ntsl_stress and upstream's
# v7.2.11 ntsync selftest (kselftest harness), against the repo's ntsync uapi headers. Prints DIR.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
nl=$(cd "$here/.." && pwd)
repo=$(cd "$nl/../../.." && pwd)
out=${1:-$HOME/.local/opt/ntsync-live/tests}
mkdir -p "$out"
cc -O2 -Wall -pthread -I"$repo/vendor/ntsync-uapi" -o "$out/ntsl_stress" "$here/ntsl_stress.c"
# the selftest unoptimised, as upstream's kselftest build is: stress_wait counts in a static variable that -O2 may
# keep in a register across the ioctls (it then sees ~10000 of 40000)
cc -O0 -pthread -I"$nl/upstream/include/uapi" -I"$nl/upstream/selftests" \
    -o "$out/ntsync_selftest" "$nl/upstream/selftests/ntsync.c"
echo "$out"
