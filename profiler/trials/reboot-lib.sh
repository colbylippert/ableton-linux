# reboot-lib.sh: reboot-per-run trials (kernel plan K2, K6), ported from T0015's step driver. Sourced after
# trial-lib.sh by a driver that sets TRIAL and ORDER and defines variant_of RUN (normal, rt, or a name from
# profiler/kernel/grub/variants) plus trial-lib's arm hooks; it then calls reboot_main "$@". REBOOT_KEEP may name
# more variables that start records and every step restores (the waiter starts steps without the environment).
#   DRIVER start      record the kept configuration (KEPT_LAYOUT, KEPT_WORKERS, KEPT_DISPLAY) and reboot into the
#                     first run's boot entry
#   DRIVER step       one run per boot, started by profiler/trials/reboot-waiter.sh once the laptop is back:
#                     stop the timers that fire after every boot, wait for the desktop session, check the boot
#                     variant, settle (120 s, then until the 1-minute load is below 1.0; at most 600 s), run, then
#                     reboot into the next run's entry (one-shot grub-reboot: the default entry never changes)
#   DRIVER status     one line for the waiter
#   DRIVER selftest   read-only checks (no Live, no reboot)
STATE=$S/trial-$TRIAL.state
OUT=$S/trial-$TRIAL.out
VARIANTS_FILE=$T/../kernel/grub/variants

boot_id() { cut -c1-8 /proc/sys/kernel/random/boot_id; }
get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }
put() {  # KEY VALUE
  { grep -v "^$1=" "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
mark() {  # MARKER [detail...]: a log line, and the waiter's view in the state file
  local m=$1; shift
  echo "$(date +%T) $m $* boot=$(boot_id)"
  put last "$m"; put last_boot "$(boot_id)"
}
next_run() {
  local r d=" $(get done) "
  for r in $ORDER; do case "$d" in *" $r "*) ;; *) echo "$r"; return ;; esac; done
}
variant_args() { awk -F'|' -v n="$1" '$1 == n && $1 !~ /^#/ { print $2; exit }' "$VARIANTS_FILE"; }
boot_variant() {  # the running boot's variant: the profiler variant whose arguments are all on the command line
  local name args tok ok best= bestn=0 n
  case $(uname -v) in *PREEMPT_RT*) echo rt; return ;; esac
  while IFS='|' read -r name args; do
    case $name in ''|'#'*) continue ;; esac
    ok=1; n=0
    for tok in $args; do n=$((n + 1)); tr ' ' '\n' < /proc/cmdline | grep -qxF -- "$tok" || { ok=0; break; }; done
    [ "$ok" = 1 ] && [ "$n" -gt "$bestn" ] && { best=$name; bestn=$n; }
  done < "$VARIANTS_FILE"
  echo "${best:-normal}"
}
grub_title() {  # VARIANT -> its GRUB menu entry
  local pat
  case $1 in
    normal) pat='with Linux linux-cachyos$' ;;
    rt) pat='with Linux linux-cachyos-rt-bore$' ;;
    *) pat="with Linux linux-cachyos \\(profiler: $1\\)\$" ;;
  esac
  sudo -n grep -oE "^menuentry '[^']*'" /boot/grub/grub.cfg | cut -d"'" -f2 | grep -E "$pat" | head -n 1
}
reboot_into() {  # VARIANT: one-shot GRUB entry, then reboot
  local title; title=$(grub_title "$1")
  [ -n "$title" ] || { mark TRIAL_ABORTED "no GRUB entry for $1 (sudo profiler/kernel/grub/install.sh)"; exit 1; }
  sudo -n grub-reboot "$title" || { mark TRIAL_ABORTED "grub-reboot failed for $title"; exit 1; }
  sync; sudo -n systemctl reboot
}
step_running() { ! flock -n "$S/trial-$TRIAL.step.lock" true 2>/dev/null; }

reboot_status() {
  if [ ! -f "$STATE" ]; then
    printf 'NEXT=none VARIANT=%s RUNNING=0 BOOT=%s LAST=nostate LAST_BOOT=none DONE=\n' "$(boot_variant)" "$(boot_id)"
    return
  fi
  printf 'NEXT=%s VARIANT=%s RUNNING=%s BOOT=%s LAST=%s LAST_BOOT=%s DONE=%s\n' "$(next_run || true)" "$(boot_variant)" \
    "$(step_running && echo 1 || echo 0)" "$(boot_id)" "$(get last)" "$(get last_boot)" "$(get done | xargs | tr ' ' ',')"
}

stop_boot_timers() {  # for this boot only; the units stay enabled
  local i
  sudo -n systemctl stop snapper-cleanup.timer systemd-tmpfiles-clean.timer 2>/dev/null
  systemctl --user stop arch-update.timer 2>/dev/null
  for i in $(seq 1 60); do  # one already started: let it finish
    if systemctl --user is-active -q arch-update.service \
      || systemctl is-active -q snapper-cleanup.service systemd-tmpfiles-clean.service; then sleep 5; else break; fi
  done
  echo "$(date +%T) timers stopped for this boot: snapper-cleanup systemd-tmpfiles-clean arch-update(user)"
}

wait_session() {  # the desktop session and PipeWire, up to 5 min
  local i
  for i in $(seq 1 60); do
    if systemctl --user is-active -q graphical-session.target && pgrep -x kwin_wayland >/dev/null \
      && pgrep -x plasmashell >/dev/null && systemctl --user is-active -q pipewire.service \
      && systemctl --user is-active -q wireplumber.service; then return 0; fi
    sleep 5
  done
  return 1
}

