#!/usr/bin/env bash
# profiler/dev/build-official.sh — the "keep" gate: a full official build of the
# runtime, its installation, and the build audit, under one lock.
#
#   1. flock ~/.local/state/profiler/build.lock (one official build at a time)
#   2. refuse while wine-dev.sh holds its lock (a dev build shares the image tag
#      and the ccache) or while any Live/wineserver runs from the official or the
#      dev runtime (the installer replaces the runtime directory)
#   3. JOBS=… PIPEASIO_TSAN_MODE=skip ./build.sh  (set -o pipefail, output tee'd to
#      ~/.local/state/profiler/build-<ts>.log)  — ~50-60 min cold on 8 vCPUs,
#      ~15-20 min with a warm .ccache
#   4. ./scripts/installer.sh runtime install --yes   (promotes dist/*.tar.zst into
#      ~/.local/opt/wine-d2d1-nspa-11.13 atomically, keeping a rollback copy)
#   5. ./scripts/build-audit.sh dist/wine-d2d1-nspa-11.13-<VERSION>.tar.zst
#      (re-checks the source-tree digest, the patch stack stamp and every
#      fingerprint against the shipped tarball); a pass is recorded in
#      ~/.local/state/profiler/build-audit.env — the record setup phase build and
#      verify.sh read, so they do not re-audit this tarball — and in
#      ~/.local/state/profiler/dev/last-official-build
#
# The golden snapshot and the new runtime: profiler/bin/state records the
# runtime by identity only and never restores it, so the `state restore --name
# golden` before the next trial puts back the golden prefix and Live state and
# leaves THIS runtime in place (restore reports "runtime changed since the
# snapshot" with both identities). No re-snapshot is needed; to make the new
# runtime part of the snapshot's record anyway, re-baseline deliberately:
# profiler/bin/state snapshot --name golden --rebaseline (keeps the old one).
#
# While it runs, NOTHING in the repository may change: build.sh snapshots every
# non-ignored file into /tmp, digests the tree, and aborts if the digest moves
# during the build or the audit (build.sh:94-106, 145-152, 190-197). Run output
# belongs in ~/.local/share/profiler/runs/, never in the checkout.
#
# Usage: build-official.sh [options]
#   --jobs N               parallelism (default: setup.conf jobs, else
#                          min(nproc, max(2, (MemAvailable - 2 GiB) / 1.2 GiB)))
#   --repo DIR             the checkout to build (default: setup.conf repo_dir,
#                          ~/Projects/ableton-linux, or this checkout)
#   --tsan-mode MODE       PIPEASIO_TSAN_MODE: skip (default, non-release build) |
#                          auto | require
#   --runtime-root DIR     install into DIR instead of the configured runtime root
#   --no-install           build + audit only
#   --no-audit             skip the final build-audit re-run
#   --yes                  no confirmation prompts
#   --dry-run              print every command, change nothing
#   --no-color  -h
#
# Afterwards: the A/B that justified the change must be repeated on the official
# runtime (same switch, ABAB, n >= 3). Never `git add -A` after a build:
# dist/BUILD-INFO*.txt and dist/*.sha256 are tracked and change.
# Exit: 0 ok · 1 a step failed · 2 usage / refused.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "build-official.sh must run under bash" >&2
    exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "build-official.sh needs bash >= 4.4 (found $BASH_VERSION)" >&2
    exit 2
fi
set -euo pipefail
export LC_ALL=C.UTF-8

DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILER_ROOT="$(cd -- "$DEV_DIR/.." && pwd -P)"
OWN_CHECKOUT="$(cd -- "$PROFILER_ROOT/.." && pwd -P)"

usage() {
    cat <<'EOF'
Usage: build-official.sh [--jobs N] [--repo DIR] [--tsan-mode skip|auto|require]
                         [--runtime-root DIR] [--no-install] [--no-audit]
                         [--yes] [--dry-run] [--no-color]

The "keep" gate: under ~/.local/state/profiler/build.lock, run the official
container build (./build.sh), install the result as the official runtime
(./scripts/installer.sh runtime install --yes) and re-run the build audit.
Refuses while wine-dev.sh is building or while Live/wineserver run from the
official or the dev runtime.

No file in the repository may change while it runs (build.sh aborts on any
change to its source snapshot). Expect ~50-60 min cold, ~15-20 min with a warm
.ccache, on 8 vCPUs.
EOF
}
usage_error() {
    printf '!! %s\n   (see build-official.sh --help)\n' "$1" >&2
    exit 2
}

