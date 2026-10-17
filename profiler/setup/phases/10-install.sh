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
# input_device = PipeWire node.names): phase audio (06-audio.sh) owns the
# decision and records it in setup.conf — audio_node= (the sink: profiler-null
# for --audio-device null, the built-in speaker sink for builtin, the given
# node.name otherwise), audio_input= (a capture source on the sink's own card,
# so capture shares its hardware clock: the mirror name pro-output-N →
# pro-input-N or …__sink → …__source, else the card's first Mic source, else its
# first source — pwa_resolve_input in setup/lib/host.sh; null: profiler-null)
# and audio_mute=. The installer seeds config.ini only here, so this
# phase points it right after the install through phase audio's own
# _aud_point_pipeasio (one writer, one format); check compares the file with the
# recorded pair. When the runtime, prefix, Live and launcher are already
# present and only the PipeASIO keys are off, apply does not re-run the
# installer (--force does).
# Output locations (scripts/lib/config.sh): runtime ~/.local/opt/wine-d2d1-nspa-11.13,
# prefix ~/.wine-ableton, config ~/.config/ableton-wine/{config,preferences},
# data ~/.local/share/ableton-wine, launcher ~/.local/bin/ableton-live, PipeASIO
# ~/.config/pipeasio/config.ini (seeded with the --audio-buffer value).
# Uses the _lp_* helpers from 09-build.sh and pwa_* from lib/host.sh.

phase_register 10 install "Ableton Live 12 + Wine runtime install (scripts/installer.sh)" "build,session,audio"

_install_power() { if profile_is baremetal; then printf 'performance\n'; else printf 'off\n'; fi; }
_install_pipeasio_ini() { printf '%s/pipeasio/config.ini\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# the node.name PipeASIO must drive: audio_node= recorded by phase audio, else
# derived from AUDIO_DEVICE (null → profiler-null, builtin → resolved read-only,
# NODE → NODE); 1 when it cannot be named
_install_audio_node() {
    local n
    n="$(cfg_get audio_node)"
    if [ -z "$n" ]; then
        case "${AUDIO_DEVICE:-null}" in
            null) n=profiler-null ;;
            builtin) if declare -F pwa_resolve_device >/dev/null; then n="$(pwa_resolve_device builtin 2>/dev/null || true)"; fi ;;
            *) n="$AUDIO_DEVICE" ;;
        esac
    fi
    [ -n "$n" ] || return 1
    printf '%s\n' "$n"
}
# the capture node.name to pair with it ("" = input_device unset): audio_input=
# when phase audio recorded the pair, else profiler-null for the null sink
_install_audio_input() {
    if [ -n "$(cfg_get audio_node)" ]; then cfg_get audio_input; return 0; fi
    [ "${AUDIO_DEVICE:-null}" != null ] || printf 'profiler-null\n'
    return 0
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
# silent: 0 when the runtime, the prefix (PipeASIO registered), Live 12 and a
# working launcher are present — the installer's part of this phase is done
_install_core_present() {
    local rt prefix launcher
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"; launcher="$(_lp_launcher)"
    [ -x "$rt/bin/wine" ] && [ -x "$rt/bin/wineserver" ] || return 1
    [ -n "$("$rt/bin/wine" --version 2>/dev/null | head -n1 || true)" ] || return 1
    [ -f "$prefix/system.reg" ] && grep -qi pipeasio "$prefix/system.reg" 2>/dev/null || return 1
    [ -n "$(_lp_live_exe "$prefix")" ] || return 1
    [ -x "$launcher" ] && "$launcher" --help >/dev/null 2>&1
}

phase_install_check() {
    local rt prefix exe launcher ini n ver buf node input out_dev in_dev
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
    input="$(_install_audio_input)"
    out_dev="$(_install_ini_get "$ini" output_device)"; in_dev="$(_install_ini_get "$ini" input_device)"
    kv "audio device" "${AUDIO_DEVICE:-null} → $node, input ${input:-unset} (config: output ${out_dev:-default}, input ${in_dev:-default})"
    if [ "$out_dev" != "$node" ] || [ "$in_dev" != "$input" ]; then
        info "PipeASIO is not pointed at output $node / input ${input:-unset} yet"
        return 1
    fi
    ok "PipeASIO drives $node${input:+ (input $input)}"
    if ! _install_node_present "$node"; then
        warn "$node is not a PipeWire node right now (phase audio; wpctl status): Live would fall back to the default device"
    fi
    phase_note "Live 12 + runtime present; PipeASIO → $node"
    return 0
}

# point PipeASIO at NODE / INPUT ("" removes input_device) — through phase
# audio's _aud_point_pipeasio when it is loaded (the normal case: one writer for
# config.ini), else a minimal in-place edit of the two keys
_install_point_pipeasio() {
    local node="$1" input="${2:-}" ini key val cur
    for val in "$node" ${input:+"$input"}; do
        [[ "$val" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:@+-]*$ ]] || { fail "'$val' is not a PipeWire node.name ([A-Za-z0-9_.:@+-])"; return 1; }
    done
    ini="$(_install_pipeasio_ini)"
    if [ ! -f "$ini" ]; then
        if is_dry_run; then info "would set output_device = $node${input:+, input_device = $input} in $ini (the installer seeds the file)"; return 0; fi
        fail "the installer did not seed $ini: PipeASIO cannot be pointed at $node" || return 1
    fi
    _install_node_present "$node" || warn "$node is not a PipeWire node right now (phase audio): writing it anyway"
    if declare -F _aud_point_pipeasio >/dev/null; then
        _aud_point_pipeasio "$node" "$input"
        return
    fi
    for key in output_device input_device; do
        if [ "$key" = output_device ]; then val="$node"; else val="$input"; fi
        cur="$(_install_ini_get "$ini" "$key")"
        if [ "$cur" = "$val" ]; then
            skip "$ini already has $key = ${val:-(unset)}"
        elif [ -z "$val" ]; then
            run -- sed -i "/^[[:space:]]*$key[[:space:]]*=/d" "$ini" || return 1
        elif grep -qE "^[[:space:]]*$key[[:space:]]*=" "$ini"; then
            # node names are [A-Za-z0-9_.:@+-] only: safe in a sed replacement with | delimiters
            run -- sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $val|" "$ini" || return 1
        else
            ensure_line "$ini" "$key = $val" || return 1
        fi
    done
    return 0
}

