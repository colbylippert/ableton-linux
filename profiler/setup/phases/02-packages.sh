#!/usr/bin/env bash
# profiler/setup/phases/02-packages.sh — phase 02 "packages": the host tool set.
#   * Arch does not support partial upgrades: one `pacman -Syu --noconfirm`, then
#     `pacman -S --needed --noconfirm` of the list below (nothing runs when every
#     package is already installed, unless --force asks for the upgrade)
#   * the running kernel must still be the installed kernel package afterwards
#     (headers, bcc and bpftrace match the installed one): otherwise need_reboot
#   * ananicy-cpp is switched off through `profiler-root-helper knob set ananicy
#     off`, so `profiler-root-helper reset` can restore it (the baseline was taken
#     in phase 01, before this change)
# Check (read-only): `pacman -T` reports every package as installed and
# ananicy-cpp.service is neither enabled nor active (or not installed).
#
# Package names were verified with `pacman -Si` on the CachyOS laptop
# (2026-10-16, cachyos-*-v3 + core/extra): design A's `bcc-tools` no longer
# exists as a package — it is a virtual provide of `bcc-libbpf-tools` — so the
# real name is used. Added to design A's list: cmake ninja (host builds and the
# repo's test targets), realtime-privileges (the realtime group phase 04 joins),
# iw (Wi-Fi power save, phase 05), kde-cli-tools + kconfig (kde-inhibit,
# kwriteconfig6, phase 05), pipewire + wireplumber (pw-dump/pw-metadata/wpctl,
# phase 06); all of them are no-ops on a KDE desktop install.

phase_register 02 packages "pacman -Syu, then the build/trace/desktop tool set (--needed); ananicy-cpp off" "sudo"

: "${P2_ANANICY_UNIT:=ananicy-cpp.service}"

