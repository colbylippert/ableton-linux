#!/usr/bin/env bash
# profiler/setup/phases/05-session.sh — phase 05 "session": a desktop that is
# always logged in, never locks, dims, sleeps or suspends, and is reachable
# from SSH.
#   * --autologin: detects the display manager (systemctl is-active, then the
#     display-manager.service alias) —
#       Plasma Login Manager → [Autologin] User=<user> Session=plasma Relogin=true
#         set in /etc/plasmalogin.conf in place (other keys/sections kept; the
#         first change leaves /etc/plasmalogin.conf.profiler-bak). The daemon
#         reads /etc/plasmalogin.conf (drop-ins in /etc/plasmalogin.conf.d and
#         /usr/lib/plasmalogin/plasmalogin.conf.d lose against it).
#       SDDM → /etc/sddm.conf.d/zz-profiler-autologin.conf (templates/
#         dm-autologin.conf), plus the same keys in /etc/sddm.conf's
#         [Autologin] section when it has one (that file is read last and wins)
#       anything else → warning, nothing changed
#     Takes effect at the next boot or logout.
#   * KDE: no screen lock (kscreenlockerrc Autolock/LockOnResume false), no
#     dimming, no display power-off and no idle suspend on AC (powerdevilrc
#     [AC][Display], [AC][SuspendAndShutdown]); battery profiles stay as they are
#   * belt and braces: user unit profiler-inhibit.service (kde-inhibit --power
#     --screenSaver --notifications sleep infinity), enabled for
#     graphical-session.target
#   * profiler/bin/with-session-env symlinked to ~/.local/bin/with-session-env
#   * laptops (LAPTOP=1 from the driver, else a system battery):
#     /etc/systemd/logind.conf.d/90-profiler-lid.conf (HandleLidSwitchExternalPower=
#     ignore, HandleLidSwitchDocked=ignore; battery behaviour kept), applied with
#     `systemctl kill -s HUP systemd-logind` — never a restart, which would end
#     the session; and powerdevilrc [AC][SuspendAndShutdown] LidAction=0, because
#     PowerDevil holds logind's handle-lid-switch inhibitor while Plasma runs
#   * Wi-Fi (any wireless interface): /etc/NetworkManager/conf.d/
#     90-profiler-wifi-powersave.conf (wifi.powersave = 2) read through
#     `nmcli general reload conf` (effective at the next reconnect), plus
#     `iw dev <if> set power_save off` now — NetworkManager is never restarted,
#     the SSH session may run over that Wi-Fi
# Check (read-only): the autologin keys, the KDE keys (kreadconfig6), the inhibit
# unit file/enablement (active whenever graphical-session.target is), the
# symlink, the logind drop-in + logind's live HandleLidSwitch* properties, the
# NetworkManager drop-in + `iw dev <if> get power_save` = off. A display probe
# (xdotool getdisplaygeometry through with-session-env) is reported, not required.

phase_register 05 session "autologin (Plasma Login Manager/SDDM), no lock/DPMS/suspend, inhibit unit, laptop lid + Wi-Fi power save, with-session-env" "packages"

: "${P5_PLASMALOGIN_CONF:=/etc/plasmalogin.conf}"
: "${P5_SDDM_CONF:=/etc/sddm.conf}"
: "${P5_SDDM_DROPIN:=/etc/sddm.conf.d/zz-profiler-autologin.conf}"
: "${P5_LOGIND_DROPIN:=/etc/systemd/logind.conf.d/90-profiler-lid.conf}"
: "${P5_NM_DROPIN:=/etc/NetworkManager/conf.d/90-profiler-wifi-powersave.conf}"
: "${P5_INHIBIT:=profiler-inhibit.service}"

