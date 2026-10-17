#!/usr/bin/env bash
# profiler/setup/phases/00-preflight.sh — phase 00 "preflight": audit the host
# before anything is changed, and record the facts that later phases and
# verify.sh rely on. This file is also the worked example of the phase
# conventions documented at the top of lib/phase.sh:
#   * sourced by the driver: only definitions at the top level, plus phase_register
#   * phase_preflight_check  — read-only; 0 when every hard requirement holds AND
#                              the host facts are recorded for the running kernel
#   * phase_preflight_apply  — the only mutation is writing
#                              ~/.local/state/profiler/host-facts.env through `run`
#   * output only via step/ok/warn/fail/info/kv; hard failures via fail (counted),
#     soft ones via warn; need_reboot when the kernel package disagrees with the
#     running kernel
# Read-only probes call commands directly (not through `run`), so they keep
# working under --dry-run.

phase_register 00 preflight "distro, CPU, kernel, tracing facilities, resources, network, session" ""

: "${PREFLIGHT_RC:=}"          # cached audit result for this process ("" = not run yet)
: "${PF_HARD:=0}"
declare -a PREFLIGHT_FACTS=()

_pf_fact() { PREFLIGHT_FACTS+=("$1=$2"); }
_pf_fail() { PF_HARD=$(( PF_HARD + 1 )); fail "$*" || true; }
_pf_http() {   # _pf_http URL [--any] → prints the HTTP status code ("" when unreachable)
    local url="$1" code
    if [ "${2:-}" = --any ]; then
        code="$(curl -sI -m 10 -o /dev/null -w '%{http_code}' -- "$url" 2>/dev/null || true)"
    else
        code="$(curl -fsI -m 10 -o /dev/null -w '%{http_code}' -- "$url" 2>/dev/null || true)"
    fi
    printf '%s\n' "${code:-}"
}

