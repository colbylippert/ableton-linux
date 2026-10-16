#!/usr/bin/env bash
# profiler/dev/wine-dev.sh — developer build loop for the project's Wine fork.
#
# A persistent rootless podman container (default name "wine-dev"), created from
# the repository's Containerfile — the same Ubuntu 22.04 image ./build.sh uses —
# holds an unpacked, patched Wine tree and an incremental out-of-tree build at
# exactly the paths the official pipeline uses (scripts/container-build.sh:140-180):
#
#   /work/wine-src   vendor/wine-base-5c23dd1c.tar.zst + patches/NNNN-*.patch then
#                    patches/performance/*.patch, applied with `git am --3way` (a
#                    synthetic "From: dist <build@localhost>" + "Date:" header is
#                    prepended when a patch has none), then tagged series-aceb236
#   /work/build      CPPFLAGS=-I/opt/ntsync-uapi ../wine-src/configure
#                    --prefix=/opt/wine-d2d1-nspa-11.13 --enable-archs=i386,x86_64
#                    --disable-tests; make -j$JOBS
#   /work/stage      make install DESTDIR=/work/stage → /work/stage/opt/wine-d2d1-nspa-11.13
#   /work/pipeasio   vendor/pipeasio-1.5.0.tar.gz + patches/pipeasio/*.patch (patch -p1),
#                    cmake/Ninja against the staged Wine (container-build.sh:250-262,
#                    363-373, 438-444, 562-563)
#   /src             the repository, read-only
#   /ccache          $REPO/.ccache, shared with ./build.sh (the image puts
#                    /usr/lib/ccache-shims first on PATH and sets CCACHE_DIR=/ccache)
#
# Same compilers, same ccache, same paths and flags: a patch that builds here
# reproduces in ./build.sh, and the official build hits this cache. Iterations take
# seconds; the one-time init takes ~25-40 minutes on 8 vCPUs.
#
# The host sees the tree at ~/wine-dev/work (bind-mounted at /work, uid-mapped
# with --userns=keep-id), so editing and committing happen on the host.
#
# Usage: wine-dev.sh [global options] SUBCOMMAND [options]
#   init [--force] [--no-build]      image → container → unpack → series → configure →
#                                    make → install → checks (idempotent; --force redoes
#                                    the tree from scratch)
#   apply [--abort] PATCH…           git am --3way PATCH… into the dev tree (same
#                                    header rule as the build); --abort = git am --abort
#   edit [--path]                    where to edit, how to commit (--path: path only)
#   build [--dir DIR]… [--install|--no-install]
#                                    incremental make of the whole tree, or of DIR
#                                    (make DIR/all, e.g. --dir dlls/ntdll), then make
#                                    install into the stage (default: yes for a whole-
#                                    tree build; no with --dir, Wine has no per-directory
#                                    install target — use sync --artifacts instead)
#   pipeasio-init                    unpack + patch + cmake-configure PipeASIO against
#                                    the staged Wine
#   pipeasio-build [--test]          cmake --build + install into the stage (--test also
#                                    runs the non-integration CTest scope)
#   sync [--strip] [--artifacts] [--dir DIR]… [--fast]
#                                    first run: reflink-copy the official runtime to the
#                                    dev runtime; every run: rsync the stage over it
#                                    (checksum compare; --fast: size+mtime), list the
#                                    changed files, write PROFILER-DEV-INFO.txt.
#                                    --artifacts: first copy the freshly built modules
#                                    from /work/build/DIR into the stage (no make install
#                                    needed). --strip: strip like the official build;
#                                    default unstripped so the tracer/perf see symbols.
#                                    Refuses while any process runs from either runtime.
#   format-patch [--number NNNN] [--name SLUG] [--pipeasio] [--out DIR] [--force]
#                                    export HEAD as patches/NNNN-SLUG.patch (or
#                                    patches/pipeasio/NNNN-SLUG.patch) and print the
#                                    build-audit checklist
#   shell [CMD…]                     interactive bash in the container, or run CMD there
#   status [--deep]                  container, tree, build, runtime, locks, processes
#   logs [-n N] [--follow] [--list]  the latest wine-dev log
#   reset [--keep-work] [--runtime]  remove the container and ~/wine-dev/work (kept with
#                                    --keep-work); --runtime also removes the dev runtime.
#                                    The image and the ccache stay.
#
# Global options (before the subcommand):
#   --dry-run    print every command, change nothing      --yes   no confirmations
#   --jobs N     parallelism for this invocation          --no-color   -h, --help
#
# Environment (defaults):
#   WINE_DEV_NAME=wine-dev             IMAGE=ableton-wine-build:22.04
#   WINE_DEV_WORK=~/wine-dev/work      REPO=~/Projects/ableton-linux (setup.conf
#                                      repo_dir, else the checkout this script is in)
#   CCACHE=$REPO/.ccache               DEV_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev
#   JOBS=setup.conf jobs, else min(nproc, max(2, (MemAvailable - 2 GiB) / 1.2 GiB))
#   INSTALL_PREFIX=/opt/wine-d2d1-nspa-11.13
#   WINE_OFFICIAL_ROOT=runtime_root from ~/.config/ableton-wine/config, else
#                                      ~/.local/opt/wine-d2d1-nspa-11.13
#
# Launching Live on the dev runtime (the launcher validates only bin/wine,
# bin/wineserver and the prefix's system.reg):
#   ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev WINE_X=1 \
#       profiler/bin/with-session-env scripts/ableton-live "SET.als"
# A/B compares WINE_X=0 vs WINE_X=1 on ONE runtime; a "keep" decision needs
# profiler/dev/build-official.sh and the same A/B on the official runtime.
#
# State: ~/.local/state/profiler/wine-dev.lock (+ wine-dev.building while a
# mutating subcommand runs; build-official.sh refuses while it is held),
# ~/.local/state/profiler/dev/wine-dev-<ts>-<cmd>.log (wine-dev-latest.log),
# dev/last-build, dev/last-sync. Nothing is written under the repository except
# the patch file format-patch creates. Exit: 0 ok · 1 failed · 2 usage/refused.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "wine-dev.sh must run under bash" >&2
    exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "wine-dev.sh needs bash >= 4.4 (found $BASH_VERSION)" >&2
    exit 2
fi
set -euo pipefail
export LC_ALL=C.UTF-8

DEV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILER_ROOT="$(cd -- "$DEV_DIR/.." && pwd -P)"
OWN_CHECKOUT="$(cd -- "$PROFILER_ROOT/.." && pwd -P)"

usage() {
    cat <<'EOF'
Usage: wine-dev.sh [--dry-run] [--yes] [--jobs N] [--no-color] SUBCOMMAND [options]

Persistent podman build container for the project's Wine fork: the same image,
paths, patch application, configure flags and ccache as ./build.sh, with
incremental rebuilds in seconds.

Subcommands:
  init [--force] [--no-build]        create/start the container, unpack the Wine base,
                                     apply the patch series, configure, make, install
                                     into the stage (~25-40 min once; resumable)
  apply [--abort] PATCH...           git am --3way into the dev tree
  edit [--path]                      where the tree is and how to commit
  build [--dir DIR]... [--install]   incremental make (+ make install into the stage)
  pipeasio-init                      unpack + patch + configure PipeASIO
  pipeasio-build [--test]            build + install PipeASIO into the stage
  sync [--strip] [--artifacts] [--dir DIR]... [--fast]
                                     update ~/.local/opt/wine-d2d1-nspa-11.13-dev from the stage
  format-patch [--number NNNN] [--name SLUG] [--pipeasio] [--out DIR] [--force]
                                     export HEAD into patches/ + print the audit checklist
  shell [CMD...]                     bash (or CMD) inside the container
  status [--deep]                    what exists, what is pending, what is running
  logs [-n N] [--follow] [--list]    the latest log
  reset [--keep-work] [--runtime]    remove the container (and the work tree / dev runtime)

Environment: WINE_DEV_NAME IMAGE WINE_DEV_WORK REPO CCACHE DEV_ROOT JOBS
             INSTALL_PREFIX WINE_OFFICIAL_ROOT (see the header of this script)

Typical loop:
  wine-dev.sh init                       # once
  $EDITOR ~/wine-dev/work/wine-src/dlls/ntdll/unix/sync.c
  wine-dev.sh build --dir dlls/ntdll && wine-dev.sh sync --artifacts --dir dlls/ntdll
  ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev WINE_X=1 \
      profiler/bin/with-session-env scripts/ableton-live SET.als
  git -C ~/wine-dev/work/wine-src commit -am "ntdll: ..."
  wine-dev.sh format-patch --number 0108 --name ntdll-my-change
EOF
}

