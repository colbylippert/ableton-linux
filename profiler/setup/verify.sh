#!/usr/bin/env bash
# profiler/setup/verify.sh — the post-setup gate: re-checks everything
# setup-machine.sh is responsible for, without changing the host, and exits 0
# only when every hard check passes.
#
#   profiler/setup/verify.sh [--profile vm|baremetal] [--repo-dir DIR]
#                            [--only C[,C]] [--skip C[,C]] [--quick] [--strict]
#                            [--no-sudo] [--no-log] [--list] [--no-color] [-h]
#
# What runs (in this order; --list prints the table):
#   * every phase's read-only `phase_<name>_check` from profiler/setup/phases/
#     (00 preflight … 17 dashboard; 18 summary is a report, not a state) — a
#     phase file that is not delivered yet is reported as "not-run"
#   * the extra probes of design A §2.6, interleaved by topic: kernel package vs
#     uname -r, sudo -n / the root helper, required commands, rootless podman,
#     realtime groups and limits, the display probe and the display-manager
#     autologin, PipeWire clock settings, the audio device contract
#     (--audio-device / audio_node= / mute / PipeASIO's output_device), the
#     laptop (AC power, lid-switch policy, Wi-Fi power save, ananicy-cpp), the
#     checkout (branch, aceb236 ancestry, clean tree, bench/SHA256SUMS), dist/
#     artifacts, the installed runtime's identity, `state diff --name golden`,
#     the recorded NTSync check
#
# Read-only, by construction: inside this script `run` refuses to execute
# anything (a phase check that tried would print "[verify: blocked]"),
# cfg_set and the sudo keepalive are no-ops, git runs with --no-optional-locks
# (no index refresh), and no probe starts Wine, builds or installs anything —
# the NTSync result comes from the record phase tracecheck wrote (its probe runs
# in a throwaway clone of the prefix), the dashboard is probed over HTTP. The
# only writes are this run's log ~/.local/state/profiler/verify/verify-<ts>.log
# (verify-latest.log points at it) and verify-last.env, both outside the
# repository; --no-log writes nothing at all. `sudo -n` (never a prompt) is
# used for the privilege probes; --no-sudo never invokes sudo (the phase check
# "sudo" is then skipped and the other checks run as under --dry-run).
#
# Status per row: ok · warn (passed with warnings) · failed (hard) · not-run
# (phase file missing) · skipped (deselected). Exit: 0 every hard check passed ·
# 1 at least one failed (or a warning with --strict) · 2 usage · 3 all passed
# but a re-login or reboot is required first (group changes, kernel update).
# Settings come from ~/.config/profiler/setup.conf (written by setup-machine.sh);
# nothing is written there. Run as your own user: ssh -t HOST 'bash -lc "…"'.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "verify.sh must run under bash (bash $0 … or bash -lc '…')" >&2
    exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "verify.sh needs bash >= 4.4 (found $BASH_VERSION)" >&2
    exit 2
fi
set -euo pipefail
export LC_ALL=C.UTF-8

if [ "$(id -u)" -eq 0 ]; then
    echo "!! refusing to run as root: run verify.sh as your own user (it only uses sudo -n)" >&2
    exit 2
fi

SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILER_ROOT="$(cd -- "$SETUP_ROOT/.." && pwd -P)"
TEMPLATES_DIR="$SETUP_ROOT/templates"
OWN_CHECKOUT="$(cd -- "$PROFILER_ROOT/.." && pwd -P)"
export SETUP_ROOT PROFILER_ROOT TEMPLATES_DIR
: "${USER:=$(id -un)}"
export USER

usage() {
    cat <<'EOF'
Usage: verify.sh [options]

Re-checks the machine setup (every phase check plus extra probes) without
changing anything, prints the same coloured table as setup-machine.sh and
exits 0 only when every hard check passes.

  --profile vm|baremetal  profile to verify against [saved in ~/.config/profiler/setup.conf;
                          else guessed from systemd-detect-virt]
  --repo-dir DIR          the ableton-linux checkout [saved; else ~/Projects/ableton-linux]
  --only C[,C]            run only these checks (names from --list)
  --skip C[,C]            skip these checks
  --quick                 skip the slow checks (drift; preflight's network probes)
  --strict                warnings count as failures (exit 1)
  --no-sudo               never invoke sudo (skips the sudo phase check and the
                          sudo -n privilege probes)
  --no-log                write nothing at all (no log, no verify-last.env)
  --list                  print the check table and exit
  --no-color              plain output (NO_COLOR=1 does the same)
  --dry-run               accepted for compatibility; verify never changes anything
  -h, --help              this text

Exit codes: 0 all hard checks passed · 1 a check failed · 2 usage ·
3 passed, but log out/in or reboot first (see ACTIONS REQUIRED).
Log: ~/.local/state/profiler/verify/verify-<timestamp>.log (verify-latest.log).

Examples:
  verify.sh                       full check (a minute or two)
  verify.sh --quick --no-sudo     fast, no sudo at all
  verify.sh --only laptop,audio-device,pipewire
EOF
}

usage_error() {
    printf '!! %s\n   (see --help)\n' "$1" >&2
    exit 2
}

# ---------------------------------------------------------- option parsing ----
opt_profile="" opt_repo="" ONLY="" SKIP="" QUICK=0 STRICT=0 NO_SUDO=0 NO_LOG=0 list_checks=0
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --*=*) args+=("${1%%=*}" "${1#*=}") ;;
        *) args+=("$1") ;;
    esac
    shift
done
set -- ${args[@]+"${args[@]}"}

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   need_value "$@"; opt_profile="$2"; shift ;;
        --repo-dir)  need_value "$@"; opt_repo="$2"; shift ;;
        --only)      need_value "$@"; ONLY="$2"; shift ;;
        --skip)      need_value "$@"; SKIP="$2"; shift ;;
        --quick)     QUICK=1 ;;
        --strict)    STRICT=1 ;;
        --no-sudo)   NO_SUDO=1 ;;
        --no-log)    NO_LOG=1 ;;
        --dry-run)   ;;
        --list)      list_checks=1 ;;
        --no-color)  export NO_COLOR=1 ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; [ $# -eq 0 ] || usage_error "unexpected argument: $1" ;;
        -*)          usage_error "unknown option: $1" ;;
        *)           usage_error "unexpected argument: $1" ;;
    esac
    shift
done
case "$opt_profile" in ""|vm|baremetal) ;; *) usage_error "--profile must be vm or baremetal (got '$opt_profile')" ;; esac

# ------------------------------------------------------------- libraries ----
for lib in log.sh phase.sh host.sh; do
    [ -r "$SETUP_ROOT/lib/$lib" ] || { printf '!! missing library %s\n' "$SETUP_ROOT/lib/$lib" >&2; exit 2; }
    # shellcheck source=/dev/null
    . "$SETUP_ROOT/lib/$lib"
done
log_colors_init

# ------------------------------------------------- read-only guard rails ----
# The phase checks are read-only by contract; these overrides make verify.sh
# unable to change the host even if one is not: `run` executes nothing,
# cfg_set writes nothing, the sudo keepalive never prompts, state dirs are
# never created. --no-sudo additionally runs the checks under DRY_RUN=1 (the
# phases' own "no sudo" mode) with PROFILER_NO_SUDO=1 for the tools they call.
run() {
    local a shown=()
    while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; --timeout) shift 2 ;; *) shift ;; esac; done
    for a in "$@"; do shown+=("$a"); done
    _emit "$C_CYAN" "[verify: blocked]" "  " "$C_DIM\$ $(_fmt_cmd "${shown[@]}")$C_RESET"
    RUN_STATUS=0
    return 0
}
cfg_set() { return 0; }
sudo_keepalive_start() { return 0; }
_mkdir_unless_dry() { :; }
ASSUME_YES=1 FORCE=0
if [ "$NO_SUDO" = 1 ]; then DRY_RUN=1 PROFILER_NO_SUDO=1; else DRY_RUN=0 PROFILER_NO_SUDO=0; fi
[ "$QUICK" != 1 ] || PREFLIGHT_NO_NET=1
export ASSUME_YES FORCE DRY_RUN PROFILER_NO_SUDO PREFLIGHT_NO_NET
git_ro() { git --no-optional-locks "$@"; }

