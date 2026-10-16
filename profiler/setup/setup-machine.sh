#!/usr/bin/env bash
# profiler/setup/setup-machine.sh — set up a CachyOS/Arch machine for the Wine
# interface profiler (Ableton Live under the project's Wine fork): sudo, packages,
# rootless podman, RT limits, desktop session, PipeWire, repo, Live media, the Wine
# build, the Live install, plugins, AbletonOSC, the human checklist, the golden
# snapshot, tracer prerequisites, Claude Code and the dashboard.
#
# Run as your own user (never root), on the target machine:
#   profiler/setup/setup-machine.sh --profile vm
# Over SSH (the login shell is fish, so go through bash -lc; -t for sudo):
#   ssh -t abletonlinux 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile vm"'
#
# Options persist to ~/.config/profiler/setup.conf, so re-runs need no flags.
# Each phase is idempotent and resumable; see lib/phase.sh for the conventions.
# Exit codes: 0 ok · 1 a phase failed · 2 usage/configuration error · 3 finished,
# but a re-login or reboot is required before continuing.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "setup-machine.sh must run under bash (bash $0 … or bash -lc '…')" >&2
    exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "setup-machine.sh needs bash >= 4.4 (found $BASH_VERSION)" >&2
    exit 2
fi
set -euo pipefail
export LC_ALL=C.UTF-8

if [ "$(id -u)" -eq 0 ]; then
    echo "!! refusing to run as root: run setup-machine.sh as your own user; it uses sudo where needed" >&2
    exit 2
fi

SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILER_ROOT="$(cd -- "$SETUP_ROOT/.." && pwd -P)"
TEMPLATES_DIR="$SETUP_ROOT/templates"
OWN_CHECKOUT="$(cd -- "$PROFILER_ROOT/.." && pwd -P)"
export SETUP_ROOT PROFILER_ROOT TEMPLATES_DIR

usage() {
    cat <<'EOF'
Usage: setup-machine.sh --profile vm|baremetal [options]

Sets up this machine for the Wine interface profiler, phase by phase. Every
phase checks the host first and only applies what is missing, so the script
is safe to re-run after a failure, a reboot or a re-login.

Profile (required on the first run; remembered in ~/.config/profiler/setup.conf):
  --profile vm          development VM: passwordless sudo on, SDDM autologin on,
                        PipeASIO buffer 128, no timing claims
  --profile baremetal   measurement machine: passwordless sudo off, autologin off,
                        buffer 64 (the root helper still gets a NOPASSWD rule)

Paths and build:
  --live-installer PATH  Ableton Live 12 Trial installer .exe (the -N.bin slices
                         must sit beside it)  [MEDIA_DIR/Ableton Live 12 Trial Installer.exe]
  --media-dir DIR        where the Live media lives            [~/Proprietary/ableton]
  --repo-dir DIR         the ableton-linux checkout to build   [~/Projects/ableton-linux]
  --jobs N               build parallelism [min(nproc, (MemAvailable-2 GiB)/1.2 GiB)]
  --audio-buffer N       PipeASIO buffer: 64|128|256|512|1024  [vm 128, baremetal 64]

Host policy (profile defaults; --no-… turns a default off):
  --passwordless-sudo / --no-passwordless-sudo   NOPASSWD ALL rule for this user
  --autologin / --no-autologin                   SDDM autologin into Plasma Wayland
  --vm-ram-check         warn and print the .vmx instructions when RAM < 12 GiB

Run control:
  --yes                  non-interactive: no checklist wait, accept defaults
  --dry-run              print every command, change nothing (sudo never invoked)
  --only P[,P]           run only these phases (dependencies must be done already)
  --skip P[,P]           skip these phases
  --from P               start at phase P
  --force                re-apply phases whose check already passes / markers exist
  --list-phases          print the phase table (with done markers) and exit
  --no-color             plain output (NO_COLOR=1 does the same)
  -h, --help             this text

Output: coloured progress on the terminal, a plain copy in
~/.local/state/profiler/setup-<timestamp>.log (setup-latest.log points at it),
and a summary table with warnings and required actions at the end.
Exit codes: 0 ok · 1 phase failed · 2 usage · 3 re-login/reboot required.

Examples:
  setup-machine.sh --profile vm --vm-ram-check
  setup-machine.sh --from build --yes
  setup-machine.sh --only audio,install --dry-run
  setup-machine.sh --list-phases
EOF
}

usage_error() {
    printf '!! %s\n   (see --help)\n' "$1" >&2
    exit 2
}

