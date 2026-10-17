#!/usr/bin/env bash
# profiler/setup/verify.sh — the post-setup gate: re-checks everything
# setup-machine.sh is responsible for, without changing the host, and exits 0
# only when every hard check passes.
#
#   profiler/setup/verify.sh [--profile vm|baremetal] [--repo-dir DIR]
#                            [--only C[,C]] [--skip C[,C]] [--quick] [--strict]
#                            [--dry-run] [--list] [--no-color] [-h]
#
# What runs (in this order; --list prints the table):
#   * every phase's read-only `phase_<name>_check` from profiler/setup/phases/
#     (00 preflight … 17 dashboard; 18 summary is a report, not a state), under
#     DRY_RUN=1 so a stray `run` inside a check prints instead of executing —
#     a phase file that is not delivered yet is reported as "not-run"
#   * the extra probes of design A §2.6, interleaved by topic: kernel package vs
#     uname -r, sudo -n / the root helper, required commands, rootless podman,
#     realtime groups and limits, the display probe, PipeWire nodes and clock
#     settings, the checkout (branch, aceb236 ancestry, clean tree,
#     bench/SHA256SUMS), dist/ artifacts, the installed runtime's identity,
#     `state diff --name golden`, scripts/check-ntsync.sh and the dashboard build
#
# Nothing on the host is configured, installed or removed. Side effects that
# remain, all outside the repository: the log ~/.local/state/profiler/verify/
# verify-<ts>.log (verify-latest.log points at it) and verify-last.env; the
# build phase's audit extracts the tarball under ~/.cache/profiler/tmp when no
# audit is recorded; check-ntsync.sh starts a wineserver for the prefix for a few
# seconds (skipped while Live runs); `npm run build` writes the git-ignored
# profiler/dashboard/dist/. --quick skips those three; --dry-run prints the
# ntsync and dashboard-build commands instead of running them.
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
  --quick                 skip the slow checks: build (tarball audit), ntsync, dashboard-build
  --strict                warnings count as failures (exit 1)
  --dry-run               print the ntsync / dashboard-build commands instead of running them
  --list                  print the check table and exit
  --no-color              plain output (NO_COLOR=1 does the same)
  -h, --help              this text

Exit codes: 0 all hard checks passed · 1 a check failed · 2 usage ·
3 passed, but log out/in or reboot first (see ACTIONS REQUIRED).
Log: ~/.local/state/profiler/verify/verify-<timestamp>.log (verify-latest.log).

Examples:
  verify.sh                       full check (5–10 min when the build audit runs)
  verify.sh --quick               a minute: no tarball audit, no ntsync probe, no npm build
  verify.sh --only pipewire,display,realtime
EOF
}

usage_error() {
    printf '!! %s\n   (see --help)\n' "$1" >&2
    exit 2
}

# ---------------------------------------------------------- option parsing ----
opt_profile="" opt_repo="" ONLY="" SKIP="" QUICK=0 STRICT=0 VERIFY_DRY_RUN=0 list_checks=0
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
        --dry-run)   VERIFY_DRY_RUN=1 ;;
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
for lib in log.sh phase.sh; do
    [ -r "$SETUP_ROOT/lib/$lib" ] || { printf '!! missing library %s\n' "$SETUP_ROOT/lib/$lib" >&2; exit 2; }
    # shellcheck source=/dev/null
    . "$SETUP_ROOT/lib/$lib"