_ses_unit_path() { printf '%s/systemd/user/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$P5_INHIBIT"; }
_ses_kde_inhibit() { command -v kde-inhibit 2>/dev/null || printf '/usr/bin/kde-inhibit\n'; }
_ses_link() { printf '%s/.local/bin/with-session-env\n' "$HOME"; }
_ses_wse() {   # the with-session-env the symlink points at: the configured repo's, else this checkout's
    if [ -x "$REPO_DIR/profiler/bin/with-session-env" ]; then printf '%s\n' "$REPO_DIR/profiler/bin/with-session-env"
    else printf '%s\n' "$PROFILER_ROOT/bin/with-session-env"; fi
}
_ses_session_name() {
    if [ -f /usr/share/wayland-sessions/plasma.desktop ]; then printf 'plasma\n'
    elif [ -f /usr/share/wayland-sessions/plasmawayland.desktop ]; then printf 'plasmawayland\n'
    else printf 'plasma\n'; fi
}

# display manager: plasmalogin | sddm | gdm | lightdm | other:<unit> | none
_ses_dm() {
    local u target
    for u in plasmalogin sddm gdm lightdm; do
        systemctl is-active -q "$u.service" 2>/dev/null && { printf '%s\n' "$u"; return 0; }
    done
    target="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
    case "${target##*/}" in
        "") printf 'none\n' ;;
        plasmalogin.service) printf 'plasmalogin\n' ;;
        sddm.service) printf 'sddm\n' ;;
        gdm.service) printf 'gdm\n' ;;
        lightdm.service) printf 'lightdm\n' ;;
        *) printf 'other:%s\n' "${target##*/}" ;;
    esac
}

# the KEY=VALUE lines of the rendered templates/dm-autologin.conf
_ses_autologin_keys() {
    local text
    text="$(USER="$(_p1_user)" SESSION_NAME="$(_ses_session_name)" render_template "$TEMPLATES_DIR/dm-autologin.conf")" || return 1
    grep -E '^[A-Za-z][A-Za-z0-9_]*=' <<< "$text"
}