usage_error() {
    printf '!! %s\n   (see wine-dev.sh --help)\n' "$1" >&2
    exit 2
}

# ------------------------------------------------------------- libraries ----
LOG_SH="$PROFILER_ROOT/setup/lib/log.sh"
[ -r "$LOG_SH" ] || { printf '!! missing library %s\n' "$LOG_SH" >&2; exit 2; }
# shellcheck source=../setup/lib/log.sh
. "$LOG_SH"

# ------------------------------------------------------- global options ----
ASSUME_YES="${WINE_DEV_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
JOBS_OPT=""
CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --jobs) [ $# -ge 2 ] || usage_error "--jobs needs a value"; JOBS_OPT="$2"; shift ;;
        --jobs=*) JOBS_OPT="${1#*=}" ;;
        --no-color) export NO_COLOR=1 ;;
        -h|--help|help) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage_error "unknown global option: $1" ;;
        *) break ;;
    esac
    shift
done
[ $# -gt 0 ] || { usage; exit 2; }
CMD="$1"; shift
[ -z "$JOBS_OPT" ] || [[ "$JOBS_OPT" =~ ^[1-9][0-9]*$ ]] || usage_error "--jobs needs a positive integer (got '$JOBS_OPT')"
export DRY_RUN ASSUME_YES
log_colors_init

# ------------------------------------------------------------ settings ----
STATE_DIR="${PROFILER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/profiler}"
export PROFILER_STATE_DIR="$STATE_DIR"
SETUP_CONF="${PROFILER_SETUP_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/profiler/setup.conf}"
ABLETON_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/profiler"
DEV_STATE="$STATE_DIR/dev"
DEV_LOCK="$STATE_DIR/wine-dev.lock"
DEV_BUSY="$STATE_DIR/wine-dev.building"
OFFICIAL_LOCK="$STATE_DIR/build.lock"
SERIES_TAG="series-aceb236"
PIPEASIO_TAG="series-pipeasio"
RUNTIME_NAME="wine-d2d1-nspa-11.13"

# last "key=value" line of a key=value file (setup.conf, ableton-wine/config)
_kv_file_get() {   # _kv_file_get FILE KEY [DEFAULT]
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

_default_jobs() {
    local j avail_kb mem_jobs
    j="$(_kv_file_get "$SETUP_CONF" jobs)"
    if [[ "$j" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$j"; return 0; fi
    j="$(nproc 2>/dev/null || echo 4)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        mem_jobs=$(( (avail_kb / 1048576 - 2) * 10 / 12 ))
        [ "$mem_jobs" -ge 2 ] || mem_jobs=2
        [ "$mem_jobs" -ge "$j" ] || j="$mem_jobs"
    fi
    printf '%s\n' "$j"
}

WINE_DEV_NAME="${WINE_DEV_NAME:-wine-dev}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
WINE_DEV_WORK="${WINE_DEV_WORK:-$HOME/wine-dev/work}"
REPO="${REPO:-$(_default_repo)}"
CCACHE="${CCACHE:-$REPO/.ccache}"
DEV_ROOT="${DEV_ROOT:-$HOME/.local/opt/$RUNTIME_NAME-dev}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/$RUNTIME_NAME}"
OFFICIAL_ROOT="${WINE_OFFICIAL_ROOT:-$(_kv_file_get "$ABLETON_CONF" runtime_root "$HOME/.local/opt/$RUNTIME_NAME")}"
if [ -n "$JOBS_OPT" ]; then JOBS="$JOBS_OPT"
elif [[ "${JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then :
else JOBS="$(_default_jobs)"; fi
[ "$(basename -- "$INSTALL_PREFIX")" = "$RUNTIME_NAME" ] || usage_error "INSTALL_PREFIX must end in /$RUNTIME_NAME (got '$INSTALL_PREFIX'; scripts/container-build.sh:28-31)"
export WINE_DEV_NAME IMAGE WINE_DEV_WORK REPO CCACHE DEV_ROOT INSTALL_PREFIX JOBS

WINE_SRC="$WINE_DEV_WORK/wine-src"
BUILD_DIR="$WINE_DEV_WORK/build"
STAGE="$WINE_DEV_WORK/stage"
STAGE_ROOT="$STAGE$INSTALL_PREFIX"
PIPEASIO_SRC="$WINE_DEV_WORK/pipeasio"
MARK_DIR="$WINE_DEV_WORK/.dev"            # /work/.dev inside the container: staged scripts + step markers
C_STAGE_ROOT="/work/stage$INSTALL_PREFIX"  # the stage as the container sees it

SCRATCH=""
DEV_LOCKED=0
SUMMARY_ON_EXIT=0

# ------------------------------------------------------------- helpers ----
_is_dry() { [ "${DRY_RUN:-0}" = 1 ]; }
_st() { if _is_dry; then printf 'dry-run\n'; else printf 'ok\n'; fi; }
_now() { printf '%(%s)T\n' -1; }
_scratch() {
    if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH" ]; then
        SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wine-dev.XXXXXX")" || die "cannot create a temporary directory"
    fi
    printf '%s\n' "$SCRATCH"
}

# one plain line in the "command output" style (indented bar), terminal + log
_lines() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$(now_hms)" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        _log_file "[$(now_hms)]     $G_BAR $line"
    done
}

_log_open() {   # _log_open CMD — per-invocation log under ~/.local/state/profiler/dev/
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p -- "$DEV_STATE" 2>/dev/null || true
    log_init "$DEV_STATE/wine-dev-$ts-$1.log"
    # log_init refreshes <dir>/setup-latest.log unconditionally; in our private
    # directory that name is wrong, so replace it with wine-dev-latest.log.
    rm -f -- "$DEV_STATE/setup-latest.log" 2>/dev/null || true
    [ -z "$LOGFILE" ] || ln -sfn -- "$(basename -- "$LOGFILE")" "$DEV_STATE/wine-dev-latest.log" 2>/dev/null || true
    SUMMARY_ON_EXIT=1
}

_banner() {
    printf '%s%sWine dev loop — %s%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET" "$C_DIM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$C_RESET" >&"$LOG_FD"
    _log_file "Wine dev loop — $1"
    kv "container" "$WINE_DEV_NAME ($IMAGE)"
    kv "work tree" "$WINE_DEV_WORK"
    kv "repo" "$REPO"
    kv "ccache" "$CCACHE"
    kv "dev runtime" "$DEV_ROOT"
    kv "official runtime" "$OFFICIAL_ROOT"
    kv "jobs" "$JOBS"
    kv "log" "${LOGFILE:-(none)}"
    ! _is_dry || info "dry run: commands are printed, nothing is changed"
}

_record() {   # _record NAME TEXT — timestamped marker in ~/.local/state/profiler/dev/
    _is_dry && return 0
    mkdir -p -- "$DEV_STATE" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$DEV_STATE/$1" 2>/dev/null || true
}

_confirm() {   # _confirm PROMPT → 0 to proceed
    local answer
    if [ "$ASSUME_YES" = 1 ]; then info "$1 — yes (--yes)"; return 0; fi
    if _is_dry; then info "$1 — continuing (dry run)"; return 0; fi
    if ! { : < /dev/tty; } 2>/dev/null; then fail "$1 — no terminal to confirm on; pass --yes"; return 1; fi
    printf '%s%s%s %s [y/N] %s' "$C_BOLD" "$C_CYAN" "$G_STEP" "$1" "$C_RESET" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
    _log_file "[$(now_hms)]   $G_STEP $1 [y/N] $answer"
    case "$answer" in y|Y|yes|YES) return 0 ;; *) info "cancelled"; return 1 ;; esac
}

_check_tools() {   # hard failure, except under --dry-run (previews must work before setup installed podman)
    local c missing=()
    for c in "$@"; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ "${#missing[@]}" -gt 0 ] || return 0
    if _is_dry; then warn "missing command(s): ${missing[*]} (dry run continues; setup phases 'packages'/'podman' install them)"; return 0; fi
    fail "missing command(s): ${missing[*]} (setup-machine.sh phases 'packages'/'podman' install them)"
    return 1
}

_check_repo() {
    local f
    for f in Containerfile vendor/wine-base-5c23dd1c.tar.zst vendor/wine-base.sha256 vendor/pipeasio-1.5.0.tar.gz patches/SERIES.sha256 scripts/container-build.sh; do
        [ -e "$REPO/$f" ] || { fail "$REPO does not look like the ableton-linux checkout (missing $f); set REPO="; return 1; }
    done
    return 0
}

# --------------------------------------------------------------- locks ----
_lock_dev() {
    mkdir -p -- "$STATE_DIR" 2>/dev/null || true
    if ! command -v flock >/dev/null 2>&1; then warn "flock not found: the wine-dev lock is not enforced"; return 0; fi
    exec 9>>"$DEV_LOCK" || { warn "cannot open $DEV_LOCK; the wine-dev lock is not enforced"; return 0; }
    if ! flock -n 9; then
        die "another wine-dev.sh is running ($(tr '\n' ' ' < "$DEV_BUSY" 2>/dev/null || echo 'details unknown')); wait for it or check  wine-dev.sh logs" 2
    fi
    printf 'pid=%s\ncmd=%s\nstarted=%s\nlog=%s\n' "$$" "$CMD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOGFILE:-}" > "$DEV_BUSY" 2>/dev/null || true
    DEV_LOCKED=1
}
_unlock_dev() {
    [ "$DEV_LOCKED" = 1 ] || return 0
    rm -f -- "$DEV_BUSY" 2>/dev/null || true
    DEV_LOCKED=0
}
_official_build_running() {   # 0 when build-official.sh holds its lock
    command -v flock >/dev/null 2>&1 || return 1
    [ -e "$OFFICIAL_LOCK" ] || return 1
    ! ( exec 8>>"$OFFICIAL_LOCK" && flock -n 8 ) 2>/dev/null
}

# ---------------------------------------------------- runtime processes ----
_runtime_pids() {   # _runtime_pids ROOT… → "pid<TAB>exe" for every process whose exe lives under a root
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
_refuse_if_runtime_busy() {   # _refuse_if_runtime_busy ROOT…
    local busy pid exe
    busy="$(_runtime_pids "$@")"
    [ -n "$busy" ] || return 0
    fail "processes are still running from the runtime(s) — refusing to replace files under them:" || true
    while IFS=$'\t' read -r pid exe; do [ -n "$pid" ] && kv "pid $pid" "$exe"; done <<< "$busy"
    info "quit Live (File > Quit / liveinject.exe ctrlq) and wait for wineserver to exit; then re-run"
    return 1
}

# -------------------------------------------------------------- podman ----
_podman_state() { podman inspect -f '{{.State.Status}}' "$WINE_DEV_NAME" 2>/dev/null || printf 'absent\n'; }

_require_container() {
    local st
    st="$(_podman_state)"
    case "$st" in
        running) return 0 ;;
        absent)
            if _is_dry; then info "(dry run) the container would be created and started"; return 0; fi
            fail "container '$WINE_DEV_NAME' does not exist: run  wine-dev.sh init"; return 1 ;;
        *)
            step "starting container $WINE_DEV_NAME (was $st)"
            run -- podman start "$WINE_DEV_NAME" || return 1 ;;
    esac
}

