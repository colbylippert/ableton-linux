#!/usr/bin/env bash
# profiler/setup/lib/host.sh — read-only host probes shared by setup-machine.sh
# (every phase), verify.sh and profiler/bin/bench: the PipeWire audio node the
# profiler drives and the power-supply state of a laptop. Sourced, never
# executed; defines functions only (prefixes pwa_ and host_), needs no other
# library, works under `set -euo pipefail` and never changes the host —
# callers that mute a node run `wpctl set-mute ID 1` themselves (the setup
# phases through `run`, so --dry-run prints it).
#
# Audio (PipeWire; every function returns 1 when PipeWire is unreachable)
#   pwa_available            0 when pw-cli can talk to this user's PipeWire
#   pwa_nodes                one line per node: ID<TAB>node.name<TAB>media.class<TAB>priority.session
#   pwa_node_id NAME         numeric object id of the node whose node.name is NAME
#                            (ids change on every PipeWire restart: resolve each time)
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
#   host_has_battery         0 when any supply's type is Battery (a laptop: LAPTOP=1)
#   host_on_ac               0 when a Mains/USB supply is online, or no battery exists
#   host_power_summary       one line, e.g. "AC online (ADP1); BAT1 91% Not charging"
#   host_battery_facts       KEY=VALUE lines: ac_online battery battery_capacity battery_status

[ -n "${BASH_VERSION:-}" ] || { echo "host.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }

# ----------------------------------------------------------------- audio ----
pwa_available() {
    command -v pw-cli >/dev/null 2>&1 || return 1
    timeout 5 pw-cli info 0 >/dev/null 2>&1
}

pwa_nodes() {
    local out
    command -v pw-cli >/dev/null 2>&1 || return 1
    out="$(timeout 10 pw-cli ls Node 2>/dev/null)" || return 1
    awk '
        function val(s) { sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s }
        function flush() { if (id != "") printf "%s\t%s\t%s\t%s\n", id, name, cls, prio }
        /^[[:space:]]*id [0-9]+, type PipeWire:Interface:Node/ {
            flush(); id = $2; sub(/,$/, "", id); name = ""; cls = ""; prio = "0"; next
        }
        /^[[:space:]]*node\.name = /        { name = val($0); next }
        /^[[:space:]]*media\.class = /      { cls = val($0); next }
        /^[[:space:]]*priority\.session = / { prio = val($0); next }
        END { flush() }
    ' <<< "$out"
}

pwa_node_id() {
    local want="$1" id name rest
    [ -n "$want" ] || return 1
    while IFS=$'\t' read -r id name rest; do
        if [ "$name" = "$want" ]; then printf '%s\n' "$id"; return 0; fi
    done < <(pwa_nodes || true)
    return 1
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
    local dev="${1:-builtin}" nodes default="" best="" best_prio=-1 id name cls prio
    case "$dev" in
        null) printf 'profiler-null\n'; return 0 ;;
        builtin) ;;
        "") return 1 ;;
        *) printf '%s\n' "$dev"; return 0 ;;
    esac
    nodes="$(pwa_nodes)" || return 1
    default="$(pwa_default_sink || true)"
    while IFS=$'\t' read -r id name cls prio; do
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
host_has_battery() {
    local t
    for t in /sys/class/power_supply/*/type; do
        [ -r "$t" ] || continue
        [ "$(cat -- "$t" 2>/dev/null)" = Battery ] && return 0
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
        [ "$(cat -- "$d/type" 2>/dev/null || true)" = Battery ] || continue
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
                out+="${out:+; }$name $(cat -- "$d/capacity" 2>/dev/null || echo '?')% $(cat -- "$d/status" 2>/dev/null || echo '?')" ;;
        esac
    done
    printf '%s\n' "${out:-no power-supply information}"
}