# --------------------------------------------------------------- phases ----
PHASES_DIR="$SETUP_ROOT/phases"
[ -d "$PHASES_DIR" ] || die "no phases directory at $PHASES_DIR — the checkout is incomplete" 2
shopt -s nullglob
phase_files=("$PHASES_DIR"/[0-9][0-9]-*.sh)
shopt -u nullglob
for f in ${phase_files[@]+"${phase_files[@]}"}; do
    # shellcheck source=/dev/null
    . "$f" || die "failed to source phase file $f" 2
done

# the phases setup-machine.sh is specified to have (design A §2.1); a phase that
# is registered but not listed here still gets its check run, after these
EXPECTED_PHASES="00:preflight 01:sudo 02:packages 03:podman 04:limits 05:session 06:audio 07:repo 08:media 09:build 10:install 11:plugins 12:osc 13:human 14:golden 15:tracecheck 16:claude 17:dashboard"
declare -A EXPECTED_NUM=()
for entry in $EXPECTED_PHASES; do EXPECTED_NUM[${entry#*:}]="${entry%%:*}"; done

# check order: phase checks interleaved with the verify-owned probes by topic
CHECK_ORDER=(
    phase:preflight probe:kernel probe:laptop
    phase:sudo probe:privilege
    phase:packages probe:tools
    phase:podman probe:containers
    phase:limits probe:realtime
    phase:session probe:display
    phase:audio probe:pipewire probe:audio-device
    phase:repo probe:checkout
    phase:media
    phase:build probe:dist
    phase:install probe:runtime
    phase:plugins phase:osc phase:human
    phase:golden probe:drift
    phase:tracecheck probe:ntsync
    phase:claude
    phase:dashboard
)
declare -A PROBE_DESC=(
    [kernel]="running kernel = installed kernel package, matching headers, BTF, /dev/ntsync"
    [laptop]="laptop only: AC power, lid-switch policy on AC, Wi-Fi power save off, ananicy-cpp, cpufreq policy"
    [privilege]="sudo -n per profile policy, root helper through sudoers 91-profiler-helper, baseline"
    [tools]="commands the phases, the tracer and the agent loop need"
    [containers]="rootless podman: subuids, overlay driver, netavark, linger, build image"
    [realtime]="realtime/audio membership, chrt -r, rtprio/memlock, limits and sysctl drop-ins"
    [display]="DISPLAY from the user session, xdotool probe, display-manager autologin, inhibit unit"
    [pipewire]="PipeWire socket, clock settings (min-quantum 32), conf.d drop-ins, null sink when used"
    [audio-device]="--audio-device contract: audio_node= recorded, node present, muted (real sinks), PipeASIO output/input_device"
    [checkout]="branch, aceb236 ancestry, clean tree, bench/SHA256SUMS, trace-point patches"
    [dist]="dist/ artifacts for VERSION, tarball checksum, recorded build audit"
    [runtime]="installed runtime identity vs dist VERSION, modules, launcher, prefix"
    [drift]="profiler/bin/state diff --name golden (read-only)"
    [ntsync]="NTSync: the record phase tracecheck wrote for the installed runtime, wineserver built with ntsync"
)
SLOW_CHECKS="drift"

declare -a CHECK_NAMES=() CHECK_KINDS=()
declare -A CHECK_KIND_OF=()
add_check() {
    [ -z "${CHECK_KIND_OF[$1]+x}" ] || return 0
    CHECK_NAMES+=("$1"); CHECK_KINDS+=("$2"); CHECK_KIND_OF[$1]="$2"
}
for entry in "${CHECK_ORDER[@]}"; do add_check "${entry#*:}" "${entry%%:*}"; done
for (( i = 0; i < ${#PHASE_NAMES[@]}; i++ )); do
    n="${PHASE_NAMES[i]}"
    [ "$n" != summary ] || continue
    add_check "$n" phase
done

check_desc() {
    local name="$1"
    if [ "${CHECK_KIND_OF[$name]}" = probe ]; then
        printf '%s\n' "${PROBE_DESC[$name]:-}"
    elif [ -n "${PHASE_INDEX[$name]+x}" ]; then
        printf 'phase check: %s\n' "${PHASE_DESCS[${PHASE_INDEX[$name]}]}"
    else
        printf 'phase check: (phase file %s-%s.sh not delivered yet)\n' "${EXPECTED_NUM[$name]:-NN}" "$name"
    fi
}

if [ "$list_checks" -eq 1 ]; then
    printf '%-16s %-6s %s\n' "check" "kind" "what it verifies"
    for (( i = 0; i < ${#CHECK_NAMES[@]}; i++ )); do
        n="${CHECK_NAMES[i]}"
        printf '%-16s %-6s %s%s\n' "$n" "${CHECK_KINDS[i]}" "$(check_desc "$n")" "$(case " $SLOW_CHECKS " in *" $n "*) printf '  [slow; --quick skips]' ;; esac)"
    done
    exit 0
fi

# ------------------------------------------------------------ selection ----
_in_csv() { local x="$1" y; IFS=',' read -r -a _lst <<< "$2"; for y in ${_lst[@]+"${_lst[@]}"}; do [ "$x" = "$y" ] && return 0; done; return 1; }
for n in ${ONLY//,/ } ${SKIP//,/ }; do
    [ -n "${CHECK_KIND_OF[$n]+x}" ] || usage_error "unknown check '$n' (see --list)"
done
declare -a SELECTED=()
for n in "${CHECK_NAMES[@]}"; do
    if [ -n "$ONLY" ]; then _in_csv "$n" "$ONLY" || continue; fi
    if [ -n "$SKIP" ] && _in_csv "$n" "$SKIP"; then continue; fi
    if [ "$QUICK" -eq 1 ] && [ -z "$ONLY" ]; then case " $SLOW_CHECKS " in *" $n "*) continue ;; esac; fi
    SELECTED+=("$n")
done
[ "${#SELECTED[@]}" -gt 0 ] || usage_error "the selection leaves no check to run"

# ------------------------------------------------- resolve the settings ----
# the same resolution as setup-machine.sh, read-only: option > setup.conf > default
PROFILE_SOURCE=saved
PROFILE="${opt_profile:-$(cfg_get profile)}"
[ -z "$opt_profile" ] || PROFILE_SOURCE=option
if [ -z "$PROFILE" ]; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    if [ "$virt" = none ]; then PROFILE=baremetal; else PROFILE=vm; fi
    PROFILE_SOURCE="guessed from systemd-detect-virt=${virt:-unknown}"
fi
case "$PROFILE" in vm|baremetal) ;; *) usage_error "saved profile '$PROFILE' in $PROFILER_SETUP_CONF is invalid; pass --profile" ;; esac
if [ "$PROFILE" = vm ]; then
    def_pwsudo=1 def_autologin=1 def_buffer=128 def_audio=null
else
    def_pwsudo=0 def_autologin=0 def_buffer=64 def_audio=builtin
fi
default_repo="$HOME/Projects/ableton-linux"
if [ ! -d "$default_repo/.git" ] && [ -d "$OWN_CHECKOUT/.git" ]; then default_repo="$OWN_CHECKOUT"; fi
MEDIA_DIR="$(cfg_get media_dir "$HOME/Proprietary/ableton")"
LIVE_INSTALLER="$(cfg_get live_installer "$MEDIA_DIR/Ableton Live 12 Trial Installer.exe")"
REPO_DIR="${opt_repo:-$(cfg_get repo_dir "$default_repo")}"
AUDIO_BUFFER="$(cfg_get audio_buffer "$def_buffer")"
AUDIO_DEVICE="$(cfg_get audio_device "$def_audio")"
PASSWORDLESS_SUDO="$(cfg_get passwordless_sudo "$def_pwsudo")"
AUTOLOGIN="$(cfg_get autologin "$def_autologin")"
VM_RAM_CHECK="$(cfg_get vm_ram_check 0)"
if host_has_battery; then LAPTOP=1; else LAPTOP=0; fi
JOBS="$(cfg_get jobs)"; JOBS_SOURCE=config
if [ -z "$JOBS" ] || ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    JOBS_SOURCE=auto
    JOBS="$(nproc 2>/dev/null || echo 4)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        mem_jobs=$(( (avail_kb - 2 * 1048576) * 10 / (12 * 1048576) ))
        [ "$mem_jobs" -ge 2 ] || mem_jobs=2
        [ "$mem_jobs" -ge "$JOBS" ] || JOBS="$mem_jobs"
    fi
fi
export PROFILE MEDIA_DIR LIVE_INSTALLER REPO_DIR AUDIO_BUFFER AUDIO_DEVICE PASSWORDLESS_SUDO AUTOLOGIN VM_RAM_CHECK
export JOBS JOBS_SOURCE LAPTOP

# ----------------------------------------------------------- utilities ----
verify_log_init() {
    local dir ts
    if [ "$NO_LOG" = 1 ]; then log_init --no-file; return 0; fi
    exec 3>&1
    LOG_FD=3
    log_colors_init
    dir="$PROFILER_STATE_DIR/verify"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    LOGFILE="$dir/verify-$ts.log"
    if mkdir -p -- "$dir" 2>/dev/null && : >> "$LOGFILE" 2>/dev/null; then
        ln -sfn -- "verify/verify-$ts.log" "$PROFILER_STATE_DIR/verify-latest.log" 2>/dev/null || true
        printf '# profiler verify log — %s — %s (pid %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${0##*/}" "$$" >> "$LOGFILE"
    else
        LOGFILE=""
        warn "cannot write a log file under $dir; continuing without one"
    fi
    export LOGFILE LOG_FD
}

# stream TEXT indented into the terminal (first MAX lines) and the log (all)
show_block() {
    local text="${1:-}" max="${2:-200}" n=0 line ts
    [ -n "$text" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$(( n + 1 ))
        ts="$(now_hms)"
        if [ "$n" -le "$max" ]; then
            printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        fi
        _log_file "[$ts]     $G_BAR $line"
    done <<< "$text"
    [ "$n" -le "$max" ] || info "… $(( n - max )) more line(s) in the log"
}

# path resolution identical to scripts/lib/config.sh and profiler/bin/state
v_abl_cfg() {
    local file="${ABLETON_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}/config" line
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
    done < "$file"
    return 0
}
v_runtime_root() { local v="${ABLETON_WINE_ROOT:-}"; [ -n "$v" ] || v="$(v_abl_cfg runtime_root)"; [ -n "$v" ] || v="$HOME/.local/opt/wine-d2d1-nspa-11.13"; printf '%s\n' "$v"; }
v_prefix() { local v="${ABLETON_WINEPREFIX:-}"; [ -n "$v" ] || v="$(v_abl_cfg prefix)"; [ -n "$v" ] || v="$HOME/.wine-ableton"; printf '%s\n' "$v"; }
v_launcher() { printf '%s/ableton-live\n' "${ABLETON_BIN_HOME:-$HOME/.local/bin}"; }
# 0 when a Wine process uses the prefix (09-build.sh's lifecycle.sh mirror)
v_prefix_busy() {
    if declare -F _lp_prefix_busy >/dev/null; then _lp_prefix_busy "$1"; return; fi
    return 1
}
v_repo_version() { tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || true; }
first_line() { head -n1 2>/dev/null | tr -d '\r' || true; }
pw_setting() { sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" <<< "$2" | head -n1 || true; }
logind_prop() { busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p' || true; }
# the effective [SECTION] KEY= of a display manager's config (last file wins:
# /usr/lib/DM/DM.conf.d/*.conf, /etc/DM.conf.d/*.conf, /etc/DM.conf)
dm_value() {
    local dm="$1" section="$2" key="$3" f val="" sect="" line
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
                "$key="*) if [ "$sect" = "[$section]" ]; then val="${line#"$key="}"; fi ;;
            esac
        done < "$f"
    done
    printf '%s\n' "$val"
}

# ------------------------------------------------------------- probes ----
# Each probe prints through ok/warn/fail/info/kv and returns 1 on a hard
# failure (after `fail`), 0 otherwise. They run in a condition context, so
# `set -e` does not apply inside; every hard failure is explicit.

probe_kernel() {
    local kver pkgbase pkgver hver rc=0
    kver="$(uname -r)"
    kv "kernel" "$kver"
    if [ -r "/usr/lib/modules/$kver/pkgbase" ]; then
        pkgbase="$(cat "/usr/lib/modules/$kver/pkgbase")"
        pkgver="$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}' || true)"
        if pacman -Ql "$pkgbase" 2>/dev/null | grep -qxF "$pkgbase /usr/lib/modules/$kver/"; then
            ok "running kernel is the installed $pkgbase ${pkgver:-?}"
        else
            fail "installed $pkgbase ${pkgver:-?} does not own /usr/lib/modules/$kver/: reboot into the installed kernel (headers and bcc must match the running kernel)" || true
            need_reboot; rc=1
        fi
        hver="$(pacman -Q "$pkgbase-headers" 2>/dev/null | awk '{print $2}' || true)"
        if [ -z "$hver" ]; then
            fail "$pkgbase-headers is not installed (phase packages): bcc/bpftrace cannot compile kernel-side probes" || true; rc=1
        elif [ "$hver" != "$pkgver" ]; then
            fail "$pkgbase-headers $hver does not match $pkgbase ${pkgver:-?} (pacman -Syu, then reboot)" || true; rc=1
        else
            ok "$pkgbase-headers $hver matches the kernel package"
        fi
    else
        fail "/usr/lib/modules/$kver/pkgbase is missing: the running kernel's package is gone (upgraded without a reboot?)" || true
        need_reboot; rc=1
    fi
    if [ -r /sys/kernel/btf/vmlinux ]; then ok "kernel BTF at /sys/kernel/btf/vmlinux"; else fail "no /sys/kernel/btf/vmlinux (CONFIG_DEBUG_INFO_BTF): the CO-RE tracer cannot load" || true; rc=1; fi
    if [ -c /dev/ntsync ]; then ok "/dev/ntsync present (mode $(stat -c %a /dev/ntsync 2>/dev/null || echo ?))"; else fail "/dev/ntsync is missing (kernel 6.14+ with CONFIG_NTSYNC; sudo modprobe ntsync)" || true; rc=1; fi
    return "$rc"
}

probe_laptop() {
    local rc=0 lid ext dock eff conf ifc ps n=0 st gov epp prof nmv
    if [ "$LAPTOP" != 1 ]; then ok "no battery in /sys/class/power_supply: not a laptop, nothing to check"; return 0; fi
    kv "power" "$(host_power_summary)"
    if host_on_ac; then ok "on AC power"; else warn "on battery: plug in the charger (profiler/bin/bench refuses to measure on battery)"; fi
    # lid: the effective logind policy (an empty HandleLidSwitchExternalPower inherits HandleLidSwitch)
    if command -v busctl >/dev/null 2>&1; then
        lid="$(logind_prop HandleLidSwitch)"; ext="$(logind_prop HandleLidSwitchExternalPower)"; dock="$(logind_prop HandleLidSwitchDocked)"
        eff="${ext:-$lid}"
        kv "lid switch" "battery ${lid:-?} · AC ${ext:-(inherits: $lid)} · docked ${dock:-?}"
        conf="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | sed -n 's/^[[:space:]]*HandleLidSwitchExternalPower[[:space:]]*=[[:space:]]*//p' | tail -n1 || true)"
        if [ "$eff" = ignore ]; then
            ok "closing the lid on AC is ignored (HandleLidSwitchExternalPower)"
        elif [ "$conf" = ignore ]; then
            warn "a logind drop-in sets HandleLidSwitchExternalPower=ignore, but the running logind still says '${eff:-?}': it applies after a reboot (or systemctl kill -s HUP systemd-logind)"
        elif [ "$PROFILE" = baremetal ]; then
            fail "closing the lid on AC would '$eff' the laptop and kill an unattended run (phase session: logind drop-in HandleLidSwitchExternalPower=ignore)" || true; rc=1
        else
            warn "closing the lid on AC would '$eff' the laptop"
        fi
        if [ "$dock" = ignore ]; then ok "closing the lid while docked is ignored"; else warn "HandleLidSwitchDocked is '${dock:-?}', expected ignore"; fi
    else
        warn "busctl not found: the lid-switch policy was not checked"
    fi
    # Wi-Fi power save, per wireless interface that is up
    for ifc in /sys/class/net/*; do
        [ -d "$ifc/wireless" ] || [ -e "$ifc/phy80211" ] || continue
        [ "$(cat "$ifc/operstate" 2>/dev/null || true)" = up ] || continue
        n=$(( n + 1 ))
        if command -v iw >/dev/null 2>&1; then
            ps="$(iw dev "${ifc##*/}" get power_save 2>/dev/null | sed -n 's/^Power save: *//p' | head -n1 || true)"
            case "$ps" in
                off) ok "Wi-Fi ${ifc##*/}: power save off" ;;
                on) warn "Wi-Fi ${ifc##*/}: power save is ON (~100 ms latency spikes; phase session: NetworkManager drop-in + iw)" ;;
                *) warn "Wi-Fi ${ifc##*/}: power-save state unknown" ;;
            esac
        else
            warn "iw not found: the Wi-Fi power-save state was not checked"
        fi
    done
    if [ "$n" -gt 0 ]; then
        nmv="$(grep -rhsE '^[[:space:]]*wifi\.powersave[[:space:]]*=' /etc/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d 2>/dev/null | tail -n1 | sed 's/.*=[[:space:]]*//' || true)"
        if [ "$nmv" = 2 ]; then ok "NetworkManager keeps Wi-Fi power save off (wifi.powersave = 2)"; else warn "no NetworkManager drop-in with wifi.powersave = 2 (power save comes back on reconnect)"; fi
    fi
    # schedulers and cpufreq policy (facts; ananicy-cpp renices Wine/Live by rule)
    st="$(systemctl is-active ananicy-cpp.service 2>/dev/null || true)"
    if [ "$st" = active ] && [ "$PROFILE" = baremetal ]; then
        warn "ananicy-cpp is active: it renices processes by rule (setup: profiler-root-helper knob set ananicy off)"
    else
        kv "ananicy-cpp" "${st:-not installed}"
    fi
    gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    epp="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo '?')"
    prof="$(timeout 5 powerprofilesctl get 2>/dev/null || echo '?')"
    kv "cpufreq" "governor $gov, EPP $epp, power profile $prof (the launcher holds 'performance' while Live runs)"
    kv "topology" "P-cores $(cat /sys/devices/cpu_core/cpus 2>/dev/null || echo '?') · E-cores $(cat /sys/devices/cpu_atom/cpus 2>/dev/null || echo '-')"
    return "$rc"
}

probe_privilege() {
    local helper=/usr/local/sbin/profiler-root-helper rc=0 out owner mode
    if [ "$NO_SUDO" = 1 ]; then
        info "--no-sudo: the sudo -n probes are skipped"
    elif sudo -n true 2>/dev/null; then
        ok "sudo -n true works (NOPASSWD)"
    elif [ "$PASSWORDLESS_SUDO" = 1 ]; then
        fail "sudo -n true needs a password although passwordless sudo is the policy here (phase sudo: /etc/sudoers.d/90-profiler-$USER)" || true; rc=1
    else
        info "sudo -n true needs a password: expected, passwordless sudo is off for the $PROFILE profile"
    fi
    if [ -e "$helper" ]; then
        owner="$(stat -c %U -- "$helper" 2>/dev/null || echo ?)"; mode="$(stat -c %a -- "$helper" 2>/dev/null || echo ?)"
        kv "helper" "$helper ($owner, mode $mode)"
        if [ "$owner" = root ] && [ "$mode" = 755 ]; then ok "helper owned by root, mode 0755"; else warn "helper should be root-owned mode 0755 (is $owner $mode); it refuses to run otherwise"; fi
        if [ "$NO_SUDO" = 1 ]; then
            if out="$("$helper" version 2>&1)"; then show_block "$out" 8; fi
        elif out="$(sudo -n "$helper" version 2>&1)"; then
            ok "sudo -n profiler-root-helper version → $(first_line <<< "$out")"
            show_block "$(tail -n +2 <<< "$out")" 8
            if grep -q '^baseline=present' <<< "$out"; then ok "host-knob baseline recorded (/var/lib/profiler/baseline.env)"; else warn "no host-knob baseline yet: sudo -n profiler-root-helper snapshot (phase sudo takes it)"; fi
        else
            fail "sudo -n $helper version fails: the sudoers rule /etc/sudoers.d/91-profiler-helper is missing or invalid (phase sudo)" || true; rc=1
            show_block "$out" 5
        fi
        if cmp -s -- "$helper" "$SETUP_ROOT/root-helper/profiler-root-helper"; then
            ok "installed helper is identical to the checkout's copy"
        else
            warn "installed helper differs from $SETUP_ROOT/root-helper/profiler-root-helper (re-run: setup-machine.sh --only sudo --force)"
        fi
    else
        fail "$helper is not installed (phase sudo)" || true; rc=1
    fi
    return "$rc"
}

probe_tools() {
    local rc=0 c missing=() optional_missing=()
    local -a required=(podman git bpftrace bpftool clang readelf strings python3 rsync zstd cabextract unzip jq curl node npm pw-cli pw-metadata wpctl chrt flock timeout tar sha256sum)
    local -a optional=(perf pahole xdotool Xvfb shellcheck tmux socat lsof ccache inotifywait kde-inhibit kwriteconfig6 fish iw busctl)
    for c in "${required[@]}"; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
    for c in "${optional[@]}"; do command -v -- "$c" >/dev/null 2>&1 || optional_missing+=("$c"); done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "required commands present: ${required[*]}"
    else
        fail "missing required command(s): ${missing[*]} (phase packages)" || true; rc=1
    fi
    if [ "${#optional_missing[@]}" -eq 0 ]; then ok "optional commands present: ${optional[*]}"; else warn "optional command(s) missing: ${optional_missing[*]}"; fi
    if command -v podman >/dev/null 2>&1; then kv "podman" "$(podman --version 2>/dev/null | first_line)"; fi
    if command -v bpftrace >/dev/null 2>&1; then kv "bpftrace" "$(bpftrace --version 2>/dev/null | first_line)"; fi
    if command -v clang >/dev/null 2>&1; then kv "clang" "$(clang --version 2>/dev/null | first_line)"; fi
    if command -v node >/dev/null 2>&1; then kv "node / npm" "$(node --version 2>/dev/null | first_line) / $(npm --version 2>/dev/null | first_line)"; fi
    if command -v perf >/dev/null 2>&1; then kv "perf" "$(perf version 2>/dev/null | first_line)"; fi
    return "$rc"
}

probe_containers() {
    local rc=0 info_out rootless driver net linger
    command -v podman >/dev/null 2>&1 || { fail "podman is not installed (phase packages)" || true; return 1; }
    if getsubids "$USER" >/dev/null 2>&1 || grep -q "^$USER:" /etc/subuid 2>/dev/null; then
        ok "subuid/subgid ranges exist for $USER"
    else
        fail "no subuid/subgid range for $USER (phase podman: usermod --add-subuids … --add-subgids …)" || true; rc=1
    fi
    info_out="$(podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}} {{.Host.NetworkBackend}}' 2>/dev/null || true)"
    read -r rootless driver net <<< "${info_out:-? ? ?}"
    kv "podman info" "rootless=$rootless driver=$driver network=$net"
    if [ "$rootless" = true ]; then ok "rootless"; else fail "podman info does not report a rootless setup (got '${rootless:-?}')" || true; rc=1; fi
    if [ "$driver" = overlay ]; then ok "graph driver overlay"; else fail "graph driver is '${driver:-?}', expected overlay (vfs is unusably slow for the Wine build; phase podman: podman system migrate, fuse-overlayfs)" || true; rc=1; fi
    if [ "$net" = netavark ]; then ok "network backend netavark"; else warn "network backend is '${net:-?}', expected netavark"; fi
    linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
    if [ "$linger" = yes ]; then ok "linger enabled (user units survive logouts)"; else warn "loginctl linger is off for $USER: the dashboard unit stops at logout (phase podman: loginctl enable-linger)"; fi
    if podman image exists ableton-wine-build:22.04 2>/dev/null; then kv "image" "ableton-wine-build:22.04 present"; else info "image ableton-wine-build:22.04 not built yet (the first ./build.sh or wine-dev.sh init builds it)"; fi
    if podman container exists wine-dev 2>/dev/null; then kv "wine-dev" "container exists ($(podman container inspect --format '{{.State.Status}}' wine-dev 2>/dev/null || echo ?))"; fi
    return "$rc"
}

probe_realtime() {
    local rc=0 g members rl ml sw pep kptr f
    for g in realtime audio; do
        members="$(getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n' || true)"
        if grep -qx -- "$USER" <<< "$members"; then
            if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx -- "$g"; then
                ok "member of $g (effective in this session)"
            else
                warn "$USER is in group $g, but this session does not carry it yet: log out and back in"
                need_relogin
            fi
        else
            fail "$USER is not a member of group $g (phase limits: usermod -aG realtime,audio)" || true; rc=1
        fi
    done
    if chrt -r 10 true 2>/dev/null; then ok "chrt -r 10 true works (the launcher's RT probe)"; else warn "chrt -r 10 true fails: Live would run without SCHED_RR (limits take effect after a re-login)"; fi
    rl="$(ulimit -r 2>/dev/null || echo ?)"; ml="$(ulimit -l 2>/dev/null || echo ?)"
    kv "ulimit -r / -l" "$rl / $ml"
    [ "$ml" = unlimited ] || warn "memlock limit is $ml KiB, expected unlimited (90-ableton-rt.conf; re-login)"
    { [[ "$rl" =~ ^[0-9]+$ ]] && [ "$rl" -ge 95 ]; } || [ "$rl" = unlimited ] || warn "rtprio limit is $rl, expected >= 95"
    for f in /etc/security/limits.d/90-ableton-rt.conf /etc/security/limits.d/90-profiler.conf /etc/sysctl.d/90-ableton-rt.conf; do
        if [ -f "$f" ]; then ok "$f present"; else fail "$f is missing (phase limits)" || true; rc=1; fi
    done
    if [ "$PROFILE" = vm ]; then
        if [ -f /etc/sysctl.d/90-profiler.conf ]; then ok "/etc/sysctl.d/90-profiler.conf present"; else fail "/etc/sysctl.d/90-profiler.conf is missing (phase limits, vm profile)" || true; rc=1; fi
    fi
    sw="$(sysctl -n vm.swappiness 2>/dev/null || echo ?)"
    pep="$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo ?)"
    kptr="$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo ?)"
    kv "sysctl" "vm.swappiness=$sw kernel.perf_event_paranoid=$pep kernel.kptr_restrict=$kptr"
    [ "$sw" = 10 ] || warn "vm.swappiness is $sw, expected 10 (90-ableton-rt.conf; sysctl --system)"
    if [ "$PROFILE" = vm ]; then
        [ "$pep" = "-1" ] || warn "kernel.perf_event_paranoid is $pep, the vm profile sets -1 (90-profiler.conf; sysctl --system)"
        [ "$kptr" = 0 ] || warn "kernel.kptr_restrict is $kptr, the vm profile sets 0 (90-profiler.conf; sysctl --system)"
    fi
    return "$rc"
}

probe_display() {
    local rc=0 env_out disp wl stype geom v unit dm user session
    local wse="$PROFILER_ROOT/bin/with-session-env"
    [ -x "$wse" ] || { fail "missing $wse" || true; return 1; }
    if env_out="$("$wse" --print 2>/dev/null)"; then
        disp="$(sed -n 's/^DISPLAY=//p' <<< "$env_out" | head -n1 || true)"
        wl="$(sed -n 's/^WAYLAND_DISPLAY=//p' <<< "$env_out" | head -n1 || true)"
        stype="$(sed -n 's/^XDG_SESSION_TYPE=//p' <<< "$env_out" | head -n1 || true)"
        kv "session" "DISPLAY=$disp WAYLAND_DISPLAY=${wl:-?} XDG_SESSION_TYPE=${stype:-?}"
        ok "desktop session environment available (with-session-env)"
        if command -v xdotool >/dev/null 2>&1; then
            if geom="$("$wse" timeout 10 xdotool getdisplaygeometry 2>/dev/null)"; then
                ok "display probe: ${geom//$'\n'/ } (xdotool getdisplaygeometry on DISPLAY=$disp)"
            else
                fail "xdotool getdisplaygeometry fails on DISPLAY=$disp (Xwayland not reachable from this session?)" || true; rc=1
            fi
        else
            warn "xdotool is missing: the display geometry was not probed (phase packages)"
        fi
    else
        fail "no DISPLAY in the user session (systemctl --user show-environment): log in on the console (phase session sets up autologin); install, human and bench need it" || true
        rc=1
    fi
    if [ -x "$HOME/.local/bin/with-session-env" ]; then ok "~/.local/bin/with-session-env installed"; else warn "~/.local/bin/with-session-env is not installed (phase session)"; fi
    # display manager and its effective autologin (the main file overrides the drop-ins)
    unit="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
    case "${unit##*/}" in plasmalogin.service) dm=plasmalogin ;; sddm.service) dm=sddm ;; *) dm="" ;; esac
    if [ "$AUTOLOGIN" = 1 ]; then
        if [ -z "$dm" ]; then
            fail "autologin is requested, but the display manager is '${unit##*/}' (not Plasma Login Manager or SDDM)" || true; rc=1
        else
            user="$(dm_value "$dm" Autologin User)"; session="$(dm_value "$dm" Autologin Session)"
            kv "autologin" "$dm: User=${user:-} Session=${session:-} Relogin=$(dm_value "$dm" Autologin Relogin)"
            if [ "$user" = "$USER" ]; then ok "$dm logs $USER in automatically"; else fail "$dm autologin user is '${user:-none}', not $USER (phase session --autologin: [Autologin] User=$USER in /etc/$dm.conf or a drop-in)" || true; rc=1; fi
            if [ -n "$session" ] && { [ -f "/usr/share/wayland-sessions/$session.desktop" ] || [ -f "/usr/share/xsessions/$session.desktop" ]; }; then
                ok "autologin session $session exists"
            else
                fail "autologin Session='${session:-}' names no /usr/share/wayland-sessions/*.desktop (expected plasma)" || true; rc=1
            fi
        fi
    elif [ -n "$dm" ]; then
        kv "autologin" "off by policy ($dm: User=$(dm_value "$dm" Autologin User))"
    fi
    if systemctl --user is-active -q profiler-inhibit.service 2>/dev/null; then ok "profiler-inhibit.service active (no sleep/lock/notifications)"; else warn "profiler-inhibit.service is not active (phase session)"; fi
    if command -v kreadconfig6 >/dev/null 2>&1; then
        v="$(kreadconfig6 --file kscreenlockerrc --group Daemon --key Autolock --default true 2>/dev/null || echo ?)"
        if [ "$v" = false ]; then ok "KDE screen autolock disabled"; else warn "KDE screen autolock is '$v' (phase session: kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false)"; fi
    fi
    return "$rc"
}

probe_pipewire() {
    local rc=0 sock md nodes minq maxq q rate forceq allowed confd prefix
    sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0"
    if [ -S "$sock" ]; then ok "PipeWire socket $sock"; else fail "PipeWire is not running (no $sock)" || true; return 1; fi
    if ! command -v pw-cli >/dev/null 2>&1 || ! command -v pw-metadata >/dev/null 2>&1; then
        fail "pw-cli / pw-metadata missing (pipewire package)" || true; return 1
    fi
    kv "libpipewire" "$(pw-cli --version 2>/dev/null | sed -n 's/^Linked with libpipewire //p' | head -n1 || true)"
    nodes="$(pw-cli ls Node 2>/dev/null || true)"
    if grep -q 'node.name = "profiler-null"' <<< "$nodes"; then
        ok "profiler-null sink present"
    elif [ "$AUDIO_DEVICE" = null ]; then
        fail "profiler-null sink is missing (phase audio: 90-profiler-null-sink.conf + PipeWire restart); PipeASIO is configured to use it" || true; rc=1
    else
        info "no profiler-null sink (not used: --audio-device $AUDIO_DEVICE)"
    fi
    md="$(pw-metadata -n settings 2>/dev/null || true)"
    rate="$(pw_setting clock.rate "$md")"; allowed="$(pw_setting clock.allowed-rates "$md")"
    q="$(pw_setting clock.quantum "$md")"; minq="$(pw_setting clock.min-quantum "$md")"; maxq="$(pw_setting clock.max-quantum "$md")"
    forceq="$(pw_setting clock.force-quantum "$md")"
    kv "clock" "rate ${rate:-?} allowed ${allowed:-?} quantum ${q:-?} min ${minq:-?} max ${maxq:-?} force ${forceq:-?}"
    if [[ "$minq" =~ ^[0-9]+$ ]] && [ "$minq" -le 32 ]; then
        ok "clock.min-quantum $minq (PipeASIO may request down to 32)"
    elif [[ "$minq" =~ ^[0-9]+$ ]] && [ "$minq" -le "$AUDIO_BUFFER" ]; then
        warn "clock.min-quantum is $minq (phase audio sets 32): buffers below $minq are silently pinned to $minq"
    else
        fail "clock.min-quantum is ${minq:-unset}: PipeASIO's $AUDIO_BUFFER-frame buffer would be pinned to it (phase audio: 91-profiler-clock.conf)" || true; rc=1
    fi
    [ "$rate" = 48000 ] || warn "clock.rate is ${rate:-?}, expected 48000"
    case "$allowed" in *48000*) ;; *) warn "clock.allowed-rates '${allowed:-?}' does not list 48000" ;; esac
    if [ "${forceq:-0}" != 0 ]; then
        prefix="$(v_prefix)"
        if v_prefix_busy "$prefix"; then info "clock.force-quantum=$forceq while Live runs (PipeASIO holds the graph quantum)"; else warn "clock.force-quantum=$forceq is left over (Live not running): pw-metadata -n settings 0 clock.force-quantum 0 — state restore does this"; fi
    else
        ok "clock.force-quantum 0"
    fi
    confd="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
    if ls -- "$confd"/*profiler*clock*.conf >/dev/null 2>&1; then ok "clock drop-in present ($(basename -- "$(ls -- "$confd"/*profiler*clock*.conf | head -n1)"))"; else warn "no profiler clock drop-in in $confd (phase audio)"; fi
    if [ "$AUDIO_DEVICE" = null ]; then
        if ls -- "$confd"/*profiler*null*.conf >/dev/null 2>&1; then ok "null-sink drop-in present"; else warn "no profiler null-sink drop-in in $confd (phase audio)"; fi
    fi
    return "$rc"
}

probe_audio_device() {
    local rc=0 node="" rec res id="" state ini out_dev in_dev
    kv "audio device" "$AUDIO_DEVICE"
    if ! pwa_available; then fail "PipeWire is not reachable (pw-cli): the audio device cannot be checked" || true; return 1; fi
    rec="$(cfg_get audio_node)"
    case "$AUDIO_DEVICE" in
        null)
            node=profiler-null
            [ -z "$rec" ] || [ "$rec" = profiler-null ] || warn "audio_node=$rec in setup.conf, but --audio-device null uses profiler-null" ;;
        builtin)
            res="$(pwa_resolve_device builtin 2>/dev/null || true)"
            if [ -n "$rec" ]; then
                ok "audio_node=$rec recorded in setup.conf"
                node="$rec"
                [ -z "$res" ] || [ "$res" = "$rec" ] || warn "--audio-device builtin resolves to $res now, but audio_node=$rec (default sink changed? setup-machine.sh --only audio)"
            else
                fail "audio_node= is not recorded in $PROFILER_SETUP_CONF (phase audio resolves --audio-device builtin and records it)" || true; rc=1
                node="$res"
            fi ;;
        *)
            node="$AUDIO_DEVICE"
            [ -z "$rec" ] || [ "$rec" = "$node" ] || warn "audio_node=$rec in setup.conf differs from --audio-device $AUDIO_DEVICE" ;;
    esac
    if [ -z "$node" ]; then fail "no audio node can be named for --audio-device $AUDIO_DEVICE" || true; return 1; fi
    if id="$(pwa_node_id "$node")"; then
        ok "$node is PipeWire node $id"
    else
        fail "$node is not a PipeWire node (wpctl status / pw-cli ls Node; phase audio)" || true; rc=1; id=""
    fi
    case "$node" in
        alsa_output.*Speaker*|profiler-null) ;;
        *) [ "$AUDIO_DEVICE" != builtin ] || warn "$node has no \"Speaker\" in its name: --audio-device builtin fell back to the default sink" ;;
    esac
    if [ "$AUDIO_DEVICE" != null ] && [ -n "$id" ]; then
        state="$(pwa_mute_state "$node")"
        case "$state" in
            muted) ok "$node is muted (the real clock runs, nothing is heard)" ;;
            unmuted) warn "$node is NOT muted (phase audio mutes it; profiler/bin/bench re-applies the mute before every run)" ;;
            *) warn "mute state of $node: $state" ;;
        esac
    fi
    ini="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    if [ -r "$ini" ]; then
        out_dev="$(sed -n 's/^[[:space:]]*output_device[[:space:]]*=[[:space:]]*//p' "$ini" | tail -n1 | sed 's/[[:space:]]*$//' || true)"
        in_dev="$(sed -n 's/^[[:space:]]*input_device[[:space:]]*=[[:space:]]*//p' "$ini" | tail -n1 | sed 's/[[:space:]]*$//' || true)"
        kv "pipeasio" "$ini: output_device ${out_dev:-unset}, input_device ${in_dev:-unset}, buffer_size $(sed -n 's/^[[:space:]]*buffer_size[[:space:]]*=[[:space:]]*//p' "$ini" | tail -n1 || true)"
        if [ "$out_dev" = "$node" ] && [ "$in_dev" = "$node" ]; then
            ok "PipeASIO drives $node (output_device and input_device)"
        else
            fail "PipeASIO is not pointed at $node (phase install sets output_device/input_device = $node in $ini)" || true; rc=1
        fi
    else
        warn "no PipeASIO config at $ini yet (phase install; the installer seeds it)"
    fi
    return "$rc"
}

