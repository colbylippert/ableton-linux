#!/usr/bin/env bash
# profiler/setup/phases/01-sudo.sh — phase 01 "sudo": make every later root
# operation non-interactive and install the profiler's root entry point.
#   * sudo credential: cached once (lib/phase.sh's keepalive renews it) so that
#     `run --sudo` (= sudo -n) works for the rest of the run
#   * --passwordless-sudo (vm default; the laptop runs with it): the rule file
#     /etc/sudoers.d/90-profiler-<user> from templates/sudoers-passwordless
#     (<user> ALL=(root) NOPASSWD: ALL), rendered, validated with `visudo -cf`
#     on the temp copy, then installed 0440 root:root. --no-passwordless-sudo
#     removes that file again.
#   * every profile: the root helper profiler/setup/root-helper/profiler-root-helper
#     → /usr/local/sbin/profiler-root-helper (0755 root:root), its state dirs
#     (/var/lib/profiler, /usr/local/lib/profiler; /run/profiler is created by the
#     helper on demand) and /etc/sudoers.d/91-profiler-helper (templates/
#     sudoers-helper: NOPASSWD for the helper only)
#   * vm profile, or any profile with passwordless sudo (the helper is then a
#     guard-rail, not a security boundary): /etc/profiler/allow-user-tools lists
#     the checkout's profiler/ directory so the helper may run tracer tools from it
#   * the baseline of the host knobs: `profiler-root-helper snapshot` (first call
#     only; `profiler-root-helper reset` restores it later). It runs before phase
#     02 disables ananicy-cpp and phase 04 changes sysctls, so the baseline holds
#     the distribution's values.
#   * record ~/.local/state/profiler/sudo.env: hashes of the rendered rules and
#     of the helper, so the check can be answered without sudo
# Check (read-only): helper installed, identical, root 0755; state dirs; baseline
# present; the record matches the current templates. Outside --dry-run it also
# proves the rules live: `sudo -n -k true` (NOPASSWD in force) and the rule files'
# contents read as root, or `sudo -n -k profiler-root-helper version` when only
# the helper rule exists. Under --dry-run (and verify.sh, which runs every check
# with DRY_RUN=1) sudo is never invoked: the record stands in for the root-only
# /etc/sudoers.d (0750), and verify.sh's privilege probe does the live test.
#
# This file also defines the _p1_* helpers shared by phases 01–08 (the driver
# sources every phase file before any phase runs):
#   _p1_user                 the login name (USER, or id -un when unset)
#   _p1_show TEXT            stream captured text into the terminal + log, "│"-prefixed
#   _p1_need_relogin / _p1_need_reboot   the lib/phase.sh flags, raised once
#   _p1_live_pids / _p1_live_running     Live processes: a Wine process (exe is a
#                            Wine binary) whose command line names "Ableton Live…​.exe";
#                            a shell that merely mentions the installer (this
#                            driver with --live-installer) never matches
#   _p1_laptop               0 on a laptop: LAPTOP=1 from the driver, else a
#                            system battery in /sys/class/power_supply
#   _p1_need_cmds CMD…       require_cmd, except that under --dry-run a missing
#                            command (installed by phase 02 later) is reported and
#                            tolerated so the dry run can print the whole plan
#   _p1_sha256               sha256 (hex) of stdin
#   _p1_record_get FILE KEY  value of KEY= in a record file ("" when absent)
#   _p1_record_write FILE    stdin → FILE (0644) through `run`
#   _p1_root_read FILE       print FILE read as root (sudo -n cat); never under --dry-run
#   _p1_template_current SRC DST   0 when the readable DST holds exactly the
#                            rendered SRC (USER is set for @@USER@@)

phase_register 01 sudo "sudo credential, NOPASSWD rule (--passwordless-sudo), root helper + sudoers rule, host-knob baseline" ""

