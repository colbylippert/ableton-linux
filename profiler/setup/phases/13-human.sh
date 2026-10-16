#!/usr/bin/env bash
# profiler/setup/phases/13-human.sh — phase 13 "human": the one interactive
# step. Live is launched on the desktop (profiler/bin/with-session-env
# ~/.local/bin/ableton-live) with the checklist printed here; the phase waits
# until Live has been quit (File > Quit) — or Enter is pressed — and then
# verifies the evidence: the newest Preferences/Log.txt mentions PipeASIO and
# "Open: finished", no crash-recovery files (CrashDetection.cfg,
# CrashRecoveryInfo.cfg, BaseFiles/*) and no wineserver left for the prefix.
# Before the launch it takes the post-install snapshot (profiler/bin/state) if
# none exists, and clears stale crash-recovery state.
#
# With --yes (non-interactive) nothing is launched: the checklist is printed,
# an ACTIONS REQUIRED entry asks for `setup-machine.sh --only human`, the phase
# passes with a warning so the remaining phases can run, and phase golden
# defers its golden snapshot until the evidence exists.
# PROFILER_HUMAN_TIMEOUT (seconds, default 3600) bounds the wait.
# Uses the _lp_* helpers from 09-build.sh.

phase_register 13 human "first launch of Live: licence, ASIO/PipeASIO, AbletonOSC (manual checklist)" "install,osc,session"

: "${_HUMAN_DEFERRED:=0}"           # set by apply under --yes: check then passes with a warning
: "${PROFILER_HUMAN_TIMEOUT:=3600}"

# every Live 12 Preferences directory in the prefix, one per line
_human_prefs_dirs() {
    local prefix="${1:-$(_lp_prefix)}" d
    for d in "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/"Live "*/Preferences; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
    return 0
}

