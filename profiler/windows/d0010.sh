#!/usr/bin/env bash
# d0010.sh [TAG]: D0010, T0031's change on Windows (profiler/plans/kernel-plan.md), driven from the workstation (Git Bash).
# Order A1 B1 A2 B2, each run on a fresh Windows boot through GRUB (from Linux, a one-shot grub-reboot into the entry):
#   A  "Windows Boot Manager (on /dev/nvme0n1p1)": C1E on, as the firmware sets it; LiveIdleGuard stopped and
#      IDLESTATEMAX reset to 0 (every idle state)
#   B  "Windows Boot Manager, C1E off (profiler)": GRUB clears C1E (46_profiler-c1e-off); LiveIdleGuard started, so
#      the cores idle no deeper than C1 while Live runs
# Each run: the harness copied from this checkout, settle.ps1, the service set for the arm, bench-win.py for Inbuilts,
# Max4Live and VSTs at 120 s with 5 workers (as D0005's Windows runs), summarise.py, the service's status and log;
# then back to Linux (a restart: GRUB's default). Needs LiveIdleGuard installed (install --manual) in
# C:\ProgramData\LiveIdleGuard and the ssh aliases ableton-laptop and ableton-win.
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
ENTRY_A="Windows Boot Manager (on /dev/nvme0n1p1)"
ENTRY_B="Windows Boot Manager, C1E off (profiler)"
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

boot_windows() {  # ENTRY: a fresh boot into Windows through that GRUB entry
  to_linux || { say "Linux did not come up"; return 1; }
  lin "sudo -n grub-reboot '$1' && sudo -n systemctl reboot" > /dev/null 2>&1
  sleep 30
  wait_for windows 900 || { say "Windows did not come up through '$1'"; return 1; }
}

run_windows() {  # TAG ARM
  local s dirs="" log="$OUT/$1.log"
  scp -q -o BatchMode=yes "$HERE/bench-win.py" "$HERE/summarise.py" "$HERE/settle.ps1" ableton-win:AbletonBench/ >> "$log" 2>&1 \
    || { echo "could not copy the harness" >> "$log"; : > "$OUT/$1.jsonl"; return 1; }
  win "powershell -NoProfile -ExecutionPolicy Bypass -File $WB\\settle.ps1" >> "$log" 2>&1
  if [ "$2" = B ]; then
    win "sc start LiveIdleGuard" >> "$log" 2>&1
  else
    win "sc stop LiveIdleGuard" >> "$log" 2>&1
    win "powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 0 && powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IDLESTATEMAX 0 && powercfg /setactive SCHEME_CURRENT" >> "$log" 2>&1
  fi
  echo "== service before the Sets" >> "$log"; win "$GUARD status" >> "$log" 2>&1
  for s in $SETS; do
    win "$WINPY $WB\\bench-win.py --set Benchmark_$s --duration 120 --workers 5 --out $WB\\runs\\$1-$s" >> "$log" 2>&1
    dirs="$dirs $WB\\runs\\$1-$s"
  done
  win "$WINPY $WB\\summarise.py --json$dirs" > "$OUT/$1.jsonl" 2>> "$log"
  echo "== service after the Sets" >> "$log"; win "$GUARD status" >> "$log" 2>&1
  echo "== service log" >> "$log"; win 'powershell -NoProfile -Command "Get-Content C:\ProgramData\LiveIdleGuard\live-idle-guard.log -Tail 12"' >> "$log" 2>&1
  if [ "$2" = B ]; then win "sc stop LiveIdleGuard" >> "$log" 2>&1; fi
}

say "D0010 $TAG: order $ORDER; results in $OUT"
for r in $ORDER; do
  arm=${r:0:1}
  entry=$ENTRY_A
  [ "$arm" = B ] && entry=$ENTRY_B
  tag="$TAG-$r"
  say "boot into '$entry' for $tag"
  boot_windows "$entry" || exit 1
  say "run $tag ($arm)"
  run_windows "$tag" "$arm"
  tr -d '\r' < "$OUT/$tag.jsonl" | grep '^{' | sed "s/^{/{\"run\": \"$r\", /" >> "$OUT/results.jsonl"
  n=$(tr -d '\r' < "$OUT/$tag.jsonl" | grep -c '^{')
  say "run $tag done: $n Set results"
  [ "$n" -gt 0 ] || { say "run $tag produced no results (see $OUT/$tag.log); stopping"; to_linux; exit 1; }
done
to_linux && say "D0010 $TAG done (Linux up)"
