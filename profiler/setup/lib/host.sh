#!/usr/bin/env bash
# profiler/setup/lib/host.sh — read-only host probes shared by setup-machine.sh
# (every phase), verify.sh and profiler/bin/bench: the PipeWire audio node the
# profiler drives and the power-supply state of a laptop. Sourced, never
# executed; defines functions only (prefixes pwa_/_pwa_, pipeasio_ and host_), needs no other
# library, works under `set -euo pipefail` and never changes the host —
# callers that mute a node run `wpctl set-mute ID 1` themselves (the setup
# phases through `run`, so --dry-run prints it).
#
# Audio (PipeWire; every function returns 1 when PipeWire is unreachable)
#   pwa_available            0 when pw-cli can talk to this user's PipeWire
#   pwa_nodes                one line per node: ID<TAB>node.name<TAB>media.class<TAB>priority.session<TAB>device.id
#   pwa_node_id NAME         numeric object id of the node whose node.name is NAME
#                            (ids change on every PipeWire restart: resolve each time)
#   pwa_node_lookup NAME [SECONDS]
#                            the same id, robustly (profiler/bin/bench's gate): looked
#                            up by node.name with pw-dump + jq (15 s timeout) and with
#                            pw-cli ls Node, retried with backoff (0.25 s doubling to
#                            2 s) for up to SECONDS (default 10) — a node is missing
#                            for a moment while WirePlumber re-creates it, and either
#                            tool can fail or time out on a busy daemon. A hit after
#                            misses is noted on stderr; a final miss prints the
#                            evidence there (each tool's exit status, the Audio/Sink
#                            node.names it saw, wpctl status's Sinks) and returns 1
#   pwa_resolve_input SINK   the capture node.name PipeASIO pairs with the Audio/Sink
#                            SINK — a source on the same PipeWire device (card): the
#                            mirror name (alsa_output.→alsa_input., output→input,
#                            sink→source: …pro-output-0 → …pro-input-0), else the
#                            lexically first source whose node.name contains "Mic"
#                            (the built-in Speaker sink, HiFi Line sinks), else the
#                            lexically first source on the card; returns 1 (prints
#                            nothing) when SINK is unknown, has no device.id, or the
#                            card has no capture node. node.names, not ids: the choice
#                            survives PipeWire restarts
#   pwa_pick_input SINK      the same rule on a node list read from stdin
#                            (node.name<TAB>media.class<TAB>device.id; phase audio
#                            feeds it from pw-dump)
#   pwa_default_sink         node.name of the default audio sink (pw-metadata
#                            default.audio.sink, else wpctl inspect @DEFAULT_AUDIO_SINK@)
#   pwa_resolve_device DEV   the node.name the profiler uses for --audio-device DEV:
#                              null     → profiler-null (the null sink of phase audio)
#                              builtin  → the ALSA Audio/Sink whose node.name contains
#                                         "Speaker" — the default sink when it is one,
#                                         else the one with the highest priority.session
#                                         — and the default sink when no node has
#                                         "Speaker" in its name
#                              other    → DEV itself (a node.name given verbatim)
#   pwa_mute_state NAME      prints muted | unmuted | absent | unknown
#                            (wpctl get-volume ID: "Volume: 0.40 [MUTED]")
#
# Power supply (/sys/class/power_supply)
#   host_has_battery         0 when a system battery exists (a laptop: LAPTOP=1): a
#                            supply of type Battery whose scope is not "Device" (a
#                            wireless mouse or headset reports type=Battery,
#                            scope=Device and does not make a desktop a laptop)
#   host_on_ac               0 when a Mains/USB supply is online, or no battery exists
#   host_power_summary       one line, e.g. "AC online (ADP1); BAT1 91% Not charging"
#   host_battery_facts       KEY=VALUE lines: ac_online battery battery_capacity battery_status
#
# PipeASIO (~/.config/pipeasio/config.ini; text only, the caller writes the file)
#   pipeasio_ini_render FILE OUT IN
#                            FILE's text with output_device = OUT and input_device = IN
#                            in [pipeasio] (input_device removed when IN is empty; the
#                            section appended when absent). The one renderer for setup
#                            phase audio (_aud_point_pipeasio) and `state restore`/`diff`

