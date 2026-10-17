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
#
# Bare metal (the laptop) adds, as facts and warnings — never as hard failures,
# since later phases fix most of it: power (AC vs battery, battery capacity;
# profiler/bin/bench refuses to measure on battery), the hybrid CPU topology
# (/sys/devices/cpu_core/cpus = P-cores, cpu_atom/cpus = E-cores), cpufreq
# driver/governor/EPP/turbo, power-profiles-daemon and its profile, ananicy-cpp,
# irqbalance and rtkit, the graphics adapters (Intel iGPU + NVIDIA dGPU note),
# the network path (Wi-Fi vs Ethernet, Wi-Fi power save), the display manager
# and its autologin, the lid-switch policy and the audio device that
# --audio-device resolves to. PREFLIGHT_NO_NET=1 (verify.sh --quick) skips the
# reachability probes.

phase_register 00 preflight "distro, CPU, kernel, tracing facilities, resources, power, network, session, audio" ""

: "${PREFLIGHT_RC:=}"          # cached audit result for this process ("" = not run yet)
: "${PF_HARD:=0}"
: "${PREFLIGHT_NO_NET:=0}"
declare -a PREFLIGHT_FACTS=()

_pf_fact() { PREFLIGHT_FACTS+=("$1=$2"); }
_pf_read() { cat -- "$1" 2>/dev/null | head -n1 | tr -d '\n' || true; }   # first line of a sysfs file, "" when absent

# --------------------------------------------------- bare-metal sections ----
# power supply: AC vs battery (a measurement on battery is invalid: the CPU
# clocks and EPP follow the battery policy)
_pf_power() {
    local line
    declare -F host_has_battery >/dev/null || return 0      # lib/host.sh not loaded
    step "power"
    if ! host_has_battery; then
        kv "power supply" "$(host_power_summary)"
        _pf_fact laptop 0
        return 0
    fi
    kv "power supply" "$(host_power_summary)"
    _pf_fact laptop 1
    while IFS= read -r line; do _pf_fact "${line%%=*}" "${line#*=}"; done < <(host_battery_facts)
    if host_on_ac; then
        ok "laptop on AC power"
    else
        warn "the laptop runs on BATTERY: plug in the charger — the build drains it, and profiler/bin/bench refuses to measure on battery (--allow-battery overrides)"
    fi
}

# CPU: model, hybrid P/E topology, cpufreq policy, power profile, schedulers' helpers
_pf_cpu() {
    local model core atom drv gov epp noturbo ppd prof svc st
    step "CPU topology and power policy"
    model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 || true)"
    kv "cpu" "${model:-?} ($(nproc 2>/dev/null || echo ?) threads)"
    _pf_fact cpu_model "${model:-}"
    core="$(_pf_read /sys/devices/cpu_core/cpus)"; atom="$(_pf_read /sys/devices/cpu_atom/cpus)"
    if [ -n "$core" ] && [ -n "$atom" ]; then
        kv "hybrid topology" "P-cores (cpu_core) $core · E-cores (cpu_atom) $atom"
        info "hybrid CPU: pin the measured threads to P-cores ($core); E-cores ($atom) are slower and add variance"
    elif [ -n "$core" ]; then
        kv "topology" "cpu_core $core (no E-cores)"
    fi
    _pf_fact cpu_core_cpus "$core"
    _pf_fact cpu_atom_cpus "$atom"
    drv="$(_pf_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"
    gov="$(_pf_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    epp="$(_pf_read /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    noturbo="$(_pf_read /sys/devices/system/cpu/intel_pstate/no_turbo)"
    st="$(_pf_read /sys/devices/system/cpu/intel_pstate/status)"
    kv "cpufreq" "driver ${drv:-?}${st:+ ($st)}, governor ${gov:-?}, EPP ${epp:-?}${noturbo:+, no_turbo $noturbo}"
    _pf_fact cpufreq_driver "$drv"; _pf_fact governor "$gov"; _pf_fact epp "$epp"; _pf_fact no_turbo "$noturbo"
    ppd=""; prof=""
    if systemctl is-active -q power-profiles-daemon.service 2>/dev/null; then
        ppd=active
        prof="$(timeout 5 powerprofilesctl get 2>/dev/null || true)"
        kv "power profile" "${prof:-?} (power-profiles-daemon; the launcher holds 'performance' while Live runs with --power=performance)"
    else
        ppd=inactive
        kv "power profile" "power-profiles-daemon not active"
    fi
    _pf_fact power_profiles_daemon "$ppd"; _pf_fact power_profile "$prof"
    for svc in ananicy-cpp irqbalance rtkit-daemon; do
        st="$(systemctl is-active "$svc.service" 2>/dev/null || true)"
        _pf_fact "svc_${svc//-/_}" "${st:-unknown}"
    done
    st="$(systemctl is-active ananicy-cpp.service 2>/dev/null || true)"
    if [ "$st" = active ]; then
        if profile_is baremetal; then
            info "ananicy-cpp is active: it renices processes by rule (Wine/Live included) — setup disables it through the root helper (profiler-root-helper knob set ananicy off; reset restores it)"
        else
            kv "ananicy-cpp" "active"
        fi
    else
        kv "ananicy-cpp" "${st:-not installed}"
    fi
    # is-active prints "inactive" AND exits non-zero: never append a fallback to its output
    kv "irqbalance / rtkit" "$(systemctl is-active irqbalance.service 2>/dev/null || true) / $(systemctl is-active rtkit-daemon.service 2>/dev/null || true)"
}