# _cexec [--root] [--quiet] -- SCRIPT   run SCRIPT with `bash -c` inside the container.
# Never `bash -l`: Ubuntu's /etc/profile resets PATH and would drop /usr/lib/ccache-shims.
_cexec() {
    local -a popts=() ropts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --root) popts+=(--user root) ;;
            --quiet) ropts+=(--quiet) ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done
    run "${ropts[@]}" -- podman exec "${popts[@]}" -e "JOBS=$JOBS" -w /work "$WINE_DEV_NAME" bash -c "$*"
}

_stage_scripts() {   # copy container/*.sh into /work/.dev so podman exec can run them (run gives no stdin)
    local f
    for f in init.sh pipeasio-init.sh; do
        [ -r "$DEV_DIR/container/$f" ] || { fail "missing $DEV_DIR/container/$f"; return 1; }
        if [ -f "$MARK_DIR/$f" ] && cmp -s -- "$DEV_DIR/container/$f" "$MARK_DIR/$f"; then continue; fi
        run --quiet -- install -D -m 0755 -- "$DEV_DIR/container/$f" "$MARK_DIR/$f" || return 1
    done
    return 0
}

_container_create() {
    local relabel=""
    [ -f /sys/fs/selinux/enforce ] && relabel=",Z"     # build.sh:130-131
    step "creating container $WINE_DEV_NAME from $IMAGE"
    run -- podman create --name "$WINE_DEV_NAME" --userns=keep-id --init -w /work \
        -v "$WINE_DEV_WORK:/work:rw$relabel" \
        -v "$REPO:/src:ro$relabel" \
        -v "$CCACHE:/ccache:rw$relabel" \
        -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE=5G \
        -e "JOBS=$JOBS" -e "INSTALL_PREFIX=$INSTALL_PREFIX" -e HOME=/work \
        --label profiler.wine-dev=1 \
        "$IMAGE" sleep infinity
}

_container_check_mounts() {
    local mounts want src dst
    mounts="$(podman inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}' "$WINE_DEV_NAME" 2>/dev/null)" || return 0
    for want in "$WINE_DEV_WORK:/work" "$REPO:/src" "$CCACHE:/ccache"; do
        src="$(readlink -f -- "${want%%:*}" 2>/dev/null || printf '%s' "${want%%:*}")"
        dst="${want#*:}"
        if ! grep -qxF -- "$src:$dst" <<< "$mounts" && ! grep -qxF -- "$want" <<< "$mounts"; then
            warn "container $WINE_DEV_NAME does not mount $want (it has: $(tr '\n' ' ' <<< "$mounts")) — run  wine-dev.sh reset --keep-work  and init again"
        fi
    done
}

# The official build (running as root inside its container) links the configure
# prefix to the stage (container-build.sh:178-179). Our container runs as the host
# uid, which cannot write /opt, so do it as root in the container's own layer.
_opt_symlink() {
    run --quiet --allow-fail -- podman exec --user root "$WINE_DEV_NAME" sh -c "ln -sfn '$C_STAGE_ROOT' '$INSTALL_PREFIX'" \
        || warn "could not create the $INSTALL_PREFIX → stage symlink inside the container (exit $RUN_STATUS); tools fall back to relative lookup"
}

# Build the image from a minimal context: the Containerfile plus the files its
# COPY/ADD lines reference. A whole-repository context would drag .ccache (GBs),
# dist/ and node_modules into podman's context copy; build.sh avoids that with
# its git snapshot, this is the equivalent for the dev loop.
_image_build() {
    local ctx line src a rel
    local -a srcs=() words=()
    step "building image $IMAGE from $REPO/Containerfile (first time only, ~10 min, needs network: snapshot.ubuntu.com, apt.llvm.org, docker.io)"
    ( cd "$REPO/vendor" && sha256sum -c --quiet llvm-apt-key.sha256 ntsync-uapi.sha256 pipewire-sdk.sha256 ) \
        || { fail "vendored image inputs do not match their checksums (vendor/*.sha256)"; return 1; }
    ok "vendored image inputs verified"
    while IFS= read -r line; do
        read -r -a words <<< "$line"
        [ "${#words[@]}" -ge 3 ] || continue
        unset 'words[0]' 'words[-1]'
        for a in "${words[@]}"; do case "$a" in --*) ;; *) srcs+=("$a") ;; esac; done
    done < <(grep -E '^(COPY|ADD)[[:space:]]' "$REPO/Containerfile")
    [ "${#srcs[@]}" -gt 0 ] || { fail "no COPY/ADD sources found in $REPO/Containerfile"; return 1; }
    if _is_dry; then
        info "would assemble a build context with Containerfile + ${srcs[*]}"
        run -- podman build -t "$IMAGE" -f "$REPO/Containerfile" "<minimal-context>"
        return 0
    fi
    mkdir -p -- "$CACHE_DIR" || { fail "cannot create $CACHE_DIR"; return 1; }
    ctx="$(mktemp -d "$CACHE_DIR/image-context.XXXXXX")" || { fail "mktemp failed"; return 1; }
    install -m 0644 -- "$REPO/Containerfile" "$ctx/Containerfile"
    for src in "${srcs[@]}"; do
        for a in "$REPO"/$src; do
            [ -e "$a" ] || { fail "Containerfile references $src, which is missing from $REPO"; rm -rf -- "$ctx"; return 1; }
            rel="${a#"$REPO"/}"
            mkdir -p -- "$ctx/$(dirname -- "$rel")"
            cp -a -- "$a" "$ctx/$rel"
        done
    done
    kv "context" "$ctx ($(du -sh -- "$ctx" 2>/dev/null | cut -f1))"
    if run -- podman build -t "$IMAGE" -f "$ctx/Containerfile" "$ctx"; then
        rm -rf -- "$ctx"
        ok "image $IMAGE built"
        return 0
    fi
    rm -rf -- "$ctx"
    return 1
}