# _ses_ini_set FILE SECTION KEY=VALUE… → FILE's text (empty when absent) with
# KEY=VALUE set inside [SECTION]: existing keys are replaced in place (later
# duplicates of them dropped), missing ones appended at the end of the first
# such section (before its trailing blank lines), the section appended when
# absent. Comments, other keys and other sections are kept verbatim.
_ses_ini_set() {
    local file="$1" section="$2" kvs
    shift 2
    kvs="$(printf '%s\n' "$@")"
    { if [ -r "$file" ]; then cat -- "$file"; fi; } | awk -v sec="$section" -v kv="$kvs" '
        BEGIN {
            n = split(kv, arr, "\n")
            for (i = 1; i <= n; i++) {
                if (arr[i] == "") continue
                k = arr[i]; sub(/=.*/, "", k)
                v = arr[i]; sub(/^[^=]*=/, "", v)
                if (!(k in val)) order[++m] = k
                val[k] = v
            }
        }
        function flush(   i) {
            for (i = 1; i <= m; i++)
                if (!(order[i] in done)) { print order[i] "=" val[order[i]]; done[order[i]] = 1 }
        }
        {
            if ($0 ~ /^[[:space:]]*\[[^]]*\][[:space:]]*$/) {
                if (insec) { flush(); printf "%s", blanks; blanks = "" }
                name = $0; sub(/^[[:space:]]*\[/, "", name); sub(/\][[:space:]]*$/, "", name)
                insec = (name == sec)
                if (insec) found = 1
                print
                next
            }
            if (insec) {
                if ($0 ~ /^[[:space:]]*$/) { blanks = blanks $0 "\n"; next }
                printf "%s", blanks; blanks = ""
                if ($0 ~ /^[[:space:]]*[^#;[:space:]][^=]*=/) {
                    k = $0; sub(/=.*/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                    if (k in val) {
                        if (!(k in done)) { print k "=" val[k]; done[k] = 1 }
                        next
                    }
                }
            }
            print
        }
        END {
            if (insec) { flush(); printf "%s", blanks }
            else if (!found) {
                if (NR > 0 && $0 !~ /^[[:space:]]*$/) print ""
                print "[" sec "]"
                flush()
            }
        }'
}
# 0 when FILE already carries the keys (desired text == current text)
_ses_ini_current() {
    local file="$1" section="$2" want have
    shift 2
    [ -r "$file" ] || return 1
    want="$(_ses_ini_set "$file" "$section" "$@"; printf x)"
    have="$(cat -- "$file"; printf x)"
    [ "$want" = "$have" ]
}
# rewrite FILE (root-owned 0644) with the keys; the first change keeps FILE.profiler-bak
_ses_ini_apply() {
    local file="$1" section="$2" tmp
    shift 2
    if _ses_ini_current "$file" "$section" "$@"; then skip "$file already has [$section] $*"; return 0; fi
    _tmpdir >/dev/null || return 1
    tmp="$(mktemp "$PROFILER_TMPDIR/ini.XXXXXX")" || { fail "mktemp failed"; return 1; }
    _ses_ini_set "$file" "$section" "$@" > "$tmp"
    if [ -e "$file" ] && [ ! -e "$file.profiler-bak" ]; then
        run --sudo -- cp -p -- "$file" "$file.profiler-bak" || { rm -f -- "$tmp"; return 1; }
        is_dry_run || ok "backup: $file.profiler-bak"
    fi
    if is_dry_run; then
        info "would set [$section] $* in $file, giving:"
        _p1_show "$(cat -- "$tmp")"
    fi
    if run --sudo -- install -m 0644 -o root -g root "$tmp" "$file"; then
        rm -f -- "$tmp"
        is_dry_run || ok "set [$section] $* in $file"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# FILE|GROUP[/SUBGROUP]|KEY|VALUE, one per line
_ses_kde_settings() {
    printf '%s\n' \
        "kscreenlockerrc|Daemon|Autolock|false" \
        "kscreenlockerrc|Daemon|LockOnResume|false" \
        "powerdevilrc|AC/Display|DimDisplayWhenIdle|false" \
        "powerdevilrc|AC/Display|TurnOffDisplayWhenIdle|false" \
        "powerdevilrc|AC/SuspendAndShutdown|AutoSuspendAction|0"
    if _p1_laptop; then printf '%s\n' "powerdevilrc|AC/SuspendAndShutdown|LidAction|0"; fi
}
_ses_group_args() { local g IFS=/; for g in $1; do printf -- '--group\n%s\n' "$g"; done; }
_ses_kde_get() {   # FILE GROUPS KEY → current value ("" when unset)
    local -a ga=()
    mapfile -t ga < <(_ses_group_args "$2")
    kreadconfig6 --file "$1" "${ga[@]}" --key "$3" 2>/dev/null || true
}

_ses_wifi_ifaces() {
    local d
    for d in /sys/class/net/*; do
        [ -d "$d/wireless" ] || [ -e "$d/phy80211" ] || continue
        printf '%s\n' "${d##*/}"
    done
}
_ses_wifi_ps() { iw dev "$1" get power_save 2>/dev/null | sed -n 's/^Power save: *//p' | head -n1; }
_ses_nm_present() { [ -d /etc/NetworkManager ] || command -v NetworkManager >/dev/null 2>&1; }
_ses_logind_prop() {
    busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null \
        | sed -n 's/^s "\(.*\)"$/\1/p'
}
_ses_logind_live_ok() { [ "$(_ses_logind_prop HandleLidSwitchExternalPower)" = ignore ] && [ "$(_ses_logind_prop HandleLidSwitchDocked)" = ignore ]; }

# ------------------------------------------------------------------ check ----
_ses_check_autologin() {
    local dm
    local -a keys=()
    if [ "${AUTOLOGIN:-0}" != 1 ]; then kv "autologin" "off (--no-autologin / $PROFILE default)"; return 0; fi
    dm="$(_ses_dm)"
    kv "display manager" "$dm"
    mapfile -t keys < <(_ses_autologin_keys)
    [ "${#keys[@]}" -gt 0 ] || { info "templates/dm-autologin.conf yields no keys"; return 1; }
    case "$dm" in
        plasmalogin)
            if _ses_ini_current "$P5_PLASMALOGIN_CONF" Autologin "${keys[@]}"; then ok "Plasma Login Manager autologin: ${keys[*]} ($P5_PLASMALOGIN_CONF)"
            else info "$P5_PLASMALOGIN_CONF lacks [Autologin] ${keys[*]}"; return 1; fi ;;
        sddm)
            USER="$(_p1_user)" SESSION_NAME="$(_ses_session_name)" _p1_template_current "$TEMPLATES_DIR/dm-autologin.conf" "$P5_SDDM_DROPIN" \
                || { info "$P5_SDDM_DROPIN is missing or outdated"; return 1; }
            if [ -r "$P5_SDDM_CONF" ] && grep -q '^[[:space:]]*\[Autologin\]' "$P5_SDDM_CONF" \
               && ! _ses_ini_current "$P5_SDDM_CONF" Autologin "${keys[@]}"; then
                info "$P5_SDDM_CONF has an [Autologin] section that overrides the drop-in"; return 1
            fi
            ok "SDDM autologin: ${keys[*]}" ;;
        *)
            warn "display manager '$dm': autologin is configured only for Plasma Login Manager and SDDM; log in by hand after a reboot" ;;
    esac
    return 0
}