done
log_colors_init
# the phase checks are read-only by contract; DRY_RUN=1 turns any `run` they
# might still call into a printed line. The verify-owned probes that execute
# something go through vrun, which applies --dry-run instead.
ASSUME_YES=1 FORCE=0 DRY_RUN=1
export ASSUME_YES FORCE DRY_RUN
vrun() { DRY_RUN="$VERIFY_DRY_RUN" run "$@"; }
is_vdry() { [ "$VERIFY_DRY_RUN" = 1 ]; }

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
    phase:preflight probe:kernel
    phase:sudo probe:privilege
    phase:packages probe:tools
    phase:podman probe:containers
    phase:limits probe:realtime
    phase:session probe:display
    phase:audio probe:pipewire
    phase:repo probe:checkout
    phase:media
    phase:build probe:dist
    phase:install probe:runtime
    phase:plugins phase:osc phase:human
    phase:golden probe:drift
    phase:tracecheck probe:ntsync
    phase:claude
    phase:dashboard probe:dashboard-build
)
declare -A PROBE_DESC=(
    [kernel]="running kernel = installed kernel package, matching headers, BTF"
    [privilege]="sudo -n per profile policy, root helper through sudoers 91-profiler-helper, baseline"
    [tools]="commands the phases, the tracer and the agent loop need"
    [containers]="rootless podman: subuids, overlay driver, netavark, linger, build image"
    [realtime]="realtime/audio membership, chrt -r, rtprio/memlock, limits and sysctl drop-ins"
    [display]="DISPLAY from the user session, xdotool probe, autologin drop-in, inhibit unit"
    [pipewire]="PipeWire socket, profiler-null sink, clock settings, conf.d drop-ins"
    [checkout]="branch, aceb236 ancestry, clean tree, bench/SHA256SUMS, trace-point patches"
    [dist]="dist/ artifacts for VERSION, tarball checksum, recorded build audit"
    [runtime]="installed runtime identity vs dist VERSION, modules, launcher, PipeASIO config"
    [drift]="profiler/bin/state diff --name golden (read-only)"
    [ntsync]="scripts/check-ntsync.sh — Live closed; starts a wineserver for seconds"
    [dashboard-build]="npm run build in profiler/dashboard (dist/ is git-ignored)"
)
SLOW_CHECKS="build ntsync dashboard-build"

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
if [ "$PROFILE" = vm ]; then def_pwsudo=1 def_autologin=1 def_buffer=128; else def_pwsudo=0 def_autologin=0 def_buffer=64; fi
default_repo="$HOME/Projects/ableton-linux"
if [ ! -d "$default_repo/.git" ] && [ -d "$OWN_CHECKOUT/.git" ]; then default_repo="$OWN_CHECKOUT"; fi
MEDIA_DIR="$(cfg_get media_dir "$HOME/Proprietary/ableton")"
LIVE_INSTALLER="$(cfg_get live_installer "$MEDIA_DIR/Ableton Live 12 Trial Installer.exe")"
REPO_DIR="${opt_repo:-$(cfg_get repo_dir "$default_repo")}"
AUDIO_BUFFER="$(cfg_get audio_buffer "$def_buffer")"
PASSWORDLESS_SUDO="$(cfg_get passwordless_sudo "$def_pwsudo")"
AUTOLOGIN="$(cfg_get autologin "$def_autologin")"
VM_RAM_CHECK="$(cfg_get vm_ram_check 0)"
JOBS="$(cfg_get jobs)"; JOBS_SOURCE=config
if [ -z "$JOBS" ] || ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    JOBS_SOURCE=auto
    JOBS="$(nproc 2>/dev/null || echo 4)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        mem_jobs=$(( (avail_kb / 1048576 - 2) * 10 / 12 ))
        [ "$mem_jobs" -ge 2 ] || mem_jobs=2
        [ "$mem_jobs" -ge "$JOBS" ] || JOBS="$mem_jobs"
    fi
fi
export PROFILE MEDIA_DIR LIVE_INSTALLER REPO_DIR AUDIO_BUFFER PASSWORDLESS_SUDO AUTOLOGIN VM_RAM_CHECK JOBS JOBS_SOURCE