# ---------------------------------------------------------- option parsing ----
opt_profile="" opt_installer="" opt_media="" opt_repo="" opt_jobs="" opt_buffer=""
opt_pwsudo="" opt_autologin="" opt_ramcheck="" list_phases=0
ASSUME_YES=0 DRY_RUN=0 FORCE=0 ONLY="" SKIP="" FROM=""

# split --opt=value into --opt value
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
        --profile)        need_value "$@"; opt_profile="$2"; shift ;;
        --live-installer) need_value "$@"; opt_installer="$2"; shift ;;
        --media-dir)      need_value "$@"; opt_media="$2"; shift ;;
        --repo-dir)       need_value "$@"; opt_repo="$2"; shift ;;
        --jobs)           need_value "$@"; opt_jobs="$2"; shift ;;
        --audio-buffer)   need_value "$@"; opt_buffer="$2"; shift ;;
        --passwordless-sudo)    opt_pwsudo=1 ;;
        --no-passwordless-sudo) opt_pwsudo=0 ;;
        --autologin)            opt_autologin=1 ;;
        --no-autologin)         opt_autologin=0 ;;
        --vm-ram-check)         opt_ramcheck=1 ;;
        --no-vm-ram-check)      opt_ramcheck=0 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --only)           need_value "$@"; ONLY="$2"; shift ;;
        --skip)           need_value "$@"; SKIP="$2"; shift ;;
        --from)           need_value "$@"; FROM="$2"; shift ;;
        --force)          FORCE=1 ;;
        --list-phases)    list_phases=1 ;;
        --no-color)       export NO_COLOR=1 ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; [ $# -eq 0 ] || usage_error "unexpected argument: $1" ;;
        -*)               usage_error "unknown option: $1" ;;
        *)                usage_error "unexpected argument: $1" ;;
    esac
    shift
done

case "$opt_profile" in ""|vm|baremetal) ;; *) usage_error "--profile must be vm or baremetal (got '$opt_profile')" ;; esac
[ -z "$opt_jobs" ] || [[ "$opt_jobs" =~ ^[1-9][0-9]*$ ]] || usage_error "--jobs needs a positive integer (got '$opt_jobs')"
case "$opt_buffer" in ""|64|128|256|512|1024) ;; *) usage_error "--audio-buffer must be 64, 128, 256, 512 or 1024 (got '$opt_buffer')" ;; esac
[ -n "$ONLY$SKIP$FROM" ] && [ "$list_phases" -eq 1 ] && usage_error "--list-phases takes no phase selection"
[ -z "$ONLY" ] || [ -z "$FROM" ] || usage_error "--only and --from exclude each other"

# ------------------------------------------------------------- libraries ----
for lib in log.sh phase.sh; do
    [ -r "$SETUP_ROOT/lib/$lib" ] || { printf '!! missing library %s\n' "$SETUP_ROOT/lib/$lib" >&2; exit 2; }
    # shellcheck source=/dev/null
    . "$SETUP_ROOT/lib/$lib"
done
log_colors_init
export ASSUME_YES DRY_RUN FORCE ONLY SKIP FROM

# --------------------------------------------------------------- phases ----
PHASES_DIR="$SETUP_ROOT/phases"
[ -d "$PHASES_DIR" ] || die "no phases directory at $PHASES_DIR — the checkout is incomplete (expected profiler/setup/phases/NN-<name>.sh)" 2
shopt -s nullglob
phase_files=("$PHASES_DIR"/[0-9][0-9]-*.sh)
shopt -u nullglob
[ "${#phase_files[@]}" -gt 0 ] || die "no phase files in $PHASES_DIR (expected NN-<name>.sh)" 2
for f in "${phase_files[@]}"; do
    # shellcheck source=/dev/null
    . "$f" || die "failed to source phase file $f" 2
done

if [ "$list_phases" -eq 1 ]; then
    phase_list
    exit 0
fi

# ------------------------------------------------- resolve the options ----
PROFILE="${opt_profile:-$(cfg_get profile)}"
if [ -z "$PROFILE" ]; then
    usage_error "--profile vm|baremetal is required on the first run (nothing saved in $PROFILER_SETUP_CONF yet)"
fi
case "$PROFILE" in vm|baremetal) ;; *) usage_error "saved profile '$PROFILE' in $PROFILER_SETUP_CONF is invalid; pass --profile" ;; esac

if [ "$PROFILE" = vm ]; then
    def_pwsudo=1 def_autologin=1 def_buffer=128
else
    def_pwsudo=0 def_autologin=0 def_buffer=64
fi

default_repo="$HOME/Projects/ableton-linux"
if [ ! -d "$default_repo/.git" ] && [ -d "$OWN_CHECKOUT/.git" ]; then default_repo="$OWN_CHECKOUT"; fi