settle() {  # 120 s, then until the 1-minute load average is below 1.0; at most 600 s in all
  local la t0=$SECONDS
  sleep 120
  while [ $((SECONDS - t0)) -lt 600 ]; do
    read -r la _ < /proc/loadavg
    awk -v l="$la" 'BEGIN { exit !(l < 1.0) }' && break
    sleep 5
  done
  read -r la _ < /proc/loadavg
  echo "$(date +%T) settled: load $la after $((SECONDS - t0)) s, uptime $(cut -d' ' -f1 /proc/uptime)s"
}

reboot_finish() {
  (cd ~/Projects/ableton-linux && profiler/bin/state restore --name golden >/dev/null 2>&1)
  mark TRIAL_DONE "runs:$(get done)"
}

reboot_step() {
  local run arm want have nxt fails tag
  exec 7>"$S/trial-$TRIAL.step.lock"
  flock -n 7 || { echo "$(date +%T) STEP_BUSY boot=$(boot_id)"; exit 0; }
  [ -f "$STATE" ] || { echo "$(date +%T) no $TRIAL state"; exit 0; }
  KEPT_LAYOUT=$(get layout) KEPT_WORKERS=$(get workers) KEPT_DISPLAY=$(get display)
  export KEPT_LAYOUT KEPT_WORKERS KEPT_DISPLAY ABLETON_MAX_AUDIO_THREADS=$(get workers)
  local k val
  while IFS='=' read -r k val; do case $k in env_*) export "${k#env_}=$val" ;; esac; done < "$STATE"
  run=$(next_run)
  [ -n "$run" ] || { reboot_finish; exit 0; }
  arm=${run%[0-9]}; want=$(variant_of "$run"); tag=trial-$TRIAL-$run
  stop_boot_timers
  mark STEP_START "$run wants $want, uptime $(cut -d' ' -f1 /proc/uptime)s"
  wait_session || { mark TRIAL_ABORTED "no desktop session after 5 min"; exit 1; }
  have=$(boot_variant)
  echo "$(date +%T) kernel $(uname -r), boot variant $have, cmdline: $(cat /proc/cmdline | cut -c1-200)"
  [ "$have" = "$want" ] || { mark MODE_MISMATCH "$run wants $want, the boot is $have"; exit 1; }
  settle
  campaign_setup   # the session lock, checks and environment (trial-lib.sh); leaves us in the checkout
  [ -e "$R/$tag" ] && mv "$R/$tag" "$R/$tag.failed-$(date +%s)"
  if run_one "$tag" "$arm"; then
    profiler/bin/history-add "$R/$tag/bench" --trial "$TRIAL" --arm "$arm" >/dev/null 2>&1 || echo "$(date +%T) history-add failed for $tag"
    put done "$(get done) $run"; put fails 0
  else
    fails=$(( $(get fails) + 1 )); put fails "$fails"
    if [ "$fails" -ge 2 ]; then
      profiler/bin/state restore --name golden >/dev/null 2>&1
      mark TRIAL_ABORTED "$run failed twice"; exit 1
    fi
    echo "$(date +%T) $run failed; it runs again after a reboot"
  fi
  exec 9>&-
  nxt=$(next_run)
  if [ -z "$nxt" ]; then reboot_finish; exit 0; fi
  mark REBOOT "next=$nxt into $(variant_of "$nxt")"
  reboot_into "$(variant_of "$nxt")"
}

reboot_start() {
  local r v
  : "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
  [ -e "$STATE" ] && { echo "a $TRIAL state exists: $STATE"; exit 2; }
  pgrep -f 'Live 12 Trial.exe' >/dev/null && { echo "Live is running"; exit 2; }
  flock -n "$S/live-session.lock" true || { echo "the session lock is held (a trial or an install runs)"; exit 2; }
  for r in $ORDER; do v=$(variant_of "$r"); [ -n "$(grub_title "$v")" ] || { echo "no GRUB entry for $v"; exit 2; }; done
  printf 'order=%s\ndone=\nfails=0\nlayout=%s\nworkers=%s\ndisplay=%s\n' "$ORDER" "$KEPT_LAYOUT" "$KEPT_WORKERS" "$KEPT_DISPLAY" > "$STATE"
  for v in ${REBOOT_KEEP:-}; do put "env_$v" "${!v:-}"; done
  exec >>"$OUT" 2>&1
  r=$(next_run)
  mark START "$TRIAL order: $ORDER; layout=$KEPT_LAYOUT workers=$KEPT_WORKERS display=$KEPT_DISPLAY"
  mark REBOOT "next=$r into $(variant_of "$r")"
  reboot_into "$(variant_of "$r")"
}

reboot_selftest() {  # read-only: no Live, no reboot, no state
  local tmp r; tmp=$(mktemp -d)
  echo "boot variant now: $(boot_variant) ($(uname -r))"
  for r in $ORDER; do echo "$r -> $(variant_of "$r"): $(grub_title "$(variant_of "$r")")"; done
  echo "grubenv: $(sudo -n grub-editenv list | tr '\n' ' ')"
  STATE=$tmp/state; printf 'order=%s\ndone= A1 B1\nfails=0\n' "$ORDER" > "$STATE"
  echo "next after A1 B1: $(next_run) wants $(variant_of "$(next_run)")"
  put last REBOOT; put last_boot "$(boot_id)"; reboot_status
  sampler_start "$tmp/power.tsv"; sleep 12; sampler_stop
  echo "sampler: $(wc -l < "$tmp/power.tsv") rows; $(power_summary "$tmp/power.tsv")"
  rm -rf "$tmp"
}

reboot_main() {
  case "${1:-}" in
    start) reboot_start ;;
    step) exec >>"$OUT" 2>&1; reboot_step ;;
    status) reboot_status ;;
    selftest) reboot_selftest ;;
    *) echo "usage: ${0##*/} start | step | status | selftest"; exit 2 ;;
  esac
}
