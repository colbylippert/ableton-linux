#!/usr/bin/env bash
# profiler/setup/phases/04-limits.sh — phase 04 "limits": realtime rights,
# resource limits and the profiler's sysctls.
#   * the user joins the realtime (realtime-privileges: rtprio 98, memlock
#     unlimited) and audio groups — need_relogin until the session carries them
#   * the repo's own RT profile, non-interactively: scripts/setup-realtime.sh
#     writes /etc/security/limits.d/90-ableton-rt.conf (@audio rtprio 95, memlock
#     unlimited, nice -19) and /etc/sysctl.d/90-ableton-rt.conf (vm.swappiness =
#     10) and applies them (it uses `sudo -n` first, which phase 01 made work)
#   * /etc/security/limits.d/90-profiler.conf (templates/limits-profiler.conf):
#     <user> nofile 524288
#   * /etc/sysctl.d/90-profiler.conf (templates/sysctl-profiler.conf):
#     kernel.perf_event_paranoid = -1, kernel.kptr_restrict = 0 — on every
#     profile, the profiler machines are dedicated to it
#   * when a distribution udev rule resets vm.swappiness as zram comes up
#     (CachyOS 30-zram.rules: 150 at every boot),
#     /etc/udev/rules.d/99-profiler-zram-swappiness.rules
#     (templates/udev-zram-swappiness.rules) keeps the RT profile's value
#   * `sysctl --system` when a live value differs
# Check (read-only): group membership (getent), the RT drop-ins, both profiler
# drop-ins and the udev override equal to their templates, and the live
# vm.swappiness / kernel.perf_event_paranoid / kernel.kptr_restrict values. A
# session that does not carry the groups yet raises need_relogin (a warning,
# not a failure: nothing but a new login fixes it).

phase_register 04 limits "realtime/audio groups, RT limits (scripts/setup-realtime.sh), nofile, perf/kptr sysctls" "packages"

: "${P4_RT_GROUP:=audio}"             # scripts/setup-realtime.sh's default ABLETON_RT_GROUP
: "${P4_LIMITS_RT:=/etc/security/limits.d/90-ableton-rt.conf}"
: "${P4_SYSCTL_RT:=/etc/sysctl.d/90-ableton-rt.conf}"
: "${P4_LIMITS:=/etc/security/limits.d/90-profiler.conf}"
: "${P4_SYSCTL:=/etc/sysctl.d/90-profiler.conf}"
: "${P4_UDEV:=/etc/udev/rules.d/99-profiler-zram-swappiness.rules}"