# ---------------------------------------------------------- tree facts ----
_wine_head() { git -C "$WINE_SRC" log -1 --format='%h %s' 2>/dev/null || printf 'unknown\n'; }
_wine_dirty() { git -C "$WINE_SRC" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }
_wine_since() { git -C "$WINE_SRC" rev-list --count "$SERIES_TAG..HEAD" 2>/dev/null || printf '?\n'; }
_wine_tag_ok() { git -C "$WINE_SRC" rev-parse -q --verify "refs/tags/$SERIES_TAG" >/dev/null 2>&1; }

# patches/ changed since init? prints the differing file names (empty = no drift)
_series_drift() {
    [ -r "$MARK_DIR/series.sha256" ] || return 0
    diff <(sort -k2 -- "$MARK_DIR/series.sha256") \
         <(cd "$REPO/patches" 2>/dev/null && sha256sum [0-9][0-9][0-9][0-9]-*.patch performance/*.patch 2>/dev/null | sort -k2) 2>/dev/null \
        | awk '/^[<>]/ {print $3}' | sort -u | tr '\n' ' '
}
_warn_series_drift() {
    local drift
    drift="$(_series_drift)"
    [ -z "$drift" ] || warn "patches/ changed since init (${drift% }): the dev tree does not contain them — wine-dev.sh apply PATCH, or init --force"
}

_launch_hint() {
    info "launch Live on the dev runtime:"
    info "  ABLETON_WINE_ROOT=$DEV_ROOT WINE_X=1 $REPO/profiler/bin/with-session-env $REPO/scripts/ableton-live SET.als"
    info "  A/B: WINE_X=0 vs WINE_X=1 on this one runtime; a 'keep' needs profiler/dev/build-official.sh"
}

# ================================================================= init ====
_init_step() {   # _init_step STEP — one step of container/init.sh, with a summary row
    local s="$1" t0
    t0="$(_now)"
    step "wine: $s"
    if _cexec -- "bash /work/.dev/init.sh $s"; then
        summary_add "wine-$s" "$(_st)" $(( $(_now) - t0 ))
        return 0
    fi
    summary_add "wine-$s" failed $(( $(_now) - t0 ))
    return 1
}

cmd_init() {
    local force=0 no_build=0 st t0 s
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1 ;;
            --no-build) no_build=1 ;;
            *) usage_error "init: unknown option $1" ;;
        esac
        shift
    done
    _log_open init
    _lock_dev
    _banner "init"

    section 1 6 "checks"
    _check_tools podman git cmp sha256sum || die "cannot continue" 2
    _check_repo || die "cannot continue" 2
    if _official_build_running; then
        die "build-official.sh is running (lock $OFFICIAL_LOCK); it shares the image tag and the ccache — wait for it" 2
    fi
    ok "repository $REPO ($(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo 'not a git checkout'))"
    [ -d "$WINE_DEV_WORK" ] || info "work tree $WINE_DEV_WORK will be created (plain directory; ~6 GB after the build)"

    section 2 6 "image"
    if podman image exists "$IMAGE" 2>/dev/null; then
        ok "image $IMAGE present"
        summary_add image skipped 0 "present"
    else
        t0="$(_now)"
        _image_build || { summary_add image failed $(( $(_now) - t0 )); return 1; }
        summary_add image "$(_st)" $(( $(_now) - t0 ))
    fi

    section 3 6 "container"
    run -- mkdir -p -- "$WINE_DEV_WORK" "$CCACHE" "$MARK_DIR" || return 1
    st="$(_podman_state)"
    if [ "$st" = absent ]; then
        _container_create || return 1
    else
        info "container $WINE_DEV_NAME exists ($st)"
        _container_check_mounts
    fi
    _require_container || return 1
    _opt_symlink
    if [ "$force" -eq 1 ] && [ -e "$WINE_SRC" ]; then
        _confirm "--force: delete $WINE_SRC, $BUILD_DIR, $STAGE and $PIPEASIO_SRC and redo everything?" || return 1
        run -- rm -rf -- "$WINE_SRC" "$BUILD_DIR" "$STAGE" "$PIPEASIO_SRC" || return 1
        run -- sh -c 'rm -f -- "$1"/*.done "$1"/*.sha256' wine-dev "$MARK_DIR" || return 1
    fi
    _stage_scripts || return 1
    summary_add container "$(_st)" 0 "$WINE_DEV_NAME"

    section 4 6 "wine source + patch series"
    for s in unpack series; do _init_step "$s" || return 1; done

    section 5 6 "configure + build"
    _init_step configure || return 1
    if [ "$no_build" -eq 1 ]; then
        info "--no-build: stopping before make (run  wine-dev.sh build  later)"
    else
        for s in build install; do _init_step "$s" || return 1; done
    fi

    section 6 6 "checks"
    if [ "$no_build" -eq 1 ]; then
        skip "post-build checks (no build)"
    else
        _init_step check || return 1
        _record last-build "init"
    fi
    ok "wine-dev ready: $WINE_SRC ($(_wine_head))"
    info "next: edit the tree, then  wine-dev.sh build [--dir dlls/ntdll]  and  wine-dev.sh sync"
    info "PipeASIO: wine-dev.sh pipeasio-init && wine-dev.sh pipeasio-build"
}

# ================================================================ apply ====
cmd_apply() {
    local abort=0 p real tmp t0
    local -a patches=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --abort) abort=1 ;;
            -*) usage_error "apply: unknown option $1" ;;
            *) patches+=("$1") ;;
        esac
        shift
    done
    _log_open apply
    _lock_dev
    _banner "apply"
    [ -d "$WINE_SRC/.git" ] || die "no dev tree at $WINE_SRC — run  wine-dev.sh init" 2
    if [ "$abort" -eq 1 ]; then
        step "git am --abort"
        run -- git -C "$WINE_SRC" am --abort || return 1
        summary_add abort "$(_st)" 0
        ok "HEAD: $(_wine_head)"
        return 0
    fi
    [ "${#patches[@]}" -gt 0 ] || usage_error "apply: give at least one patch file (or --abort)"
    _wine_tag_ok || warn "tag $SERIES_TAG is missing: the series step of init did not complete"
    for p in "${patches[@]}"; do
        [ -f "$p" ] || { fail "no such patch file: $p"; return 1; }
        real="$(readlink -f -- "$p")"
        t0="$(_now)"
        step "git am --3way $(basename -- "$p")"
        # container-build.sh:156-164: patches without mail headers get a fixed neutral ident
        if head -8 -- "$real" | grep -q '^From: '; then
            tmp="$real"
        else
            tmp="$(mktemp "$(_scratch)/patch.XXXXXX")"
            { printf 'From: dist <build@localhost>\nDate: Thu, 01 Jan 2026 00:00:00 +0000\n'; cat -- "$real"; } > "$tmp"
            info "no From:/Date: header — synthetic 'From: dist <build@localhost>' prepended (as the build does)"
        fi
        if run -- git -C "$WINE_SRC" -c user.email=build@localhost -c user.name=dist am --3way "$tmp"; then
            summary_add "$(basename -- "$p")" "$(_st)" $(( $(_now) - t0 ))
        else
            summary_add "$(basename -- "$p")" failed $(( $(_now) - t0 ))
            info "resolve the conflicts in $WINE_SRC, then: git -C $WINE_SRC am --continue   — or: wine-dev.sh apply --abort"
            return 1
        fi
    done
    ok "HEAD: $(_wine_head) ($(_wine_since) commit(s) since $SERIES_TAG)"
    info "next: wine-dev.sh build && wine-dev.sh sync"
}

# ================================================================= edit ====
cmd_edit() {
    local path_only=0
    while [ $# -gt 0 ]; do
        case "$1" in --path) path_only=1 ;; *) usage_error "edit: unknown option $1" ;; esac
        shift
    done
    if [ "$path_only" -eq 1 ]; then printf '%s\n' "$WINE_SRC"; return 0; fi
    kv "wine source" "$WINE_SRC"
    if [ -d "$WINE_SRC/.git" ]; then
        kv "HEAD" "$(_wine_head)"
        kv "since $SERIES_TAG" "$(_wine_since) commit(s), $(_wine_dirty) uncommitted change(s)"
    else
        kv "state" "absent — run  wine-dev.sh init"
    fi
    kv "build dir" "$BUILD_DIR"
    kv "stage" "$STAGE_ROOT"
    kv "pipeasio source" "$PIPEASIO_SRC"
    kv "dev runtime" "$DEV_ROOT"
    info "loop: edit → wine-dev.sh build [--dir dlls/ntdll] → wine-dev.sh sync [--artifacts --dir dlls/ntdll] → launch (below)"
    info "commit on the host (one commit per patch; format-patch exports HEAD):"
    info "  git -C $WINE_SRC add -A && git -C $WINE_SRC -c user.name=dist -c user.email=build@localhost commit -m 'ntdll: ...'"
    info "PE probes against this tree:"
    info "  ABLETON_WINE_SOURCE=$WINE_SRC ABLETON_WINE_BUILD=$BUILD_DIR $REPO/tools/build_apcprobe.sh"
    _launch_hint
}

# ================================================================ build ====
cmd_build() {
    local install_mode="" d t0 targets=""
    local -a dirs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) [ $# -ge 2 ] || usage_error "--dir needs a directory"; dirs+=("$2"); shift ;;
            --dir=*) dirs+=("${1#*=}") ;;
            --install) install_mode=yes ;;
            --no-install) install_mode=no ;;
            *) usage_error "build: unknown option $1" ;;
        esac
        shift
    done
    _log_open build
    _lock_dev
    _banner "build"
    _check_tools podman || die "cannot continue" 2
    [ -f "$BUILD_DIR/Makefile" ] || _is_dry || die "no configured build at $BUILD_DIR — run  wine-dev.sh init" 2
    for d in "${dirs[@]}"; do
        d="${d%/}"
        case "$d" in /*|*..*|"") usage_error "--dir must be a relative path inside the build tree (got '$d')" ;; esac
        [ -d "$BUILD_DIR/$d" ] || _is_dry || die "no such build directory: $BUILD_DIR/$d" 2
        targets="$targets ${d}/all"
    done
    if [ -z "$install_mode" ]; then
        if [ "${#dirs[@]}" -eq 0 ]; then install_mode=yes; else install_mode=no; fi
    fi
    ! _official_build_running || warn "build-official.sh is running: both builds share the CPU and the ccache (safe, but slower)"
    _warn_series_drift
    _require_container || return 1
    kv "tree" "$(_wine_head), $(_wine_dirty) uncommitted change(s)"

    section 1 2 "make"
    t0="$(_now)"
    step "make -j$JOBS${targets:- (whole tree)}"
    if _cexec -- "set -euo pipefail; cd /work/build && make -j\"\$JOBS\"$targets"; then
        summary_add make "$(_st)" $(( $(_now) - t0 )) "${targets:-whole tree}"
    else
        summary_add make failed $(( $(_now) - t0 ))
        return 1
    fi

    section 2 2 "install into the stage"
    if [ "$install_mode" = yes ]; then
        t0="$(_now)"
        step "make install DESTDIR=/work/stage"
        if _cexec -- "set -euo pipefail; cd /work/build && make install DESTDIR=/work/stage"; then
            summary_add install "$(_st)" $(( $(_now) - t0 ))
        else
            summary_add install failed $(( $(_now) - t0 ))
            return 1
        fi
        _record last-build "build${targets}"
        ok "stage updated: $STAGE_ROOT"
        info "next: wine-dev.sh sync"
    else
        skip "make install (Wine has no per-directory install target; the stage is unchanged)"
        _record last-build "build${targets} (no install)"
        info "next: wine-dev.sh sync --artifacts${dirs[*]:+ --dir ${dirs[*]}}   (copies the built modules into the stage and the dev runtime)"
        info "      or  wine-dev.sh build --install  for a full make install"
    fi
}

# ============================================================= pipeasio ====
_pipeasio_step() {   # _pipeasio_step STEP
    local s="$1" t0
    t0="$(_now)"
    step "pipeasio: $s"
    if _cexec -- "bash /work/.dev/pipeasio-init.sh $s"; then
        summary_add "pipeasio-$s" "$(_st)" $(( $(_now) - t0 ))
        return 0
    fi
    summary_add "pipeasio-$s" failed $(( $(_now) - t0 ))
    return 1
}

cmd_pipeasio_init() {
    local s
    [ $# -eq 0 ] || usage_error "pipeasio-init takes no options"
    _log_open pipeasio-init
    _lock_dev
    _banner "pipeasio-init"
    _check_tools podman || die "cannot continue" 2
    _check_repo || die "cannot continue" 2
    [ -x "$STAGE_ROOT/bin/winebuild" ] && [ -x "$STAGE_ROOT/bin/winegcc" ] || _is_dry \
        || die "the stage has no winebuild/winegcc at $STAGE_ROOT/bin — run  wine-dev.sh init  (full build) first" 2
    _require_container || return 1
    _stage_scripts || return 1
    section 1 1 "pipeasio source, series, configure"
    for s in unpack series configure; do _pipeasio_step "$s" || return 1; done
    ok "PipeASIO configured at $PIPEASIO_SRC/build"
    info "next: wine-dev.sh pipeasio-build [--test]"
}

cmd_pipeasio_build() {
    local test=0 s
    while [ $# -gt 0 ]; do
        case "$1" in --test) test=1 ;; *) usage_error "pipeasio-build: unknown option $1" ;; esac
        shift
    done
    _log_open pipeasio-build
    _lock_dev
    _banner "pipeasio-build"
    _check_tools podman || die "cannot continue" 2
    [ -d "$PIPEASIO_SRC/build" ] || _is_dry || die "PipeASIO is not configured — run  wine-dev.sh pipeasio-init" 2
    _require_container || return 1
    _stage_scripts || return 1
    section 1 1 "pipeasio build"
    _pipeasio_step build || return 1
    [ "$test" -eq 0 ] || _pipeasio_step test || return 1
    _pipeasio_step install || return 1
    _record last-build "pipeasio-build"
    ok "PipeASIO installed into the stage"
    info "next: wine-dev.sh sync"
}

# ================================================================= sync ====
_artifacts_to_stage() {   # _artifacts_to_stage DIR… — copy built modules from /work/build/DIR into the stage
    local d arch f dst n=0
    shopt -s nullglob
    for d in "$@"; do
        d="${d%/}"
        case "$d" in
            server)
                for f in "$BUILD_DIR/server/wineserver"; do
                    run --quiet -- install -m 0755 -- "$f" "$STAGE_ROOT/bin/wineserver" || { shopt -u nullglob; return 1; }
                    n=$(( n + 1 )); kv "bin/wineserver" "← server/wineserver"
                done ;;
            loader)
                for f in "$BUILD_DIR"/loader/wine "$BUILD_DIR"/loader/wine-preloader; do
                    run --quiet -- install -m 0755 -- "$f" "$STAGE_ROOT/bin/$(basename -- "$f")" || { shopt -u nullglob; return 1; }
                    n=$(( n + 1 )); kv "bin/$(basename -- "$f")" "← loader/$(basename -- "$f")"
                done ;;
            *)
                for arch in "$BUILD_DIR/$d"/*-windows "$BUILD_DIR/$d"/*-unix; do
                    [ -d "$arch" ] || continue
                    for f in "$arch"/*.dll "$arch"/*.so "$arch"/*.exe "$arch"/*.sys "$arch"/*.drv "$arch"/*.cpl "$arch"/*.ocx "$arch"/*.acm "$arch"/*.ax; do
                        [ -f "$f" ] || continue
                        dst="$STAGE_ROOT/lib/wine/$(basename -- "$arch")/$(basename -- "$f")"
                        run --quiet -- install -m 0644 -- "$f" "$dst" || { shopt -u nullglob; return 1; }
                        n=$(( n + 1 )); kv "lib/wine/$(basename -- "$arch")/$(basename -- "$f")" "← $d/$(basename -- "$arch")"
                    done
                done ;;
        esac
    done
    shopt -u nullglob
    if [ "$n" -eq 0 ] && ! _is_dry; then
        fail "no built modules found under $BUILD_DIR for: $* (expected DIR/<arch>-windows/*.dll, DIR/<arch>-unix/*.so)"
        return 1
    fi
    ok "$n module(s) copied into the stage"
}

# container-build.sh:607-610, applied to the stage (the next make install re-installs unstripped files)
_stage_strip() {
    step "stripping the stage like the official build (llvm-strip --strip-all PE, strip --strip-unneeded unix)"
    _cexec -- "set -euo pipefail; P='$C_STAGE_ROOT'
find \"\$P/lib/wine\" -type f \\( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.cpl' -o -name '*.ocx' \\) -exec llvm-strip --strip-all {} +
strip --strip-unneeded \"\$P\"/lib/wine/*-unix/*.so
for f in \"\$P\"/bin/*; do strip --strip-unneeded \"\$f\" 2>/dev/null || true; done"
}

_write_dev_info() {   # _write_dev_info STRIPPED MODE
    local tmp head dirty since pa official_version
    head="$(git -C "$WINE_SRC" log -1 --format='%H %s' 2>/dev/null || echo unknown)"
    dirty="$(_wine_dirty)"
    since="$(git -C "$WINE_SRC" log --format='  %h %s' "$SERIES_TAG..HEAD" 2>/dev/null || true)"
    pa="$(git -C "$PIPEASIO_SRC" log -1 --format='%H %s' 2>/dev/null || echo none)"
    official_version="$(sed -n 's/^dist-version: *//p' "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null | head -n1)"
    tmp="$(mktemp "$(_scratch)/dev-info.XXXXXX")"
    {
        printf '# PROFILER-DEV-INFO.txt — written by profiler/dev/wine-dev.sh sync.\n'
        printf '# This runtime is a DEVELOPMENT build (unofficial): ABLETON-WINE-BUILD-INFO.txt here\n'
        printf '# still describes the official runtime it was seeded from, not these binaries.\n'
        printf 'synced=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'source=%s\n' "$WINE_SRC"
        printf 'head=%s\n' "$head"
        printf 'dirty=%s\n' "$([ "$dirty" = 0 ] && echo no || echo "yes ($dirty uncommitted change(s))")"
        printf 'series_tag=%s %s\n' "$SERIES_TAG" "$(git -C "$WINE_SRC" rev-parse -q --verify "refs/tags/$SERIES_TAG" 2>/dev/null || echo missing)"
        printf 'commits_since_series=%s\n' "$(_wine_since)"
        [ -z "$since" ] || printf '%s\n' "$since"
        printf 'pipeasio_head=%s\n' "$pa"
        printf 'stripped=%s\n' "$1"
        printf 'mode=%s\n' "$2"
        printf 'jobs=%s\n' "$JOBS"
        printf 'seeded_from=%s%s\n' "$OFFICIAL_ROOT" "${official_version:+ (dist-version $official_version)}"
    } > "$tmp"
    run --quiet -- install -m 0644 -- "$tmp" "$DEV_ROOT/PROFILER-DEV-INFO.txt" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok "wrote $DEV_ROOT/PROFILER-DEV-INFO.txt (head ${head%% *}, dirty=$dirty, stripped=$1)"
}

cmd_sync() {
    local strip=0 artifacts=0 fast=0 t0 changes n mode="stage-rsync"
    local -a dirs=() rsync_opts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --strip) strip=1 ;;
            --artifacts) artifacts=1 ;;
            --dir) [ $# -ge 2 ] || usage_error "--dir needs a directory"; dirs+=("$2"); shift ;;
            --dir=*) dirs+=("${1#*=}") ;;
            --fast) fast=1 ;;
            *) usage_error "sync: unknown option $1" ;;
        esac
        shift
    done
    [ "$artifacts" -eq 1 ] || [ "${#dirs[@]}" -eq 0 ] || usage_error "sync: --dir only makes sense with --artifacts"
    _log_open sync
    _lock_dev
    _banner "sync"
    _check_tools rsync cp install || die "cannot continue" 2
    if _official_build_running; then
        die "build-official.sh is running: it replaces $OFFICIAL_ROOT (the seed of the dev runtime) — wait for it" 2
    fi

    section 1 4 "safety"
    _refuse_if_runtime_busy "$OFFICIAL_ROOT" "$DEV_ROOT" || return 1
    ok "no process runs from $OFFICIAL_ROOT or $DEV_ROOT"
    [ -x "$STAGE_ROOT/bin/wine" ] || _is_dry || die "no staged Wine at $STAGE_ROOT — run  wine-dev.sh init  (or build --install)" 2
    _warn_series_drift
    kv "tree" "$(_wine_head), $(_wine_dirty) uncommitted change(s), $(_wine_since) commit(s) since $SERIES_TAG"

    section 2 4 "dev runtime"
    if [ -d "$DEV_ROOT" ]; then
        ok "dev runtime exists at $DEV_ROOT"
    else
        if [ ! -x "$OFFICIAL_ROOT/bin/wine" ]; then
            _is_dry || die "no official runtime at $OFFICIAL_ROOT to seed the dev runtime (setup phase 'install' or build-official.sh first)" 2
            warn "no official runtime at $OFFICIAL_ROOT yet (dry run continues)"
        fi
        t0="$(_now)"
        step "seeding $DEV_ROOT from $OFFICIAL_ROOT (cp -a --reflink=auto: instant on btrfs)"
        run -- cp -a --reflink=auto -- "$OFFICIAL_ROOT" "$DEV_ROOT" || return 1
        summary_add seed "$(_st)" $(( $(_now) - t0 ))
        ! _is_dry || info "(dry run) the following steps assume the seed exists"
    fi

    section 3 4 "stage"
    if [ "$artifacts" -eq 1 ]; then
        mode="artifacts"
        [ "${#dirs[@]}" -gt 0 ] || dirs=(dlls/ntdll)
        step "copying built modules from $BUILD_DIR/{${dirs[*]}} into the stage"
        _artifacts_to_stage "${dirs[@]}" || return 1
        summary_add artifacts "$(_st)" 0 "${dirs[*]}"
    fi
    if [ "$strip" -eq 1 ]; then
        _require_container || return 1
        t0="$(_now)"
        _stage_strip || { summary_add strip failed $(( $(_now) - t0 )); return 1; }
        summary_add strip "$(_st)" $(( $(_now) - t0 ))
    fi

    section 4 4 "copy"
    rsync_opts=(-a --itemize-changes --exclude 'ABLETON-WINE-*.txt' --exclude '.ableton-linux-runtime' --exclude 'PROFILER-DEV-INFO.txt')
    [ "$fast" -eq 1 ] || rsync_opts+=(--checksum)
    t0="$(_now)"
    if [ -d "$DEV_ROOT" ] && [ -d "$STAGE_ROOT" ]; then
        step "comparing $STAGE_ROOT with $DEV_ROOT ($([ "$fast" -eq 1 ] && echo 'size+mtime' || echo 'checksums'))"
        changes="$(rsync "${rsync_opts[@]}" --dry-run -- "$STAGE_ROOT/" "$DEV_ROOT/" 2>/dev/null | grep -E '^[>ch*]' || true)"
        n="$(printf '%s' "$changes" | grep -c . || true)"
        if [ "$n" -eq 0 ]; then
            ok "dev runtime already matches the stage"
        else
            info "$n file(s) to update$([ "$n" -gt 40 ] && echo ' (first 40 shown)'):"
            printf '%s\n' "$changes" | head -n 40 | _lines
        fi
    else
        n="?"
        info "(dry run) nothing to compare yet"
    fi
    if [ "$n" != 0 ]; then
        step "rsync stage → dev runtime"
        run --quiet -- rsync "${rsync_opts[@]}" -- "$STAGE_ROOT/" "$DEV_ROOT/" || { summary_add rsync failed $(( $(_now) - t0 )); return 1; }
    fi
    summary_add rsync "$(_st)" $(( $(_now) - t0 )) "$n file(s)"
    if ! _is_dry; then
        [ -x "$DEV_ROOT/bin/wine" ] && [ -x "$DEV_ROOT/bin/wineserver" ] || { fail "dev runtime is incomplete: bin/wine or bin/wineserver missing under $DEV_ROOT"; return 1; }
    fi
    _write_dev_info "$([ "$strip" -eq 1 ] && echo yes || echo no)" "$mode" || return 1
    _record last-sync "$mode${dirs[*]:+ ${dirs[*]}}"
    ok "dev runtime at $DEV_ROOT is up to date"
    _launch_hint
}