: "${P1_HELPER_DST:=/usr/local/sbin/profiler-root-helper}"
: "${P1_ALLOW_USER_TOOLS:=/etc/profiler/allow-user-tools}"
: "${P1_HELPER_RULE:=/etc/sudoers.d/91-profiler-helper}"
: "${P1_BASELINE:=/var/lib/profiler/baseline.env}"

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

# pids of running Live instances, one per line. A match needs BOTH the command
# line ("Ableton Live…​.exe") and a Wine process image (/proc/PID/exe is wine,
# wine64, a preloader, or lies under */lib/wine/ or ~/.local/opt/wine-*), so the
# setup driver started with --live-installer ".../Ableton Live 12 Trial
# Installer.exe" (exe = bash) or an SSH wrapper never counts.
_p1_live_pids() {
    local proc pid cmd exe
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] && [ "$pid" != "$PPID" ] || continue
        cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.[eE][xX][eE]*) ;; *) continue ;; esac
        exe="$(readlink -f -- "$proc/exe" 2>/dev/null || true)"
        case "${exe##*/}" in
            wine|wine64|wine-preloader|wine64-preloader) printf '%s\n' "$pid"; continue ;;
        esac
        case "$exe" in
            */lib/wine/*|*/lib64/wine/*|"$HOME"/.local/opt/wine-*) printf '%s\n' "$pid" ;;
        esac
    done
    return 0
}
_p1_live_running() { [ -n "$(_p1_live_pids)" ]; }

# laptop toggles: the driver exports LAPTOP=1|0; without it, a battery whose
# scope is the system (a wireless mouse reports type=Battery with scope=Device)
_p1_laptop() {
    local d scope
    case "${LAPTOP:-}" in 1) return 0 ;; 0) return 1 ;; esac
    for d in /sys/class/power_supply/*; do
        [ -r "$d/type" ] || continue
        [ "$(cat "$d/type" 2>/dev/null)" = Battery ] || continue
        scope="$(cat "$d/scope" 2>/dev/null || true)"
        [ "$scope" = Device ] && continue
        return 0
    done
    return 1
}

_p1_need_cmds() {
    local c missing=()
    for c in "$@"; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ "${#missing[@]}" -gt 0 ] || return 0
    if is_dry_run; then
        info "dry run: ${missing[*]} not installed yet (phase packages installs it); the commands below are printed only"
        return 0
    fi
    fail "missing command(s): ${missing[*]} (phase packages)"
    return 1
}

_p1_sha256() { sha256sum | cut -c1-64; }
_p1_record_get() {
    local file="$1" key="$2" line
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
    done < "$file"
    return 0
}
_p1_record_write() {
    local file="$1" tmp
    _tmpdir >/dev/null || return 1
    tmp="$(mktemp "$PROFILER_TMPDIR/record.XXXXXX")" || { fail "mktemp failed"; return 1; }
    cat > "$tmp"
    if run --quiet -- install -D -m 0644 "$tmp" "$file"; then
        rm -f -- "$tmp"
        if is_dry_run; then info "would record $file"; else kv "record" "$file"; fi
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}
# FILE's content as root, exactly (trailing newlines kept); 1 when unreadable
_p1_root_read() {
    local out
    is_dry_run && return 1
    out="$(sudo -n cat -- "$1" 2>/dev/null && printf x)" || return 1
    printf '%s' "${out%x}"
}
_p1_template_current() {
    local src="$1" dst="$2" want have
    [ -r "$dst" ] || return 1
    want="$(USER="$(_p1_user)" render_template "$src" && printf x)" || return 1
    have="$(cat -- "$dst" && printf x)" || return 1
    [ "${want%x}" = "${have%x}" ]
}

# --------------------------------------------------------------- sudo ----
_sudo_helper_src() { printf '%s/root-helper/profiler-root-helper\n' "$SETUP_ROOT"; }
# sudoers.d skips file names containing '.' or '~': keep the user part plain
_sudo_rule_file() { local u="$1"; printf '/etc/sudoers.d/90-profiler-%s\n' "${u//[^A-Za-z0-9_-]/_}"; }
_sudo_record() { printf '%s/sudo.env\n' "$PROFILER_STATE_DIR"; }
_sudo_render() { local text; text="$(USER="$(_p1_user)" render_template "$1" && printf x)" || return 1; printf '%s' "${text%x}"; }
_sudo_render_sha() { _sudo_render "$1" | _p1_sha256; }
# user-tool roots the helper should accept: this checkout and the configured repo (under $HOME only)
_sudo_tool_roots() {
    local r out=()
    for r in "$PROFILER_ROOT" "$REPO_DIR/profiler"; do
        [ -d "$r" ] || continue
        r="$(readlink -m -- "$r")"
        case "$r" in "$HOME"/?*) ;; *) continue ;; esac
        _in_list "$r" ${out[@]+"${out[@]}"} || out+=("$r")
    done
    [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
}
_sudo_user_tools_wanted() { profile_is vm || [ "${PASSWORDLESS_SUDO:-0}" = 1 ]; }

# render SRC, validate it with visudo -cf, then install it 0440 root:root at DST
_sudo_install_rule() {
    local src="$1" dst="$2" tmp out
    _tmpdir >/dev/null || return 1
    tmp="$(mktemp "$PROFILER_TMPDIR/sudoers.XXXXXX")" || { fail "mktemp failed"; return 1; }
    if ! _sudo_render "$src" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
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

# 0 when the root-only rule file DST holds exactly the rendered SRC (needs sudo -n)
_sudo_rule_matches() {
    local src="$1" dst="$2" want have
    want="$(_sudo_render "$src" && printf x)" || return 1
    have="$(_p1_root_read "$dst" && printf x)" || return 1
    [ "${want%x}" = "${have%x}" ]
}

phase_sudo_check() {
    local user src dst rule90 rec owner mode r live=1 out rc
    user="$(_p1_user)"; src="$(_sudo_helper_src)"; dst="$P1_HELPER_DST"
    rule90="$(_sudo_rule_file "$user")"; rec="$(_sudo_record)"
    step "checking the root helper, its sudoers rule and the baseline"
    if [ ! -x "$dst" ]; then info "root helper not installed at $dst"; return 1; fi
    if ! cmp -s -- "$src" "$dst"; then info "root helper at $dst differs from $src (update pending)"; return 1; fi
    owner="$(stat -c %U -- "$dst" 2>/dev/null || echo ?)"; mode="$(stat -c %a -- "$dst" 2>/dev/null || echo ?)"
    if [ "$owner" != root ] || [ "$mode" != 755 ]; then info "$dst is $owner mode $mode, expected root 0755 (the helper refuses to run otherwise)"; return 1; fi
    ok "root helper installed ($(sha256sum < "$dst" | cut -c1-16), root 0755)"
    for r in /var/lib/profiler /usr/local/lib/profiler; do
        [ -d "$r" ] || { info "$r is missing"; return 1; }
    done
    if [ -s "$P1_BASELINE" ] && grep -q '^snapshot_ts=' "$P1_BASELINE" 2>/dev/null; then
        ok "host-knob baseline present ($P1_BASELINE, $(sed -n 's/^snapshot_ts=//p' "$P1_BASELINE" | head -n1))"
    else
        info "host-knob baseline not taken yet (profiler-root-helper snapshot)"
        return 1
    fi
    if _sudo_user_tools_wanted; then
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            if [ -r "$P1_ALLOW_USER_TOOLS" ] && grep -qxF -- "$r" "$P1_ALLOW_USER_TOOLS"; then
                ok "helper accepts tracer tools from $r ($P1_ALLOW_USER_TOOLS)"
            else
                info "$P1_ALLOW_USER_TOOLS does not list $r"
                return 1
            fi
        done < <(_sudo_tool_roots)
    elif [ -e "$P1_ALLOW_USER_TOOLS" ]; then
        warn "$P1_ALLOW_USER_TOOLS exists, but passwordless sudo is off on this $PROFILE profile: the helper runs tracer tools from the checkout (remove the file to require install-tracer)"
    fi
    # the record: what the last apply installed, comparable without root
    if [ "$(_p1_record_get "$rec" passwordless)" != "${PASSWORDLESS_SUDO:-0}" ] \
       || [ "$(_p1_record_get "$rec" rule_helper_sha256)" != "$(_sudo_render_sha "$TEMPLATES_DIR/sudoers-helper")" ] \
       || [ "$(_p1_record_get "$rec" helper_sha256)" != "$(_p1_sha256 < "$src")" ]; then
        info "no current record of the installed rules ($rec)"
        return 1
    fi
    if [ "${PASSWORDLESS_SUDO:-0}" = 1 ] && [ "$(_p1_record_get "$rec" rule_passwordless_sha256)" != "$(_sudo_render_sha "$TEMPLATES_DIR/sudoers-passwordless")" ]; then
        info "the recorded $rule90 does not match templates/sudoers-passwordless"
        return 1
    fi
    if is_dry_run; then
        info "dry run (or verify.sh): sudo is not invoked; the rules are taken from $rec ($(_p1_record_get "$rec" ts))"
        live=0
    fi
    if [ "$live" -eq 1 ]; then
        if [ "${PASSWORDLESS_SUDO:-0}" = 1 ]; then
            if ! sudo -n -k true 2>/dev/null; then info "sudo -n -k true needs a password: the NOPASSWD rule for $user is not in force"; return 1; fi
            ok "NOPASSWD ALL in force for $user"
            if ! _sudo_rule_matches "$TEMPLATES_DIR/sudoers-passwordless" "$rule90"; then info "$rule90 is missing or differs from the template"; return 1; fi
            if ! _sudo_rule_matches "$TEMPLATES_DIR/sudoers-helper" "$P1_HELPER_RULE"; then info "$P1_HELPER_RULE is missing or differs from the template"; return 1; fi
            ok "$rule90 and $P1_HELPER_RULE match the templates"
        else
            if ! sudo -n -k "$dst" version >/dev/null 2>&1; then info "sudo -n -k $dst version needs a password: $P1_HELPER_RULE is not in force"; return 1; fi
            ok "the helper runs through sudo -n without a password ($P1_HELPER_RULE)"
            if sudo -n true 2>/dev/null; then
                _sudo_rule_matches "$TEMPLATES_DIR/sudoers-helper" "$P1_HELPER_RULE" || { info "$P1_HELPER_RULE differs from the template"; return 1; }
                if sudo -n test -e "$rule90" 2>/dev/null; then info "$rule90 still exists although passwordless sudo is off"; return 1; fi
            fi
        fi
        out="$("$dst" version 2>&1)"; rc=$?
        [ "$rc" -eq 0 ] || { _p1_show "$out"; info "$dst version failed (exit $rc)"; return 1; }
    fi
    phase_note "helper $(sha256sum < "$dst" | cut -c1-8), rules, baseline$([ "${PASSWORDLESS_SUDO:-0}" = 1 ] && printf ', NOPASSWD')"
    return 0
}

phase_sudo_apply() {
    local user src dst rule90 r roots
    _p1_need_cmds sudo visudo install cmp sha256sum || return 1
    user="$(_p1_user)"; src="$(_sudo_helper_src)"; dst="$P1_HELPER_DST"; rule90="$(_sudo_rule_file "$user")"
    [ -r "$src" ] || { fail "missing root helper source $src"; return 1; }
    [ -r "$TEMPLATES_DIR/sudoers-helper" ] || { fail "missing template $TEMPLATES_DIR/sudoers-helper"; return 1; }
    step "sudo credential"
    if is_dry_run; then
        info "dry run: sudo is not invoked"
    elif sudo -n true 2>/dev/null; then
        ok "sudo works without a prompt (cached credential or NOPASSWD rule)"
    elif _have_tty; then
        info "sudo needs your password once (the keepalive renews the credential until the run ends)"
        # shellcheck disable=SC2024  # the redirect feeds sudo's own prompt, deliberately
        sudo -v < /dev/tty || { fail "sudo -v failed"; return 1; }
        ok "credential cached"
    else
        fail "sudo needs a password but there is no terminal: run over 'ssh -t', or install the NOPASSWD rule by hand" || return 1
    fi
    if [ "${PASSWORDLESS_SUDO:-0}" = 1 ]; then
        step "NOPASSWD ALL rule for $user ($rule90)"
        _sudo_install_rule "$TEMPLATES_DIR/sudoers-passwordless" "$rule90" || return 1
    else
        info "passwordless sudo is off ($PROFILE profile / --no-passwordless-sudo): only the root helper gets a NOPASSWD rule"
        if ! is_dry_run && sudo -n test -e "$rule90" 2>/dev/null; then
            run --sudo -- rm -f -- "$rule90" || return 1
            ok "removed $rule90 (passwordless sudo switched off)"
        fi
    fi
    step "root helper $dst"
    if [ -x "$dst" ] && cmp -s -- "$src" "$dst"; then
        skip "$dst is current"
    else
        run --sudo -- install -D -m 0755 -o root -g root "$src" "$dst" || return 1
        is_dry_run || ok "installed $dst"
    fi
    run --sudo -- install -d -m 0755 -o root -g root /var/lib/profiler /usr/local/lib/profiler || return 1
    _sudo_install_rule "$TEMPLATES_DIR/sudoers-helper" "$P1_HELPER_RULE" || return 1
    if _sudo_user_tools_wanted; then
        step "tracer tools from the checkout ($P1_ALLOW_USER_TOOLS)"
        roots="$(_sudo_tool_roots)"
        if [ -z "$roots" ]; then
            warn "neither $PROFILER_ROOT nor $REPO_DIR/profiler lies under $HOME: the helper accepts user tools only from the invoking user's home; use install-tracer"
        else
            [ -d "${P1_ALLOW_USER_TOOLS%/*}" ] || run --sudo -- install -d -m 0755 -o root -g root "${P1_ALLOW_USER_TOOLS%/*}" || return 1
            while IFS= read -r r; do
                [ -n "$r" ] || continue
                ensure_line "$P1_ALLOW_USER_TOOLS" "$r" --sudo || return 1
            done <<< "$roots"
        fi
    fi
    step "baseline of the host knobs (profiler-root-helper snapshot; an existing baseline is kept)"
    run --sudo -- "$dst" snapshot || return 1
    if ! is_dry_run; then
        run --allow-fail -- "$dst" version || warn "profiler-root-helper version failed (exit $RUN_STATUS)"
    fi
    step "recording the installed rules ($(_sudo_record))"
    _p1_record_write "$(_sudo_record)" < <(
        printf '# written by profiler/setup/phases/01-sudo.sh; read by its check (no sudo needed)\n'
        printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'user=%s\n' "$user"
        printf 'passwordless=%s\n' "${PASSWORDLESS_SUDO:-0}"
        if [ "${PASSWORDLESS_SUDO:-0}" = 1 ]; then
            printf 'rule_passwordless=%s\n' "$rule90"
            printf 'rule_passwordless_sha256=%s\n' "$(_sudo_render_sha "$TEMPLATES_DIR/sudoers-passwordless")"
        fi
        printf 'rule_helper=%s\n' "$P1_HELPER_RULE"
        printf 'rule_helper_sha256=%s\n' "$(_sudo_render_sha "$TEMPLATES_DIR/sudoers-helper")"
        printf 'helper=%s\n' "$dst"
        printf 'helper_sha256=%s\n' "$(_p1_sha256 < "$src")"
        printf 'user_tools=%s\n' "$(_sudo_user_tools_wanted && _sudo_tool_roots | paste -sd, - || printf off)"
    ) || return 1
    phase_note "helper, rules$([ "${PASSWORDLESS_SUDO:-0}" = 1 ] && printf ' (NOPASSWD)'), baseline"
    return 0
}