# graphics adapters: the Intel iGPU drives the desktop (Xwayland :0, where Live
# renders); an NVIDIA dGPU stays idle unless something is launched with prime-run
_pf_gpu() {
    local gpus nv=0 intel=0 ver rpm="" d
    command -v lspci >/dev/null 2>&1 || { kv "graphics" "lspci not installed (pciutils)"; return 0; }
    gpus="$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)"
    [ -n "$gpus" ] || return 0
    step "graphics"
    _pf_show_lines "$gpus"
    if grep -qi nvidia <<< "$gpus"; then nv=1; fi
    if grep -qi intel <<< "$gpus"; then intel=1; fi
    _pf_fact gpu_nvidia "$nv"; _pf_fact gpu_intel "$intel"
    if [ "$nv" -eq 1 ] && [ "$intel" -eq 1 ]; then
        ver="$(sed -n 's/^NVRM version: *//p' /proc/driver/nvidia/version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
        for d in /sys/bus/pci/devices/*; do
            [ "$(_pf_read "$d/vendor")" = 0x10de ] || continue
            case "$(_pf_read "$d/class")" in 0x0300*|0x0302*) rpm="$(_pf_read "$d/power/runtime_status")"; break ;; esac
        done
        info "hybrid graphics: the Intel iGPU drives the Plasma session and Xwayland (where Live draws); the NVIDIA dGPU${ver:+ (driver $ver)} stays unused unless a program starts with prime-run${rpm:+; its runtime PM state is '$rpm'}"
        _pf_fact gpu_nvidia_runtime_pm "$rpm"
    fi
}

# network path: Wi-Fi vs Ethernet and the Wi-Fi power-save state (power save on
# adds ~100 ms latency spikes to the SSH link the profiler is driven over)
_pf_netpath() {
    local dev wifi=0 ps="" n carrier
    dev="$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1 || true)"
    [ -n "$dev" ] || { kv "default route" "none"; _pf_fact net_default_dev ""; return 0; }
    if [ -d "/sys/class/net/$dev/wireless" ] || [ -e "/sys/class/net/$dev/phy80211" ]; then wifi=1; fi
    _pf_fact net_default_dev "$dev"; _pf_fact net_wifi "$wifi"
    if [ "$wifi" -eq 1 ]; then
        if command -v iw >/dev/null 2>&1; then
            ps="$(iw dev "$dev" get power_save 2>/dev/null | sed -n 's/^Power save: *//p' | head -n1 || true)"
        fi
        kv "network" "Wi-Fi ($dev), power save ${ps:-unknown}"
        _pf_fact wifi_power_save "${ps:-unknown}"
        if [ "$ps" = on ]; then
            info "Wi-Fi power save is on (~100 ms latency spikes): setup turns it off (NetworkManager drop-in + iw)"
        fi
        for n in /sys/class/net/*; do
            [ -e "$n/device" ] || continue
            if [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; then continue; fi
            carrier="$(_pf_read "$n/carrier")"
            [ "$carrier" = 1 ] || info "Ethernet ${n##*/} is present but has no link: a cable gives a steadier SSH connection than Wi-Fi"
        done
    else
        kv "network" "wired ($dev)"
    fi
}