# ========================================================= format-patch ====
_slug() {
    local s="${1,,}"
    s="${s//[^a-z0-9]/-}"
    while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
    s="${s#-}"; s="${s%-}"
    printf '%s\n' "${s:0:60}"
}
_next_number() {   # _next_number DIR → highest NNNN + 1
    local f n max=0
    for f in "$1"/[0-9][0-9][0-9][0-9]-*.patch; do
        [ -e "$f" ] || continue
        n="${f##*/}"; n="${n%%-*}"; n=$(( 10#$n ))
        [ "$n" -le "$max" ] || max="$n"
    done
    printf '%04d\n' $(( max + 1 ))
}
_audit_line() {   # _audit_line REGEX DEFAULT → line number in scripts/build-audit.sh
    local n
    n="$(grep -n -m1 -- "$1" "$REPO/scripts/build-audit.sh" 2>/dev/null | cut -d: -f1 || true)"
    printf '%s\n' "${n:-$2}"
}

cmd_format_patch() {
    local number="" name="" pipeasio=0 outdir="" force=0 src tag file subject count dirty tmp
    local wt pt fp so tail_var label
    while [ $# -gt 0 ]; do
        case "$1" in
            --number) [ $# -ge 2 ] || usage_error "--number needs a value"; number="$2"; shift ;;
            --number=*) number="${1#*=}" ;;
            --name) [ $# -ge 2 ] || usage_error "--name needs a value"; name="$2"; shift ;;
            --name=*) name="${1#*=}" ;;
            --pipeasio) pipeasio=1 ;;
            --out) [ $# -ge 2 ] || usage_error "--out needs a directory"; outdir="$2"; shift ;;
            --out=*) outdir="${1#*=}" ;;
            --force) force=1 ;;
            *) usage_error "format-patch: unknown option $1" ;;
        esac
        shift
    done
    [ -z "$number" ] || [[ "$number" =~ ^[0-9]{4}$ ]] || usage_error "--number must be four digits (got '$number')"
    _log_open format-patch
    _lock_dev
    _banner "format-patch"
    _check_tools git || die "cannot continue" 2
    if [ "$pipeasio" -eq 1 ]; then
        src="$PIPEASIO_SRC"; tag="$PIPEASIO_TAG"; label="PipeASIO"
        : "${outdir:=$REPO/patches/pipeasio}"
        tail_var="REQUIRED_PIPEASIO_TAIL"
    else
        src="$WINE_SRC"; tag="$SERIES_TAG"; label="Wine"
        : "${outdir:=$REPO/patches}"
        tail_var="REQUIRED_WINE_TAIL"
    fi
    [ -d "$src/.git" ] || die "no $label dev tree at $src — run  wine-dev.sh $([ "$pipeasio" -eq 1 ] && echo pipeasio-)init" 2
    git -C "$src" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 || die "tag $tag is missing in $src (init did not finish its series step)" 2
    case "$outdir" in "$REPO"/*)
        if _official_build_running; then
            die "build-official.sh is running: writing into $outdir would change the source tree and abort it" 2
        fi ;;
    esac
    count="$(git -C "$src" rev-list --count "$tag..HEAD" 2>/dev/null || echo 0)"
    [ "$count" -ge 1 ] || die "no commits since $tag in $src — commit your change first (see  wine-dev.sh edit)" 2
    dirty="$(git -C "$src" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$dirty" = 0 ] || warn "$dirty uncommitted change(s) in $src are NOT exported (only HEAD is)"
    [ "$count" -eq 1 ] || warn "$count commits since $tag; only HEAD is exported — to ship one patch: git -C $src reset --soft $tag && git -C $src commit"
    subject="$(git -C "$src" log -1 --format=%s)"
    [ -n "$name" ] || name="$(_slug "$subject")"
    [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || usage_error "--name must be a slug of [a-z0-9.-] (got '$name')"
    if [ -z "$number" ]; then
        # re-exporting the same change keeps its number (refused without --force); a new slug gets the next one
        for file in "$outdir"/[0-9][0-9][0-9][0-9]-"$name".patch; do
            [ -e "$file" ] || continue
            number="${file##*/}"; number="${number%%-*}"
            break
        done
        [ -n "$number" ] || number="$(_next_number "$outdir")"
    fi
    file="$outdir/$number-$name.patch"
    if [ -e "$file" ] && [ "$force" -eq 0 ]; then die "$file exists (use --force to overwrite)" 2; fi
    kv "HEAD" "$(git -C "$src" log -1 --format='%h %s')"
    kv "patch" "$file"
    step "git format-patch -1 --no-numbered --no-signature --stat=80"
    tmp="$(mktemp "$(_scratch)/fp.XXXXXX")"
    git -C "$src" format-patch -1 --no-numbered --no-signature --stat=80 --stdout HEAD > "$tmp" \
        || { rm -f -- "$tmp"; fail "git format-patch failed"; return 1; }
    [ -s "$tmp" ] || { rm -f -- "$tmp"; fail "git format-patch produced nothing"; return 1; }
    run -- install -D -m 0644 -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    summary_add "$number-$name" "$(_st)" 0 "$label"
    ok "wrote $file"

    wt="$(_audit_line '^readonly REQUIRED_WINE_TAIL=' 13)"
    pt="$(_audit_line '^readonly REQUIRED_PIPEASIO_TAIL=' 15)"
    fp="$(_audit_line "^FINGERPRINTS='" 352)"
    so="$(_audit_line "^STAMP_ONLY='" 424)"
    printf '\n%s%sBuild-audit checklist (scripts/build-audit.sh) — the build fails its audit until this is done%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&"$LOG_FD"
    _log_file "Build-audit checklist (scripts/build-audit.sh)"
    if [ "$pipeasio" -eq 1 ]; then
        info "1. $tail_var (scripts/build-audit.sh:$pt) → 'pipeasio/$number-$name.patch'"
    else
        info "1. $tail_var (scripts/build-audit.sh:$wt) → '$number-$name.patch'"
    fi
    info "2. add a FINGERPRINTS line (scripts/build-audit.sh:$fp; patch|ascii|wide|module|literal — a distinctive string the"
    info "   change compiles into a shipped module, e.g. 0108|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_USDT_V1), or a"
    info "   STAMP_ONLY line (scripts/build-audit.sh:$so; patch|reason) for logic-only changes — else the audit says UNLISTED"
    info "3. ./scripts/build-audit.sh --freeze   (rewrites patches/SERIES.sha256 — commit it with the patch)"
    info "4. the performance series stays exactly performance/0001 (scripts/test-release-policy.sh:436): new Wine work goes"
    info "   in the main series; configure.ac changes must also patch the generated configure (no autoreconf in the build);"
    info "   wineserver protocol changes need regenerated server_protocol.h, request_handlers.h, request_trace.h"
    info "5. make test  must stay green (if VERSION changes, CHANGELOG.md's first '## ' heading must equal it)"
    info "6. every change ships behind an opt-in env switch (default off) + a PE probe in tools/ + a note in notes/"
    info "7. keep → profiler/dev/build-official.sh  (flock + ./build.sh + installer.sh runtime install --yes + audit),"
    info "   then repeat the A/B on the official runtime"
}