LOG_SH="$PROFILER_ROOT/setup/lib/log.sh"
[ -r "$LOG_SH" ] || { printf '!! missing library %s\n' "$LOG_SH" >&2; exit 2; }
# shellcheck source=../setup/lib/log.sh
. "$LOG_SH"

# ------------------------------------------------------------- options ----
opt_jobs="" opt_repo="" opt_tsan="" opt_runtime_root=""
NO_INSTALL=0 NO_AUDIT=0 ASSUME_YES=0 DRY_RUN="${DRY_RUN:-0}"
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
        --jobs)         need_value "$@"; opt_jobs="$2"; shift ;;
        --repo)         need_value "$@"; opt_repo="$2"; shift ;;
        --tsan-mode)    need_value "$@"; opt_tsan="$2"; shift ;;
        --runtime-root) need_value "$@"; opt_runtime_root="$2"; shift ;;
        --no-install)   NO_INSTALL=1 ;;
        --no-audit)     NO_AUDIT=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        --no-color)     export NO_COLOR=1 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             usage_error "unknown option: $1" ;;
        *)              usage_error "unexpected argument: $1" ;;
    esac
    shift
done
[ -z "$opt_jobs" ] || [[ "$opt_jobs" =~ ^[1-9][0-9]*$ ]] || usage_error "--jobs needs a positive integer (got '$opt_jobs')"
case "$opt_tsan" in ""|skip|auto|require) ;; *) usage_error "--tsan-mode must be skip, auto or require (got '$opt_tsan')" ;; esac
export DRY_RUN
log_colors_init

# ------------------------------------------------------------ settings ----
STATE_DIR="${PROFILER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/profiler}"
export PROFILER_STATE_DIR="$STATE_DIR"
SETUP_CONF="${PROFILER_SETUP_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/profiler/setup.conf}"
ABLETON_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config"
DEV_STATE="$STATE_DIR/dev"
BUILD_LOCK="$STATE_DIR/build.lock"
DEV_LOCK="$STATE_DIR/wine-dev.lock"
DEV_BUSY="$STATE_DIR/wine-dev.building"
RUNTIME_NAME="wine-d2d1-nspa-11.13"

_kv_file_get() {   # _kv_file_get FILE KEY [DEFAULT] — last key=value line wins
    local file="$1" key="$2" default="${3:-}" line value found=0
    if [ -r "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$key="*) value="${line#*=}"; found=1 ;; esac
        done < "$file"
    fi
    if [ "$found" -eq 1 ]; then printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
}
_default_repo() {
    local saved d="$HOME/Projects/ableton-linux"
    saved="$(_kv_file_get "$SETUP_CONF" repo_dir)"
    if [ -n "$saved" ] && [ -d "$saved/.git" ]; then printf '%s\n' "$saved"; return 0; fi
    if [ -d "$d/.git" ]; then printf '%s\n' "$d"; return 0; fi
    if [ -d "$OWN_CHECKOUT/.git" ]; then printf '%s\n' "$OWN_CHECKOUT"; return 0; fi
    printf '%s\n' "$d"
}
_default_jobs() {   # min(nproc, max(2, (MemAvailable - 2 GiB) / 1.2 GiB)) — ~1.2 GiB per compile job
    local j avail_kb mem_jobs
    j="$(nproc 2>/dev/null || echo 4)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        mem_jobs=$(( (avail_kb / 1048576 - 2) * 10 / 12 ))
        [ "$mem_jobs" -ge 2 ] || mem_jobs=2
        [ "$mem_jobs" -ge "$j" ] || j="$mem_jobs"
    fi
    printf '%s\n' "$j"
}

REPO="${opt_repo:-${REPO:-$(_default_repo)}}"
# JOBS: --jobs > environment > setup.conf (as computed by setup-machine.sh) > formula
env_jobs="${JOBS:-}"
if [ -n "$opt_jobs" ]; then JOBS="$opt_jobs"; JOBS_SOURCE=option
elif [[ "$env_jobs" =~ ^[1-9][0-9]*$ ]]; then JOBS="$env_jobs"; JOBS_SOURCE=env
else JOBS="$(_kv_file_get "$SETUP_CONF" jobs)"; JOBS_SOURCE=setup.conf; fi
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then JOBS="$(_default_jobs)"; JOBS_SOURCE=auto; fi
CACHE_TMP="${XDG_CACHE_HOME:-$HOME/.cache}/profiler/tmp"   # disk-backed scratch for the audit's tarball unpack (/tmp is a small tmpfs on the VM)
TSAN_MODE="${opt_tsan:-skip}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
OFFICIAL_ROOT="${opt_runtime_root:-$(_kv_file_get "$ABLETON_CONF" runtime_root "$HOME/.local/opt/$RUNTIME_NAME")}"
DEV_ROOT="${DEV_ROOT:-$HOME/.local/opt/$RUNTIME_NAME-dev}"
RAWLOG=""
BUILD_LOCKED=0

