#!/usr/bin/env bash
# profiler/setup/phases/10-install.sh — phase 10 "install": the Wine runtime,
# the prefix and Ableton Live 12 through the repo's own installer
# (scripts/installer.sh install …), run inside the desktop session via
# profiler/bin/with-session-env (the Inno Setup payload needs a window
# connection), then PipeASIO pointed at the profiler-null sink that phase 06
# created (PipeASIO selects PipeWire nodes by node.name).
#
# Flags (grammar at scripts/installer.sh:25-32, INSTALLER.md "Pre-flight
# choices"): --live-installer FILE --live-major 12 --link=off --yes
# --audio-buffer=N --audio-threads=auto --rt=auto --power=P --dpi=100
# --shortcuts=preserve. Profile values: vm → --power=off, buffer 128 (default);
# baremetal → --power=performance, buffer 64. ABLETON_LIVE_INSTALL_TIMEOUT=7200
# (installer default 3600 s, max 14400).
#
# Output locations (scripts/lib/config.sh): runtime ~/.local/opt/wine-d2d1-nspa-11.13,
# prefix ~/.wine-ableton, config ~/.config/ableton-wine/{config,preferences},
# data ~/.local/share/ableton-wine, launcher ~/.local/bin/ableton-live, PipeASIO
# ~/.config/pipeasio/config.ini (seeded with the --audio-buffer value).
# Uses the _lp_* helpers from 09-build.sh.

phase_register 10 install "Ableton Live 12 + Wine runtime install (scripts/installer.sh)" "build,session,audio"