_lim_in_group() {   # USER GROUP → 0 when GROUP lists USER (the account, not this session)
    local members
    members="$(getent group "$2" 2>/dev/null | cut -d: -f4)" || return 1
    grep -qxF -- "$1" <<< "${members//,/$'\n'}"
}
_lim_session_has() { local g; g="$(id -nG 2>/dev/null)" || return 1; grep -qxF -- "$1" <<< "${g// /$'\n'}"; }
# the swappiness the RT profile asks for (90-ableton-rt.conf; 10 before it exists)
_lim_swappiness() {
    local v
    v="$(sed -n 's/^[[:space:]]*vm\.swappiness[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$P4_SYSCTL_RT" 2>/dev/null | tail -n1)"
    printf '%s\n' "${v:-10}"
}
# 0 when a udev rule other than ours sets vm.swappiness (zram rules)
_lim_udev_overrides_swappiness() {
    local f
    for f in /usr/lib/udev/rules.d/*.rules /etc/udev/rules.d/*.rules; do
        [ -r "$f" ] && [ "$f" != "$P4_UDEV" ] || continue
        grep -q 'SYSCTL{vm\.swappiness}' "$f" 2>/dev/null && return 0
    done
    return 1
}
_lim_rt_dropins_ok() {
    grep -Eq "^@${P4_RT_GROUP}[[:space:]]+-[[:space:]]+rtprio[[:space:]]+[0-9]+" "$P4_LIMITS_RT" 2>/dev/null \
        && grep -Eq "^@${P4_RT_GROUP}[[:space:]]+-[[:space:]]+memlock[[:space:]]+unlimited" "$P4_LIMITS_RT" 2>/dev/null \
        && grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$P4_SYSCTL_RT" 2>/dev/null
}
_lim_setup_realtime() {   # path of scripts/setup-realtime.sh (configured repo first, then this checkout)
    local f
    for f in "$REPO_DIR/scripts/setup-realtime.sh" "$(dirname -- "$PROFILER_ROOT")/scripts/setup-realtime.sh"; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}
# "key=want:have" for every live sysctl that differs; empty when all match
_lim_sysctl_drift() {
    local k want have out=""
    for k in "vm.swappiness=$(_lim_swappiness)" "kernel.perf_event_paranoid=-1" "kernel.kptr_restrict=0"; do
        want="${k#*=}"; k="${k%%=*}"
        have="$(sysctl -n "$k" 2>/dev/null || echo '?')"
        [ "$have" = "$want" ] || out="${out:+$out }$k=$want(is $have)"
    done
    printf '%s\n' "$out"
}

phase_limits_check() {
    local user g drift rc=0
    user="$(_p1_user)"
    step "checking groups, limits and sysctls"
    for g in realtime "$P4_RT_GROUP"; do
        if ! getent group "$g" >/dev/null 2>&1; then info "group $g does not exist"; return 1; fi
        if ! _lim_in_group "$user" "$g"; then info "$user is not a member of $g"; return 1; fi
    done
    ok "$user is in realtime and $P4_RT_GROUP"
    for g in realtime "$P4_RT_GROUP"; do
        if ! _lim_session_has "$g"; then
            warn "this session does not carry group $g yet: log out and back in (RT limits apply at login)"
            _p1_need_relogin
        fi
    done
    if ! _lim_rt_dropins_ok; then info "the RT profile drop-ins ($P4_LIMITS_RT, $P4_SYSCTL_RT) are missing or incomplete"; return 1; fi
    ok "RT profile drop-ins present (scripts/setup-realtime.sh)"
    _p1_template_current "$TEMPLATES_DIR/limits-profiler.conf" "$P4_LIMITS" || { info "$P4_LIMITS is missing or differs from the template"; return 1; }
    _p1_template_current "$TEMPLATES_DIR/sysctl-profiler.conf" "$P4_SYSCTL" || { info "$P4_SYSCTL is missing or differs from the template"; return 1; }
    ok "$P4_LIMITS and $P4_SYSCTL match the templates"
    if _lim_udev_overrides_swappiness; then
        if SWAPPINESS="$(_lim_swappiness)" _p1_template_current "$TEMPLATES_DIR/udev-zram-swappiness.rules" "$P4_UDEV"; then
            ok "zram udev override keeps vm.swappiness at $(_lim_swappiness) after boot ($P4_UDEV)"
        else
            info "a distribution udev rule resets vm.swappiness at boot and $P4_UDEV is missing or outdated"
            return 1
        fi
    fi
    drift="$(_lim_sysctl_drift)"
    if [ -n "$drift" ]; then info "live sysctls differ: $drift"; return 1; fi
    ok "vm.swappiness $(_lim_swappiness), kernel.perf_event_paranoid -1, kernel.kptr_restrict 0"
    kv "ulimit -r / -l / -n" "$(ulimit -r 2>/dev/null) / $(ulimit -l 2>/dev/null) / $(ulimit -n 2>/dev/null)"
    if chrt -r 10 true 2>/dev/null; then ok "chrt -r 10 true works (the launcher's RT probe)"; else warn "chrt -r 10 true fails in this session (RT limits apply after a new login)"; fi
    phase_note "realtime+$P4_RT_GROUP, RT drop-ins, nofile, perf/kptr sysctls"
    return "$rc"
}

phase_limits_apply() {
    local user script add="" g drift changed=0 sw
    user="$(_p1_user)"
    step "groups realtime and $P4_RT_GROUP"
    if ! getent group realtime >/dev/null 2>&1; then
        if is_dry_run; then info "dry run: group realtime appears with the realtime-privileges package (phase packages)"; else
            run --sudo -- groupadd -r realtime || return 1
        fi
    fi
    for g in realtime "$P4_RT_GROUP"; do _lim_in_group "$user" "$g" || add="${add:+$add,}$g"; done
    if [ -n "$add" ]; then
        run --sudo -- usermod -aG "$add" "$user" || return 1
        is_dry_run || ok "added $user to $add (takes effect at the next login)"
    else
        skip "$user is already in realtime and $P4_RT_GROUP"
    fi
    if ! _lim_session_has realtime || ! _lim_session_has "$P4_RT_GROUP"; then _p1_need_relogin; fi
    step "the repo's RT profile (scripts/setup-realtime.sh)"
    if _lim_rt_dropins_ok; then
        skip "$P4_LIMITS_RT and $P4_SYSCTL_RT already present"
    elif script="$(_lim_setup_realtime)"; then
        run --timeout 600 -- env ABLETON_RT_GROUP="$P4_RT_GROUP" bash "$script" || return 1
        if ! is_dry_run && ! _lim_rt_dropins_ok; then fail "scripts/setup-realtime.sh finished but $P4_LIMITS_RT / $P4_SYSCTL_RT are incomplete"; return 1; fi
        changed=1
    else
        fail "scripts/setup-realtime.sh not found in $REPO_DIR or $(dirname -- "$PROFILER_ROOT")"
        return 1
    fi
    step "profiler drop-ins"
    USER="$user" write_template "$TEMPLATES_DIR/limits-profiler.conf" "$P4_LIMITS" --sudo --mode 0644 --owner root:root || return 1
    USER="$user" write_template "$TEMPLATES_DIR/sysctl-profiler.conf" "$P4_SYSCTL" --sudo --mode 0644 --owner root:root || return 1
    if _lim_udev_overrides_swappiness; then
        sw="$(_lim_swappiness)"
        step "zram udev override (a distribution rule resets vm.swappiness at boot)"
        if SWAPPINESS="$sw" _p1_template_current "$TEMPLATES_DIR/udev-zram-swappiness.rules" "$P4_UDEV"; then
            skip "$P4_UDEV already up to date"
        else
            SWAPPINESS="$sw" write_template "$TEMPLATES_DIR/udev-zram-swappiness.rules" "$P4_UDEV" --sudo --mode 0644 --owner root:root || return 1
            run --sudo -- udevadm control --reload || return 1
        fi
    fi
    drift="$(_lim_sysctl_drift)"
    if [ -n "$drift" ] || is_dry_run; then
        step "applying the sysctl drop-ins (sysctl --system)${drift:+: $drift}"
        run --quiet --sudo -- sysctl --system || return 1
        if ! is_dry_run; then
            drift="$(_lim_sysctl_drift)"
            [ -z "$drift" ] || { fail "sysctl --system left live values that differ: $drift (another drop-in sorts later?)"; return 1; }
            ok "live sysctls match the drop-ins"
        fi
    else
        skip "live sysctls already match"
    fi
    phase_note "groups, RT profile, nofile, perf/kptr sysctls$([ "$changed" -eq 1 ] && printf ' (RT profile installed)')"
    return 0
}