_is_dry() { [ "${DRY_RUN:-0}" = 1 ]; }
_st() { if _is_dry; then printf 'dry-run\n'; else printf 'ok\n'; fi; }
_now() { printf '%(%s)T\n' -1; }

# ----------------------------------------------------------------- log ----
_log_open() {
    local ts latest prev
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p -- "$STATE_DIR" "$DEV_STATE" 2>/dev/null || true
    latest="$STATE_DIR/setup-latest.log"
    prev="$(readlink -- "$latest" 2>/dev/null || true)"
    log_init "$STATE_DIR/build-official-$ts.log"
    # log_init refreshes setup-latest.log unconditionally; that symlink belongs to
    # setup-machine.sh, so put it back and keep our own "latest" pointer.
    if [ -n "$prev" ]; then ln -sfn -- "$prev" "$latest" 2>/dev/null || true; else rm -f -- "$latest" 2>/dev/null || true; fi
    [ -z "$LOGFILE" ] || ln -sfn -- "$(basename -- "$LOGFILE")" "$STATE_DIR/build-official-latest.log" 2>/dev/null || true
    RAWLOG="$STATE_DIR/build-$ts.log"
}

# ---------------------------------------------------- runtime processes ----
_runtime_pids() {   # _runtime_pids ROOT… → "pid<TAB>exe" for processes whose exe lives under a root
    local root proc pid exe r
    local -a roots=()
    for root in "$@"; do
        [ -n "$root" ] && [ -e "$root" ] || continue
        roots+=("$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")")
    done
    [ "${#roots[@]}" -gt 0 ] || return 0
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        exe="$(readlink -f -- "$proc/exe" 2>/dev/null)" || continue
        [ -n "$exe" ] || continue
        for r in "${roots[@]}"; do
            case "$exe" in "$r"/*) printf '%s\t%s\n' "$pid" "$exe"; break ;; esac
        done
    done
    return 0
}

_dev_loop_running() {   # 0 when wine-dev.sh holds its lock
    command -v flock >/dev/null 2>&1 || return 1
    [ -e "$DEV_LOCK" ] || return 1
    ! ( exec 8>>"$DEV_LOCK" && flock -n 8 ) 2>/dev/null
}

_confirm() {
    local answer
    if [ "$ASSUME_YES" = 1 ]; then info "$1 — yes (--yes)"; return 0; fi
    if _is_dry; then info "$1 — continuing (dry run)"; return 0; fi
    if ! { : < /dev/tty; } 2>/dev/null; then info "$1 — no terminal; continuing (pass --yes to silence this)"; return 0; fi
    printf '%s%s%s %s [Y/n] %s' "$C_BOLD" "$C_CYAN" "$G_STEP" "$1" "$C_RESET" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
    _log_file "[$(now_hms)]   $G_STEP $1 [Y/n] $answer"
    case "$answer" in n|N|no|NO) info "cancelled"; return 1 ;; *) return 0 ;; esac
}

_record() {   # last-official-build marker
    _is_dry && return 0
    mkdir -p -- "$DEV_STATE" 2>/dev/null || true
    printf '%s\n' "$@" > "$DEV_STATE/last-official-build" 2>/dev/null || true
}

# build-audit.env — the record setup phase build (09-build.sh) and verify.sh read,
# in the same format phase build writes, so neither re-audits this tarball
_record_audit() {   # RESULT
    local tmp rec="$STATE_DIR/build-audit.env"
    _is_dry && return 0
    mkdir -p -- "$STATE_DIR" 2>/dev/null || true
    tmp="$(mktemp "$STATE_DIR/.build-audit.XXXXXX" 2>/dev/null)" || { warn "cannot write $rec"; return 0; }
    {
        printf '# written by profiler/dev/build-official.sh after scripts/build-audit.sh (result=ok|failed)\n'
        printf 'ts=%s\nversion=%s\ntarball=%s\ntarball_sha256=%s\nbuild_log=%s\nbuild_seconds=%s\njobs=%s\nresult=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${VERSION:-}" "$REPO/${RUNTIME_TARBALL:-}" \
            "$(cut -d' ' -f1 "${RUNTIME_TARBALL:-/nonexistent}.sha256" 2>/dev/null || true)" \
            "${RAWLOG:-}" "${build_secs:-}" "${JOBS:-}" "$1"
    } > "$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; warn "cannot write $rec"; return 0; }
    info "audit result ($1) recorded in $rec"
}

_on_exit() {
    local rc=$?
    if [ "${#SUMMARY_NAMES[@]}" -gt 0 ]; then summary_table; fi
    return 0
}
_on_int() { printf '\n' >&"$LOG_FD"; warn "interrupted"; exit 130; }
trap _on_exit EXIT
trap _on_int INT TERM

# ================================================================= go ====
_log_open
printf '%s%sWine Interface Profiler — official build (the "keep" gate)%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$C_RESET" >&"$LOG_FD"
_log_file "Wine Interface Profiler — official build"
kv "repo" "$REPO"
kv "jobs" "$JOBS ($JOBS_SOURCE)"
kv "tsan mode" "$TSAN_MODE$([ "$TSAN_MODE" = skip ] && echo ' (non-release build; the audit accepts it)')"
kv "image" "$IMAGE"
kv "runtime root" "$OFFICIAL_ROOT"
kv "install" "$([ "$NO_INSTALL" -eq 1 ] && echo no || echo 'installer.sh runtime install --yes')"
kv "audit" "$([ "$NO_AUDIT" -eq 1 ] && echo no || echo 'build-audit.sh on the tarball')"
kv "script log" "${LOGFILE:-(none)}"
kv "build log" "$RAWLOG"
! _is_dry || info "dry run: commands are printed, nothing is changed"

# ----------------------------------------------------------- preflight ----
section 1 4 "preflight"
t0="$(_now)"
pf_fail=0
pf() { pf_fail=$(( pf_fail + 1 )); fail "$*" || true; }

step "tools"
missing=()
for c in podman git zstd tar sha256sum flock timeout cmp; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [ "${#missing[@]}" -eq 0 ]; then
    ok "podman git zstd tar sha256sum flock timeout cmp"
elif _is_dry; then
    warn "missing command(s): ${missing[*]} (dry run continues)"
else
    pf "missing command(s): ${missing[*]} (setup-machine.sh phase 'packages'/'podman')"
fi

step "repository"
for f in build.sh VERSION scripts/installer.sh scripts/build-audit.sh scripts/container-build.sh Containerfile patches/SERIES.sha256; do
    [ -e "$REPO/$f" ] || pf "$REPO is not the ableton-linux checkout (missing $f); pass --repo"
done
if [ "$pf_fail" -eq 0 ]; then
    cd -- "$REPO"
    VERSION="$(sed -n '1p' VERSION)"
    RUNTIME_TARBALL="dist/$RUNTIME_NAME-$VERSION.tar.zst"
    kv "VERSION" "$VERSION"
    kv "HEAD" "$(git log -1 --format='%h %s' 2>/dev/null || echo '(not a git checkout)')"
    n_mod="$(git status --porcelain --untracked-files=no 2>/dev/null | grep -vc '^.. dist/' || true)"
    n_untracked="$(git status --porcelain --untracked-files=all 2>/dev/null | grep -c '^??' || true)"
    kv "working tree" "${n_mod:-0} modified tracked file(s), ${n_untracked:-0} untracked non-ignored file(s) — all of it is snapshotted and built"
    if ./scripts/build-audit.sh --check-series-policy patches/SERIES.sha256 >/dev/null 2>&1; then
        ok "patches/SERIES.sha256 ends at the required tails"
    else
        warn "patches/SERIES.sha256 does not satisfy build-audit.sh's series policy: the build's audit will fail (new patch? run ./scripts/build-audit.sh --freeze and update REQUIRED_*_TAIL)"
    fi
    series_now="$(cd patches && { sha256sum [0-9][0-9][0-9][0-9]-*.patch performance/*.patch pipeasio/*.patch 2>/dev/null || true; } | sort -k2)"
    if [ "$series_now" = "$(sort -k2 patches/SERIES.sha256 2>/dev/null)" ]; then
        ok "patches/ matches the frozen series manifest"
    else
        warn "patches/ differs from patches/SERIES.sha256 (unfrozen patch?): the build's audit will fail unless ./scripts/build-audit.sh --freeze is run first"
    fi
fi

step "locks"
mkdir -p -- "$STATE_DIR" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
    exec 9>>"$BUILD_LOCK" || pf "cannot open $BUILD_LOCK"
    if flock -n 9; then
        BUILD_LOCKED=1
        ok "acquired $BUILD_LOCK"
    else
        pf "another official build is running (lock $BUILD_LOCK is held); wait for it"
    fi
    if _dev_loop_running; then
        pf "wine-dev.sh is running ($(tr '\n' ' ' 2>/dev/null < "$DEV_BUSY" || echo 'details unknown')): it shares the image tag and the ccache — wait for it"
    else
        ok "wine-dev.sh is not running"
    fi
else
    warn "flock not found: locks are not enforced"
fi

step "runtime processes"
busy="$(_runtime_pids "$OFFICIAL_ROOT" "$DEV_ROOT")"
if [ -n "$busy" ]; then
    pf "Live/Wine processes are running from the runtimes; the installer must replace $OFFICIAL_ROOT — quit Live (File > Quit) and wait for wineserver:"
    while IFS=$'\t' read -r pid exe; do [ -n "$pid" ] && kv "pid $pid" "$exe"; done <<< "$busy"
else
    ok "no process runs from $OFFICIAL_ROOT or $DEV_ROOT"
fi

step "resources"
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
[[ "$mem_avail_kb" =~ ^[0-9]+$ ]] || mem_avail_kb=0
tmp_avail="$(df -B1 --output=avail /tmp 2>/dev/null | tail -n1 | tr -d ' ' || true)"
[[ "$tmp_avail" =~ ^[0-9]+$ ]] || tmp_avail=0
tmp_fs="$(findmnt -n -o FSTYPE /tmp 2>/dev/null || echo ?)"
kv "/tmp" "$(( tmp_avail / 1073741824 )) GiB free ($tmp_fs); build.sh keeps its source snapshot, output stage and host-side audit unpack there (peak ~2.5 GB)"
if [ "$tmp_avail" -ge $(( 2 * 1073741824 )) ]; then ok "/tmp has >= 2 GiB free"; else pf "/tmp has only $(( tmp_avail / 1048576 )) MiB free; build.sh needs >= 2 GiB there (hard-coded, no TMPDIR)"; fi
[ "$tmp_fs" != tmpfs ] || info "/tmp is RAM-backed: its peak use counts against the $(( mem_avail_kb / 1048576 )) GiB available to the compile jobs"
repo_avail="$(df -B1 --output=avail -- "$REPO" 2>/dev/null | tail -n1 | tr -d ' ' || true)"
[[ "$repo_avail" =~ ^[0-9]+$ ]] || repo_avail=0
kv "free at repo" "$(( repo_avail / 1073741824 )) GiB (dist/ ~1 GB, .ccache up to 5 GB, container storage ~10 GB)"
[ "$repo_avail" -ge $(( 10 * 1073741824 )) ] || warn "less than 10 GiB free at $REPO"
kv "memory" "$(( mem_avail_kb / 1048576 )) GiB available → JOBS=$JOBS (~1.2 GiB per job)"
if command -v podman >/dev/null 2>&1; then
    if podman image exists "$IMAGE" 2>/dev/null; then
        ok "image $IMAGE present (build.sh still runs podman build; cached layers make it quick)"
    else
        info "image $IMAGE missing: build.sh builds it first (~10 min, needs snapshot.ubuntu.com, apt.llvm.org, docker.io)"
    fi
    if [ -d "$REPO/.ccache" ]; then kv "ccache" "$REPO/.ccache ($(du -sh -- "$REPO/.ccache" 2>/dev/null | cut -f1)) — warm cache: ~15-20 min"; else kv "ccache" "none yet — cold build: ~50-60 min on 8 vCPUs"; fi
fi
if [ "$NO_INSTALL" -eq 0 ]; then
    if systemctl --user is-active --quiet pipewire.service 2>/dev/null; then
        ok "PipeWire is running (installer.sh runtime install requires it, >= 1.4.2)"
    else
        warn "pipewire.service is not active for this user: installer.sh runtime install will refuse (log in to the desktop session or start it)"
    fi
fi
if [ -n "${ABLETON_WINE_ROOT:-}" ] && [ -z "$opt_runtime_root" ]; then
    warn "ABLETON_WINE_ROOT=$ABLETON_WINE_ROOT is set in the environment (dev runtime?); ignoring it so the OFFICIAL runtime at $OFFICIAL_ROOT is installed (pass --runtime-root to override)"
    unset ABLETON_WINE_ROOT
fi

if [ "$pf_fail" -gt 0 ]; then
    summary_add preflight failed $(( $(_now) - t0 )) "$pf_fail hard check(s) failed"
    die "refusing to build: $pf_fail hard check(s) failed (see above)" 2
fi
summary_add preflight "$(_st)" $(( $(_now) - t0 ))

printf '\n%s%s%s  NO REPOSITORY EDITS UNTIL THIS FINISHES  %s\n' "$C_BOLD" "$C_YELLOW" "$G_WARN" "$C_RESET" >&"$LOG_FD"
_log_file "  NO REPOSITORY EDITS UNTIL THIS FINISHES"
info "build.sh snapshots every non-ignored file in $REPO and aborts if the tree's digest changes while it builds"
info "or audits. Agents: do not touch patches/, scripts/, profiler/, notes/ or any tracked file until the summary"
info "table appears; keep run output in ~/.local/share/profiler/runs/. Progress: tail -f $RAWLOG"
_confirm "start the official build now (~15-60 min)?" || die "cancelled" 2

# --------------------------------------------------------------- build ----
section 2 4 "build (./build.sh)"
t0="$(_now)"
step "JOBS=$JOBS PIPEASIO_TSAN_MODE=$TSAN_MODE ./build.sh 2>&1 | tee $RAWLOG"
if run -- env "JOBS=$JOBS" "PIPEASIO_TSAN_MODE=$TSAN_MODE" "IMAGE=$IMAGE" \
        bash -c 'set -o pipefail; ./build.sh 2>&1 | tee -- "$1"' build-official "$RAWLOG"; then
    build_secs=$(( $(_now) - t0 ))
    if _is_dry; then
        summary_add build dry-run "$build_secs"
    else
        missing=()
        for f in "$RUNTIME_TARBALL" "$RUNTIME_TARBALL.sha256" "dist/BUILD-INFO-$VERSION.txt" dist/BUILD-INFO.txt dist/pipewire-version-probe dist/ableton-linkd dist/cabextract-static; do
            [ -s "$f" ] || missing+=("$f")
        done
        if [ "${#missing[@]}" -gt 0 ]; then
            summary_add build failed "$build_secs" "outputs missing"
            die "build.sh returned 0 but dist/ lacks: ${missing[*]}" 1
        fi
        kv "tarball" "$RUNTIME_TARBALL ($(du -h -- "$RUNTIME_TARBALL" | cut -f1))"
        kv "patch-head" "$(sed -n 's/^patch-head: *//p' "dist/BUILD-INFO-$VERSION.txt" | head -n1)"
        kv "source-tree" "$(sed -n 's/^source-tree: *//p' "dist/BUILD-INFO-$VERSION.txt" | head -n1)"
        kv "sanitizers" "$(sed -n 's/^pipeasio-sanitizers: *//p' "dist/BUILD-INFO-$VERSION.txt" | head -n1)"
        summary_add build ok "$build_secs" "$VERSION"
        ok "official build finished in $(( build_secs / 60 )) min"
    fi
else
    summary_add build failed $(( $(_now) - t0 )) "see $RAWLOG"
    info "the full build output is in $RAWLOG"
    die "./build.sh failed (exit $RUN_STATUS)" 1
fi

# ------------------------------------------------------------- install ----
section 3 4 "install (installer.sh runtime install)"
if [ "$NO_INSTALL" -eq 1 ]; then
    skip "--no-install: the tarball stays in dist/ (install later: ./scripts/installer.sh runtime install --yes)"
    summary_add install skipped 0 "--no-install"
else
    t0="$(_now)"
    busy="$(_runtime_pids "$OFFICIAL_ROOT" "$DEV_ROOT")"
    if [ -n "$busy" ]; then
        summary_add install failed 0 "runtime busy"
        fail "Live/Wine started during the build; the runtime cannot be replaced now:" || true
        while IFS=$'\t' read -r pid exe; do [ -n "$pid" ] && kv "pid $pid" "$exe"; done <<< "$busy"
        die "quit Live and run: ./scripts/installer.sh runtime install --yes" 1
    fi
    install_args=(runtime install --yes)
    [ -z "$opt_runtime_root" ] || install_args+=(--runtime-root "$opt_runtime_root")
    if run -- ./scripts/installer.sh "${install_args[@]}"; then
        if _is_dry; then
            summary_add install dry-run $(( $(_now) - t0 ))
        else
            if [ -x "$OFFICIAL_ROOT/bin/wine" ]; then
                installed_version="$(sed -n 's/^dist-version: *//p' "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null | head -n1 || true)"
                installed_head="$(sed -n 's/^patch-head: *//p' "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null | head -n1 || true)"
                if cmp -s -- "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" "dist/BUILD-INFO-$VERSION.txt"; then
                    ok "installed runtime at $OFFICIAL_ROOT is this build (dist-version $installed_version, patch-head ${installed_head:0:12})"
                else
                    warn "BUILD-INFO of $OFFICIAL_ROOT differs from dist/BUILD-INFO-$VERSION.txt (installed dist-version ${installed_version:-?})"
                fi
                kv "wine" "$("$OFFICIAL_ROOT/bin/wine" --version 2>/dev/null || echo '?')"
            else
                warn "no bin/wine under $OFFICIAL_ROOT after the install (runtime_root configured elsewhere? check ~/.config/ableton-wine/config)"
            fi
            summary_add install ok $(( $(_now) - t0 )) "$OFFICIAL_ROOT"
        fi
    else
        summary_add install failed $(( $(_now) - t0 ))
        die "installer.sh runtime install failed (exit $RUN_STATUS); the previous runtime is rolled back by the installer" 1
    fi
