#!/usr/bin/env bash
# profiler/setup/phases/01-sudo.sh — phase 01 "sudo": make every later root
# operation non-interactive and install the profiler's root entry point.
#   * sudo credential: cached once (the driver's keepalive renews it) so that
#     `run --sudo` (= sudo -n) works for the rest of the run
#   * --passwordless-sudo (vm default): /etc/sudoers.d/90-profiler-<user> from
#     templates/sudoers-passwordless (<user> ALL=(root) NOPASSWD: ALL), rendered,
#     validated with `visudo -cf` on the temp copy, then installed 0440 root:root
#   * both profiles: the root helper profiler/setup/root-helper/profiler-root-helper
#     → /usr/local/sbin/profiler-root-helper (0755 root:root), its state dirs
#     (/var/lib/profiler, /usr/local/lib/profiler, /run/profiler) and
#     /etc/sudoers.d/91-profiler-helper (templates/sudoers-helper: NOPASSWD for
#     the helper only); vm profile: /etc/profiler/allow-user-tools lists the
#     checkout's profiler/ directory so the helper may run tracer tools from it
#   * the baseline of the host knobs: `profiler-root-helper snapshot` (first call
#     only; `profiler-root-helper reset` restores it later)
# Check (read-only): `sudo -n -l` lists the rules, the installed helper equals the
# source, `sudo -n profiler-root-helper version` works and reports the baseline.
# Under --dry-run sudo is never invoked, so the check reports what it cannot see
# and the apply prints the commands.
#
# This file also defines the _p1_* helpers shared by phases 01–08 (the driver
# sources every phase file before any phase runs):
#   _p1_user            the login name (USER, or id -un when unset)
#   _p1_show TEXT       stream captured text into the terminal + log, "│"-prefixed
#   _p1_need_relogin / _p1_need_reboot   the lib/phase.sh flags, raised once
#   _p1_live_running    0 when Live or a wineserver runs (phases that restart
#                       services or touch the audio graph refuse then)

phase_register 01 sudo "sudo credential, NOPASSWD rule (vm), root helper + sudoers rule, host-knob baseline" ""

: "${P1_HELPER_DST:=/usr/local/sbin/profiler-root-helper}"
: "${P1_ALLOW_USER_TOOLS:=/etc/profiler/allow-user-tools}"
: "${P1_HELPER_RULE:=/etc/sudoers.d/91-profiler-helper}"

# ------------------------------------------------------ shared helpers ----
_p1_user() { printf '%s\n' "${USER:-$(id -un)}"; }
_p1_show() {
    local line ts
    [ -n "${1:-}" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        ts="$(now_hms)"
        printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        _log_file "[$ts]     $G_BAR $line"
    done <<< "$1"
}
_p1_need_relogin() { [ "${NEED_RELOGIN:-0}" = 1 ] || need_relogin; }
_p1_need_reboot()  { [ "${NEED_REBOOT:-0}" = 1 ] || need_reboot; }
# Live ("Ableton Live*.exe" in a command line) or any wineserver
_p1_live_running() {
    local proc cmd
    for proc in /proc/[0-9]*; do
        cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*|wineserver*|*/wineserver*) return 0 ;; esac
    done
    return 1
}

# --------------------------------------------------------------- sudo ----
_sudo_helper_src() { printf '%s/root-helper/profiler-root-helper\n' "$SETUP_ROOT"; }
# sudoers.d skips file names containing '.' or '~': keep the user part plain
_sudo_rule_file() { local u="$1"; printf '/etc/sudoers.d/90-profiler-%s\n' "${u//[^A-Za-z0-9_-]/_}"; }

# render SRC, validate it with visudo -cf, then install it 0440 root:root at DST
_sudo_install_rule() {
    local src="$1" dst="$2" tmp out
    tmp="$(mktemp "$(_tmpdir)/sudoers.XXXXXX")" || { fail "mktemp failed"; return 1; }
    if ! USER="$(_p1_user)" render_template "$src" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    if out="$(visudo -cf "$tmp" 2>&1)"; then
        ok "visudo -cf: ${src##*/} parses OK"
    else
        _p1_show "$out"
        rm -f -- "$tmp"
        fail "visudo rejects the rendered ${src##*/}; nothing was installed" || return 1
    fi
    rm -f -- "$tmp"
    USER="$(_p1_user)" write_template "$src" "$dst" --sudo --mode 0440 --owner root:root
}

