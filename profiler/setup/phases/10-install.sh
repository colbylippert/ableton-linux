#!/usr/bin/env bash
# profiler/setup/phases/10-install.sh — phase 10 "install": the Wine runtime,
# the prefix and Ableton Live 12 through the repo's own installer
# (scripts/installer.sh install …), run inside the desktop session via
# profiler/bin/with-session-env (the Inno Setup payload needs a window
# connection), then PipeASIO pointed at the audio node the profiler drives.
#
# Flags (grammar at scripts/installer.sh:25-32 — `--power=performance|balanced|off`,
# `--audio-buffer=64|128|256|512|1024`, `--rt=auto|off`; INSTALLER.md "Pre-flight
# choices"): --live-installer FILE --live-major 12 --link=off --yes
# --audio-buffer=$AUDIO_BUFFER --audio-threads=auto --rt=auto --power=P --dpi=100
# --shortcuts=preserve. Profile values: vm → --power=off (buffer 128 by default);
# baremetal → --power=performance (the launcher then holds the
# power-profiles-daemon "performance" profile while Live runs) and buffer 64 by
# default. ABLETON_LIVE_INSTALL_TIMEOUT=7200 (installer default 3600 s, max 14400).
#
# PipeASIO device (~/.config/pipeasio/config.ini, keys output_device and
# input_device = a PipeWire node.name): --audio-device null → profiler-null (the
# null sink of phase audio); builtin → audio_node= from setup.conf (the speaker
# sink phase audio resolved and muted; resolved here read-only when phase audio
# has not recorded it yet); any other value → that node.name verbatim. Both keys
# name the same sink: PipeASIO connects its outputs to the sink's playback ports
# and finds no non-monitor capture ports on a sink, so no microphone (a second
# clock domain) is pulled into the graph.
#
# Output locations (scripts/lib/config.sh): runtime ~/.local/opt/wine-d2d1-nspa-11.13,
# prefix ~/.wine-ableton, config ~/.config/ableton-wine/{config,preferences},
# data ~/.local/share/ableton-wine, launcher ~/.local/bin/ableton-live, PipeASIO
# ~/.config/pipeasio/config.ini (seeded with the --audio-buffer value).
# Uses the _lp_* helpers from 09-build.sh and pwa_* from lib/host.sh.

phase_register 10 install "Ableton Live 12 + Wine runtime install (scripts/installer.sh)" "build,session,audio"

_install_power() { if profile_is baremetal; then printf 'performance\n'; else printf 'off\n'; fi; }
_install_pipeasio_ini() { printf '%s/pipeasio/config.ini\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# the node.name PipeASIO must use for AUDIO_DEVICE; 1 when it cannot be named
_install_audio_node() {
    local n
    case "${AUDIO_DEVICE:-null}" in
        null) printf 'profiler-null\n' ;;
        builtin)
            n="$(cfg_get audio_node)"
            if [ -z "$n" ] && declare -F pwa_resolve_device >/dev/null; then
                n="$(pwa_resolve_device builtin 2>/dev/null || true)"
            fi
            [ -n "$n" ] || return 1
            printf '%s\n' "$n" ;;
        *) printf '%s\n' "$AUDIO_DEVICE" ;;
    esac
}
# 0 when the node exists in PipeWire right now (phase audio created / found it)
_install_node_present() {
    declare -F pwa_node_id >/dev/null || return 1
    pwa_node_id "$1" >/dev/null
}
# value of KEY in the [pipeasio] section ("" when unset)
_install_ini_get() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | tail -n1 | sed 's/[[:space:]]*$//' || true
}

phase_install_check() {
    local rt prefix exe launcher ini n ver buf node out_dev in_dev
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"; launcher="$(_lp_launcher)"
    step "checking the runtime, the prefix and the launcher"
    kv "runtime" "$rt"
    kv "prefix" "$prefix"
    if [ ! -x "$rt/bin/wine" ] || [ ! -x "$rt/bin/wineserver" ]; then
        info "runtime not installed at $rt"
        return 1
    fi
    ver="$("$rt/bin/wine" --version 2>/dev/null | head -n1 || true)"
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
    buf="$(_install_ini_get "$ini" buffer_size)"
    kv "pipeasio config" "$ini (buffer_size ${buf:-?})"
    [ "${buf:-}" = "$AUDIO_BUFFER" ] || warn "PipeASIO buffer_size is ${buf:-unset}, setup expects $AUDIO_BUFFER (edit $ini or re-run with --audio-buffer)"
    if ! node="$(_install_audio_node)"; then
        info "--audio-device ${AUDIO_DEVICE:-?}: no audio node recorded or resolvable yet (phase audio records audio_node=)"
        return 1
    fi
    out_dev="$(_install_ini_get "$ini" output_device)"; in_dev="$(_install_ini_get "$ini" input_device)"
    kv "audio device" "${AUDIO_DEVICE:-null} → $node (config: output ${out_dev:-default}, input ${in_dev:-default})"
    if [ "$out_dev" != "$node" ] || [ "$in_dev" != "$node" ]; then
        info "PipeASIO is not pointed at $node yet"
        return 1
    fi
    ok "PipeASIO drives $node (output_device and input_device)"
    if ! _install_node_present "$node"; then
        warn "$node is not a PipeWire node right now (phase audio; wpctl status): Live would fall back to the default device"
    fi
    phase_note "Live 12 + runtime present; PipeASIO → $node"
    return 0
}