phase_session_check() {
    local line f g k v cur unit target link ifc ps
    step "checking autologin, KDE power/lock settings, the inhibit unit and the session helper"
    _ses_check_autologin || return 1
    if command -v kreadconfig6 >/dev/null 2>&1; then
        while IFS='|' read -r f g k v; do
            cur="$(_ses_kde_get "$f" "$g" "$k")"
            [ "$cur" = "$v" ] || { info "$f [${g//\//][}] $k is '${cur:-unset}', want $v"; return 1; }
        done < <(_ses_kde_settings)
        ok "KDE: no autolock, no lock on resume, no dimming/display-off/idle suspend on AC$(_p1_laptop && printf ', lid does nothing on AC')"
    else
        info "kreadconfig6 is missing (kconfig, phase packages)"; return 1
    fi
    unit="$(_ses_unit_path)"
    KDE_INHIBIT="$(_ses_kde_inhibit)" _p1_template_current "$TEMPLATES_DIR/profiler-inhibit.service" "$unit" \
        || { info "$unit is missing or differs from the template"; return 1; }
    [ "$(systemctl --user is-enabled "$P5_INHIBIT" 2>/dev/null)" = enabled ] || { info "$P5_INHIBIT is not enabled"; return 1; }
    if systemctl --user is-active -q graphical-session.target 2>/dev/null; then
        systemctl --user is-active -q "$P5_INHIBIT" 2>/dev/null || { info "$P5_INHIBIT is not running although the graphical session is"; return 1; }
        ok "$P5_INHIBIT enabled and running"
    else
        ok "$P5_INHIBIT enabled (starts with the graphical session; none is running now)"
    fi
    link="$(_ses_link)"; target="$(_ses_wse)"
    if [ -L "$link" ] && [ "$(readlink -- "$link")" = "$target" ] && [ -x "$link" ]; then ok "$link → $target"
    else info "$link does not point at $target"; return 1; fi
    if _p1_laptop; then
        _p1_template_current "$TEMPLATES_DIR/logind-lid.conf" "$P5_LOGIND_DROPIN" || { info "$P5_LOGIND_DROPIN is missing or outdated"; return 1; }
        _ses_logind_live_ok || { info "logind has not loaded $P5_LOGIND_DROPIN yet (HandleLidSwitchExternalPower=$(_ses_logind_prop HandleLidSwitchExternalPower))"; return 1; }
        ok "laptop: lid ignored on external power and docked (logind), battery behaviour kept"
    fi
    while IFS= read -r ifc; do
        [ -n "$ifc" ] || continue
        if _ses_nm_present; then
            _p1_template_current "$TEMPLATES_DIR/nm-wifi-powersave.conf" "$P5_NM_DROPIN" || { info "$P5_NM_DROPIN is missing or outdated"; return 1; }
        fi
        command -v iw >/dev/null 2>&1 || { info "iw is missing (phase packages)"; return 1; }
        ps="$(_ses_wifi_ps "$ifc")"
        [ "$ps" = off ] || { info "Wi-Fi power save on $ifc is '${ps:-?}'"; return 1; }
        ok "Wi-Fi power save off on $ifc"
    done < <(_ses_wifi_ifaces)
    if command -v xdotool >/dev/null 2>&1 && line="$("$target" timeout 10 xdotool getdisplaygeometry 2>/dev/null)"; then
        ok "display probe: ${line//$'\n'/ } (xdotool through with-session-env)"
    else
        warn "display probe failed (no desktop session logged in, or xdotool missing): install, human and bench need the session"
    fi
    phase_note "autologin $( [ "${AUTOLOGIN:-0}" = 1 ] && _ses_dm || printf off), no lock/DPMS/suspend, inhibit unit$(_p1_laptop && printf ', lid ignored on AC')"
    return 0
}

