#!/usr/bin/env bash
# profiler/setup/phases/06-audio.sh — phase 06 "audio": the PipeWire graph clock
# and the device PipeASIO drives.
#   * ~/.config/pipewire/pipewire.conf.d/90-profiler-null-sink.conf (a 48 kHz null
#     sink "profiler-null" for --audio-device null and tests) and
#     91-profiler-clock.conf (rate 48000, allowed-rates [48000], quantum 256,
#     min-quantum 32, max-quantum 2048: min-quantum must not exceed the smallest
#     buffer PipeASIO will request), then the user PipeWire services restart
#     (pipewire, pipewire-pulse, wireplumber) — refused while Live runs
#   * the PipeASIO device, from AUDIO_DEVICE (driver option --audio-device;
#     default builtin on baremetal, null on vm):
#       builtin   lib/host.sh's pwa_resolve_device (the rule verify.sh and bench
#                 share): the ALSA Audio/Sink whose node.name contains "Speaker"
#                 (the default sink when it is one, else the highest
#                 priority.session), else the default sink when it is an ALSA
#                 sink; input = the Mic source on the same
#                 PipeWire device (the default source first), else unset. The
#                 sink is MUTED (wpctl set-mute <id> 1): the graph keeps the
#                 card's hardware clock, the room stays quiet.
#       null      profiler-null for output and input; not muted
#       <name>    that Audio/Sink node.name; input unset (PipeASIO then picks a
#                 capture source on the same card itself); not muted
#     Recorded in ~/.config/profiler/setup.conf: audio_node=, audio_input=,
#     audio_mute=1|0 (profiler/bin/bench re-applies the mute before every run)
#     and audio_pipeasio=configured|pending.
#   * PipeASIO's ~/.config/pipeasio/config.ini (seeded by phase 10's installer):
#     output_device = audio_node, input_device = audio_input (removed when
#     unset). When the file does not exist yet the phase records "pending" and
#     passes; the next setup run completes it. Phase 10 can call
#     _aud_point_pipeasio (below) right after the installer instead.
# Check (read-only): both drop-ins equal their templates, the live
# `pw-metadata -n settings` clock values match 91-profiler-clock.conf with
# clock.force-quantum 0 (unless Live runs), profiler-null exists, the recorded
# audio_node/audio_input/audio_mute equal what AUDIO_DEVICE resolves to now, the
# sink is muted when audio_mute=1, and config.ini (when it exists) names it.

phase_register 06 audio "PipeWire null sink + clock limits (min-quantum 32), PipeASIO device (built-in speaker, muted)" "packages"

_aud_confd() { printf '%s/pipewire/pipewire.conf.d\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
_aud_ini() { printf '%s/pipeasio/config.ini\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
_aud_env() { XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; export XDG_RUNTIME_DIR; }

# builtin | null | <PipeWire node.name>
_aud_mode() {
    local m="${AUDIO_DEVICE:-}"
    [ -n "$m" ] || m="$(cfg_get audio_device)"
    if [ -z "$m" ]; then if profile_is vm; then m=null; else m=builtin; fi; fi
    printf '%s\n' "$m"
}
_aud_mode_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:@+-]*$ ]]; }