MEDIA_DIR="${opt_media:-$(cfg_get media_dir "$HOME/Proprietary/ableton")}"
LIVE_INSTALLER="${opt_installer:-$(cfg_get live_installer "$MEDIA_DIR/Ableton Live 12 Trial Installer.exe")}"
REPO_DIR="${opt_repo:-$(cfg_get repo_dir "$default_repo")}"
AUDIO_BUFFER="${opt_buffer:-$(cfg_get audio_buffer "$def_buffer")}"
PASSWORDLESS_SUDO="${opt_pwsudo:-$(cfg_get passwordless_sudo "$def_pwsudo")}"
AUTOLOGIN="${opt_autologin:-$(cfg_get autologin "$def_autologin")}"
VM_RAM_CHECK="${opt_ramcheck:-$(cfg_get vm_ram_check 0)}"
case "$AUDIO_BUFFER" in 64|128|256|512|1024) ;; *) usage_error "saved audio_buffer '$AUDIO_BUFFER' is invalid; pass --audio-buffer" ;; esac

# build parallelism: option > saved > min(nproc, max(2, (MemAvailable - 2 GiB) / 1.2 GiB))
JOBS_SOURCE=option
JOBS="$opt_jobs"
if [ -z "$JOBS" ]; then JOBS="$(cfg_get jobs)"; JOBS_SOURCE=config; fi
if [ -z "$JOBS" ] || ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    JOBS_SOURCE=auto
    JOBS="$(nproc 2>/dev/null || echo 4)"
    if [ -r /proc/meminfo ]; then
        avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
        if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
            mem_jobs=$(( (avail_kb / 1048576 - 2) * 10 / 12 ))
            [ "$mem_jobs" -ge 2 ] || mem_jobs=2
            [ "$mem_jobs" -ge "$JOBS" ] || JOBS="$mem_jobs"
        fi
    fi
fi
export PROFILE MEDIA_DIR LIVE_INSTALLER REPO_DIR AUDIO_BUFFER PASSWORDLESS_SUDO AUTOLOGIN VM_RAM_CHECK JOBS JOBS_SOURCE

# ------------------------------------------------------------- go ----
log_init
printf '%s%sWine Interface Profiler — machine setup%s  %s(%s profile)%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$PROFILE" "$C_RESET" >&"$LOG_FD"
_log_file "Wine Interface Profiler — machine setup ($PROFILE profile)"
kv "host" "$(hostname 2>/dev/null || uname -n) · $(id -un)"
kv "repo" "$REPO_DIR"
kv "media dir" "$MEDIA_DIR"
kv "live installer" "$LIVE_INSTALLER"
kv "jobs" "$JOBS ($JOBS_SOURCE)"
kv "audio buffer" "$AUDIO_BUFFER"
kv "passwordless sudo" "$([ "$PASSWORDLESS_SUDO" = 1 ] && echo on || echo off)"
kv "autologin" "$([ "$AUTOLOGIN" = 1 ] && echo on || echo off)"
kv "log" "${LOGFILE:-(none)}"
[ "$DRY_RUN" != 1 ] || info "dry run: commands are printed, nothing is changed, options are not saved"
[ "$FORCE" != 1 ] || info "force: done-markers and passing checks are ignored"

# persist the effective options so re-runs need no flags
if [ "$DRY_RUN" != 1 ]; then
    cfg_set profile "$PROFILE" && cfg_set media_dir "$MEDIA_DIR" && cfg_set live_installer "$LIVE_INSTALLER" \
        && cfg_set repo_dir "$REPO_DIR" && cfg_set audio_buffer "$AUDIO_BUFFER" \
        && cfg_set passwordless_sudo "$PASSWORDLESS_SUDO" && cfg_set autologin "$AUTOLOGIN" \
        && cfg_set vm_ram_check "$VM_RAM_CHECK" || die "cannot save options to $PROFILER_SETUP_CONF" 2
    [ "$JOBS_SOURCE" = auto ] || cfg_set jobs "$JOBS" || true
fi

phase_select
kv "phases" "$(IFS=,; printf '%s' "${PHASES_SELECTED[*]}")"
PHASE_SUMMARY_ON_EXIT=1
rc=0
phases_run_all || rc=$?
case "$rc" in
    0) ok "setup complete" ;;
    3) warn "setup complete, but a re-login or reboot is required (see ACTIONS REQUIRED)" ;;
    *) fail "setup stopped: a phase failed (re-run the same command to resume)" || true; rc=1 ;;
esac
exit "$rc"