[ -n "${BASH_VERSION:-}" ] || { echo "host.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }

# ----------------------------------------------------------------- audio ----
pwa_available() {
    command -v pw-cli >/dev/null 2>&1 || return 1
    timeout 5 pw-cli info 0 >/dev/null 2>&1
}

# pw-cli ls Node text (stdin) → pwa_nodes lines
_pwa_parse_ls() {
    awk '
        function val(s) { sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s }
        function flush() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\n", id, name, cls, prio, dev }
        /^[[:space:]]*id [0-9]+, type PipeWire:Interface:Node/ {
            flush(); id = $2; sub(/,$/, "", id); name = ""; cls = ""; prio = "0"; dev = ""; next
        }
        /^[[:space:]]*node\.name = /        { name = val($0); next }
        /^[[:space:]]*media\.class = /      { cls = val($0); next }
        /^[[:space:]]*priority\.session = / { prio = val($0); next }
        /^[[:space:]]*device\.id = /        { dev = val($0); next }
        END { flush() }
    '
}

pwa_nodes() {
    local out
    command -v pw-cli >/dev/null 2>&1 || return 1
    out="$(timeout 10 pw-cli ls Node 2>/dev/null)" || return 1
    _pwa_parse_ls <<< "$out"
}

pwa_node_id() {
    local want="$1" id name rest
    [ -n "$want" ] || return 1
    while IFS=$'\t' read -r id name rest; do
        if [ "$name" = "$want" ]; then printf '%s\n' "$id"; return 0; fi
    done < <(pwa_nodes || true)
    return 1
}

# "id<TAB>node.name<TAB>media.class…" lines (stdin) → "Audio/Sink nodes: a, b; Audio/Source nodes: c"
_pwa_audio_names() {
    awk -F'\t' '
        $3 == "Audio/Sink"   { sinks = sinks (sinks == "" ? "" : ", ") $2 }
        $3 == "Audio/Source" { srcs = srcs (srcs == "" ? "" : ", ") $2 }
        END { if (sinks != "" || srcs != "") printf "Audio/Sink nodes: %s; Audio/Source nodes: %s", (sinks == "" ? "none" : sinks), (srcs == "" ? "none" : srcs) }'
}

# pw-dump JSON (stdin) → "id<TAB>node.name<TAB>media.class" for every node; 1 without jq
_pwa_dump_nodes() {
    command -v jq >/dev/null 2>&1 || return 1
    jq -r '.[] | select(.type == "PipeWire:Interface:Node") | (.info.props // {}) as $p
           | [(.id | tostring), ($p["node.name"] // ""), ($p["media.class"] // "")] | @tsv' 2>/dev/null
}

pwa_node_lookup() {
    local want="$1" budget="${2:-10}" start=$SECONDS attempt=0 delay=0.25 id=""
    local dump_rc dump_out dump_err cli_rc cli_out cli_err dump_names cli_names first_miss=""
    [ -n "$want" ] || return 1
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=10
    while :; do
        attempt=$((attempt + 1))
        dump_rc=127 dump_out="" dump_err="" cli_rc=127 cli_out="" cli_err="" id=""
        if command -v pw-dump >/dev/null 2>&1; then
            dump_rc=0
            dump_out="$(timeout 15 pw-dump -N 2>/dev/null)" || dump_rc=$?
            if [ -n "$dump_out" ]; then
                id="$(_pwa_dump_nodes <<< "$dump_out" | awk -F'\t' -v n="$want" '$2 == n { print $1; exit }' || true)"
            fi
        fi
        if [ -z "$id" ] && command -v pw-cli >/dev/null 2>&1; then
            cli_rc=0
            # the listing counts even when pw-cli exits non-zero at disconnect
            cli_out="$(timeout 10 pw-cli ls Node 2>/dev/null)" || cli_rc=$?
            id="$(_pwa_parse_ls <<< "$cli_out" | awk -F'\t' -v n="$want" '$2 == n { print $1; exit }' || true)"
        fi
        if [[ "$id" =~ ^[0-9]+$ ]]; then
            [ "$attempt" -eq 1 ] || printf 'pwa_node_lookup: %s found as node %s on attempt %d after %ss (first miss: %s)\n' \
                "$want" "$id" "$attempt" "$((SECONDS - start))" "$first_miss" >&2
            printf '%s\n' "$id"
            return 0
        fi
        [ -n "$first_miss" ] || first_miss="pw-dump exit $dump_rc, pw-cli exit $cli_rc"
        [ $((SECONDS - start)) -lt "$budget" ] || break
        sleep "$delay"
        case "$delay" in 0.25) delay=0.5 ;; 0.5) delay=1 ;; *) delay=2 ;; esac
    done
    # the evidence: what each tool returned on the last attempt
    dump_names="$(_pwa_dump_nodes <<< "$dump_out" 2>/dev/null | _pwa_audio_names || true)"
    cli_names="$(_pwa_parse_ls <<< "$cli_out" | _pwa_audio_names || true)"
    {
        printf 'pwa_node_lookup: no node named %s after %d attempts in %ss\n' "$want" "$attempt" "$((SECONDS - start))"
        printf '  pw-dump -N (timeout 15): exit %s, %s bytes; %s\n' "$dump_rc" "${#dump_out}" "${dump_names:-no Audio/Sink or Audio/Source nodes}"
        printf '  pw-cli ls Node (timeout 10): exit %s, %s bytes; %s\n' "$cli_rc" "${#cli_out}" "${cli_names:-no Audio/Sink or Audio/Source nodes}"
        printf '  XDG_RUNTIME_DIR=%s; wpctl status, Audio section:\n' "${XDG_RUNTIME_DIR:-unset}"
        if command -v wpctl >/dev/null 2>&1; then
            timeout 5 wpctl status 2>&1 | sed -n '/^Audio/,/^Video/p' | sed '/^Video/d; s/^/    /' || true
        else
            printf '    (wpctl not installed)\n'
        fi
    } >&2
    return 1
}