# ================================================================ shell ====
cmd_shell() {
    local st
    local -a tty=()
    _check_tools podman || die "cannot continue" 2
    st="$(_podman_state)"
    case "$st" in
        running) ;;
        absent) die "container '$WINE_DEV_NAME' does not exist: run  wine-dev.sh init" 2 ;;
        *) if _is_dry; then info "(dry run) would start $WINE_DEV_NAME"; else podman start "$WINE_DEV_NAME" >/dev/null || die "cannot start $WINE_DEV_NAME" 1; fi ;;
    esac
    [ -t 0 ] && [ -t 1 ] && tty=(-t)
    if _is_dry; then
        info "(dry run) would exec: podman exec -i ${tty[*]} -w /work $WINE_DEV_NAME ${*:-bash}"
        return 0
    fi
    if [ $# -eq 0 ]; then
        exec podman exec -i "${tty[@]}" -w /work -e "JOBS=$JOBS" -e "TERM=${TERM:-xterm}" "$WINE_DEV_NAME" bash
    fi
    exec podman exec -i "${tty[@]}" -w /work -e "JOBS=$JOBS" "$WINE_DEV_NAME" "$@"
}

# =============================================================== status ====
cmd_status() {
    local deep=0 st busy pid exe drift n line info_file
    while [ $# -gt 0 ]; do
        case "$1" in --deep) deep=1 ;; *) usage_error "status: unknown option $1" ;; esac
        shift
    done
    printf '%s%sWine dev loop — status%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&"$LOG_FD"
    kv "work tree" "$WINE_DEV_WORK"
    kv "repo" "$REPO$([ -d "$REPO/.git" ] && printf ' (%s)' "$(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null)")"
    kv "ccache" "$CCACHE$([ -d "$CCACHE" ] && printf ' (%s)' "$(du -sh -- "$CCACHE" 2>/dev/null | cut -f1)")"
    kv "jobs" "$JOBS"

    step "container"
    if ! command -v podman >/dev/null 2>&1; then
        warn "podman is not installed (setup-machine.sh phase 'podman')"
    else
        if podman image exists "$IMAGE" 2>/dev/null; then kv "image" "$IMAGE present"; else kv "image" "$IMAGE missing (init builds it, or ./build.sh)"; fi
        st="$(_podman_state)"
        kv "$WINE_DEV_NAME" "$st"
        [ "$st" = absent ] || _container_check_mounts
    fi

    step "wine tree"
    if [ -d "$WINE_SRC/.git" ]; then
        kv "HEAD" "$(_wine_head)"
        if _wine_tag_ok; then
            kv "since $SERIES_TAG" "$(_wine_since) commit(s)"
            git -C "$WINE_SRC" log --format='  %h %s' "$SERIES_TAG..HEAD" 2>/dev/null | head -n 10 | _lines
        else
            warn "tag $SERIES_TAG missing: the series step did not complete (run init again)"
        fi
        n="$(_wine_dirty)"
        kv "uncommitted" "$n change(s)"
        drift="$(_series_drift)"
        if [ -n "$drift" ]; then warn "patches/ changed since init: ${drift% }"; else kv "series" "matches $REPO/patches"; fi
    else
        kv "tree" "absent ($WINE_SRC) — run  wine-dev.sh init"
    fi

    step "build and stage"
    kv "configured" "$([ -f "$BUILD_DIR/include/config.h" ] && echo yes || echo no)"
    kv "staged wine" "$([ -x "$STAGE_ROOT/bin/wine" ] && echo "present ($STAGE_ROOT)" || echo absent)"
    kv "staged pipeasio" "$([ -s "$STAGE_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so" ] && echo present || echo absent)"
    if [ -d "$PIPEASIO_SRC/.git" ]; then kv "pipeasio tree" "$(git -C "$PIPEASIO_SRC" log -1 --format='%h %s' 2>/dev/null)"; else kv "pipeasio tree" "absent (pipeasio-init)"; fi
    for line in unpack series configure build install check pipeasio-configure pipeasio-install; do
        [ -f "$MARK_DIR/$line.done" ] && kv "step $line" "done $(cat "$MARK_DIR/$line.done" 2>/dev/null)"
    done
    kv "last build" "$(cat "$DEV_STATE/last-build" 2>/dev/null || echo never)"
    kv "last sync" "$(cat "$DEV_STATE/last-sync" 2>/dev/null || echo never)"
    if [ -f "$DEV_STATE/last-build" ] && [ -f "$DEV_STATE/last-sync" ] && [ "$DEV_STATE/last-build" -nt "$DEV_STATE/last-sync" ]; then
        info "the last build is newer than the last sync: run  wine-dev.sh sync"
    fi

    step "dev runtime"
    if [ -d "$DEV_ROOT" ]; then
        kv "path" "$DEV_ROOT$([ -x "$DEV_ROOT/bin/wine" ] || echo ' (INCOMPLETE: no bin/wine)')"
        info_file="$DEV_ROOT/PROFILER-DEV-INFO.txt"
        if [ -r "$info_file" ]; then
            grep -E '^(synced|head|dirty|commits_since_series|stripped|mode|seeded_from)=' "$info_file" | _lines
        else
            kv "PROFILER-DEV-INFO" "missing (never synced)"
        fi
        if [ "$deep" -eq 1 ] && [ -d "$STAGE_ROOT" ] && command -v rsync >/dev/null 2>&1; then
            n="$(rsync -a --checksum --itemize-changes --dry-run --exclude 'ABLETON-WINE-*.txt' --exclude '.ableton-linux-runtime' --exclude 'PROFILER-DEV-INFO.txt' -- "$STAGE_ROOT/" "$DEV_ROOT/" 2>/dev/null | grep -cE '^[>ch*]' || true)"
            kv "pending from stage" "$n file(s) (checksum compare)"
        fi
    else
        kv "dev runtime" "absent — wine-dev.sh sync seeds it from $OFFICIAL_ROOT"
    fi
    kv "official runtime" "$OFFICIAL_ROOT $([ -x "$OFFICIAL_ROOT/bin/wine" ] && echo "(dist-version $(sed -n 's/^dist-version: *//p' "$OFFICIAL_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null | head -n1))" || echo '(absent)')"

    step "locks and processes"
    if [ -f "$DEV_BUSY" ]; then warn "wine-dev.sh busy: $(tr '\n' ' ' < "$DEV_BUSY")"; else kv "wine-dev lock" "free"; fi
    if _official_build_running; then warn "build-official.sh is running ($OFFICIAL_LOCK)"; else kv "official build" "not running"; fi
    busy="$(_runtime_pids "$OFFICIAL_ROOT" "$DEV_ROOT")"
    if [ -n "$busy" ]; then
        warn "processes running from the runtimes (sync/build-official refuse while they run):"
        while IFS=$'\t' read -r pid exe; do [ -n "$pid" ] && kv "pid $pid" "$exe"; done <<< "$busy"
    else
        kv "runtime processes" "none"
    fi
    kv "latest log" "$(readlink -f -- "$DEV_STATE/wine-dev-latest.log" 2>/dev/null || echo none)"
    _launch_hint
}

