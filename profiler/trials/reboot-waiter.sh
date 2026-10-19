#!/usr/bin/env bash
# reboot-waiter.sh TRIAL [--host HOST]: drives a reboot-per-run trial (profiler/trials/reboot-lib.sh) from the
# controlling host. Start the trial on the laptop first (profiler/trials/trial-TRIAL.sh start: it records its state
# and reboots). The waiter starts one step on every new boot that follows a REBOOT or START mark, and returns 0 when
# the trial is done, 1 when it stopped (TRIAL_ABORTED, MODE_MISMATCH), 3 when the laptop stays unreachable for 15 min.
set -u
trial=${1:?usage: reboot-waiter.sh TRIAL [--host HOST]}
host=ableton-laptop
[ "${2:-}" = --host ] && host=${3:?}
drv=profiler/trials/trial-$trial.sh
remote() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" bash -s; }   # the laptop's login shell is fish
field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }
started_boot= seen=$SECONDS
while :; do
  if ! s=$(remote <<<"cd ~/Projects/ableton-linux && $drv status" 2>/dev/null) || [ -z "$s" ]; then
    [ $((SECONDS - seen)) -lt 900 ] || { echo "$(date +%T) $trial: $host unreachable for 15 min"; exit 3; }
    sleep 10; continue
  fi
  seen=$SECONDS
  last=$(field LAST "$s"); boot=$(field BOOT "$s"); last_boot=$(field LAST_BOOT "$s"); running=$(field RUNNING "$s")
  case $last in
    TRIAL_DONE) echo "$(date +%T) $trial done: $s"; exit 0 ;;
    TRIAL_ABORTED|MODE_MISMATCH) echo "$(date +%T) $trial stopped: $s"; exit 1 ;;
  esac
  if [ "$running" = 0 ] && [ "$boot" != "$last_boot" ] && [ "$boot" != "$started_boot" ] &&
     { [ "$last" = REBOOT ] || [ "$last" = START ]; }; then
    remote <<<"cd ~/Projects/ableton-linux && setsid -f $drv step > /dev/null 2>&1 < /dev/null"
    started_boot=$boot
    echo "$(date +%T) $trial: step started on boot $boot ($s)"
  fi
  sleep 30
done
