#!/usr/bin/env bash
# d0010.sh [TAG]: D0010, T0031's change on Windows (profiler/plans/kernel-plan.md), driven from the workstation (Git Bash).
# Order A1 B1 A2 B2, each run on a fresh boot of the Windows entry through GRUB (from Linux, one-shot grub-reboot).
# Since the every-boot setup (2026-10-20: GRUB's 01_profiler-c1e-off clears C1E on every boot, Windows' power plan holds
# IDLESTATEMAX 1) this rerun form takes B as the machine is and makes A the firmware default for one run:
#   A  grubenv profiler_c1e=on for that boot (C1E on, as the firmware sets it) and IDLESTATEMAX 0 for the run
#      (every idle state), put back to 1 after the Sets; profiler_c1e unset once back in Linux
#   B  as the machine is: C1E off from GRUB, IDLESTATEMAX 1
# (D0010 itself, 2026-10-20 05:04-05:50, booted the then-separate "Windows Boot Manager, C1E off (profiler)" entry for
# B and held C1-only idle there with LiveIdleGuard, which stays installed with manual start.)
# Each run: the harness copied from this checkout, settle.ps1, the arm's idle setting, bench-win.py for Inbuilts,
# Max4Live and VSTs at 120 s with 5 workers (as D0005's Windows runs), summarise.py, the idle setting before and after;
# then back to Linux (a restart: GRUB's default). Needs the ssh aliases ableton-laptop and ableton-win.
# Writes OUT/results.jsonl (one JSON line per Set-run, with "run"), OUT/<tag>.log per run, OUT/progress.log.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAG=${1:-d0010}
OUT=${OUT:-$HOME/profiler-crossos/$TAG}
ORDER=${ORDER:-"A1 B1 A2 B2"}
SETS="Inbuilts Max4Live VSTs"
WB='C:\Users\colby\AbletonBench'
WINPY='"C:\Program Files\Python313\python.exe"'
GUARD='C:\ProgramData\LiveIdleGuard\live-idle-guard.exe'
ENTRY="Windows Boot Manager (on /dev/nvme0n1p1)"
IDLE0="powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 0 && powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 0 && powercfg /setactive SCHEME_CURRENT"
IDLE1="powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 1 && powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 1 && powercfg /setactive SCHEME_CURRENT"
mkdir -p "$OUT"
say() { echo "$(date +%T) $*" | tee -a "$OUT/progress.log"; }
lin() { ssh -o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=30 ableton-laptop "$@"; }
win() { ssh -o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=30 ableton-win "$@"; }

wait_for() {  # linux|windows [timeout s]
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "${2:-900}" ]; do
    if [ "$1" = linux ]; then lin true 2>/dev/null && return 0; else win 'exit 0' 2>/dev/null && return 0; fi
    sleep 10
  done
  return 1
}

to_linux() {
  if win 'exit 0' 2>/dev/null; then win 'shutdown /r /t 2' > /dev/null 2>&1; sleep 30; fi
  wait_for linux 900
}

boot_windows() {  # ARM: a fresh boot into Windows, with C1E on for A (grubenv profiler_c1e=on for that boot)
  to_linux || { say "Linux did not come up"; return 1; }
  if [ "$1" = A ]; then lin "sudo -n grub-editenv - set profiler_c1e=on"; else lin "sudo -n grub-editenv - unset profiler_c1e"; fi
  lin "sudo -n grub-reboot '$ENTRY' && sudo -n systemctl reboot" > /dev/null 2>&1
  sleep 30
  wait_for windows 900 || { say "Windows did not come up"; return 1; }
}

run_windows() {  # TAG ARM
  local s dirs="" log="$OUT/$1.log"
  scp -q -o BatchMode=yes "$HERE/bench-win.py" "$HERE/summarise.py" "$HERE/settle.ps1" ableton-win:AbletonBench/ >> "$log" 2>&1 \
    || { echo "could not copy the harness" >> "$log"; : > "$OUT/$1.jsonl"; return 1; }
  win "powershell -NoProfile -ExecutionPolicy Bypass -File $WB\\settle.ps1" >> "$log" 2>&1
  if [ "$2" = A ]; then win "$IDLE0" >> "$log" 2>&1; else win "$IDLE1" >> "$log" 2>&1; fi
  echo "== idle setting before the Sets" >> "$log"; win "$GUARD status" >> "$log" 2>&1
  for s in $SETS; do
    win "$WINPY $WB\\bench-win.py --set Benchmark_$s --duration 120 --workers 5 --out $WB\\runs\\$1-$s" >> "$log" 2>&1
    dirs="$dirs $WB\\runs\\$1-$s"
  done
  win "$WINPY $WB\\summarise.py --json$dirs" > "$OUT/$1.jsonl" 2>> "$log"
  [ "$2" = A ] && win "$IDLE1" >> "$log" 2>&1        # back to the every-boot setting
  echo "== idle setting after the Sets" >> "$log"; win "$GUARD status" >> "$log" 2>&1
}

say "D0010 $TAG: order $ORDER; results in $OUT"
for r in $ORDER; do
  arm=${r:0:1}
  tag="$TAG-$r"
  say "boot into Windows ($arm: C1E $([ "$arm" = A ] && echo on || echo off)) for $tag"
  boot_windows "$arm" || exit 1
  say "run $tag ($arm)"
  run_windows "$tag" "$arm"
  tr -d '\r' < "$OUT/$tag.jsonl" | grep '^{' | sed "s/^{/{\"run\": \"$r\", /" >> "$OUT/results.jsonl"
  n=$(tr -d '\r' < "$OUT/$tag.jsonl" | grep -c '^{')
  say "run $tag done: $n Set results"
  [ "$n" -gt 0 ] || { say "run $tag produced no results (see $OUT/$tag.log); stopping"; to_linux; exit 1; }
done
to_linux && lin "sudo -n grub-editenv - unset profiler_c1e" && say "D0010 $TAG done (Linux up, C1E off on every boot again)"