_preflight_audit() {
    local id like pretty arch virt shell kver kmaj kmin rest mode jit pkgbase pkgver
    local mem_kb avail_kb mem_gib avail_gib swap_kb home_avail home_fs tmp_avail tmp_fs
    local rt cs thp url code env_dump var ntp opt
    local -a kmiss=() emiss=()
    PF_HARD=0
    PREFLIGHT_FACTS=()

    # ---------------------------------------------------------------- host
    step "host"
    if [ -r /etc/os-release ]; then
        id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
        like="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
        pretty="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-$id}")"
        kv "distro" "$pretty (ID=$id${like:+, ID_LIKE=$like})"
        case "$id" in
            cachyos|arch) ok "distro '$id' is supported" ;;
            *) if [[ " $like " == *" arch "* ]]; then
                   warn "distro '$id' is Arch-like but untested; package names assume CachyOS/Arch"
               else
                   _pf_fail "unsupported distro '$id': the phases use pacman and CachyOS/Arch package names"
               fi ;;
        esac
        _pf_fact distro "$id"
    else
        _pf_fail "/etc/os-release is missing; cannot identify the distribution"
    fi
    arch="$(uname -m)"
    kv "machine" "$arch"
    if [ "$arch" = x86_64 ]; then ok "x86_64"; else _pf_fail "machine is $arch, need x86_64"; fi
    if [ -x /lib/ld-linux-x86-64.so.2 ] && /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3 (supported'; then
        ok "CPU level x86-64-v3 supported (CachyOS v3 repositories)"
        _pf_fact x86_64_v3 1
    else
        warn "the dynamic loader does not report x86-64-v3 support (CachyOS v3 packages need it; plain Arch does not)"
        _pf_fact x86_64_v3 0
    fi
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    kv "virtualization" "${virt:-unknown}"
    _pf_fact virtualization "${virt:-unknown}"
    if profile_is vm && [ "$virt" = none ]; then warn "profile 'vm' on a host that systemd-detect-virt calls bare metal"; fi
    if profile_is baremetal && [ -n "$virt" ] && [ "$virt" != none ]; then warn "profile 'baremetal' under '$virt': no timing claims are valid here"; fi
    kv "user" "$(id -un) (uid $(id -u))"
    shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
    kv "login shell" "${shell:-?}"
    case "$shell" in
        */fish) info "login shell is fish: invoke everything remotely as  ssh -t HOST 'bash -lc \"…\"'" ;;
    esac
    _pf_fact login_shell "${shell:-}"
    kv "cpus" "$(nproc 2>/dev/null || echo ?)"
    _pf_fact nproc "$(nproc 2>/dev/null || echo 0)"

    # -------------------------------------------------------------- kernel
    step "kernel and tracing facilities"
    kver="$(uname -r)"
    kv "kernel" "$kver"
    _pf_fact kernel "$kver"
    kmaj="${kver%%.*}"; rest="${kver#*.}"; kmin="${rest%%[^0-9]*}"
    [[ "$kmaj" =~ ^[0-9]+$ ]] || kmaj=0
    [[ "$kmin" =~ ^[0-9]+$ ]] || kmin=0
    if (( kmaj > 6 || (kmaj == 6 && kmin >= 14) )); then
        ok "kernel $kver is 6.14 or newer (NTSync)"
    else
        _pf_fail "kernel $kver is older than 6.14; NTSync and the tracer need 6.14+"
    fi
    if [ -c /dev/ntsync ]; then
        mode="$(stat -c %a /dev/ntsync 2>/dev/null || echo ?)"
        ok "/dev/ntsync present (mode $mode)"
        [ "$mode" = 666 ] || warn "/dev/ntsync mode is $mode, expected 0666 so Wine can open it as $(id -un)"
    else
        _pf_fail "/dev/ntsync is missing (kernel 6.14+ with CONFIG_NTSYNC; try: sudo modprobe ntsync)"
    fi
    if [ -d /sys/module/ntsync ]; then
        ok "ntsync module loaded"
    elif grep -q 'ntsync' "/lib/modules/$kver/modules.builtin" 2>/dev/null; then
        ok "ntsync built into the kernel"
    else
        warn "ntsync is not loaded (/sys/module/ntsync missing)"
    fi
    if [ -r /sys/kernel/btf/vmlinux ]; then ok "kernel BTF available (CO-RE)"; else _pf_fail "/sys/kernel/btf/vmlinux is missing (CONFIG_DEBUG_INFO_BTF): the tracer needs BTF"; fi
    if [ -d /sys/bus/event_source/devices/uprobe ]; then ok "uprobe PMU present"; else _pf_fail "no uprobe PMU at /sys/bus/event_source/devices/uprobe (CONFIG_UPROBE_EVENTS)"; fi
    if mountpoint -q /sys/kernel/tracing 2>/dev/null; then ok "tracefs mounted"; else _pf_fail "tracefs is not mounted at /sys/kernel/tracing"; fi
    jit="$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null || echo ?)"
    if [ "$jit" = 1 ]; then ok "BPF JIT enabled"; else warn "net.core.bpf_jit_enable=$jit (expected 1)"; fi
    if [ -r /proc/config.gz ] && command -v zgrep >/dev/null 2>&1; then
        for opt in UPROBE_EVENTS BPF_EVENTS KPROBES USER_STACKTRACE_SUPPORT DEBUG_INFO_BTF HZ_1000; do
            zgrep -qx "CONFIG_$opt=y" /proc/config.gz 2>/dev/null || kmiss+=("$opt")
        done
        if [ "${#kmiss[@]}" -eq 0 ]; then
            ok "kconfig: UPROBE_EVENTS BPF_EVENTS KPROBES USER_STACKTRACE_SUPPORT DEBUG_INFO_BTF HZ_1000"
        else
            warn "kconfig options not =y: ${kmiss[*]}"
        fi
    else
        warn "/proc/config.gz unavailable; kernel config not checked"
    fi
    if [ -r "/usr/lib/modules/$kver/pkgbase" ]; then
        pkgbase="$(cat "/usr/lib/modules/$kver/pkgbase")"
        pkgver="$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}')"
        kv "kernel package" "$pkgbase ${pkgver:-(not installed?)}"
        _pf_fact kernel_pkgbase "$pkgbase"
        _pf_fact kernel_pkgver "${pkgver:-}"
        if pacman -Ql "$pkgbase" 2>/dev/null | grep -qxF "$pkgbase /usr/lib/modules/$kver/"; then
            ok "running kernel matches the installed $pkgbase package"
        else
            warn "installed $pkgbase ${pkgver:-?} is not the running kernel $kver: reboot before building (headers/bcc must match)"
            need_reboot
        fi
    else
        warn "/usr/lib/modules/$kver/pkgbase is missing: the running kernel's package is gone (upgraded without a reboot?)"
        need_reboot
    fi

    # ----------------------------------------------------------- resources
    step "resources"
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    # GiB figures are rounded for display only (8084712 kB is "8 GiB", not 7); every threshold below compares raw kB
    mem_gib=$(( (mem_kb + 524288) / 1048576 )); avail_gib=$(( (avail_kb + 524288) / 1048576 ))
    kv "memory" "${mem_gib} GiB total, ${avail_gib} GiB available"
    _pf_fact mem_total_kb "$mem_kb"
    if [ "$mem_kb" -lt $(( 12 * 1048576 )) ]; then
        warn "RAM is ${mem_gib} GiB (< 12 GiB): the container build needs ~1.2 GiB per job, JOBS is clamped to ${JOBS:-?}"
        if [ "${VM_RAM_CHECK:-0}" = 1 ]; then
            info "to give the VM 16 GiB: power it off, set   memsize = \"16384\"   in its .vmx (e.g. C:\\vms\\vmware\\AbletonLinux\\AbletonLinux.vmx), power on"
            action_required "raise the VM to 16 GiB RAM (power off, memsize = \"16384\" in the .vmx)"
        fi
    else
        ok "RAM ${mem_gib} GiB"
    fi
    kv "build jobs" "${JOBS:-?} (${JOBS_SOURCE:-auto})"
    _pf_fact jobs "${JOBS:-}"
    if [ "$swap_kb" -gt 0 ]; then ok "swap present ($(( (swap_kb + 524288) / 1048576 )) GiB)"; else warn "no swap: a -j${JOBS:-?} Wine build may run out of memory"; fi
    home_avail="$(df -B1 --output=avail -- "$HOME" 2>/dev/null | tail -n1 | tr -d ' ')"
    home_fs="$(stat -f -c %T -- "$HOME" 2>/dev/null || echo ?)"
    [[ "$home_avail" =~ ^[0-9]+$ ]] || home_avail=0
    kv "free in \$HOME" "$(( home_avail / 1073741824 )) GiB ($home_fs)"
    _pf_fact home_fs "$home_fs"
    if [ "$home_avail" -ge $(( 60 * 1073741824 )) ]; then
        ok "at least 60 GiB free in $HOME"
    else
        _pf_fail "need >= 60 GiB free in $HOME (checkout, ccache, container storage, runtime, snapshots); have $(( home_avail / 1073741824 )) GiB"
    fi
    [ "$home_fs" = btrfs ] || info "$HOME is not on btrfs: snapshots will use rsync instead of reflinks"
    tmp_fs="$(findmnt -n -o FSTYPE /tmp 2>/dev/null || echo ?)"
    tmp_avail="$(df -B1 --output=avail /tmp 2>/dev/null | tail -n1 | tr -d ' ')"
    [[ "$tmp_avail" =~ ^[0-9]+$ ]] || tmp_avail=0
    kv "/tmp" "$(( tmp_avail / 1073741824 )) GiB free ($tmp_fs)"
    [ "$tmp_fs" != tmpfs ] || warn "/tmp is tmpfs (RAM-backed): build.sh hard-codes /tmp for its source snapshot (no TMPDIR); keep >= 2 GiB free there and store nothing else in it"
    if [ "$tmp_avail" -ge $(( 2 * 1073741824 )) ]; then ok "/tmp has >= 2 GiB free"; else _pf_fail "/tmp has only $(( tmp_avail / 1048576 )) MiB free; build.sh needs >= 2 GiB there"; fi
    rt="$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo ?)"
    kv "sched_rt_runtime_us" "$rt"
    _pf_fact sched_rt_runtime_us "$rt"
    cs="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo ?)"
    kv "clocksource" "$cs"
    _pf_fact clocksource "$cs"
    [ "$cs" = tsc ] || warn "clocksource is '$cs', not tsc: timestamps are more expensive and less precise"
    thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '[?]')"
    thp="${thp#*[}"; thp="${thp%%]*}"
    kv "transparent hugepages" "$thp"
    _pf_fact thp "$thp"

    # ------------------------------------------------------------- network
    step "network"
    for url in https://github.com https://snapshot.ubuntu.com https://apt.llvm.org; do
        code="$(_pf_http "$url")"
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then ok "$url ($code)"; else warn "$url unreachable (http ${code:-none}); the container image build needs it"; fi
    done
    code="$(_pf_http https://registry-1.docker.io/v2/ --any)"
    case "$code" in
        2[0-9][0-9]|401) ok "https://registry-1.docker.io/v2/ ($code)" ;;
        *) warn "docker registry unreachable (http ${code:-none}); the base image pull needs it" ;;
    esac
    if command -v pacman-conf >/dev/null 2>&1; then
        url="$(pacman-conf -r core Server 2>/dev/null | head -n1)"
        if [ -n "$url" ]; then
            code="$(_pf_http "$url/core.db")"
            if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then ok "pacman mirror $url ($code)"; else warn "pacman mirror $url unreachable (http ${code:-none})"; fi
        else
            warn "pacman-conf lists no server for [core]"
        fi
    else
        warn "pacman-conf not found; mirror reachability not checked"
    fi

    # ------------------------------------------------------------- session
    step "session and time"
    env_dump="$(systemctl --user show-environment 2>/dev/null || true)"
    for var in DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS; do
        grep -q "^$var=" <<< "$env_dump" || emiss+=("$var")
    done
    if [ "${#emiss[@]}" -eq 0 ]; then
        ok "Plasma session detected (DISPLAY, WAYLAND_DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS in systemctl --user)"
        _pf_fact session 1
    else
        warn "no graphical session in 'systemctl --user show-environment' (missing: ${emiss[*]}); phases install/human need the desktop logged in"
        _pf_fact session 0
    fi
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [ "$ntp" = yes ]; then ok "clock is NTP-synchronised"; else warn "clock not NTP-synchronised (NTPSynchronized=${ntp:-?})"; fi
    if command -v vmware-toolbox-cmd >/dev/null 2>&1; then
        kv "vmware timesync" "$(vmware-toolbox-cmd timesync status 2>/dev/null || true)"
    fi

    # --------------------------------------------------------------- tools
    step "tools this script needs"
    if require_cmd sudo curl git tar zstd sha256sum timeout flock; then
        ok "sudo curl git tar zstd sha256sum timeout flock"
    else
        PF_HARD=$(( PF_HARD + 1 ))
    fi

    PREFLIGHT_RC="$PF_HARD"
    if [ "$PF_HARD" -gt 0 ]; then
        info "preflight: $PF_HARD hard requirement(s) unmet (see $G_FAIL lines above)"
    else
        ok "preflight: all hard requirements met"
    fi
    [ "$PF_HARD" -eq 0 ]
}