phase_sudo_check() {
    local user src dst list out rc
    user="$(_p1_user)"; src="$(_sudo_helper_src)"; dst="$P1_HELPER_DST"
    step "checking sudo rules and the root helper"
    if is_dry_run; then
        info "dry run: sudo is never invoked, so the sudoers rules and the baseline cannot be verified"
        if [ -x "$dst" ] && cmp -s "$src" "$dst"; then ok "root helper installed at $dst"; else info "root helper not installed or outdated at $dst"; fi
        return 1
    fi
    if ! list="$(sudo -n -l 2>/dev/null)"; then
        info "sudo -n -l fails: no cached credential and no NOPASSWD rule yet"
        return 1
    fi
    if [ "$PASSWORDLESS_SUDO" = 1 ]; then
        if grep -qE '^[[:space:]]*\(root\)[[:space:]]+NOPASSWD:[[:space:]]+ALL[[:space:]]*$' <<< "$list"; then
            ok "NOPASSWD ALL rule active for $user"
        else
            info "sudo -l lists no '(root) NOPASSWD: ALL' rule for $user ($(_sudo_rule_file "$user") not installed)"
            return 1
        fi
    else
        kv "passwordless sudo" "off ($PROFILE profile): sudo uses the cached credential"
    fi
    if [ ! -x "$dst" ]; then info "root helper not installed at $dst"; return 1; fi
    if ! cmp -s "$src" "$dst"; then info "root helper at $dst differs from $src (update pending)"; return 1; fi
    ok "root helper installed ($(sha256sum < "$dst" | cut -c1-16))"
    if ! grep -qE "NOPASSWD:.*(^|[[:space:],])$dst([[:space:],]|$)" <<< "$list"; then
        info "sudo -l lists no NOPASSWD rule for $dst ($P1_HELPER_RULE)"
        return 1
    fi
    ok "sudoers rule for the helper present"
    out="$(sudo -n -- "$dst" version 2>&1)"; rc=$?
    _p1_show "$out"
    if [ "$rc" -ne 0 ]; then info "sudo -n $dst version failed (exit $rc)"; return 1; fi
    if grep -q '^baseline=present' <<< "$out"; then
        ok "host-knob baseline present (/var/lib/profiler/baseline.env)"
    else
        info "host-knob baseline not taken yet (profiler-root-helper snapshot)"
        return 1
    fi
    if profile_is vm; then
        if [ -r "$P1_ALLOW_USER_TOOLS" ] && grep -qxF "$PROFILER_ROOT" "$P1_ALLOW_USER_TOOLS"; then
            ok "helper accepts tracer tools from $PROFILER_ROOT ($P1_ALLOW_USER_TOOLS)"
        else
            info "$P1_ALLOW_USER_TOOLS does not list $PROFILER_ROOT (vm profile)"
            return 1
        fi
    fi
    phase_note "sudo rules, helper $(sha256sum < "$dst" | cut -c1-8), baseline"
    return 0
}

phase_sudo_apply() {
    local user src dst
    require_cmd sudo visudo install cmp || return 1
    user="$(_p1_user)"; src="$(_sudo_helper_src)"; dst="$P1_HELPER_DST"
    [ -r "$src" ] || { fail "missing root helper source $src"; return 1; }
    step "sudo credential"
    if is_dry_run; then
        info "dry run: sudo is not invoked"
    elif sudo -n true 2>/dev/null; then
        ok "sudo works without a prompt (cached credential or NOPASSWD rule)"
    elif _have_tty; then
        info "sudo needs your password once (the keepalive renews the credential until the run ends)"
        sudo -v < /dev/tty || { fail "sudo -v failed"; return 1; }
        ok "credential cached"
    else
        fail "sudo needs a password but there is no terminal: run over 'ssh -t', or install the NOPASSWD rule by hand" || return 1
    fi
    if [ "$PASSWORDLESS_SUDO" = 1 ]; then
        step "NOPASSWD ALL rule for $user ($(_sudo_rule_file "$user"))"
        _sudo_install_rule "$TEMPLATES_DIR/sudoers-passwordless" "$(_sudo_rule_file "$user")" || return 1
    else
        info "passwordless sudo is off ($PROFILE profile / --no-passwordless-sudo): only the root helper gets a NOPASSWD rule"
    fi
    step "root helper $dst"
    if [ -x "$dst" ] && cmp -s "$src" "$dst"; then
        skip "$dst is current"
    else
        run --sudo -- install -m 0755 -o root -g root "$src" "$dst" || return 1
        is_dry_run || ok "installed $dst"
    fi
    run --sudo -- install -d -m 0755 -o root -g root /var/lib/profiler /usr/local/lib/profiler /run/profiler || return 1
    _sudo_install_rule "$TEMPLATES_DIR/sudoers-helper" "$P1_HELPER_RULE" || return 1
    if profile_is vm; then
        step "tracer tools from the checkout ($P1_ALLOW_USER_TOOLS)"
        run --sudo -- install -d -m 0755 -o root -g root /etc/profiler || return 1
        ensure_line "$P1_ALLOW_USER_TOOLS" "$PROFILER_ROOT" --sudo || return 1
        if [ -d "$REPO_DIR/profiler" ] && [ "$(readlink -m -- "$REPO_DIR/profiler")" != "$(readlink -m -- "$PROFILER_ROOT")" ]; then
            ensure_line "$P1_ALLOW_USER_TOOLS" "$REPO_DIR/profiler" --sudo || return 1
        fi
        case "$PROFILER_ROOT" in "$HOME"/*) ;; *) warn "$PROFILER_ROOT is outside $HOME: the helper only accepts user tools from directories under the invoking user's home" ;; esac
    elif [ -e "$P1_ALLOW_USER_TOOLS" ]; then
        warn "$P1_ALLOW_USER_TOOLS exists on the baremetal profile: the helper accepts tracer tools from the checkout (remove it to require install-tracer)"
    fi
    step "baseline of the host knobs (profiler-root-helper snapshot; kept on re-runs)"
    run --sudo -- "$dst" snapshot || return 1
    run --allow-fail -- "$dst" version || warn "profiler-root-helper version failed (exit $RUN_STATUS)"
    phase_note "sudo rules, helper, baseline"
    return 0
}