# ------------------------------------------------------------------ apply ----
_ses_apply_autologin() {
    local dm
    local -a keys=()
    if [ "${AUTOLOGIN:-0}" != 1 ]; then skip "autologin off"; return 0; fi
    dm="$(_ses_dm)"
    mapfile -t keys < <(_ses_autologin_keys)
    [ "${#keys[@]}" -gt 0 ] || { fail "templates/dm-autologin.conf yields no keys"; return 1; }
    [ -f "/usr/share/wayland-sessions/$(_ses_session_name).desktop" ] || warn "no /usr/share/wayland-sessions/$(_ses_session_name).desktop: autologin names a session that may not exist"
    case "$dm" in
        plasmalogin)
            step "autologin: Plasma Login Manager ($P5_PLASMALOGIN_CONF)"
            _ses_ini_apply "$P5_PLASMALOGIN_CONF" Autologin "${keys[@]}" || return 1 ;;
        sddm)
            step "autologin: SDDM ($P5_SDDM_DROPIN)"
            USER="$(_p1_user)" SESSION_NAME="$(_ses_session_name)" write_template "$TEMPLATES_DIR/dm-autologin.conf" "$P5_SDDM_DROPIN" --sudo --mode 0644 --owner root:root || return 1
            if [ -r "$P5_SDDM_CONF" ] && grep -q '^[[:space:]]*\[Autologin\]' "$P5_SDDM_CONF"; then
                _ses_ini_apply "$P5_SDDM_CONF" Autologin "${keys[@]}" || return 1
            fi ;;
        *)
            warn "display manager '$dm': autologin left alone (supported: Plasma Login Manager, SDDM)"
            return 0 ;;
    esac
    info "autologin takes effect at the next boot or logout"
    return 0
}