# display manager and its autologin user (Plasma Login Manager reads
# /usr/lib/plasmalogin/plasmalogin.conf.d, /etc/plasmalogin.conf.d, then
# /etc/plasmalogin.conf — the last User= wins; SDDM the same with sddm.conf)
_pf_display_manager() {
    local unit dm="" user=""
    unit="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
    case "${unit##*/}" in
        plasmalogin.service) dm=plasmalogin ;;
        sddm.service) dm=sddm ;;
        "") dm="" ;;
        *) dm="${unit##*/}"; dm="${dm%.service}" ;;
    esac
    _pf_fact display_manager "${dm:-none}"
    case "$dm" in
        plasmalogin|sddm)
            user="$(_pf_autologin_user "$dm")"
            kv "display manager" "$dm (autologin user: ${user:-none})"
            _pf_fact autologin_user "$user"
            if [ "${AUTOLOGIN:-0}" = 1 ] && [ "$user" != "$(id -un)" ]; then
                info "autologin is not set for $(id -un) yet: phase session configures $dm (--autologin)"
            fi ;;
        "") kv "display manager" "none (display-manager.service is not linked)" ;;
        *) kv "display manager" "$dm (not plasmalogin/sddm: --autologin is not supported for it)" ;;
    esac
}
# the effective [Autologin] User= of DM (plasmalogin|sddm), "" when none
_pf_autologin_user() {
    local dm="$1" f user="" sect="" line
    local -a files=()
    shopt -s nullglob
    files=(/usr/lib/"$dm"/"$dm".conf.d/*.conf /etc/"$dm".conf.d/*.conf /etc/"$dm".conf)
    shopt -u nullglob
    for f in "${files[@]}"; do
        [ -r "$f" ] || continue
        sect=""
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in
                \[*\]) sect="$line" ;;
                User=*) if [ "$sect" = "[Autologin]" ]; then user="${line#User=}"; fi ;;
            esac
        done < "$f"
    done
    printf '%s\n' "$user"
}

# lid switch: closing the lid on AC must not suspend an unattended run
_pf_lid() {
    local lid ext dock
    command -v busctl >/dev/null 2>&1 || return 0
    lid="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p' || true)"
    ext="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitchExternalPower 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p' || true)"
    dock="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitchDocked 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p' || true)"
    kv "lid switch" "battery ${lid:-?} · AC ${ext:-(same as battery)} · docked ${dock:-?}"
    _pf_fact lid_switch "$lid"; _pf_fact lid_switch_external_power "$ext"; _pf_fact lid_switch_docked "$dock"
    [ -n "$ext" ] || ext="$lid"
    if [ "$ext" != ignore ]; then
        info "closing the lid on AC would $ext the laptop: setup sets HandleLidSwitchExternalPower=ignore (logind drop-in)"
    fi
}

# audio: PipeWire, the default sink and the node --audio-device resolves to
_pf_audio() {
    local def res
    declare -F pwa_available >/dev/null || return 0      # lib/host.sh not loaded
    step "audio"
    if ! pwa_available; then
        warn "PipeWire is not reachable for $(id -un) (pw-cli): the installer needs a running PipeWire >= 1.4.2 — log in to the desktop session"
        _pf_fact pipewire 0
        return 0
    fi
    _pf_fact pipewire 1
    kv "pipewire" "$(pw-cli --version 2>/dev/null | sed -n 's/^Linked with libpipewire //p' | head -n1 || true)"
    def="$(pwa_default_sink || true)"
    kv "default sink" "${def:-none}"
    _pf_fact audio_default_sink "${def:-}"
    _pf_fact audio_device "${AUDIO_DEVICE:-}"
    case "${AUDIO_DEVICE:-null}" in
        null)
            kv "audio device" "null → profiler-null (virtual sink created by phase audio)" ;;
        *)
            if res="$(pwa_resolve_device "$AUDIO_DEVICE")" && [ -n "$res" ]; then
                if pwa_node_id "$res" >/dev/null; then
                    kv "audio device" "$AUDIO_DEVICE → $res (state: $(pwa_mute_state "$res"))"
                    [ "$AUDIO_DEVICE" != builtin ] || case "$res" in *Speaker*) ;; *) warn "no ALSA sink has \"Speaker\" in its node.name: --audio-device builtin falls back to the default sink $res" ;; esac
                else
                    warn "audio device '$res' is not a PipeWire node right now (wpctl status / pw-cli ls Node list the names)"
                fi
                _pf_fact audio_resolved "$res"
            else
                warn "--audio-device $AUDIO_DEVICE resolves to no PipeWire sink (no ALSA sink and no default sink)"
            fi ;;
    esac
}

# print multi-line text as "│" lines (terminal + log)
_pf_show_lines() {
    local line ts
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        ts="$(now_hms)"
        printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        _log_file "[$ts]     $G_BAR $line"
    done <<< "$1"
}
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
        # ownership query, not `pacman -Ql | grep -q` (grep's early exit SIGPIPEs
        # pacman and pipefail turns the match into a failure)
        if [ -n "$pkgbase" ] && [ "$(pacman -Qqo -- "/usr/lib/modules/$kver/pkgbase" 2>/dev/null || true)" = "$pkgbase" ]; then
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
    if [ "${JOBS_SOURCE:-auto}" = auto ]; then
        kv "build jobs" "${JOBS:-?} = min(nproc $(nproc 2>/dev/null || echo ?), max(2, (MemAvailable $(( avail_kb / 1024 )) MiB - 2 GiB) / 1.2 GiB))"
    else
        kv "build jobs" "${JOBS:-?} (${JOBS_SOURCE})"
    fi
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

    # ----------------------------------------- power, CPU policy, graphics
    _pf_power
    _pf_cpu
    _pf_gpu

    # ------------------------------------------------------------- network
    step "network"
    _pf_netpath
    if [ "$PREFLIGHT_NO_NET" = 1 ]; then
        info "reachability probes skipped (PREFLIGHT_NO_NET=1)"
    else
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
            url="$(pacman-conf -r core Server 2>/dev/null | head -n1 || true)"
            if [ -n "$url" ]; then
                code="$(_pf_http "$url/core.db")"
                if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then ok "pacman mirror $url ($code)"; else warn "pacman mirror $url unreachable (http ${code:-none})"; fi
            else
                warn "pacman-conf lists no server for [core]"
            fi
        else
            warn "pacman-conf not found; mirror reachability not checked"
        fi
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
    _pf_display_manager
    if host_has_battery 2>/dev/null; then _pf_lid; fi

    # --------------------------------------------------------------- audio
    _pf_audio

    # --------------------------------------------------------------- tools
    # checked directly, not with require_cmd: these are hard requirements of the
    # driver itself, in a dry run too
    step "tools this script needs"
    local c
    local -a tmiss=()
    for c in sudo curl git tar zstd sha256sum timeout flock; do command -v -- "$c" >/dev/null 2>&1 || tmiss+=("$c"); done
    if [ "${#tmiss[@]}" -eq 0 ]; then
        ok "sudo curl git tar zstd sha256sum timeout flock"
    else
        _pf_fail "missing command(s) the setup itself needs: ${tmiss[*]} (pacman -S --needed ${tmiss[*]})"
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