# ================================================================= logs ====
cmd_logs() {
    local n=40 follow=0 list=0 latest
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) [ $# -ge 2 ] || usage_error "-n needs a number"; n="$2"; shift ;;
            -n*) n="${1#-n}" ;;
            --follow|-f) follow=1 ;;
            --list) list=1 ;;
            *) usage_error "logs: unknown option $1" ;;
        esac
        shift
    done
    [[ "$n" =~ ^[0-9]+$ ]] || usage_error "-n needs a number (got '$n')"
    if [ "$list" -eq 1 ]; then
        ls -1t -- "$DEV_STATE"/wine-dev-*-*.log 2>/dev/null || { printf 'no wine-dev logs under %s\n' "$DEV_STATE"; return 1; }
        return 0
    fi
    latest="$(readlink -f -- "$DEV_STATE/wine-dev-latest.log" 2>/dev/null || true)"
    [ -n "$latest" ] && [ -r "$latest" ] || { printf 'no wine-dev log yet (looked for %s)\n' "$DEV_STATE/wine-dev-latest.log" >&2; return 1; }
    printf '%s== %s ==%s\n' "$C_DIM" "$latest" "$C_RESET"
    if [ "$follow" -eq 1 ]; then exec tail -n "$n" -f -- "$latest"; fi
    tail -n "$n" -- "$latest"
}