# point PipeASIO at NODE: key = value lines in the single [pipeasio] section;
# an existing key with another value is rewritten in place
_install_point_pipeasio() {
    local node="$1" ini key cur
    [[ "$node" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:@+-]*$ ]] || { fail "'$node' is not a PipeWire node.name ([A-Za-z0-9_.:@+-])"; return 1; }
    ini="$(_install_pipeasio_ini)"
    if [ ! -f "$ini" ]; then
        if is_dry_run; then info "would set output_device/input_device = $node in $ini (the installer seeds the file)"; return 0; fi
        fail "the installer did not seed $ini: PipeASIO cannot be pointed at $node" || return 1
    fi
    _install_node_present "$node" || warn "$node is not a PipeWire node right now (phase audio): writing it anyway"
    for key in output_device input_device; do
        cur="$(_install_ini_get "$ini" "$key")"
        if [ "$cur" = "$node" ]; then
            skip "$ini already has $key = $node"
        elif grep -qE "^[[:space:]]*$key[[:space:]]*=" "$ini"; then
            # node names contain dots and dashes only ([A-Za-z0-9_.:@+-]): safe in a sed replacement with | delimiters
            run -- sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $node|" "$ini" || return 1
            is_dry_run || ok "$ini: $key = $node (was ${cur:-empty})"
        else
            ensure_line "$ini" "$key = $node" || return 1
        fi
    done
    return 0
}

phase_install_apply() {
    local installer power rt prefix node
    require_cmd cabextract strings timeout tar zstd || return 1
    installer="$REPO_DIR/scripts/installer.sh"
    [ -x "$installer" ] || prereq_fail "missing $installer (phase repo)" || return 1
    [ -f "$LIVE_INSTALLER" ] || prereq_fail "Live installer not found: $LIVE_INSTALLER (phase media; the -N.bin slices must sit beside it)" || return 1
    if ! ls -- "$REPO_DIR"/dist/wine-d2d1-nspa-11.13-*.tar.zst >/dev/null 2>&1; then
        prereq_fail "no runtime tarball in $REPO_DIR/dist (phase build)" || return 1
    fi
    step "pre-checks"
    if _lp_prefix_busy; then
        fail "Live or Wine processes are using $(_lp_prefix); quit Live first (the installer refuses to continue without a terminal)" || return 1
    fi
    if "$PROFILER_ROOT/bin/with-session-env" true >/dev/null 2>&1; then
        ok "desktop session available ($("$PROFILER_ROOT/bin/with-session-env" --print 2>/dev/null | grep '^DISPLAY=' || echo 'DISPLAY=?'))"
    else
        prereq_fail "no desktop session (DISPLAY) in 'systemctl --user show-environment': log in on the console (phase session sets up autologin); the Inno Setup payload needs a window connection" || return 1
    fi
    if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ]; then
        ok "PipeWire socket present"
    else
        prereq_fail "PipeWire is not running (no ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0): the installer requires PipeWire >= 1.4.2" || return 1
    fi
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
    step "pointing PipeASIO at the audio device (--audio-device ${AUDIO_DEVICE:-null})"
    if node="$(_install_audio_node)"; then
        kv "audio node" "$node"
        _install_point_pipeasio "$node" || return 1
    else
        prereq_fail "--audio-device ${AUDIO_DEVICE:-?} names no PipeWire node (phase audio records audio_node=; wpctl status lists the sinks)" || return 1
    fi
    info "optional, not run here: cd $REPO_DIR && make check && make test (22 scripts)"
    phase_note "Live 12 installed (buffer $AUDIO_BUFFER, power $power${node:+, PipeASIO → $node})"
    return 0
}
