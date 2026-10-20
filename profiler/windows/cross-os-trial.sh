#!/usr/bin/env bash
# cross-os-trial.sh [TAG]: D0005, the interleaved Linux-vs-Windows comparison on the dual-boot laptop
# (profiler/plans/kernel-plan.md), driven from the workstation (Git Bash).
# Order A1 B1 A2 B2 A3 B3. A: Linux in the kept configuration (profiler/windows/linux-run.sh on the laptop). B: Windows
# 11 (profiler/windows/bench-win.py, 5 workers, after settle.ps1). Each run starts from a fresh boot into its OS, the
# boots alternating (from Linux: one-shot grub-reboot into Windows Boot Manager; from Windows: a restart, which GRUB's
# default turns into Linux), and runs Inbuilts, Max4Live and VSTs for 120 s each.
# Writes OUT/results.jsonl (one JSON line per Set-run, with "run"), OUT/<tag>.log per run, OUT/progress.log.
# Environment: ORDER (the runs, e.g. "A1 A2 A3" for Linux only), LINUX_CONFIG (kept, kept-wN or upstream, for
# profiler/windows/linux-run.sh), TRIAL_ID (D0005 by default; D0006 is the upstream-only Linux baseline, D0014 the
# kept configuration with 2 workers).
# Needs the ssh aliases ableton-laptop (Linux) and ableton-win (Windows), Windows auto-logon, and C:\Users\colby\AbletonBench
# (Sets, plugins); the harness (bench-win.py, summarise.py, settle.ps1) is copied there from this checkout before each
# Windows run.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAG=${1:-d0005}
TRIAL_ID=${TRIAL_ID:-D0005}
LINUX_CONFIG=${LINUX_CONFIG:-kept}
OUT=${OUT:-$HOME/profiler-crossos/$TAG}
ORDER=${ORDER:-"A1 B1 A2 B2 A3 B3"}
SETS="Inbuilts Max4Live VSTs"
WB='C:\Users\colby\AbletonBench'
WINPY='"C:\Program Files\Python313\python.exe"'
mkdir -p "$OUT"
say() { echo "$(date +%T) $*" | tee -a "$OUT/progress.log"; }
lin() { ssh -o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=30 ableton-laptop "$@"; }
win() { ssh -o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=30 ableton-win "$@"; }
current_os() { if lin true 2>/dev/null; then echo linux; elif win 'exit 0' 2>/dev/null; then echo windows; else echo none; fi; }

wait_for() {  # linux|windows [timeout s]
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "${2:-900}" ]; do
    if [ "$1" = linux ]; then lin true 2>/dev/null && return 0; else win 'exit 0' 2>/dev/null && return 0; fi
    sleep 10
  done
  return 1
}

boot_into() {  # linux|windows: a fresh boot into it
  local cur t0=$SECONDS
  cur=$(current_os)
  while [ "$cur" = none ] && [ $((SECONDS - t0)) -lt 600 ]; do   # mid-reboot: wait for either system
    sleep 15
    cur=$(current_os)
  done
  say "boot into $1 (now $cur)"
  case $cur in
    linux)
      if [ "$1" = windows ]; then lin 'sudo -n grub-reboot "Windows Boot Manager (on /dev/nvme0n1p1)" && sudo -n systemctl reboot'
      else lin 'sudo -n systemctl reboot'; fi ;;
    windows)
      if [ "$1" = linux ]; then win 'shutdown /r /t 2'
      else win 'bcdedit /set {fwbootmgr} bootsequence {bootmgr} && shutdown /r /t 2'; fi ;;
    *) say "neither system answers"; return 1 ;;
  esac
  sleep 30
  wait_for "$1" 900 || { say "$1 did not come up within 15 min"; return 1; }
  say "$1 up"
}

run_linux() {  # TAG-run
  lin "cd ~/Projects/ableton-linux && git fetch -q fork profiler && git merge -q --ff-only fork/profiler; profiler/windows/linux-run.sh $1 $LINUX_CONFIG $TRIAL_ID" \
    > "$OUT/$1.jsonl" 2> "$OUT/$1.log"
}

run_windows() {  # TAG-run
  local s dirs=""
  if ! scp -q -o BatchMode=yes -o ConnectTimeout=6 "$HERE/bench-win.py" "$HERE/summarise.py" "$HERE/settle.ps1" \
      ableton-win:AbletonBench/ >> "$OUT/$1.log" 2>&1; then
    echo "could not copy the harness to Windows" >> "$OUT/$1.log"
    : > "$OUT/$1.jsonl"
    return 1
  fi
  win "powershell -NoProfile -ExecutionPolicy Bypass -File $WB\\settle.ps1" >> "$OUT/$1.log" 2>&1
  for s in $SETS; do
    win "$WINPY $WB\\bench-win.py --set Benchmark_$s --duration 120 --workers 5 --out $WB\\runs\\$1-$s" >> "$OUT/$1.log" 2>&1
    dirs="$dirs $WB\\runs\\$1-$s"
  done
  win "$WINPY $WB\\summarise.py --json$dirs" > "$OUT/$1.jsonl" 2>> "$OUT/$1.log"
}

say "$TRIAL_ID $TAG: order $ORDER; Linux configuration $LINUX_CONFIG; results in $OUT"
for r in $ORDER; do
  os=linux
  case $r in B*) os=windows ;; esac
  tag="$TAG-$r"
  boot_into "$os" || exit 1
  say "run $tag on $os"
  if [ "$os" = linux ]; then run_linux "$tag"; else run_windows "$tag"; fi
  tr -d '\r' < "$OUT/$tag.jsonl" | grep '^{' | sed "s/^{/{\"run\": \"$r\", /" >> "$OUT/results.jsonl"
  n=$(tr -d '\r' < "$OUT/$tag.jsonl" | grep -c '^{')
  say "run $tag done: $n Set results"
  [ "$n" -gt 0 ] || { say "run $tag produced no results (see $OUT/$tag.log); stopping"; exit 1; }
done
[ "$(current_os)" = linux ] || boot_into linux
say "$TRIAL_ID $TAG done"