phase_session_apply() {
    local f g k v cur unit link target ifc ps i wse pd_changed=0 lock_changed=0 unit_changed=0 lid_changed=0 nm_changed=0
    local -a ga=()
    _p1_need_cmds kwriteconfig6 kreadconfig6 kde-inhibit systemctl || return 1
    _ses_apply_autologin || return 1

    step "KDE: no screen lock, no dimming, no display power-off, no idle suspend on AC"
    while IFS='|' read -r f g k v; do
        cur=""
        command -v kreadconfig6 >/dev/null 2>&1 && cur="$(_ses_kde_get "$f" "$g" "$k")"
        if [ "$cur" = "$v" ]; then skip "$f [${g//\//][}] $k=$v"; continue; fi
        mapfile -t ga < <(_ses_group_args "$g")
        run -- kwriteconfig6 --file "$f" "${ga[@]}" --key "$k" "$v" || return 1
        case "$f" in powerdevilrc) pd_changed=1 ;; kscreenlockerrc) lock_changed=1 ;; esac
    done < <(_ses_kde_settings)
    if [ "$pd_changed" -eq 1 ]; then
        run --allow-fail -- systemctl --user try-restart plasma-powerdevil.service \
            || warn "plasma-powerdevil.service did not restart (exit $RUN_STATUS): the power settings apply at the next login"
    fi
    wse="$(_ses_wse)"
    if [ "$lock_changed" -eq 1 ]; then
        if run --allow-fail -- "$wse" dbus-send --session --type=method_call --dest=org.freedesktop.ScreenSaver /ScreenSaver org.kde.screensaver.configure; then
            is_dry_run || ok "screen locker reconfigured"
        else
            info "screen locker not reconfigured (exit $RUN_STATUS; no session?): the lock settings apply at the next login"
        fi
    fi

    step "user unit $P5_INHIBIT"
    unit="$(_ses_unit_path)"
    KDE_INHIBIT="$(_ses_kde_inhibit)" _p1_template_current "$TEMPLATES_DIR/profiler-inhibit.service" "$unit" || unit_changed=1
    KDE_INHIBIT="$(_ses_kde_inhibit)" write_template "$TEMPLATES_DIR/profiler-inhibit.service" "$unit" --mode 0644 || return 1
    [ "$unit_changed" -eq 0 ] || run -- systemctl --user daemon-reload || return 1
    if [ "$(systemctl --user is-enabled "$P5_INHIBIT" 2>/dev/null)" = enabled ] && [ "$unit_changed" -eq 0 ]; then
        skip "$P5_INHIBIT already enabled"
    else
        run -- systemctl --user enable "$P5_INHIBIT" || return 1
    fi
    if systemctl --user is-active -q graphical-session.target 2>/dev/null; then
        if [ "$unit_changed" -eq 1 ] || ! systemctl --user is-active -q "$P5_INHIBIT" 2>/dev/null; then
            run -- systemctl --user restart "$P5_INHIBIT" || return 1
        fi
    else
        info "no graphical session now: $P5_INHIBIT starts with the next one"
    fi

    step "session helper ~/.local/bin/with-session-env"
    link="$(_ses_link)"; target="$wse"
    if [ -L "$link" ] && [ "$(readlink -- "$link")" = "$target" ]; then
        skip "$link → $target"
    else
        run -- mkdir -p -- "${link%/*}" || return 1
        run -- ln -sfn -- "$target" "$link" || return 1
        is_dry_run || ok "$link → $target"
    fi

    if _p1_laptop; then
        step "laptop: lid on external power / docked → ignore (logind)"
        _p1_template_current "$TEMPLATES_DIR/logind-lid.conf" "$P5_LOGIND_DROPIN" || lid_changed=1
        write_template "$TEMPLATES_DIR/logind-lid.conf" "$P5_LOGIND_DROPIN" --sudo --mode 0644 --owner root:root || return 1
        if [ "$lid_changed" -eq 1 ] || ! _ses_logind_live_ok; then
            run --sudo -- systemctl kill -s HUP systemd-logind.service || return 1
            if ! is_dry_run; then
                for i in 1 2 3 4 5 6 7 8 9 10; do _ses_logind_live_ok && break; sleep 0.5; done
                _ses_logind_live_ok || { fail "logind did not pick up $P5_LOGIND_DROPIN after SIGHUP (HandleLidSwitchExternalPower=$(_ses_logind_prop HandleLidSwitchExternalPower))"; return 1; }
                ok "logind reloaded: HandleLidSwitchExternalPower=ignore HandleLidSwitchDocked=ignore"
            fi
        fi
    fi

    while IFS= read -r ifc; do
        [ -n "$ifc" ] || continue
        step "Wi-Fi power save off ($ifc)"
        if _ses_nm_present; then
            _p1_template_current "$TEMPLATES_DIR/nm-wifi-powersave.conf" "$P5_NM_DROPIN" || nm_changed=1
            write_template "$TEMPLATES_DIR/nm-wifi-powersave.conf" "$P5_NM_DROPIN" --sudo --mode 0644 --owner root:root || return 1
            if [ "$nm_changed" -eq 1 ] && systemctl is-active -q NetworkManager.service 2>/dev/null; then
                if run --sudo --allow-fail -- nmcli general reload conf; then
                    is_dry_run || ok "NetworkManager re-read its configuration (not restarted); effective at the next reconnect"
                else
                    warn "nmcli general reload conf failed (exit $RUN_STATUS): the drop-in applies from the next NetworkManager start"
                fi
                nm_changed=0
            fi
        else
            warn "NetworkManager is not installed: $ifc's power save is switched off for this boot only"
        fi
        ps=""
        command -v iw >/dev/null 2>&1 && ps="$(_ses_wifi_ps "$ifc")"
        if [ "$ps" = off ]; then
            skip "power save already off on $ifc"
        else
            run --sudo -- iw dev "$ifc" set power_save off || return 1
        fi
    done < <(_ses_wifi_ifaces)
    phase_note "session configured"
    return 0
}