_preflight_facts_file() { printf '%s/host-facts.env\n' "${PROFILER_STATE_DIR:-$HOME/.local/state/profiler}"; }

phase_preflight_check() {
    local facts
    if [ -z "$PREFLIGHT_RC" ]; then _preflight_audit || true; fi
    [ "$PREFLIGHT_RC" -eq 0 ] || return 1
    facts="$(_preflight_facts_file)"
    if [ -r "$facts" ] && grep -qxF "kernel=$(uname -r)" "$facts"; then
        kv "host facts" "$facts"
        phase_note "host audit passed"
        return 0
    fi
    info "host facts not recorded for kernel $(uname -r) yet ($facts)"
    return 1
}

phase_preflight_apply() {
    local facts tmp line
    if [ -z "$PREFLIGHT_RC" ]; then _preflight_audit || true; fi
    if [ "$PREFLIGHT_RC" -ne 0 ]; then
        fail "preflight cannot fix the host: $PREFLIGHT_RC hard requirement(s) unmet" || return 1
    fi
    facts="$(_preflight_facts_file)"
    step "recording host facts"
    tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/host-facts.XXXXXX")" || { fail "mktemp failed" || return 1; }
    {
        printf '# written by profiler/setup/phases/00-preflight.sh; read by verify.sh and the dev loop\n'
        printf 'recorded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'profile=%s\n' "$PROFILE"
        for line in "${PREFLIGHT_FACTS[@]}"; do printf '%s\n' "$line"; done
    } > "$tmp"
    if run -- install -D -m 0644 "$tmp" "$facts"; then
        rm -f -- "$tmp"
        is_dry_run || ok "host facts written to $facts"
        phase_note "host audit passed; facts recorded"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}