# ----------------------------------------------------------- utilities ----
verify_log_init() {
    local dir ts
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
# 0 when any process carries WINEPREFIX=<prefix> or runs "Ableton Live*.exe"
v_prefix_busy() {
    local prefix="$1" proc cmd
    [ -z "$(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null | tr -d '\0')" ] || return 0
    for proc in /proc/[0-9]*; do
        cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) return 0 ;; esac
    done
    return 1
}
v_repo_version() { tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || true; }
first_line() { head -n1 2>/dev/null | tr -d '\r'; }
pw_setting() { sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" <<< "$2" | head -n1; }

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
        pkgver="$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}')"
        if pacman -Ql "$pkgbase" 2>/dev/null | grep -qxF "$pkgbase /usr/lib/modules/$kver/"; then
            ok "running kernel is the installed $pkgbase ${pkgver:-?}"
        else
            fail "installed $pkgbase ${pkgver:-?} does not own /usr/lib/modules/$kver/: reboot into the installed kernel (headers and bcc must match the running kernel)" || true
            need_reboot; rc=1
        fi
        hver="$(pacman -Q "$pkgbase-headers" 2>/dev/null | awk '{print $2}')"
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

probe_privilege() {
    local helper=/usr/local/sbin/profiler-root-helper rc=0 out owner mode
    if sudo -n true 2>/dev/null; then
        ok "sudo -n true works (NOPASSWD)"
    elif [ "$PASSWORDLESS_SUDO" = 1 ]; then
        fail "sudo -n true needs a password although passwordless sudo is the policy of this profile (phase sudo: /etc/sudoers.d/90-profiler-$USER)" || true; rc=1
    else
        info "sudo -n true needs a password: expected, passwordless sudo is off for the $PROFILE profile"
    fi
    if [ -e "$helper" ]; then
        owner="$(stat -c %U -- "$helper" 2>/dev/null || echo ?)"; mode="$(stat -c %a -- "$helper" 2>/dev/null || echo ?)"
        kv "helper" "$helper ($owner, mode $mode)"
        if [ "$owner" = root ] && [ "$mode" = 755 ]; then ok "helper owned by root, mode 0755"; else warn "helper should be root-owned mode 0755 (is $owner $mode); it refuses to run otherwise"; fi
        if out="$(sudo -n "$helper" version 2>&1)"; then
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
    local -a required=(podman git bpftrace bpftool clang readelf strings python3 rsync zstd cabextract unzip jq curl node npm pw-cli pw-metadata chrt flock timeout tar sha256sum)
    local -a optional=(perf pahole xdotool Xvfb shellcheck tmux socat lsof ccache inotifywait wpctl kde-inhibit kwriteconfig6 fish)
    for c in "${required[@]}"; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
    for c in "${optional[@]}"; do command -v -- "$c" >/dev/null 2>&1 || optional_missing+=("$c"); done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "required commands present: ${required[*]}"
    else
        fail "missing required command(s): ${missing[*]} (phase packages)" || true; rc=1
    fi
    if [ "${#optional_missing[@]}" -eq 0 ]; then ok "optional commands present: ${optional[*]}"; else warn "optional command(s) missing: ${optional_missing[*]}"; fi
    command -v podman >/dev/null 2>&1 && kv "podman" "$(podman --version 2>/dev/null | first_line)"
    command -v bpftrace >/dev/null 2>&1 && kv "bpftrace" "$(bpftrace --version 2>/dev/null | first_line)"
    command -v clang >/dev/null 2>&1 && kv "clang" "$(clang --version 2>/dev/null | first_line)"
    command -v node >/dev/null 2>&1 && kv "node / npm" "$(node --version 2>/dev/null | first_line) / $(npm --version 2>/dev/null | first_line)"
    command -v perf >/dev/null 2>&1 && kv "perf" "$(perf version 2>/dev/null | first_line)"
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
        members="$(getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n')"
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
    local rc=0 env_out disp wl stype geom f found=0 v
    local wse="$PROFILER_ROOT/bin/with-session-env"
    [ -x "$wse" ] || { fail "missing $wse" || true; return 1; }
    if ! env_out="$("$wse" --print 2>/dev/null)"; then
        fail "no DISPLAY in the user session (systemctl --user show-environment): log in on the console (phase session enables autologin); install, human and bench need it" || true
        return 1
    fi
    disp="$(sed -n 's/^DISPLAY=//p' <<< "$env_out" | head -n1)"
    wl="$(sed -n 's/^WAYLAND_DISPLAY=//p' <<< "$env_out" | head -n1)"
    stype="$(sed -n 's/^XDG_SESSION_TYPE=//p' <<< "$env_out" | head -n1)"
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
    if [ -x "$HOME/.local/bin/with-session-env" ]; then ok "~/.local/bin/with-session-env installed"; else warn "~/.local/bin/with-session-env is not installed (phase session)"; fi
    if [ "$PROFILE" = vm ] && [ "$AUTOLOGIN" = 1 ]; then
        for f in /etc/sddm.conf.d/zz-profiler-autologin.conf /etc/plasmalogin.conf.d/zz-profiler-autologin.conf; do
            [ -e "$f" ] && { found=1; ok "autologin drop-in $f present"; }
        done
        [ "$found" -eq 1 ] || warn "no autologin drop-in (zz-profiler-autologin.conf under /etc/sddm.conf.d or /etc/plasmalogin.conf.d; phase session --autologin)"
    fi
    if systemctl --user is-active -q profiler-inhibit.service 2>/dev/null; then ok "profiler-inhibit.service active (no sleep/lock/notifications)"; else warn "profiler-inhibit.service is not active (phase session)"; fi
    if command -v kreadconfig6 >/dev/null 2>&1; then
        v="$(kreadconfig6 --file kscreenlockerrc --group Daemon --key Autolock --default true 2>/dev/null || echo ?)"
        if [ "$v" = false ]; then ok "KDE screen autolock disabled"; else warn "KDE screen autolock is '$v' (phase session: kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false)"; fi
    fi
    return "$rc"
}

probe_pipewire() {
    local rc=0 sock md nodes minq maxq q rate forceq allowed f confd prefix
    sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0"
    if [ -S "$sock" ]; then ok "PipeWire socket $sock"; else fail "PipeWire is not running (no $sock)" || true; return 1; fi
    command -v pw-cli >/dev/null 2>&1 && command -v pw-metadata >/dev/null 2>&1 || { fail "pw-cli / pw-metadata missing (pipewire package)" || true; return 1; }
    kv "libpipewire" "$(pw-cli --version 2>/dev/null | sed -n 's/^Linked with libpipewire //p' | head -n1)"
    nodes="$(pw-cli ls Node 2>/dev/null || true)"
    if grep -q 'node.name = "profiler-null"' <<< "$nodes"; then
        ok "profiler-null sink present"
    else
        fail "profiler-null sink is missing (phase audio: 90-profiler-null-sink.conf + PipeWire restart); PipeASIO is configured to use it" || true; rc=1
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
    for f in 90-profiler-null-sink.conf 91-profiler-clock.conf; do
        if [ -f "$confd/$f" ]; then ok "$confd/$f present"; else warn "$confd/$f is missing (phase audio)"; fi
    done
    return "$rc"
}

probe_checkout() {
    local rc=0 branch status other n
    [ -d "$REPO_DIR/.git" ] || { fail "no git checkout at $REPO_DIR (phase repo; see profiler/setup/bootstrap.md)" || true; return 1; }
    kv "repo" "$REPO_DIR"
    if [ "$(cd -- "$REPO_DIR" && pwd -P)" != "$OWN_CHECKOUT" ]; then
        warn "verify.sh runs from $OWN_CHECKOUT but the configured repo is $REPO_DIR (pass --repo-dir to check this checkout)"
    fi
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ?)"
    case "$branch" in profiler|trial/*) ok "branch $branch" ;; *) warn "branch is '$branch', expected profiler (or trial/T<id>-<slug> during a trial)" ;; esac
    if git -C "$REPO_DIR" merge-base --is-ancestor aceb236 HEAD 2>/dev/null; then
        ok "aceb236 is an ancestor of HEAD ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo ?))"
    else
        fail "aceb236 is not an ancestor of HEAD: this is not the fork's history (bootstrap from the profiler bundle)" || true; rc=1
    fi
    if [ "$(git -C "$REPO_DIR" config --get core.autocrlf 2>/dev/null || echo unset)" = false ]; then ok "core.autocrlf=false"; else warn "core.autocrlf is not false (git -C $REPO_DIR config core.autocrlf false; the scripts must stay LF)"; fi
    status="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)"
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
        [ -z "$(git -C "$REPO_DIR" ls-files bench 2>/dev/null)" ] || warn "files under bench/ are tracked by git: they must never be committed (git rm --cached -r bench)"
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
    size="$(du -h -- "$tarball" 2>/dev/null | cut -f1)"
    if ( cd -- "$REPO_DIR/dist" && sha256sum -c --status -- "$(basename -- "$tarball").sha256" 2>/dev/null ); then
        ok "dist $version: tarball checksum verified (${size:-?})"
    else
        fail "dist/$(basename -- "$tarball").sha256 does not match the tarball" || true
        return 1
    fi
    sum="$(awk '{print $1; exit}' "$tarball.sha256")"
    rec="$PROFILER_STATE_DIR/build-audit.env"
    if [ -r "$rec" ] && grep -qxF "tarball_sha256=$sum" "$rec" && grep -qxF "result=ok" "$rec"; then
        ok "build audit recorded for this tarball ($(sed -n 's/^ts=//p' "$rec" | head -n1))"
    else
        info "no recorded build audit for this tarball: the build check runs scripts/build-audit.sh (skipped with --quick)"
    fi
    return 0
}

probe_runtime() {
    local rt prefix launcher rc=0 binfo dv repo_v data_v f ini dev
    rt="$(v_runtime_root)"; prefix="$(v_prefix)"; launcher="$(v_launcher)"
    kv "runtime" "$rt"
    kv "prefix" "$prefix"
    [ -x "$rt/bin/wine" ] || { fail "runtime not installed at $rt (phase install)" || true; return 1; }
    if [ -f "$rt/.ableton-linux-runtime" ]; then ok "runtime marker .ableton-linux-runtime present (installed by scripts/installer.sh)"; else warn "no .ableton-linux-runtime marker in $rt: not installed through scripts/installer.sh?"; fi
    binfo="$rt/ABLETON-WINE-BUILD-INFO.txt"
    dv="$(sed -n 's/^dist-version: *//p' "$binfo" 2>/dev/null | head -n1)"
    repo_v="$(v_repo_version)"
    kv "build info" "dist-version ${dv:-?}; source-tree $(sed -n 's/^source-tree: *//p' "$binfo" 2>/dev/null | head -n1 | cut -c1-16)…"
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
    ini="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    if [ -r "$ini" ]; then
        kv "pipeasio" "$ini: buffer_size $(sed -n 's/^buffer_size *= *//p' "$ini" | head -n1), output_device $(sed -n 's/^output_device *= *//p' "$ini" | head -n1)"
        grep -qxE 'output_device *= *profiler-null' "$ini" && grep -qxE 'input_device *= *profiler-null' "$ini" \
            && ok "PipeASIO uses the profiler-null sink" || warn "PipeASIO is not pointed at profiler-null (phase install appends output_device/input_device)"
    else
        warn "no PipeASIO config at $ini (the installer seeds it)"
    fi
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
    local rt prefix chk probe rc=0
    rt="$(v_runtime_root)"; prefix="$(v_prefix)"; chk="$REPO_DIR/scripts/check-ntsync.sh"
    probe="$REPO_DIR/beta/tester-kit/probes/windows/ntsyncprobe.exe"
    [ -x "$chk" ] || { fail "missing $chk (phase repo)" || true; return 1; }
    if [ ! -x "$rt/bin/wineserver" ]; then warn "runtime not installed at $rt: NTSync check skipped (phase install)"; return 0; fi
    if [ ! -d "$prefix" ]; then warn "prefix $prefix does not exist: NTSync check skipped (phase install)"; return 0; fi
    if [ ! -f "$probe" ] && [ -z "${ABLETON_NTSYNC_PROBE:-}" ]; then warn "$probe is missing: check-ntsync.sh cannot run (set ABLETON_NTSYNC_PROBE)"; return 0; fi
    if v_prefix_busy "$prefix"; then
        warn "Live or a wineserver is using $prefix: check-ntsync.sh needs Live closed; skipped"
        return 0
    fi
    step "scripts/check-ntsync.sh (starts a wineserver for $prefix for a few seconds, then stops it)"
    if vrun --allow-fail --timeout 300 -- env ABLETON_WINE_ROOT="$rt" ABLETON_WINEPREFIX="$prefix" "$chk"; then
        if is_vdry; then info "dry run: not executed"; else ok "NTSync active: wineserver opens /dev/ntsync, sync semantics pass"; fi
    else
        fail "check-ntsync.sh failed (exit $RUN_STATUS): Wine does not use NTSync for this prefix (see the output above)" || true; rc=1
    fi
    return "$rc"
}