# the newest Preferences/Log.txt (by mtime); 1 when Live never ran
_human_log() {
    local d f newest="" newest_time=0 stamp
    while IFS= read -r d; do
        f="$d/Log.txt"
        [ -f "$f" ] || continue
        stamp="$(stat -c %Y -- "$f" 2>/dev/null || printf 0)"
        if [ "$stamp" -ge "$newest_time" ]; then newest="$f"; newest_time="$stamp"; fi
    done < <(_human_prefs_dirs "${1:-}")
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# crash-recovery files present in the prefix (SIGTERM-closed Live), one per line
_human_crash_files() {
    local d f
    while IFS= read -r d; do
        for f in "$d/CrashDetection.cfg" "$d/CrashRecoveryInfo.cfg"; do [ -e "$f" ] && printf '%s\n' "$f"; done
        if [ -d "$d/BaseFiles" ] && [ -n "$(find "$d/BaseFiles" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            printf '%s/BaseFiles/*\n' "$d"
        fi
    done < <(_human_prefs_dirs "${1:-}")
    return 0
}

# silent verdict shared with phase golden: 0 when the last Live session opened
# PipeASIO, quit cleanly, and nothing holds the prefix
_human_evidence() {
    local log
    log="$(_human_log)" || return 1
    grep -qa 'PipeASIO' "$log" || return 1
    grep -qa 'Open: finished' "$log" || return 1
    [ -z "$(_human_crash_files)" ] || return 1
    ! _lp_prefix_busy
}

_human_checklist() {
    local osc_note=""
    [ "$(cfg_get osc_status)" = installed ] || osc_note=" — (AbletonOSC is not installed yet: skip this item for now)"
    info "CHECKLIST — in Live on the $(hostname 2>/dev/null || echo VM) desktop (one time per machine):"
    kv "step 1" "accept the licence; authorise the Trial via ableton.com (browser inside the VM) or continue unauthorised (demo mode: no save/export)"
    kv "step 2" "Settings > Audio: Driver Type ASIO, Audio Device PipeASIO, Sample Rate 48000 (the buffer size is PipeASIO's: $AUDIO_BUFFER)"
    kv "step 3" "Settings > Link, Tempo & MIDI: Control Surface AbletonOSC, Input/Output None$osc_note"
    kv "step 4" "Settings > Licenses/Maintenance: auto-update and usage data off; Library: Cloud off; leave the GPU renderer at Live's default"
    kv "step 5" "File > Quit (Ctrl+Q) — never SIGTERM/kill Live: that leaves crash-recovery state and reopens the Set next time"
}

phase_human_check() {
    local prefix log crash r
    local -a reasons=()
    prefix="$(_lp_prefix)"
    step "checking the first-launch evidence in Live's Log.txt"
    if log="$(_human_log "$prefix")"; then
        kv "log" "$log"
        if grep -qa 'PipeASIO' "$log"; then ok "Log.txt mentions PipeASIO"; else reasons+=("Log.txt does not mention PipeASIO: Settings > Audio must select Driver Type ASIO, Device PipeASIO"); fi
        if grep -qa 'Open: finished' "$log"; then ok "the audio driver opened (Open: finished)"; else reasons+=("Log.txt has no 'Open: finished': the audio driver never opened"); fi
        if [ "$(cfg_get osc_status)" = installed ]; then
            if grep -qa 'AbletonOSC' "$log"; then ok "Log.txt mentions AbletonOSC"; else warn "Log.txt does not mention AbletonOSC (select it under Settings > Link, Tempo & MIDI > Control Surface; VERIFY the exact log line)"; fi
        fi
    else
        reasons+=("Live has not been started yet (no Preferences/Log.txt under $prefix)")
    fi
    crash="$(_human_crash_files "$prefix")"
    if [ -z "$crash" ]; then
        ok "no crash-recovery files"
    else
        reasons+=("crash-recovery files present (Live was not quit with File > Quit): $(printf '%s' "$crash" | tr '\n' ' ') — run profiler/bin/state clean-crash")
    fi
    if _lp_prefix_busy "$prefix"; then
        reasons+=("Live/Wine processes still hold the prefix: quit Live (Ctrl+Q) and wait for wineserver to exit")
    else
        ok "prefix idle (no wineserver)"
    fi
    if [ "${#reasons[@]}" -eq 0 ]; then
        phase_note "first launch verified"
        return 0
    fi
    for r in "${reasons[@]}"; do
        if [ "$_HUMAN_DEFERRED" = 1 ]; then warn "$r"; else info "$r"; fi
    done
    if [ "$_HUMAN_DEFERRED" = 1 ]; then phase_note "deferred (--yes)"; return 0; fi
    return 1
}

phase_human_apply() {
    local launcher prefix st launchlog t0 started=0 rc last_hint=0 waited
    launcher="$(_lp_launcher)"; prefix="$(_lp_prefix)"; st="$PROFILER_ROOT/bin/state"
    [ -x "$launcher" ] || { fail "launcher missing: $launcher (phase install)"; return 1; }
    [ -n "$(_lp_live_exe "$prefix")" ] || { fail "Live 12 is not installed in $prefix (phase install)"; return 1; }
    [ -x "$st" ] || { fail "missing $st"; return 1; }
    _human_checklist
    if [ "$ASSUME_YES" = 1 ]; then
        _HUMAN_DEFERRED=1
        warn "non-interactive run (--yes): Live is not launched; complete the checklist later with: $SETUP_ROOT/setup-machine.sh --only human"
        action_required "complete the Live first-launch checklist: setup-machine.sh --only human (interactive, desktop session logged in), then --only golden"
        phase_note "deferred (--yes)"
        return 0
    fi
    if _lp_prefix_busy "$prefix"; then
        fail "Live or Wine processes already use $prefix; quit Live (File > Quit) and re-run" || return 1
    fi
    if ! "$PROFILER_ROOT/bin/with-session-env" true >/dev/null 2>&1; then
        fail "no desktop session (DISPLAY) in 'systemctl --user show-environment': log in on the console (phase session enables SDDM autologin)" || return 1
    fi
    if "$st" list --names 2>/dev/null | grep -qx post-install; then
        skip "snapshot post-install already exists"
    else
        step "snapshot post-install (the state before Live ever ran)"
        run -- "$st" snapshot --name post-install || return 1
    fi
    run -- "$st" clean-crash || return 1
    launchlog="$(state_dir)/human-launch.log"
    step "launching Live on the desktop (launcher output: $launchlog)"
    run -- env HUMAN_LAUNCH_LOG="$launchlog" sh -c 'setsid -f "$@" > "$HUMAN_LAUNCH_LOG" 2>&1 < /dev/null' \
        human-launch "$PROFILER_ROOT/bin/with-session-env" "$launcher" || return 1
    if is_dry_run; then
        info "would wait for File > Quit (or Enter), then verify Log.txt, crash files and the wineserver"
        return 0
    fi
    info "work through the checklist in Live, then File > Quit. This phase continues when Live has exited"
    info "(or press Enter here after quitting; timeout ${PROFILER_HUMAN_TIMEOUT}s — PROFILER_HUMAN_TIMEOUT)"
    t0="$(_now_s)"
    while :; do
        waited=$(( $(_now_s) - t0 ))
        if _lp_prefix_busy "$prefix"; then
            [ "$started" -eq 1 ] || { started=1; ok "Live is running (pid $(_lp_live_pids | head -n1 || true))"; }
        elif [ "$started" -eq 1 ]; then
            ok "Live exited"
            break
        elif [ "$waited" -ge 180 ]; then
            fail "Live did not start within 180 s — see $launchlog" || return 1
        fi
        if [ "$waited" -ge "$PROFILER_HUMAN_TIMEOUT" ]; then
            fail "timed out after ${PROFILER_HUMAN_TIMEOUT}s waiting for Live to quit; quit it and re-run phase human" || return 1
        fi
        if [ "$started" -eq 1 ] && [ $(( waited - last_hint )) -ge 120 ]; then
            last_hint="$waited"
            info "still waiting (${waited}s): finish the checklist, then File > Quit (Ctrl+Q)"
        fi
        if _have_tty; then
            rc=0
            IFS= read -r -t 5 _ < /dev/tty || rc=$?
            if [ "$rc" -eq 0 ]; then info "Enter pressed"; break; fi
            [ "$rc" -gt 128 ] || sleep 5          # EOF on the tty: fall back to polling
        else
            sleep 5
        fi
    done
    # Enter may come a moment before wineserver is gone: give the prefix a minute to settle
    waited=0
    while _lp_prefix_busy "$prefix" && [ "$waited" -lt 60 ]; do sleep 2; waited=$(( waited + 2 )); done
    if _lp_prefix_busy "$prefix"; then
        warn "processes still hold the prefix; the verification below will report it"
    fi
    phase_note "first launch completed"
    return 0
}
