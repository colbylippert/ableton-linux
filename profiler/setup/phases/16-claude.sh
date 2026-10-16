#!/usr/bin/env bash
# profiler/setup/phases/16-claude.sh — phase 16 "claude": Claude Code as a
# native binary (curl -fsSL https://claude.ai/install.sh | bash →
# ~/.local/bin/claude), ~/.local/bin on PATH for both shells the user gets —
# fish (the login shell: ~/.config/fish/conf.d/profiler.fish) and bash
# (~/.bashrc for interactive shells AND ~/.bash_profile for `bash -lc …`, the
# remote invocation form; the stock ~/.bashrc returns early for non-interactive
# shells, so a snippet there alone would never reach bash -lc) — plus the login
# instructions. Both snippets also source ~/.config/profiler/env (0600) when it
# exists, so CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token` is picked up.

phase_register 16 claude "Claude Code native install, PATH for bash and fish, login instructions" ""

_claude_marker='profiler PATH'
_claude_bin() { printf '%s/.local/bin/claude\n' "$HOME"; }
_claude_fish_conf() { printf '%s/fish/conf.d/profiler.fish\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
_claude_env_file() { printf '%s/env\n' "$PROFILER_CONFIG_DIR"; }
_claude_logged_in() { [ -s "$HOME/.claude/.credentials.json" ]; }   # OAuth credential store (heuristic)

_claude_login_help() {
    info "Claude Code login (once per machine):"
    kv "interactive" "ssh -t $(hostname 2>/dev/null || echo abletonlinux) 'bash -lc \"cd $REPO_DIR && claude\"'  →  /login  →  open the printed URL on the Windows host  →  paste the code"
    kv "token" "or run 'claude setup-token' on a machine with a browser and put CLAUDE_CODE_OAUTH_TOKEN=… into $(_claude_env_file) (mode 0600; both shells source it)"
    if _claude_logged_in; then
        ok "a Claude credential store exists (~/.claude/.credentials.json)"
    else
        action_required "log in to Claude Code once: claude → /login (or CLAUDE_CODE_OAUTH_TOKEN in $(_claude_env_file))"
    fi
}

phase_claude_check() {
    local bin ver envf
    bin="$(_claude_bin)"
    step "checking Claude Code"
    if [ -x "$bin" ]; then
        ver="$("$bin" --version 2>/dev/null | head -n1)"
        if [ -z "$ver" ]; then info "$bin exists but --version prints nothing"; return 1; fi
        ok "claude $ver ($bin)"
    elif command -v claude >/dev/null 2>&1; then
        ver="$(claude --version 2>/dev/null | head -n1)"
        ok "claude ${ver:-?} on PATH ($(command -v claude))"
    else
        info "claude is not installed"
        return 1
    fi
    if [ -f "$(_claude_fish_conf)" ]; then ok "fish PATH snippet present ($(_claude_fish_conf))"; else info "fish PATH snippet missing"; return 1; fi
    if grep -qF "$_claude_marker" "$HOME/.bashrc" 2>/dev/null; then ok "~/.bashrc has the PATH snippet"; else info "~/.bashrc lacks the PATH snippet"; return 1; fi
    if grep -qF "$_claude_marker" "$HOME/.bash_profile" 2>/dev/null; then ok "~/.bash_profile has the PATH snippet"; else info "~/.bash_profile lacks the PATH snippet"; return 1; fi
    if command -v fish >/dev/null 2>&1; then
        if fish -c 'command -v claude' >/dev/null 2>&1; then ok "fish -c 'command -v claude' works"; else warn "a fresh fish does not find claude (check ~/.config/fish/conf.d/profiler.fish)"; fi
    fi
    if bash -lc 'command -v claude' >/dev/null 2>&1; then ok "bash -lc 'command -v claude' works"; else warn "a fresh bash -lc does not find claude (check ~/.bash_profile)"; fi
    envf="$(_claude_env_file)"
    if [ -e "$envf" ]; then
        kv "env file" "$envf (mode $(stat -c %a -- "$envf" 2>/dev/null || echo ?))"
        [ "$(stat -c %a -- "$envf" 2>/dev/null)" = 600 ] || warn "$envf should be mode 0600 (it may hold CLAUDE_CODE_OAUTH_TOKEN)"
    fi
    _claude_logged_in && ok "credential store present" || info "not logged in yet (claude → /login)"
    phase_note "claude ${ver:-present}"
    return 0
}

# append the bash PATH snippet once (marker line) to FILE
_claude_append_snippet() {
    local f="$1"
    if grep -qF "$_claude_marker" "$f" 2>/dev/null; then
        skip "$f already has the profiler PATH snippet"
        return 0
    fi
    run -- sh -c 'printf "\n" >> "$2" && cat -- "$1" >> "$2"' append-snippet "$TEMPLATES_DIR/profiler.bashrc" "$f" || return 1
    is_dry_run || ok "appended the PATH snippet to $f"
}

phase_claude_apply() {
    local bin envf tmp
    require_cmd curl bash || return 1
    bin="$(_claude_bin)"
    if [ -x "$bin" ] && [ "$FORCE" != 1 ]; then
        skip "claude already installed at $bin ($("$bin" --version 2>/dev/null | head -n1))"
    else
        step "installing Claude Code (native binary → ~/.local/bin/claude)"
        run --timeout 900 -- bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash' || return 1
        is_dry_run || { [ -x "$bin" ] || { fail "the installer finished but $bin is missing"; return 1; }; }
    fi
    step "PATH snippets for fish and bash"
    write_template "$TEMPLATES_DIR/profiler.fish" "$(_claude_fish_conf)" --mode 0644 || return 1
    _claude_append_snippet "$HOME/.bashrc" || return 1
    _claude_append_snippet "$HOME/.bash_profile" || return 1
    if ! grep -q bashrc "$HOME/.bash_profile" 2>/dev/null; then
        ensure_line "$HOME/.bash_profile" '[[ -f ~/.bashrc ]] && . ~/.bashrc' || return 1
    fi
    envf="$(_claude_env_file)"
    if [ ! -e "$envf" ]; then
        tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/profiler-env.XXXXXX")" || { fail "mktemp failed"; return 1; }
        {
            printf '# ~/.config/profiler/env — sourced by ~/.bashrc, ~/.bash_profile and fish conf.d/profiler.fish\n'
            printf '# KEY=VALUE lines, no quotes. Keep this file mode 0600.\n'
            printf '# Claude Code without an interactive /login: run `claude setup-token` elsewhere and paste\n'
            printf '#CLAUDE_CODE_OAUTH_TOKEN=\n'
        } > "$tmp"
        if run -- install -D -m 0600 "$tmp" "$envf"; then rm -f -- "$tmp"; is_dry_run || ok "created $envf (0600)"; else rm -f -- "$tmp"; return 1; fi
    fi
    _claude_login_help
    phase_note "claude installed; PATH for fish + bash"
    return 0
}