probe_dashboard_build() {
    local dir="$PROFILER_ROOT/dashboard"
    if [ ! -f "$dir/package.json" ]; then warn "profiler/dashboard/package.json does not exist: nothing to build"; return 0; fi
    command -v npm >/dev/null 2>&1 || { fail "npm is missing (phase packages)" || true; return 1; }
    [ -d "$dir/node_modules" ] || { fail "$dir/node_modules is missing: cd $dir && npm ci (phase dashboard)" || true; return 1; }
    step "npm run build in $dir (typecheck + vite build → dist/, git-ignored; output in the log)"
    if vrun --quiet --timeout 900 -- env -C "$dir" NO_COLOR=1 npm run build; then
        if is_vdry; then info "dry run: not executed"; else ok "dashboard builds ($(du -sh -- "$dir/dist" 2>/dev/null | cut -f1 || echo ?) in dist/)"; fi
        return 0
    fi
    return 1
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
kv "host" "$(hostname 2>/dev/null || uname -n) · $(id -un) · $(systemd-detect-virt 2>/dev/null || echo unknown) virtualization"
kv "repo" "$REPO_DIR"
kv "runtime / prefix" "$(v_runtime_root) · $(v_prefix)"
kv "audio buffer" "$AUDIO_BUFFER"
kv "checks" "${#SELECTED[@]} of ${#CHECK_NAMES[@]}$([ "$QUICK" -eq 1 ] && printf ' (--quick)')$([ -n "$ONLY$SKIP" ] && printf ' (selection)')"
kv "log" "${LOGFILE:-(none)}"
[ -r "$PROFILER_SETUP_CONF" ] || warn "no $PROFILER_SETUP_CONF: setup-machine.sh has not run on this machine; defaults are assumed"
[ "$VERIFY_DRY_RUN" != 1 ] || info "dry run: the ntsync and dashboard-build commands are printed, not executed"
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

# a machine-readable trace of this run for the agent loop and setup-machine.sh
rec_tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/verify-last.XXXXXX" 2>/dev/null || true)"
if [ -n "$rec_tmp" ]; then
    {
        printf '# written by profiler/setup/verify.sh (last run on this machine)\n'
        printf 'ts=%s\nprofile=%s\nresult=%s\nexit=%s\nchecks=%s\nfailed=%s\nwarnings=%s\nfailed_checks=%s\nlog=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROFILE" "$([ "$rc" -eq 0 ] && echo ok || { [ "$rc" -eq 3 ] && echo relogin-or-reboot || echo failed; })" \
            "$rc" "${#SELECTED[@]}" "${#FAILED_CHECKS[@]}" "$WARN_COUNT" "${FAILED_CHECKS[*]:-}" "${LOGFILE:-}"
    } > "$rec_tmp"
    vrun --quiet -- install -D -m 0644 "$rec_tmp" "$PROFILER_STATE_DIR/verify-last.env" || true
    rm -f -- "$rec_tmp"
fi
exit "$rc"