_install_power() { if profile_is baremetal; then printf 'performance\n'; else printf 'off\n'; fi; }
_install_pipeasio_ini() { printf '%s/pipeasio/config.ini\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
# the profiler-null sink exists (phase audio) — by PipeWire node listing or marker
_install_null_sink_present() {
    pw-cli ls Node 2>/dev/null | grep -q '"profiler-null"' && return 0
    phase_is_done audio
}

phase_install_check() {
    local rt prefix exe launcher ini n ver buf
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"; launcher="$(_lp_launcher)"
    step "checking the runtime, the prefix and the launcher"
    kv "runtime" "$rt"
    kv "prefix" "$prefix"
    if [ ! -x "$rt/bin/wine" ] || [ ! -x "$rt/bin/wineserver" ]; then
        info "runtime not installed at $rt"
        return 1
    fi
    ver="$("$rt/bin/wine" --version 2>/dev/null | head -n1)"
    if [ -z "$ver" ]; then warn "$rt/bin/wine --version prints nothing"; return 1; fi
    kv "wine" "$ver"
    if [ ! -f "$prefix/system.reg" ]; then info "prefix is incomplete (no system.reg)"; return 1; fi
    n="$(grep -ci pipeasio "$prefix/system.reg" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -eq 0 ]; then info "PipeASIO is not registered in $prefix/system.reg"; return 1; fi
    exe="$(_lp_live_exe "$prefix")"
    if [ -z "$exe" ]; then info "Live 12 is not installed in the prefix (…/drive_c/ProgramData/Ableton/Live 12*/Program/)"; return 1; fi
    kv "live exe" "$exe"
    if [ ! -x "$launcher" ]; then info "launcher missing: $launcher"; return 1; fi
    if ! "$launcher" --help >/dev/null 2>&1; then info "$launcher --help fails"; return 1; fi
    ok "runtime ($ver), PipeASIO registered ($n registry lines), Live 12 present, launcher works"
    ini="$(_install_pipeasio_ini)"
    if [ ! -r "$ini" ]; then info "no PipeASIO config at $ini"; return 1; fi
    buf="$(sed -n 's/^buffer_size *= *//p' "$ini" | head -n1)"
    kv "pipeasio config" "$ini (buffer_size ${buf:-?})"
    [ "${buf:-}" = "$AUDIO_BUFFER" ] || warn "PipeASIO buffer_size is ${buf:-unset}, setup expects $AUDIO_BUFFER (edit $ini or re-run with --audio-buffer)"
    if grep -qxE 'output_device *= *profiler-null' "$ini" && grep -qxE 'input_device *= *profiler-null' "$ini"; then
        ok "PipeASIO is pointed at the profiler-null sink"
    elif _install_null_sink_present; then
        info "PipeASIO is not pointed at the profiler-null sink yet"
        return 1
    else
        warn "profiler-null sink absent (phase audio not done): PipeASIO keeps its default device"
    fi
    phase_note "Live 12 + runtime present"
    return 0
}

# point PipeASIO at the profiler null sink: key = value lines in the single
# [pipeasio] section; an existing key with another value is rewritten in place
_install_point_pipeasio() {
    local ini key
    ini="$(_install_pipeasio_ini)"
    if [ ! -f "$ini" ]; then
        if is_dry_run; then info "would append output_device/input_device = profiler-null to $ini"; return 0; fi
        warn "the installer did not seed $ini; PipeASIO keeps its defaults"
        return 0
    fi
    if ! _install_null_sink_present; then
        warn "profiler-null sink not found (phase audio): leaving $ini on the default device"
        return 0
    fi
    for key in output_device input_device; do
        if grep -qxE "$key *= *profiler-null" "$ini"; then
            skip "$ini already has $key = profiler-null"
        elif grep -qE "^$key *=" "$ini"; then
            run -- sed -i "s/^$key *=.*/$key = profiler-null/" "$ini" || return 1
            is_dry_run || ok "$ini: $key = profiler-null"
        else
            ensure_line "$ini" "$key = profiler-null" || return 1
        fi
    done
    return 0
}

phase_install_apply() {
    local installer power rt prefix
    require_cmd cabextract strings timeout tar zstd || return 1
    installer="$REPO_DIR/scripts/installer.sh"
    [ -x "$installer" ] || { fail "missing $installer (phase repo)"; return 1; }
    [ -f "$LIVE_INSTALLER" ] || { fail "Live installer not found: $LIVE_INSTALLER (phase media; the -N.bin slices must sit beside it)"; return 1; }
    if ! ls -- "$REPO_DIR"/dist/wine-d2d1-nspa-11.13-*.tar.zst >/dev/null 2>&1; then
        fail "no runtime tarball in $REPO_DIR/dist (phase build)" || return 1
    fi
    step "pre-checks"
    if _lp_prefix_busy; then
        fail "Live or Wine processes are using $(_lp_prefix); quit Live first (the installer refuses to continue without a terminal)" || return 1
    fi
    if ! "$PROFILER_ROOT/bin/with-session-env" true >/dev/null 2>&1; then
        fail "no desktop session (DISPLAY) in 'systemctl --user show-environment': log in on the console (phase session enables SDDM autologin); the Inno Setup payload needs a window connection" || return 1
    fi
    ok "desktop session available ($("$PROFILER_ROOT/bin/with-session-env" --print 2>/dev/null | grep '^DISPLAY=' || echo 'DISPLAY=?'))"
    if [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ]; then
        fail "PipeWire is not running (no ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0): the installer requires PipeWire >= 1.4.2" || return 1
    fi
    ok "PipeWire socket present"
    power="$(_install_power)"
    kv "live installer" "$LIVE_INSTALLER"
    kv "audio buffer" "$AUDIO_BUFFER"
    kv "power profile" "$power ($PROFILE)"
    step "installing the runtime, the prefix and Live 12 (10–30 min; Inno Setup runs silently on the desktop)"
    info "non-interactive: --yes answers the overwrite question; other prompts take their default after 30 s (ABLETON_UI_PROMPT_TIMEOUT)"
    run -- env -C "$REPO_DIR" ABLETON_LIVE_INSTALL_TIMEOUT=7200 "$PROFILER_ROOT/bin/with-session-env" "$installer" install \
        --live-installer "$LIVE_INSTALLER" --live-major 12 --link=off --yes \
        "--audio-buffer=$AUDIO_BUFFER" --audio-threads=auto --rt=auto "--power=$power" --dpi=100 --shortcuts=preserve \
        || return 1
    is_dry_run || ok "installer finished"
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"
    cfg_set runtime_root "$rt" || return 1
    cfg_set prefix "$prefix" || return 1
    cfg_set launcher "$(_lp_launcher)" || return 1
    cfg_set live_exe "$(_lp_live_exe "$prefix")" || return 1
    is_dry_run && info "would record runtime_root/prefix/launcher/live_exe in $PROFILER_SETUP_CONF"
    step "pointing PipeASIO at the profiler-null sink"
    _install_point_pipeasio || return 1
    info "optional, not run here: cd $REPO_DIR && make check && make test (22 scripts)"
    phase_note "Live 12 installed (buffer $AUDIO_BUFFER, power $power)"
    return 0
}
