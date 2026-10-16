#!/usr/bin/env bash
# profiler/setup/phases/17-dashboard.sh — phase 17 "dashboard": the gains
# dashboard (Vite + React, profiler/dashboard/): `npm ci`, then the user unit
# profiler-dashboard.service (templates/profiler-dashboard.service →
# ~/.config/systemd/user/; ExecStart = npm run dev -- --host 0.0.0.0 --port 5173
# --strictPort; Restart=on-failure; WantedBy=default.target so it survives
# logouts once linger is enabled by phase podman), enabled and started.
# Skipped with a warning while profiler/dashboard/package.json does not exist.
# PROFILER_DASHBOARD_PORT overrides the port (default 5173).

phase_register 17 dashboard "Vite dashboard: npm ci + user unit profiler-dashboard.service (port 5173)" "packages"

: "${PROFILER_DASHBOARD_PORT:=5173}"

_dash_dir() { printf '%s/dashboard\n' "$PROFILER_ROOT"; }
_dash_unit() { printf '%s/systemd/user/profiler-dashboard.service\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
_dash_url() { printf 'http://%s:%s/\n' "$(hostname 2>/dev/null || echo localhost)" "$PROFILER_DASHBOARD_PORT"; }
_dash_unit_sum() { sha256sum < "$1" 2>/dev/null | cut -c1-16 || true; }
_dash_responds() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        curl -fs -m 3 -o /dev/null "http://127.0.0.1:$PROFILER_DASHBOARD_PORT/" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

phase_dashboard_check() {
    local dir
    dir="$(_dash_dir)"
    if [ ! -f "$dir/package.json" ]; then
        warn "profiler/dashboard/package.json does not exist yet (dashboard workstream): skipping the dashboard"
        phase_note "no dashboard sources"
        return 0
    fi
    step "checking the dashboard"
    if [ ! -d "$dir/node_modules" ] || [ ! -f "$dir/node_modules/.package-lock.json" ]; then info "node_modules missing (npm ci)"; return 1; fi
    if [ -f "$dir/package-lock.json" ] && [ "$dir/package-lock.json" -nt "$dir/node_modules/.package-lock.json" ]; then
        info "package-lock.json is newer than node_modules (npm ci)"
        return 1
    fi
    ok "node_modules installed"
    if [ ! -f "$(_dash_unit)" ]; then info "unit missing: $(_dash_unit)"; return 1; fi
    if ! systemctl --user is-enabled -q profiler-dashboard.service 2>/dev/null; then info "profiler-dashboard.service is not enabled"; return 1; fi
    if ! systemctl --user is-active -q profiler-dashboard.service 2>/dev/null; then info "profiler-dashboard.service is not active"; return 1; fi
    ok "profiler-dashboard.service enabled and active"
    if _dash_responds; then ok "dev server answers on port $PROFILER_DASHBOARD_PORT"; else warn "nothing answers on http://127.0.0.1:$PROFILER_DASHBOARD_PORT/ yet (journalctl --user -u profiler-dashboard.service)"; fi
    kv "url" "$(_dash_url)"
    phase_note "$(_dash_url)"
    return 0
}

phase_dashboard_apply() {
    local dir unit before after was_active=0
    dir="$(_dash_dir)"
    if [ ! -f "$dir/package.json" ]; then
        warn "profiler/dashboard/package.json does not exist yet: nothing to install"
        phase_note "no dashboard sources"
        return 0
    fi
    require_cmd npm node systemctl curl || return 1
    kv "node" "$(node --version 2>/dev/null || echo ?) · npm $(npm --version 2>/dev/null || echo ?)"
    if [ -d "$dir/node_modules" ] && [ -f "$dir/node_modules/.package-lock.json" ] && [ "$FORCE" != 1 ] \
       && ! { [ -f "$dir/package-lock.json" ] && [ "$dir/package-lock.json" -nt "$dir/node_modules/.package-lock.json" ]; }; then
        skip "node_modules is current"
    else
        step "npm ci in $dir (node_modules is git-ignored)"
        run --timeout 1800 -- env -C "$dir" npm ci || return 1
    fi
    step "user unit profiler-dashboard.service"
    unit="$(_dash_unit)"
    before="$(_dash_unit_sum "$unit")"
    systemctl --user is-active -q profiler-dashboard.service 2>/dev/null && was_active=1
    PROFILER_DASHBOARD_DIR="$dir" PROFILER_NPM="$(command -v npm)" \
        write_template "$TEMPLATES_DIR/profiler-dashboard.service" "$unit" --mode 0644 || return 1
    after="$(_dash_unit_sum "$unit")"
    run -- systemctl --user daemon-reload || return 1
    run -- systemctl --user enable --now profiler-dashboard.service || return 1
    if [ "$was_active" -eq 1 ] && [ "$before" != "$after" ]; then
        run -- systemctl --user restart profiler-dashboard.service || return 1
    fi
    is_dry_run && return 0
    if _dash_responds; then
        ok "dashboard is up: $(_dash_url)"
    else
        warn "the dev server does not answer on port $PROFILER_DASHBOARD_PORT yet: journalctl --user -u profiler-dashboard.service -n 50"
    fi
    info "from Windows: http://abletonlinux:$PROFILER_DASHBOARD_PORT/ · static build: cd $dir && npm run build"
    phase_note "$(_dash_url)"
    return 0
}