probe_checkout() {
    local rc=0 branch status other n
    [ -d "$REPO_DIR/.git" ] || { fail "no git checkout at $REPO_DIR (phase repo; see profiler/setup/bootstrap.md)" || true; return 1; }
    kv "repo" "$REPO_DIR"
    if [ "$(cd -- "$REPO_DIR" && pwd -P)" != "$OWN_CHECKOUT" ]; then
        warn "verify.sh runs from $OWN_CHECKOUT but the configured repo is $REPO_DIR (pass --repo-dir to check this checkout)"
    fi
    branch="$(git_ro -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ?)"
    case "$branch" in profiler|trial/*) ok "branch $branch" ;; *) warn "branch is '$branch', expected profiler (or trial/T<id>-<slug> during a trial)" ;; esac
    if git_ro -C "$REPO_DIR" merge-base --is-ancestor aceb236 HEAD 2>/dev/null; then
        ok "aceb236 is an ancestor of HEAD ($(git_ro -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo ?))"
    else
        fail "aceb236 is not an ancestor of HEAD: this is not the fork's history (bootstrap from the profiler bundle)" || true; rc=1
    fi
    if [ "$(git_ro -C "$REPO_DIR" config --get core.autocrlf 2>/dev/null || echo unset)" = false ]; then ok "core.autocrlf=false"; else warn "core.autocrlf is not false (git -C $REPO_DIR config core.autocrlf false; the scripts must stay LF)"; fi
    status="$(git_ro -C "$REPO_DIR" status --porcelain 2>/dev/null || true)"
    if [ -z "$status" ]; then
        ok "working tree clean"
    else
        other="$(grep -vE '^.. dist/(BUILD-INFO[^ ]*\.txt|[^ ]*\.sha256)$' <<< "$status" || true)"
        if [ -z "$other" ]; then
            info "only build residue is modified (dist/BUILD-INFO*.txt, dist/*.sha256): never commit those"
        else
            n="$(grep -c . <<< "$other" || true)"
            warn "working tree has $n uncommitted change(s)/untracked file(s): work in progress? build.sh snapshots every non-ignored file"
            show_block "$(head -n 12 <<< "$other")"
        fi
    fi
    if [ -f "$REPO_DIR/bench/SHA256SUMS" ]; then
        if ( cd -- "$REPO_DIR" && sha256sum -c --status bench/SHA256SUMS 2>/dev/null ); then
            ok "bench/SHA256SUMS verifies ($(grep -c . "$REPO_DIR/bench/SHA256SUMS" 2>/dev/null || echo ?) assets)"
        else
            fail "bench/SHA256SUMS does not verify: the benchmark Sets are incomplete (phase repo: git archive 'aceb236^' bench | tar -x)" || true; rc=1
        fi
        if grep -qx 'bench/' "$REPO_DIR/.git/info/exclude" 2>/dev/null; then ok "bench/ excluded through .git/info/exclude"; else warn "bench/ is not in $REPO_DIR/.git/info/exclude: build.sh would snapshot it and git could commit it"; fi
        [ -z "$(git_ro -C "$REPO_DIR" ls-files bench 2>/dev/null || true)" ] || warn "files under bench/ are tracked by git: they must never be committed (git rm --cached -r bench)"
    else
        fail "bench/SHA256SUMS is missing: restore the Sets (phase repo: git -C $REPO_DIR archive 'aceb236^' bench | tar -x -C $REPO_DIR)" || true; rc=1
    fi
    if [ -f "$REPO_DIR/patches/0108-ntdll-add-static-trace-points.patch" ] && [ -f "$REPO_DIR/patches/pipeasio/0017-usdt-block-markers.patch" ]; then
        ok "trace-point patches present (0108 ntdll, pipeasio 0017)"
    else
        warn "trace-point patches absent (patches/0108-…, patches/pipeasio/0017-…): the tracer stays pending"
    fi
    return "$rc"
}

probe_dist() {
    local version tarball f rec sum size
    local -a missing=()
    version="$(v_repo_version)"
    [ -n "$version" ] || { fail "cannot read $REPO_DIR/VERSION (phase repo)" || true; return 1; }
    tarball="$REPO_DIR/dist/wine-d2d1-nspa-11.13-$version.tar.zst"
    for f in "$tarball" "$tarball.sha256" "$REPO_DIR/dist/BUILD-INFO-$version.txt" "$REPO_DIR/dist/pipewire-version-probe" "$REPO_DIR/dist/ableton-linkd" "$REPO_DIR/dist/cabextract-static"; do
        [ -s "$f" ] || missing+=("${f#"$REPO_DIR"/}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        fail "dist/ is incomplete for VERSION $version: ${missing[*]} (phase build: ./build.sh)" || true
        return 1
    fi
    size="$(du -h -- "$tarball" 2>/dev/null | cut -f1 || true)"
    if ( cd -- "$REPO_DIR/dist" && sha256sum -c --status -- "$(basename -- "$tarball").sha256" 2>/dev/null ); then
        ok "dist $version: tarball checksum verified (${size:-?})"
    else
        fail "dist/$(basename -- "$tarball").sha256 does not match the tarball" || true
        return 1
    fi
    sum="$(awk '{print $1; exit}' "$tarball.sha256" || true)"
    rec="$PROFILER_STATE_DIR/build-audit.env"
    if [ -r "$rec" ] && grep -qxF "tarball_sha256=$sum" "$rec" && grep -qxF "result=ok" "$rec"; then
        ok "build audit recorded for this tarball ($(sed -n 's/^ts=//p' "$rec" | head -n1 || true))"
    elif [ -r "$PROFILER_STATE_DIR/dev/last-official-build" ] && grep -qxF "tarball_sha256=$sum" "$PROFILER_STATE_DIR/dev/last-official-build" \
         && grep -qxF "audit=ok" "$PROFILER_STATE_DIR/dev/last-official-build"; then
        ok "build audit recorded for this tarball by profiler/dev/build-official.sh"
    else
        warn "no recorded build audit for this tarball (setup-machine.sh --only build runs the audit only)"
    fi
    return 0
}

probe_runtime() {
    local rt prefix launcher rc=0 binfo dv repo_v data_v f dev
    rt="$(v_runtime_root)"; prefix="$(v_prefix)"; launcher="$(v_launcher)"
    kv "runtime" "$rt"
    kv "prefix" "$prefix"
    [ -x "$rt/bin/wine" ] || { fail "runtime not installed at $rt (phase install)" || true; return 1; }
    if [ -f "$rt/.ableton-linux-runtime" ]; then ok "runtime marker .ableton-linux-runtime present (installed by scripts/installer.sh)"; else warn "no .ableton-linux-runtime marker in $rt: not installed through scripts/installer.sh?"; fi
    binfo="$rt/ABLETON-WINE-BUILD-INFO.txt"
    dv="$(sed -n 's/^dist-version: *//p' "$binfo" 2>/dev/null | head -n1 || true)"
    repo_v="$(v_repo_version)"
    kv "build info" "dist-version ${dv:-?}; patch-head $(sed -n 's/^patch-head: *//p' "$binfo" 2>/dev/null | head -n1 | cut -c1-12 || true); source-tree $(sed -n 's/^source-tree: *//p' "$binfo" 2>/dev/null | head -n1 | cut -c1-16 || true)…"
    if [ -n "$dv" ] && [ "$dv" = "$repo_v" ]; then
        ok "installed runtime $dv matches the repo's VERSION"
    else
        warn "installed runtime is ${dv:-unknown}, the repo builds ${repo_v:-?} (scripts/installer.sh runtime install --yes, or profiler/dev/build-official.sh)"
    fi
    data_v="$(tr -d '[:space:]' < "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/VERSION" 2>/dev/null || true)"
    [ -z "$data_v" ] || [ "$data_v" = "$dv" ] || warn "~/.local/share/ableton-wine/VERSION ($data_v) differs from the runtime's dist-version (${dv:-?})"
    for f in bin/wineserver lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-unix/pipeasio64.dll.so lib/wine/x86_64-windows/pipeasio64.dll; do
        if [ -f "$rt/$f" ]; then :; else fail "$rt/$f is missing" || true; rc=1; fi
    done
    [ "$rc" -ne 0 ] || ok "wineserver, ntdll.so and both PipeASIO halves present"
    [ ! -f "$rt/PROFILER-DEV-INFO.txt" ] || warn "$rt carries PROFILER-DEV-INFO.txt: this is a dev-synced tree, not the official runtime"
    dev="$rt-dev"
    [ ! -d "$dev" ] || info "dev runtime present: $dev ($(sed -n 's/^head=//p' "$dev/PROFILER-DEV-INFO.txt" 2>/dev/null | head -n1 || true))"
    if [ -x "$launcher" ]; then ok "launcher $launcher"; else fail "launcher missing: $launcher (phase install)" || true; rc=1; fi
    if [ -f "$prefix/system.reg" ]; then ok "prefix $prefix has system.reg"; else fail "prefix $prefix is missing or incomplete (phase install)" || true; rc=1; fi
    return "$rc"
}

