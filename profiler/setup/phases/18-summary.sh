#!/usr/bin/env bash
# profiler/setup/phases/18-summary.sh — phase 18 "summary": the state of the
# machine in one block (runtime, prefix, Live, snapshots, AbletonOSC, Claude,
# dashboard), the outstanding actions (re-login, reboot, deferred human/golden,
# osc pending) and the "Next" commands. The phase table itself, WARNINGS and
# ACTIONS REQUIRED are printed by the driver's exit trap (lib/phase.sh) after
# this phase, so this phase only reports. Its check passes only after apply
# has run in this process, so the summary is printed on every run.
# Uses the _lp_* helpers from 09-build.sh, _human_evidence from 13-human.sh.

phase_register 18 summary "summary of the machine state, outstanding actions and next steps" "all"

: "${_SUMMARY_DONE:=0}"

phase_summary_check() { [ "$_SUMMARY_DONE" = 1 ]; }

phase_summary_apply() {
    local rt prefix exe launcher st snaps osc claude dash url outstanding=0
    _SUMMARY_DONE=1
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"; launcher="$(_lp_launcher)"; st="$PROFILER_ROOT/bin/state"
    step "machine state"
    kv "profile" "$PROFILE on $(hostname 2>/dev/null || uname -n) ($(systemd-detect-virt 2>/dev/null || echo unknown) virtualization)"
    kv "repo" "$REPO_DIR ($(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no git')) "
    if [ -x "$rt/bin/wine" ]; then kv "runtime" "$rt ($("$rt/bin/wine" --version 2>/dev/null | head -n1))"; else kv "runtime" "$rt (missing)"; fi
    exe="$(_lp_live_exe "$prefix")"
    kv "prefix" "$prefix$([ -f "$prefix/system.reg" ] || printf ' (missing)')"
    kv "live" "${exe:-not installed}"
    kv "launcher" "$launcher$([ -x "$launcher" ] || printf ' (missing)')"
    snaps="$("$st" list --names 2>/dev/null | tr '\n' ' ' || true)"
    kv "snapshots" "${snaps:-none}"
    kv "user library" "$(cfg_get user_library '(not recorded)')"
    osc="$(cfg_get osc_status 'not installed')"
    kv "abletonosc" "$osc"
    if [ -x "$HOME/.local/bin/claude" ]; then claude="$("$HOME/.local/bin/claude" --version 2>/dev/null | head -n1)"; else claude="$(command -v claude 2>/dev/null || true)"; fi
    kv "claude" "${claude:-not installed}"
    url="http://$(hostname 2>/dev/null || echo localhost):${PROFILER_DASHBOARD_PORT:-5173}/"
    if systemctl --user is-active -q profiler-dashboard.service 2>/dev/null; then dash="$url (active)"; else dash="$url (unit not active)"; fi
    kv "dashboard" "$dash"
    kv "build log" "$(readlink -f -- "$PROFILER_STATE_DIR/build-latest.log" 2>/dev/null || echo none)"
    kv "setup log" "${LOGFILE:-(none)}"

    step "outstanding"
    if [ "$NEED_RELOGIN" = 1 ]; then info "log out and back in: group/limit changes apply at login"; outstanding=1; fi
    if [ "$NEED_REBOOT" = 1 ]; then info "reboot: kernel/package changes apply at boot"; outstanding=1; fi
    if [ "$osc" != installed ]; then info "AbletonOSC: $osc — re-run phase osc once profiler/control/install.sh exists, then select it in Live"; outstanding=1; fi
    if [ -n "$exe" ] && ! _human_evidence; then info "the Live first-launch checklist is not complete: setup-machine.sh --only human"; outstanding=1; fi
    if ! "$st" list --names 2>/dev/null | grep -qx golden; then info "no golden snapshot yet: setup-machine.sh --only golden (after the checklist)"; outstanding=1; fi
    [ "$WARN_COUNT" -eq 0 ] || info "$WARN_COUNT warning(s) so far — listed under WARNINGS below"
    [ "$outstanding" -eq 1 ] || ok "nothing outstanding"

    step "next"
    kv "verify" "$SETUP_ROOT/verify.sh"
    kv "tracer" "$PROFILER_ROOT/bin/trace-prereqs"
    kv "smoke" "$PROFILER_ROOT/bin/bench --dry-run --tag smoke      (then: --tag baseline)"
    kv "restore" "$st restore --name golden      (before every trial)"
    kv "claude" "ssh -t $(hostname 2>/dev/null || echo abletonlinux) 'bash -lc \"cd $REPO_DIR && claude\"'      (on the VM: claude)"
    kv "dashboard" "$url"
    ok "setup phases complete — the table below has the per-phase result"
    phase_note "see above"
    return 0
}