# pkgbase of the running kernel (linux-cachyos); falls back to an installed one
# when the running kernel's modules are already gone (upgraded without a reboot)
_pkg_kernel_pkgbase() {
    local f
    if [ -r "/usr/lib/modules/$(uname -r)/pkgbase" ]; then cat "/usr/lib/modules/$(uname -r)/pkgbase"; return 0; fi
    for f in /usr/lib/modules/*/pkgbase; do [ -r "$f" ] && { cat "$f"; return 0; }; done
    printf 'linux\n'
}

# the package list, one name per line
_pkg_list() {
    local kpkg
    kpkg="$(_pkg_kernel_pkgbase)"
    printf '%s\n' \
        base-devel git binutils zstd cabextract unzip rsync ccache jq python curl \
        podman passt crun netavark aardvark-dns fuse-overlayfs \
        bpftrace bcc bcc-libbpf-tools python-bcc perf strace ltrace sysstat \
        libbpf bpf clang llvm lld pahole elfutils "${kpkg}-headers" \
        cmake ninja mingw-w64-gcc \
        xorg-server-xvfb xdotool xorg-xprop xdg-utils desktop-file-utils shared-mime-info \
        alsa-utils inotify-tools tmux socat lsof psmisc wl-clipboard \
        nodejs npm shellcheck \
        realtime-privileges iw kde-cli-tools kconfig pipewire wireplumber
    # optional extras (design A): the PipeASIO settings panel on Wayland and a
    # browser for the Live trial authorisation — the VM image may lack them
    if profile_is vm; then printf '%s\n' qt6-base qt6-wayland firefox; fi
}

# packages from the list that are not installed (pacman -T honours provides)
_pkg_missing() {
    local -a pkgs=()
    mapfile -t pkgs < <(_pkg_list)
    pacman -T "${pkgs[@]}" 2>/dev/null || true
}

# 0 when the installed kernel package owns the running kernel's module directory
# (pacman -Qqo, not `pacman -Ql | grep -q`: under pipefail grep's early exit
# would SIGPIPE pacman and turn a match into a failure)
_pkg_kernel_current() {
    local kver pkgbase owner
    kver="$(uname -r)"
    [ -r "/usr/lib/modules/$kver/pkgbase" ] || return 1
    pkgbase="$(cat "/usr/lib/modules/$kver/pkgbase")"
    owner="$(pacman -Qqo -- "/usr/lib/modules/$kver/pkgbase" 2>/dev/null || true)"
    [ -n "$pkgbase" ] && [ "$owner" = "$pkgbase" ]
}

# on | off | absent — the same rule as the helper's `knob get ananicy`
_pkg_ananicy_state() {
    local en act
    systemctl cat "$P2_ANANICY_UNIT" >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
    en="$(systemctl is-enabled "$P2_ANANICY_UNIT" 2>/dev/null || true)"
    act="$(systemctl is-active "$P2_ANANICY_UNIT" 2>/dev/null || true)"
    if [ "$en" = enabled ] || [ "$act" = active ] || [ "$act" = activating ]; then printf 'on\n'; else printf 'off\n'; fi
}

# wait (≤ 5 min) while another package manager holds the pacman database lock
_pkg_wait_lock() {
    local lock=/var/lib/pacman/db.lck i=0
    is_dry_run && return 0
    while [ -e "$lock" ]; do
        [ "$i" -gt 0 ] || info "the pacman database is locked ($lock): waiting up to 5 min for the other package manager"
        i=$(( i + 1 ))
        if [ "$i" -gt 150 ]; then
            fail "$lock is still present after 5 min: another pacman runs, or the lock is stale (remove it only when no pacman runs)"
            return 1
        fi
        sleep 2
    done
    return 0
}

phase_packages_check() {
    local missing n an kpkg
    step "checking the package set"
    command -v pacman >/dev/null 2>&1 || { fail "pacman not found: this phase needs CachyOS/Arch"; return 1; }
    n="$(_pkg_list | grep -c .)"
    missing="$(_pkg_missing)"
    if [ -n "$missing" ]; then
        info "$(grep -c . <<< "$missing") of $n package(s) missing: $(tr '\n' ' ' <<< "$missing")"
        return 1
    fi
    ok "all $n packages installed"
    kpkg="$(_pkg_kernel_pkgbase)"
    if _pkg_kernel_current; then
        ok "running kernel $(uname -r) is the installed $kpkg ($(pacman -Q "$kpkg" 2>/dev/null | awk '{print $2}'))"
    else
        warn "the running kernel $(uname -r) is not the installed $kpkg package (upgraded without a reboot?): headers, bcc and bpftrace match the installed one"
        _p1_need_reboot
    fi
    an="$(_pkg_ananicy_state)"
    case "$an" in
        on) info "$P2_ANANICY_UNIT is enabled or running (its renicing skews measurements)"; return 1 ;;
        absent) kv "ananicy-cpp" "not installed" ;;
        *) ok "ananicy-cpp off" ;;
    esac
    phase_note "$n packages; ananicy-cpp $an"
    return 0
}

phase_packages_apply() {
    local missing helper="${P1_HELPER_DST:-/usr/local/sbin/profiler-root-helper}"
    local -a pkgs=()
    command -v pacman >/dev/null 2>&1 || { fail "pacman not found: this phase needs CachyOS/Arch"; return 1; }
    mapfile -t pkgs < <(_pkg_list)       # before -Syu: a kernel upgrade removes the running kernel's pkgbase file
    missing="$(_pkg_missing)"
    if [ -n "$missing" ] || [ "$FORCE" = 1 ]; then
        _pkg_wait_lock || return 1
        step "full system upgrade first (pacman -Syu; Arch does not support partial upgrades)"
        run --sudo -- pacman -Syu --noconfirm || return 1
        if [ -n "$(_pkg_missing)" ] || is_dry_run; then
            step "installing the tool set (${#pkgs[@]} packages, --needed)"
            [ -z "$missing" ] || kv "missing" "$(tr '\n' ' ' <<< "$missing")"
            run --sudo -- pacman -S --needed --noconfirm "${pkgs[@]}" || return 1
        else
            skip "every package of the tool set is installed"
        fi
        if ! is_dry_run; then
            missing="$(_pkg_missing)"
            [ -z "$missing" ] || { fail "still missing after pacman -S: $(tr '\n' ' ' <<< "$missing")"; return 1; }
            if ! _pkg_kernel_current; then
                warn "pacman -Syu installed a new kernel; reboot before building or tracing (running $(uname -r))"
                _p1_need_reboot
            fi
        fi
    else
        skip "every package of the tool set is installed (--force upgrades the system)"
    fi
    step "ananicy-cpp (renices processes behind the profiler's back)"
    case "$(_pkg_ananicy_state)" in
        absent) skip "ananicy-cpp is not installed" ;;
        off) skip "ananicy-cpp is already off" ;;
        on)
            if ! is_dry_run && [ ! -x "$helper" ]; then
                fail "$helper is missing (phase sudo installs it): ananicy-cpp is switched through the helper so that 'profiler-root-helper reset' restores it"
                return 1
            fi
            run --sudo -- "$helper" knob set ananicy off || return 1
            is_dry_run || ok "ananicy-cpp disabled and stopped (profiler-root-helper reset restores it)"
            ;;
    esac
    phase_note "tool set installed; ananicy-cpp off"
    return 0
}