# ------------------------------------------------------------ the clock ----
_aud_tpl_clock() {   # KEY → value of default.clock.KEY in templates/pw-91-profiler-clock.conf
    local f="$TEMPLATES_DIR/pw-91-profiler-clock.conf"
    if [ "$1" = allowed-rates ]; then
        grep -o 'default\.clock\.allowed-rates *= *\[[^]]*\]' "$f" 2>/dev/null | head -n1 | sed 's/.*=//; s/[][ ,]\+/ /g; s/^ *//; s/ *$//'
    else
        grep -o "default\\.clock\\.$1 *= *[0-9]*" "$f" 2>/dev/null | head -n1 | sed 's/.*= *//'
    fi
}
_aud_setting() { sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" <<< "$2" | head -n1; }
# mismatches between the live settings metadata and the template ("" when none)
_aud_clock_drift() {
    local md k want have out=""
    md="$(timeout 5 pw-metadata -n settings 2>/dev/null || true)"
    [ -n "$md" ] || { printf 'pw-metadata -n settings printed nothing\n'; return 0; }
    for k in rate quantum min-quantum max-quantum; do
        want="$(_aud_tpl_clock "$k")"; have="$(_aud_setting "clock.$k" "$md")"
        [ -z "$want" ] || [ "$have" = "$want" ] || out="${out:+$out, }clock.$k=${have:-unset} (want $want)"
    done
    want="$(_aud_tpl_clock allowed-rates)"
    have="$(_aud_setting clock.allowed-rates "$md" | sed 's/[][ ,]\+/ /g; s/^ *//; s/ *$//')"
    [ -z "$want" ] || [ "$have" = "$want" ] || out="${out:+$out, }clock.allowed-rates=[${have:-unset}] (want [$want])"
    printf '%s\n' "$out"
}
_aud_force_quantum() { _aud_setting clock.force-quantum "$(timeout 5 pw-metadata -n settings 2>/dev/null || true)"; }
# captured first: under pipefail `pw-cli … | grep -q` can fail with SIGPIPE after a match
_aud_null_present() { local out; out="$(timeout 10 pw-cli ls Node 2>/dev/null || true)"; grep -q 'node.name = "profiler-null"' <<< "$out"; }
# user PipeWire units that exist here, in restart order
_aud_units() {
    local u
    for u in pipewire.service pipewire-pulse.service wireplumber.service; do
        systemctl --user cat "$u" >/dev/null 2>&1 && printf '%s\n' "$u"
    done
}

# ------------------------------------------------------- the device ----
# id<TAB>media.class<TAB>node.name<TAB>device.id for every Audio/Sink and Audio/Source
_aud_nodes() {
    jq -r '.[] | select(.type == "PipeWire:Interface:Node") | (.info.props // {}) as $p
           | select(($p["media.class"] // "") | test("^Audio/(Sink|Source)$"))
           | [(.id | tostring), $p["media.class"], ($p["node.name"] // ""), (($p["device.id"] // "") | tostring)] | @tsv' <<< "$1" 2>/dev/null
}
_aud_default() {   # DUMP KEY → node.name stored under KEY in the "default" metadata
    jq -r --arg k "$2" '[.[] | select(.type == "PipeWire:Interface:Metadata")
           | select((.props["metadata.name"] // "") == "default") | .metadata[]?
           | select(.key == $k) | (.value.name? // empty)] | first // empty' <<< "$1" 2>/dev/null
}
# _aud_resolve MODE → AUD_NODE AUD_NODE_ID AUD_INPUT AUD_MUTE (and AUD_WHY: a
# note, or the reason on failure); returns 1 when no node fits
_aud_resolve() {
    local mode="$1" dump nodes def_sink def_src line dev
    AUD_NODE="" AUD_NODE_ID="" AUD_INPUT="" AUD_MUTE=0 AUD_WHY=""
    if ! command -v pw-dump >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then AUD_WHY="pw-dump or jq is missing (phase packages)"; return 1; fi
    dump="$(timeout 10 pw-dump 2>/dev/null || true)"
    [ -n "$dump" ] || { AUD_WHY="pw-dump printed nothing (PipeWire not running for $(_p1_user)?)"; return 1; }
    nodes="$(_aud_nodes "$dump")"
    def_sink="$(_aud_default "$dump" default.audio.sink)"
    def_src="$(_aud_default "$dump" default.audio.source)"
    case "$mode" in
        null) AUD_NODE=profiler-null; AUD_INPUT=profiler-null ;;
        builtin)
            AUD_MUTE=1
            # lib/host.sh's rule, shared with verify.sh and profiler/bin/bench: the
            # ALSA "Speaker" sink (the default one first, else the highest
            # priority.session), else the default sink — which must be an ALSA
            # sink here ("builtin" means a hardware clock)
            if declare -F pwa_resolve_device >/dev/null 2>&1; then
                AUD_NODE="$(pwa_resolve_device builtin 2>/dev/null || true)"
            fi
            [ -n "$AUD_NODE" ] || AUD_NODE="$def_sink"
            case "$AUD_NODE" in
                alsa_output.*Speaker*) ;;
                alsa_output.*) AUD_WHY="no ALSA sink named *Speaker*: using the default ALSA sink" ;;
                *) AUD_WHY="no ALSA sink named *Speaker*, and the default sink '${AUD_NODE:-none}' is not an ALSA sink (pass --audio-device <node.name>)"; AUD_NODE=""; return 1 ;;
            esac ;;
        *) AUD_NODE="$mode" ;;
    esac
    line="$(awk -F'\t' -v n="$AUD_NODE" '$2 == "Audio/Sink" && $3 == n { print; exit }' <<< "$nodes")"
    [ -n "$line" ] || { AUD_WHY="PipeWire has no Audio/Sink named '$AUD_NODE'"; return 1; }
    AUD_NODE_ID="$(cut -f1 <<< "$line")"
    dev="$(cut -f4 <<< "$line")"
    if [ "$mode" = builtin ] && [ -n "$dev" ]; then
        # Stable choice: node ids and the default source both change when PipeWire
        # restarts, so pick the lexically first *Mic* source on the sink's card.
        AUD_INPUT="$(awk -F'\t' -v dev="$dev" '
            $2 == "Audio/Source" && $4 == dev && $3 ~ /Mic/ {
                if (first == "" || $3 < first) first = $3
            }
            END { if (first != "") print first }' <<< "$nodes")"
    fi
    return 0
}
_aud_muted() { local out; out="$(timeout 5 wpctl get-volume "$1" 2>/dev/null || true)"; grep -q '\[MUTED\]' <<< "$out"; }

# ------------------------------------------------ PipeASIO config.ini ----
# FILE OUT IN → FILE's text with output_device = OUT and input_device = IN in
# [pipeasio] (input_device removed when IN is empty; the section appended when absent)
_aud_ini_render() { pipeasio_ini_render "$@"; }   # lib/host.sh
_aud_ini_current() {   # FILE OUT IN
    local want have
    [ -r "$1" ] || return 1
    want="$(_aud_ini_render "$1" "$2" "$3"; printf x)"
    have="$(cat -- "$1"; printf x)"
    [ "$want" = "$have" ]
}
# _aud_point_pipeasio [NODE [INPUT]] — point PipeASIO's config.ini at NODE /
# INPUT (defaults: audio_node / audio_input from setup.conf; an empty INPUT
# removes input_device). Shared with phase 10, which can call it right after
# the installer seeds config.ini. Returns 0 and reports "pending" when the file
# does not exist yet; records audio_pipeasio=configured once it is pointed.
_aud_point_pipeasio() {
    local node="${1-$(cfg_get audio_node)}" input="${2-$(cfg_get audio_input)}" ini tmp mode
    ini="$(_aud_ini)"
    [ -n "$node" ] || { warn "no audio_node recorded yet (phase audio): PipeASIO keeps its default device"; return 0; }
    if [ -L "$ini" ]; then warn "$ini is a symlink (managed elsewhere): output_device/input_device left alone"; return 0; fi
    if [ ! -f "$ini" ]; then
        info "pending: $ini does not exist yet (the installer seeds it in phase install); a later setup run sets output_device = $node"
        cfg_set audio_pipeasio pending || return 1
        return 0
    fi
    if _aud_ini_current "$ini" "$node" "$input"; then
        skip "$ini already names output_device = $node${input:+, input_device = $input}"
    else
        _tmpdir >/dev/null || return 1
        tmp="$(mktemp "$PROFILER_TMPDIR/pipeasio.XXXXXX")" || { fail "mktemp failed"; return 1; }
        _aud_ini_render "$ini" "$node" "$input" > "$tmp"
        mode="$(stat -c %a -- "$ini" 2>/dev/null || echo 600)"
        is_dry_run && { info "would write $ini:"; _p1_show "$(cat -- "$tmp")"; }
        run -- install -m "$mode" "$tmp" "$ini" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
        is_dry_run || ok "$ini: output_device = $node${input:+, input_device = $input}$([ -z "$input" ] && printf ', input_device unset')"
    fi
    cfg_set audio_pipeasio configured || return 1
    return 0
}

# ------------------------------------------------------------- restart ----
_aud_restart() {
    local -a units=()
    local i drift
    if _p1_live_running; then
        fail "Live is running (pid $(_p1_live_pids | paste -sd, -)): quit it with File > Quit before PipeWire restarts"
        return 1
    fi
    mapfile -t units < <(_aud_units)
    [ "${#units[@]}" -gt 0 ] || units=(pipewire.service wireplumber.service)
    run -- systemctl --user restart "${units[@]}" || return 1
    is_dry_run && return 0
    for i in $(seq 1 40); do
        if [ -z "$(_aud_clock_drift)" ] && _aud_null_present; then
            ok "PipeWire restarted with the profiler drop-ins (${units[*]})"
            return 0
        fi
        sleep 0.5
    done
    drift="$(_aud_clock_drift)"
    _aud_null_present || drift="${drift:+$drift, }profiler-null missing"
    fail "PipeWire restarted but does not show the profiler settings after 20 s: $drift (another drop-in in $(_aud_confd) or /etc/pipewire sorting later?)"
    return 1
}

# ---------------------------------------------------------------- check ----
phase_audio_check() {
    local mode confd fq ini rec_node rec_in rec_mute drift
    mode="$(_aud_mode)"; confd="$(_aud_confd)"; ini="$(_aud_ini)"
    step "checking PipeWire and the PipeASIO device (--audio-device $mode)"
    _aud_mode_ok "$mode" || { fail "AUDIO_DEVICE '$mode' is not builtin, null or a PipeWire node.name"; return 1; }
    _p1_template_current "$TEMPLATES_DIR/pw-90-profiler-null-sink.conf" "$confd/90-profiler-null-sink.conf" || { info "$confd/90-profiler-null-sink.conf is missing or outdated"; return 1; }
    _p1_template_current "$TEMPLATES_DIR/pw-91-profiler-clock.conf" "$confd/91-profiler-clock.conf" || { info "$confd/91-profiler-clock.conf is missing or outdated"; return 1; }
    ok "PipeWire drop-ins present in $confd"
    _aud_env
    if ! command -v pw-metadata >/dev/null 2>&1 || ! command -v pw-cli >/dev/null 2>&1; then info "pw-metadata / pw-cli missing (pipewire)"; return 1; fi
    drift="$(_aud_clock_drift)"
    [ -z "$drift" ] || { info "live PipeWire clock differs from 91-profiler-clock.conf: $drift"; return 1; }
    ok "graph clock: rate $(_aud_tpl_clock rate) [$(_aud_tpl_clock allowed-rates)], quantum $(_aud_tpl_clock quantum), min $(_aud_tpl_clock min-quantum), max $(_aud_tpl_clock max-quantum)"
    fq="$(_aud_force_quantum)"
    if [ -n "$fq" ] && [ "$fq" != 0 ]; then
        if _p1_live_running; then info "clock.force-quantum=$fq while Live runs (PipeASIO holds the quantum)"
        else info "clock.force-quantum=$fq is left over (Live is not running)"; return 1; fi
    fi
    _aud_null_present || { info "the profiler-null sink is not loaded"; return 1; }
    if ! _aud_resolve "$mode"; then info "cannot resolve --audio-device $mode: $AUD_WHY"; return 1; fi
    rec_node="$(cfg_get audio_node)"; rec_in="$(cfg_get audio_input)"; rec_mute="$(cfg_get audio_mute)"
    if [ "$rec_node" != "$AUD_NODE" ] || [ "$rec_in" != "$AUD_INPUT" ] || [ "$rec_mute" != "$AUD_MUTE" ]; then
        info "recorded audio_node/audio_input/audio_mute (${rec_node:-unset}/${rec_in:-unset}/${rec_mute:-unset}) differ from the resolved $AUD_NODE/${AUD_INPUT:-unset}/$AUD_MUTE"
        return 1
    fi
    kv "audio_node" "$AUD_NODE (id $AUD_NODE_ID)"
    kv "audio_input" "${AUD_INPUT:-unset}"
    if [ "$AUD_MUTE" = 1 ]; then
        _aud_muted "$AUD_NODE_ID" || { info "$AUD_NODE is not muted"; return 1; }
        ok "$AUD_NODE muted"
    fi
    if [ -L "$ini" ]; then
        warn "$ini is a symlink: not checked"
    elif [ -f "$ini" ]; then
        _aud_ini_current "$ini" "$AUD_NODE" "$AUD_INPUT" || { info "$ini does not name output_device = $AUD_NODE${AUD_INPUT:+ / input_device = $AUD_INPUT}"; return 1; }
        ok "PipeASIO config.ini names output_device = $AUD_NODE"
    else
        info "pending: $ini does not exist yet (phase install seeds it; a later setup run points it at $AUD_NODE)"
    fi
    phase_note "PipeASIO → $AUD_NODE$([ "$AUD_MUTE" = 1 ] && printf ' (muted)')$([ -f "$ini" ] || printf '; config.ini pending')"
    return 0
}

# ---------------------------------------------------------------- apply ----
phase_audio_apply() {
    local mode confd changed=0 restart=0 fq i resolved=0
    mode="$(_aud_mode)"; confd="$(_aud_confd)"
    _aud_mode_ok "$mode" || { fail "AUDIO_DEVICE '$mode' is not builtin, null or a PipeWire node.name"; return 1; }
    _p1_need_cmds pw-cli pw-metadata pw-dump wpctl jq || return 1
    _aud_env
    step "PipeWire drop-ins ($confd)"
    _p1_template_current "$TEMPLATES_DIR/pw-90-profiler-null-sink.conf" "$confd/90-profiler-null-sink.conf" || changed=1
    _p1_template_current "$TEMPLATES_DIR/pw-91-profiler-clock.conf" "$confd/91-profiler-clock.conf" || changed=1
    write_template "$TEMPLATES_DIR/pw-90-profiler-null-sink.conf" "$confd/90-profiler-null-sink.conf" --mode 0644 || return 1
    write_template "$TEMPLATES_DIR/pw-91-profiler-clock.conf" "$confd/91-profiler-clock.conf" --mode 0644 || return 1
    if [ "$changed" -eq 1 ]; then restart=1
    elif [ -n "$(_aud_clock_drift)" ] || ! _aud_null_present; then restart=1; fi
    if [ "$restart" -eq 1 ]; then
        step "restarting the user PipeWire services so the drop-ins load"
        _aud_restart || return 1
    else
        skip "PipeWire already runs with the profiler drop-ins"
        fq="$(_aud_force_quantum)"
        if [ -n "$fq" ] && [ "$fq" != 0 ] && ! _p1_live_running; then
            run -- pw-metadata -n settings 0 clock.force-quantum 0 || return 1
        fi
    fi

    step "PipeASIO device (--audio-device $mode)"
    for i in $(seq 1 20); do
        if _aud_resolve "$mode"; then resolved=1; break; fi
        is_dry_run && break
        sleep 0.5          # ALSA nodes reappear a moment after a restart
    done
    if [ "$resolved" -eq 0 ]; then
        if is_dry_run; then
            info "dry run: --audio-device $mode does not resolve yet ($AUD_WHY); after the restart it is recorded as audio_node and, when it is a hardware sink, muted"
            phase_note "dry run"
            return 0
        fi
        fail "cannot resolve --audio-device $mode: $AUD_WHY (wpctl status lists the sinks; pass --audio-device <node.name>)"
        return 1
    fi
    [ -z "$AUD_WHY" ] || warn "$AUD_WHY"
    kv "audio_node" "$AUD_NODE (id $AUD_NODE_ID)"
    kv "audio_input" "${AUD_INPUT:-unset (PipeASIO picks a capture source on the same card)}"
    kv "mute" "$([ "$AUD_MUTE" = 1 ] && printf 'yes (bench re-applies it before every run)' || printf no)"
    cfg_set audio_node "$AUD_NODE" && cfg_set audio_input "$AUD_INPUT" && cfg_set audio_mute "$AUD_MUTE" || return 1
    is_dry_run && info "would record audio_node=$AUD_NODE audio_input=$AUD_INPUT audio_mute=$AUD_MUTE in $PROFILER_SETUP_CONF"
    if [ "$AUD_MUTE" = 1 ]; then
        if _aud_muted "$AUD_NODE_ID"; then skip "$AUD_NODE already muted"
        else
            run -- wpctl set-mute "$AUD_NODE_ID" 1 || return 1
            is_dry_run || ok "muted $AUD_NODE"
        fi
    fi
    step "PipeASIO config.ini"
    _aud_point_pipeasio "$AUD_NODE" "$AUD_INPUT" || return 1
    phase_note "PipeASIO → $AUD_NODE$([ "$AUD_MUTE" = 1 ] && printf ' (muted)')"
    return 0
}
