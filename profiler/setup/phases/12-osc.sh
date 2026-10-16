#!/usr/bin/env bash
# profiler/setup/phases/12-osc.sh — phase 12 "osc": AbletonOSC (the MIDI Remote
# Script that replaces the deleted Max-for-Live control device) into Live's User
# Library, through profiler/control/install.sh --prefix <prefix>.
#
# The User Library is <prefix>/drive_c/users/<user>/Documents/Ableton/User Library;
# Wine usually makes Documents a symlink into $HOME, so the path is resolved with
# readlink -f and recorded as user_library= in ~/.config/profiler/setup.conf
# (profiler/bin/state snapshots it separately when it lives outside the prefix).
# While profiler/control/install.sh does not exist yet (control workstream), the
# phase records the path, sets osc_status=pending, warns and passes, so later
# phases can run; a re-run installs AbletonOSC once the installer has landed.
# Uses the _lp_* helpers from 09-build.sh.

phase_register 12 osc "AbletonOSC remote script into Live's User Library" "install"

: "${_OSC_ATTEMPTED:=0}"        # set by apply: a missing control/install.sh is then tolerated by check

_osc_installer() { printf '%s/control/install.sh\n' "$PROFILER_ROOT"; }

# the prefix's Windows user directory (…/drive_c/users/<user>); 1 when none
_osc_wine_user_dir() {
    local prefix c me
    prefix="$(_lp_prefix)"; me="${USER:-$(id -un)}"
    if [ -d "$prefix/drive_c/users/$me" ]; then printf '%s\n' "$prefix/drive_c/users/$me"; return 0; fi
    for c in "$prefix"/drive_c/users/*; do
        [ -d "$c/AppData" ] || continue
        case "${c##*/}" in Public|public) continue ;; esac
        printf '%s\n' "$c"
        return 0
    done
    return 1
}

# the resolved User Library path (Documents symlink followed; legacy "My Documents" accepted)
_osc_user_library() {
    local u docs
    u="$(_osc_wine_user_dir)" || return 1
    if [ -e "$u/Documents" ] || [ -L "$u/Documents" ]; then
        docs="$(readlink -f -- "$u/Documents")"
    elif [ -e "$u/My Documents" ]; then
        docs="$(readlink -f -- "$u/My Documents")"
    else
        docs="$(readlink -f -- "$u")/Documents"
    fi
    printf '%s/Ableton/User Library\n' "$docs"
}

_osc_remote_dir() { printf '%s/Remote Scripts/AbletonOSC\n' "$1"; }

phase_osc_check() {
    local ul rd rec
    step "locating Live's User Library"
    if ! ul="$(_osc_user_library)"; then
        info "the prefix has no drive_c/users/<user> directory yet (phase install)"
        return 1
    fi
    kv "user library" "$ul"
    rec="$(cfg_get user_library)"
    if [ "$rec" != "$ul" ]; then info "user_library is not recorded in $PROFILER_SETUP_CONF yet"; return 1; fi
    rd="$(_osc_remote_dir "$ul")"
    if [ -f "$rd/INSTALLED.txt" ] || [ -f "$rd/__init__.py" ]; then
        ok "AbletonOSC installed at $rd"
        phase_note "AbletonOSC installed"
        return 0
    fi
    if [ ! -x "$(_osc_installer)" ]; then
        if [ "$_OSC_ATTEMPTED" = 1 ]; then
            warn "osc pending: $(_osc_installer) does not exist yet (control workstream); re-run phase osc once it lands"
            phase_note "osc pending"
            return 0
        fi
        info "profiler/control/install.sh is not present yet"
        return 1
    fi
    info "AbletonOSC is not installed at $rd"
    return 1
}

phase_osc_apply() {
    local ul rd inst prefix
    prefix="$(_lp_prefix)"
    if ! ul="$(_osc_user_library)"; then
        fail "prefix $prefix has no drive_c/users/<user> directory: run phase install first" || return 1
    fi
    kv "user library" "$ul"
    case "$ul" in
        "$prefix"/*) info "the User Library lives inside the prefix" ;;
        *) info "the User Library lives outside the prefix (Documents is a symlink): profiler/bin/state snapshots it separately" ;;
    esac
    cfg_set user_library "$ul" || return 1
    is_dry_run && info "would record user_library=$ul in $PROFILER_SETUP_CONF"
    inst="$(_osc_installer)"
    _OSC_ATTEMPTED=1
    if [ ! -x "$inst" ]; then
        warn "osc pending: $inst does not exist yet; AbletonOSC cannot be installed in this run"
        cfg_set osc_status pending || return 1
        action_required "once profiler/control/install.sh exists: setup-machine.sh --only osc, then select AbletonOSC as a Control Surface in Live"
        phase_note "osc pending"
        return 0
    fi
    if _lp_prefix_busy; then
        fail "Live is running; quit it (File > Quit) before installing the remote script" || return 1
    fi
    rd="$(_osc_remote_dir "$ul")"
    # Live creates the User Library on its first launch (phase human, later);
    # install.sh refuses a missing library, so the directory is created here —
    # Live adopts an existing "Documents/Ableton/User Library" as its default
    if [ ! -d "$ul/Remote Scripts" ]; then
        run -- mkdir -p -- "$ul/Remote Scripts" || return 1
    fi
    step "installing AbletonOSC into $rd"
    run -- "$inst" --prefix "$prefix" --library-path "$ul" || return 1
    cfg_set osc_status installed || return 1
    is_dry_run || ok "AbletonOSC installed"
    phase_note "AbletonOSC → $rd"
    return 0
}