probe_drift() {
    local st="$PROFILER_ROOT/bin/state" out rc=0
    [ -x "$st" ] || { fail "missing $st" || true; return 1; }
    if ! "$st" list --names 2>/dev/null | grep -qx golden; then
        warn "no golden snapshot yet (phase golden): drift cannot be measured"
        return 0
    fi
    step "profiler/bin/state diff --name golden"
    out="$("$st" diff --name golden 2>&1)" || rc=$?
    show_block "$out" 40
    if [ "$rc" -eq 0 ]; then
        ok "no drift from the golden snapshot"
    else
        warn "the live state drifted from golden (expected after a run; profiler/bin/state restore puts it back before a trial)"
    fi
    return 0
}

probe_ntsync() {
    local rt rec stamp srv
    rt="$(v_runtime_root)"
    if [ ! -x "$rt/bin/wineserver" ]; then warn "runtime not installed at $rt: NTSync not checked (phase install)"; return 0; fi
    srv="$(strings -- "$rt/bin/wineserver" 2>/dev/null | grep -c ntsync || true)"
    [[ "$srv" =~ ^[0-9]+$ ]] || srv=0
    if [ "$srv" -gt 0 ]; then ok "wineserver has $srv 'ntsync' references (built with linux/ntsync.h)"; else fail "wineserver has no 'ntsync' references: the runtime was built without NTSync" || true; return 1; fi
    rec="$PROFILER_STATE_DIR/tracecheck.env"
    if declare -F _tc_runtime_stamp >/dev/null; then stamp="$(_tc_runtime_stamp)"; else stamp=""; fi
    if [ -r "$rec" ] && grep -qxF "ntsync=ok" "$rec" && { [ -z "$stamp" ] || grep -qxF "runtime=$stamp" "$rec"; }; then
        ok "scripts/check-ntsync.sh passed for the installed runtime ($(sed -n 's/^ts=//p' "$rec" | head -n1 || true))"
    else
        warn "no NTSync result recorded for the installed runtime: setup-machine.sh --only tracecheck (runs scripts/check-ntsync.sh in a throwaway clone of the prefix)"
    fi
    return 0
}