pwa_pick_input() {
    awk -F'\t' -v sink="$1" '
        { n++; name[n] = $1; cls[n] = $2; dev[n] = $3 }
        $1 == sink && $2 == "Audio/Sink" { sdev = $3 }
        END {
            if (sink == "" || sdev == "") exit 1
            mirror = ""
            if (sink ~ /^alsa_output\./) {
                rest = substr(sink, length("alsa_output.") + 1)
                prof = rest; sub(/^.*\./, "", prof)              # the profile part, after the last dot
                card = substr(rest, 1, length(rest) - length(prof))
                gsub(/output/, "input", prof); sub(/sink$/, "source", prof)
                mirror = "alsa_input." card prof
            }
            m = ""; mic = ""; any = ""
            for (i = 1; i <= n; i++) {
                if (cls[i] != "Audio/Source" || dev[i] != sdev || name[i] == "") continue
                if (name[i] == mirror) m = name[i]
                if (name[i] ~ /Mic/ && (mic == "" || name[i] < mic)) mic = name[i]
                if (any == "" || name[i] < any) any = name[i]
            }
            pick = (m != "") ? m : ((mic != "") ? mic : any)
            if (pick == "") exit 1
            print pick
        }'
}

pwa_resolve_input() {
    local nodes
    [ -n "${1:-}" ] || return 1
    nodes="$(pwa_nodes)" || return 1
    awk -F'\t' '{ print $2 "\t" $3 "\t" $5 }' <<< "$nodes" | pwa_pick_input "$1"
}

pwa_default_sink() {
    local name=""
    if command -v pw-metadata >/dev/null 2>&1; then
        name="$(timeout 5 pw-metadata -n default 0 default.audio.sink 2>/dev/null \
                | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
    fi
    if [ -z "$name" ] && command -v wpctl >/dev/null 2>&1; then
        name="$(timeout 5 wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
                | sed -n 's/^[[:space:]*]*node\.name = "\(.*\)"[[:space:]]*$/\1/p' | head -n1 || true)"
    fi
    [ -n "$name" ] || return 1
    printf '%s\n' "$name"
}

pwa_resolve_device() {
    local dev="${1:-builtin}" nodes default="" best="" best_prio=-1 id name cls prio _devid
    case "$dev" in
        null) printf 'profiler-null\n'; return 0 ;;
        builtin) ;;
        "") return 1 ;;
        *) printf '%s\n' "$dev"; return 0 ;;
    esac
    nodes="$(pwa_nodes)" || return 1
    default="$(pwa_default_sink || true)"
    while IFS=$'\t' read -r id name cls prio _devid; do
        [ "$cls" = Audio/Sink ] || continue
        case "$name" in alsa_output.*Speaker*) ;; *) continue ;; esac
        if [ -n "$default" ] && [ "$name" = "$default" ]; then best="$name"; break; fi
        [[ "$prio" =~ ^[0-9]+$ ]] || prio=0
        if [ "$prio" -gt "$best_prio" ]; then best="$name"; best_prio="$prio"; fi
    done <<< "$nodes"
    [ -n "$best" ] || best="$default"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