# ================================================================ reset ====
cmd_reset() {
    local keep_work=0 runtime=0 st
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep-work) keep_work=1 ;;
            --runtime) runtime=1 ;;
            *) usage_error "reset: unknown option $1" ;;
        esac
        shift
    done
    _log_open reset
    _lock_dev
    _banner "reset"
    case "$WINE_DEV_WORK" in ""|/|"$HOME"|"$HOME/") die "refusing to reset WINE_DEV_WORK='$WINE_DEV_WORK'" 2 ;; esac
    if command -v podman >/dev/null 2>&1; then
        st="$(_podman_state)"
        if [ "$st" != absent ]; then
            _confirm "remove container $WINE_DEV_NAME ($st)?" || return 1
            run -- podman rm -f "$WINE_DEV_NAME" || return 1
            summary_add container "$(_st)" 0 removed
        else
            skip "container $WINE_DEV_NAME does not exist"
        fi
    else
        warn "podman is not installed; no container to remove"
    fi
    if [ "$keep_work" -eq 0 ] && [ -d "$WINE_DEV_WORK" ]; then
        [ -e "$MARK_DIR" ] || [ -e "$WINE_SRC" ] || warn "$WINE_DEV_WORK does not look like a wine-dev work tree (no .dev/ or wine-src/)"
        _confirm "delete $WINE_DEV_WORK (wine-src, build, stage, pipeasio — uncommitted work is lost)?" || return 1
        run -- rm -rf -- "$WINE_DEV_WORK" || return 1
        summary_add "work tree" "$(_st)" 0 removed
    elif [ "$keep_work" -eq 1 ]; then
        skip "keeping $WINE_DEV_WORK (--keep-work)"
    fi
    if [ "$runtime" -eq 1 ] && [ -d "$DEV_ROOT" ]; then
        _refuse_if_runtime_busy "$DEV_ROOT" || return 1
        _confirm "delete the dev runtime $DEV_ROOT?" || return 1
        run -- rm -rf -- "$DEV_ROOT" || return 1
        summary_add "dev runtime" "$(_st)" 0 removed
    fi
    if ! _is_dry; then
        rm -f -- "$DEV_STATE/last-build" "$DEV_STATE/last-sync" 2>/dev/null || true
    fi
    ok "reset done (image $IMAGE and ccache $CCACHE kept; podman rmi $IMAGE drops the image)"
}

# ================================================================= main ====
_on_exit() {
    local rc=$?
    _unlock_dev
    if [ "$SUMMARY_ON_EXIT" = 1 ] && [ "${#SUMMARY_NAMES[@]}" -gt 0 ]; then
        summary_table
    fi
    [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH" 2>/dev/null || true
    return 0
}
_on_int() {
    printf '\n' >&"$LOG_FD"
    warn "interrupted"
    exit 130
}
trap _on_exit EXIT
trap _on_int INT TERM

case "$CMD" in
    init|apply|edit|build|sync|shell|status|logs|reset) "cmd_$CMD" "$@" ;;
    pipeasio-init) cmd_pipeasio_init "$@" ;;
    pipeasio-build) cmd_pipeasio_build "$@" ;;
    format-patch) cmd_format_patch "$@" ;;
    *) usage_error "unknown subcommand: $CMD" ;;
esac