# -------------------------------------------------------------- runner ----
declare -a FAILED_CHECKS=()
run_check() {
    local name="$1" kind="$2" n="$3" total="$4" t0 warn0 fail0 status="" note="" secs
    section "$n" "$total" "$name"
    CURRENT_PHASE="$name"; PHASE_NOTE=""
    t0="$(_now_s)"; warn0="$WARN_COUNT"; fail0="$FAIL_COUNT"
    if [ "$kind" = phase ]; then
        if ! declare -F "phase_${name}_check" >/dev/null 2>&1; then
            warn "phase file ${EXPECTED_NUM[$name]:-NN}-$name.sh is not in $PHASES_DIR (not delivered yet): its check cannot run; the probes cover its ground"
            status=not-run; note="phase file missing"
        elif [ "$name" = sudo ] && [ "$NO_SUDO" = 1 ]; then
            skip "--no-sudo: the sudo phase check needs sudo -n"
            status=skipped; note="--no-sudo"
        elif "phase_${name}_check"; then
            status=ok
        fi
    elif "probe_${name//-/_}"; then
        status=ok
    fi
    if [ "$status" = ok ] && [ "$FAIL_COUNT" -gt "$fail0" ]; then status=""; fi
    if [ -z "$status" ]; then
        [ "$FAIL_COUNT" -gt "$fail0" ] || fail "$name: check failed (see the lines above)" || true
        status=failed
        FAILED_CHECKS+=("$name")
    fi
    if [ "$status" = ok ] && [ "$WARN_COUNT" -gt "$warn0" ]; then status=warn; fi
    secs=$(( $(_now_s) - t0 ))
    summary_add "$name" "$status" "$secs" "${PHASE_NOTE:-$note}"
    CURRENT_PHASE=""
    return 0
}