fi

# --------------------------------------------------------------- audit ----
section 4 4 "audit (build-audit.sh)"
if [ "$NO_AUDIT" -eq 1 ]; then
    skip "--no-audit (build.sh already audited the tarball twice: in the container and on the host)"
    summary_add audit skipped 0 "--no-audit"
else
    t0="$(_now)"
    # build-audit.sh unpacks the ~1.3 GB tarball under ${TMPDIR:-/tmp}; keep that off the tmpfs
    run -- mkdir -p -- "$CACHE_TMP" || true
    if run -- env "TMPDIR=$CACHE_TMP" ./scripts/build-audit.sh "$RUNTIME_TARBALL"; then
        summary_add audit "$(_st)" $(( $(_now) - t0 ))
        _is_dry || ok "audit passed: patch stack, fingerprints and source-tree digest match the tarball"
        _record_audit ok
    else
        summary_add audit failed $(( $(_now) - t0 ))
        _record_audit failed
        die "build-audit.sh failed (exit $RUN_STATUS): if a file in the repository changed after the build, the source-tree digest no longer matches — rebuild" 1
    fi
fi

# ---------------------------------------------------------------- done ----
_record "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "version=${VERSION:-}" "repo=$REPO" \
    "tarball=${RUNTIME_TARBALL:-}" "tarball_sha256=$(cut -d' ' -f1 "${RUNTIME_TARBALL:-/nonexistent}.sha256" 2>/dev/null || true)" \
    "source_tree=$(sed -n 's/^source-tree: *//p' "dist/BUILD-INFO-${VERSION:-}.txt" 2>/dev/null | head -n1)" \
    "patch_head=$(sed -n 's/^patch-head: *//p' "dist/BUILD-INFO-${VERSION:-}.txt" 2>/dev/null | head -n1)" \
    "installed=$([ "$NO_INSTALL" -eq 1 ] && echo no || echo "$OFFICIAL_ROOT")" \
    "audit=$([ "$NO_AUDIT" -eq 1 ] && echo skipped || echo ok)" \
    "build_log=$RAWLOG"
ok "official build complete"
info "git status now shows dist/BUILD-INFO*.txt and dist/*.sha256 as modified: never  git add -A  (commit only your patch, audit and notes)"
info "the dev runtime at $DEV_ROOT (if any) is still based on the previous official runtime;  wine-dev.sh sync  keeps updating it from the dev stage"
info "next: repeat the A/B on the official runtime — ABLETON_WINE_ROOT unset, WINE_X=0 vs WINE_X=1, interleaved ABAB, n >= 3 —"
info "      profiler/bin/bench --tag keep/<trial> …  then record the verdict in profiler/ledger.jsonl"
exit 0