phase_install_apply() {
    local installer power rt prefix node input
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
    if [ "$FORCE" != 1 ] && _install_core_present; then
        skip "runtime, prefix, Live 12 and the launcher are already installed: the installer is not re-run (--force re-runs it)"
    else
        step "installing the runtime, the prefix and Live 12 (10–30 min; Inno Setup runs silently on the desktop)"
        info "non-interactive: --yes answers the overwrite question; other prompts take their default after 30 s (ABLETON_UI_PROMPT_TIMEOUT)"
        run -- env -C "$REPO_DIR" ABLETON_LIVE_INSTALL_TIMEOUT=7200 "$PROFILER_ROOT/bin/with-session-env" "$installer" install \
            --live-installer "$LIVE_INSTALLER" --live-major 12 --link=off --yes \
            "--audio-buffer=$AUDIO_BUFFER" --audio-threads=auto --rt=auto "--power=$power" --dpi=100 --shortcuts=preserve \
            || return 1
        is_dry_run || ok "installer finished"
    fi
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"
    cfg_set runtime_root "$rt" || return 1
    cfg_set prefix "$prefix" || return 1
    cfg_set launcher "$(_lp_launcher)" || return 1
    cfg_set live_exe "$(_lp_live_exe "$prefix")" || return 1
    is_dry_run && info "would record runtime_root/prefix/launcher/live_exe in $PROFILER_SETUP_CONF"
    step "pointing PipeASIO at the audio device (--audio-device ${AUDIO_DEVICE:-null})"
    if node="$(_install_audio_node)"; then
        input="$(_install_audio_input)"
        kv "audio node" "$node (input ${input:-unset})"
        _install_point_pipeasio "$node" "$input" || return 1
    else
        prereq_fail "--audio-device ${AUDIO_DEVICE:-?} names no PipeWire node (phase audio records audio_node=; wpctl status lists the sinks)" || return 1
    fi
    info "optional, not run here: cd $REPO_DIR && make check && make test (22 scripts)"
    phase_note "Live 12 installed (buffer $AUDIO_BUFFER, power $power${node:+, PipeASIO → $node})"
    return 0
}