# ---------------------------------------------------------------- go ----
_tmpdir >/dev/null
verify_log_init
printf '%s%sWine Interface Profiler — verify%s  %s(%s profile, %s)%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$PROFILE" "$PROFILE_SOURCE" "$C_RESET" >&"$LOG_FD"
_log_file "Wine Interface Profiler — verify ($PROFILE profile, $PROFILE_SOURCE)"
kv "host" "$(hostname 2>/dev/null || uname -n) · $(id -un) · $(systemd-detect-virt 2>/dev/null || echo unknown) virtualization$([ "$LAPTOP" = 1 ] && printf ' · laptop')"
kv "repo" "$REPO_DIR"
kv "runtime / prefix" "$(v_runtime_root) · $(v_prefix)"
kv "audio" "buffer $AUDIO_BUFFER · device $AUDIO_DEVICE"
kv "checks" "${#SELECTED[@]} of ${#CHECK_NAMES[@]}$([ "$QUICK" -eq 1 ] && printf ' (--quick)')$([ -n "$ONLY$SKIP" ] && printf ' (selection)')"
kv "log" "${LOGFILE:-(none)}"
[ -r "$PROFILER_SETUP_CONF" ] || warn "no $PROFILER_SETUP_CONF: setup-machine.sh has not run on this machine; defaults are assumed"
[ "$NO_SUDO" != 1 ] || info "--no-sudo: sudo is never invoked; the phase checks run in their no-sudo (dry-run) mode"
[ "$STRICT" != 1 ] || info "strict: warnings count as failures"