pwa_mute_state() {
    local id out
    if ! id="$(pwa_node_id "${1:-}")"; then printf 'absent\n'; return 0; fi
    command -v wpctl >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    out="$(timeout 5 wpctl get-volume "$id" 2>/dev/null || true)"
    case "$out" in
        *"[MUTED]"*) printf 'muted\n' ;;
        Volume:*) printf 'unmuted\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# ----------------------------------------------------------------- power ----
# 0 when the power supply directory D is a system battery (not a peripheral's)
_host_is_sys_battery() {
    [ "$(cat -- "$1/type" 2>/dev/null || true)" = Battery ] || return 1
    [ "$(cat -- "$1/scope" 2>/dev/null || true)" != Device ]
}
host_has_battery() {
    local d
    for d in /sys/class/power_supply/*; do
        [ -d "$d" ] || continue
        _host_is_sys_battery "$d" && return 0
    done
    return 1
}

host_on_ac() {
    local d type online
    host_has_battery || return 0
    for d in /sys/class/power_supply/*; do
        type="$(cat -- "$d/type" 2>/dev/null || true)"
        case "$type" in Mains|USB|USB_C|USB_PD) ;; *) continue ;; esac
        online="$(cat -- "$d/online" 2>/dev/null || true)"
        [ "$online" = 1 ] && return 0
    done
    # no online adapter listed: trust the battery's own status
    for d in /sys/class/power_supply/*; do
        _host_is_sys_battery "$d" || continue
        case "$(cat -- "$d/status" 2>/dev/null || true)" in Charging|Full|"Not charging") return 0 ;; esac
    done
    return 1
}

host_battery_facts() {
    local d type ac=0 bat="" cap="" st=""
    for d in /sys/class/power_supply/*; do
        [ -d "$d" ] || continue
        type="$(cat -- "$d/type" 2>/dev/null || true)"
        case "$type" in
            Mains|USB|USB_C|USB_PD) [ "$(cat -- "$d/online" 2>/dev/null || true)" = 1 ] && ac=1 ;;
            Battery)
                _host_is_sys_battery "$d" || continue
                if [ -z "$bat" ]; then
                    bat="${d##*/}"
                    cap="$(cat -- "$d/capacity" 2>/dev/null || true)"
                    st="$(cat -- "$d/status" 2>/dev/null || true)"
                fi ;;
        esac
    done
    printf 'ac_online=%s\nbattery=%s\nbattery_capacity=%s\nbattery_status=%s\n' "$ac" "$bat" "$cap" "$st"
}

host_power_summary() {
    local d type out="" name
    for d in /sys/class/power_supply/*; do
        [ -d "$d" ] || continue
        name="${d##*/}"
        type="$(cat -- "$d/type" 2>/dev/null || true)"
        case "$type" in
            Mains|USB|USB_C|USB_PD)
                if [ "$(cat -- "$d/online" 2>/dev/null || true)" = 1 ]; then out+="${out:+; }AC online ($name)"; else out+="${out:+; }AC offline ($name)"; fi ;;
            Battery)
                _host_is_sys_battery "$d" || continue
                out+="${out:+; }$name $(cat -- "$d/capacity" 2>/dev/null || echo '?')% $(cat -- "$d/status" 2>/dev/null || echo '?')" ;;
        esac
    done
    printf '%s\n' "${out:-no power-supply information}"
}

# -------------------------------------------------------------- pipeasio ----
pipeasio_ini_render() {
    awk -v out="$2" -v inp="$3" '
        function emit() {
            if (!dout) { print "output_device = " out; dout = 1 }
            if (inp != "" && !din) { print "input_device = " inp; din = 1 }
        }
        /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
            if (insec) { emit(); printf "%s", blanks; blanks = "" }
            s = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s)
            insec = (s == "pipeasio"); if (insec) found = 1
            print; next
        }
        insec {
            if ($0 ~ /^[[:space:]]*$/) { blanks = blanks $0 "\n"; next }
            printf "%s", blanks; blanks = ""
            if ($0 ~ /^[[:space:]]*output_device[[:space:]]*=/) { if (!dout) { print "output_device = " out; dout = 1 }; next }
            if ($0 ~ /^[[:space:]]*input_device[[:space:]]*=/) { if (inp != "" && !din) { print "input_device = " inp; din = 1 }; next }
        }
        { print }
        END {
            if (insec) { emit(); printf "%s", blanks }
            else if (!found) { if (NR > 0 && $0 !~ /^[[:space:]]*$/) print ""; print "[pipeasio]"; emit() }
        }' "$1"
}