PHASE_SUMMARY_ON_EXIT=1
total="${#SELECTED[@]}"
i=0
for n in "${SELECTED[@]}"; do
    i=$(( i + 1 ))
    run_check "$n" "${CHECK_KIND_OF[$n]}" "$(printf '%02d' "$i")" "$(printf '%02d' "$total")"
done

summary_table
rc=0
if [ "${#FAILED_CHECKS[@]}" -gt 0 ]; then
    rc=1
    fail "verify: ${#FAILED_CHECKS[@]} check(s) failed: ${FAILED_CHECKS[*]}" || true
elif [ "$STRICT" -eq 1 ] && [ "$WARN_COUNT" -gt 0 ]; then
    rc=1
    fail "verify: no hard failure, but $WARN_COUNT warning(s) with --strict" || true
elif [ "$NEED_RELOGIN" = 1 ] || [ "$NEED_REBOOT" = 1 ]; then
    rc=3
    warn "verify: all hard checks passed, but a re-login or reboot is required first (see ACTIONS REQUIRED)"
else
    ok "verify: all ${#SELECTED[@]} check(s) passed${WARN_COUNT:+ ($WARN_COUNT warning(s))}"
fi

# a machine-readable trace of this run for the agent loop (not with --no-log)
if [ "$NO_LOG" != 1 ] && mkdir -p -- "$PROFILER_STATE_DIR" 2>/dev/null; then
    rec_tmp="$(mktemp "$PROFILER_STATE_DIR/.verify-last.XXXXXX" 2>/dev/null || true)"
    if [ -n "$rec_tmp" ]; then
        {
            printf '# written by profiler/setup/verify.sh (last run on this machine)\n'
            printf 'ts=%s\nprofile=%s\nresult=%s\nexit=%s\nchecks=%s\nfailed=%s\nwarnings=%s\nfailed_checks=%s\nlog=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROFILE" "$([ "$rc" -eq 0 ] && echo ok || { [ "$rc" -eq 3 ] && echo relogin-or-reboot || echo failed; })" \
                "$rc" "${#SELECTED[@]}" "${#FAILED_CHECKS[@]}" "$WARN_COUNT" "${FAILED_CHECKS[*]:-}" "${LOGFILE:-}"
        } > "$rec_tmp" && chmod 0644 "$rec_tmp" && mv -f -- "$rec_tmp" "$PROFILER_STATE_DIR/verify-last.env" || rm -f -- "$rec_tmp"
    fi
fi
exit "$rc"
