#!/usr/bin/env bash
# profiler/setup/phases/09-build.sh — phase 09 "build": the official rootless
# Podman build of Wine + PipeASIO (./build.sh) plus the host-side audit of the
# resulting tarball (scripts/build-audit.sh).
#
# This file also defines the _lp_* helpers shared by phases 09–18 (the driver
# sources every phase file before any phase runs, so they are available to the
# later files regardless of --only/--skip):
#   _lp_runtime_root / _lp_prefix / _lp_launcher / _lp_live_exe
#       path resolution identical to scripts/lib/config.sh:
#       environment (ABLETON_WINE_ROOT, ABLETON_WINEPREFIX) > the installer's
#       ~/.config/ableton-wine/config (runtime_root=, prefix=) > defaults
#       (~/.local/opt/wine-d2d1-nspa-11.13, ~/.wine-ableton, ~/.local/bin/ableton-live)
#   _lp_prefix_pids / _lp_live_pids / _lp_pid_is_wine / _lp_prefix_busy
#       process detection mirroring scripts/lib/lifecycle.sh
#       (ableton_prefix_wine_processes_any_runtime + ableton_live_pids): a pid
#       counts only when /proc/PID/environ carries WINEPREFIX=<prefix> exactly AND
#       /proc/PID/exe is a Wine binary (any runtime, the dev runtime included);
#       Live = such a pid whose command line names "Ableton Live…​.exe". A shell
#       whose arguments merely mention the installer (this driver started with
#       --live-installer, the `bash -lc` wrapper over SSH) never matches.
#   _lp_show TEXT        stream captured command output into the terminal + log
#   _lp_mem_jobs         the driver's MemAvailable job clamp, recomputed now
#
# Phase contract (see lib/phase.sh): check is read-only and passes when the
# dist/ artifacts for $REPO_DIR/VERSION exist, their checksum verifies and a
# passing build audit is recorded for exactly this tarball — in
# ~/.local/state/profiler/build-audit.env (written here) or in
# ~/.local/state/profiler/dev/last-official-build (written by
# profiler/dev/build-official.sh); check never runs the audit itself (it unpacks
# the ~1.3 GB tarball: minutes, and a write under ~/.cache). apply takes the same
# ~/.local/state/profiler/build.lock as build-official.sh and refuses while
# wine-dev.sh holds wine-dev.lock, runs the build with pipefail + tee into
# ~/.local/state/profiler/build-<ts>.log, then audits the tarball and records
# the result. When the artifacts already verify and only the record is missing,
# apply runs just the audit (--force rebuilds).

phase_register 09 build "Wine + PipeASIO container build (./build.sh) and build audit" "podman,repo,media"

# ------------------------------------------------------ shared helpers ----
# value of KEY from the installer's managed config (~/.config/ableton-wine/config)
_lp_abl_cfg() {
    local file="${ABLETON_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}/config" line
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
    done < "$file"
    return 0
}
_lp_runtime_root() {
    local v="${ABLETON_WINE_ROOT:-}"
    [ -n "$v" ] || v="$(_lp_abl_cfg runtime_root)"
    [ -n "$v" ] || v="$HOME/.local/opt/wine-d2d1-nspa-11.13"
    printf '%s\n' "$v"
}
_lp_prefix() {
    local v="${ABLETON_WINEPREFIX:-}"
    [ -n "$v" ] || v="$(_lp_abl_cfg prefix)"
    [ -n "$v" ] || v="$HOME/.wine-ableton"
    printf '%s\n' "$v"
}
_lp_launcher() { printf '%s/ableton-live\n' "${ABLETON_BIN_HOME:-$HOME/.local/bin}"; }
# newest "Ableton Live 12*.exe" installed in the prefix (prints nothing when none)
_lp_live_exe() {
    local prefix="${1:-$(_lp_prefix)}" f
    for f in "$prefix"/drive_c/ProgramData/Ableton/"Live 12"*/Program/"Ableton Live 12"*.exe; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done 2>/dev/null | sort -V | tail -n1
    return 0
}
# the runtime roots whose binaries count as Wine besides the generic image names:
# the configured runtime and its -dev twin (profiler/dev/wine-dev.sh sync)
_lp_runtime_roots() {
    local rt
    rt="$(_lp_runtime_root)"
    printf '%s\n%s\n' "$rt" "$rt-dev"
}
# 0 when PID is a Wine process: /proc/PID/exe resolves to a Wine image (wine,
# wine64, the preloaders, wineserver[64], .wine-wrapped — any runtime) or to a
# file under a */lib/wine/ directory or under _lp_runtime_roots. The environment
# alone never qualifies a process (a shell may carry WINEPREFIX).
_lp_pid_is_wine() {
    local pid="$1" exe root
    exe="$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)"
    [ -n "$exe" ] || return 1
    case "${exe##*/}" in
        wine|wine64|wine-preloader|wine64-preloader|wineserver|wineserver64|.wine-wrapped) return 0 ;;
    esac
    case "$exe" in */lib/wine/*|*/lib64/wine/*) return 0 ;; esac
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        root="$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")"
        case "$exe" in "$root"/*) return 0 ;; esac
    done < <(_lp_runtime_roots)
    return 1
}
# Wine processes of the prefix (WINEPREFIX=<prefix> exactly, any runtime), one
# pid per line: wineserver, Live, the installer's Inno Setup, Wine services
_lp_prefix_pids() {
    local prefix="${1:-}" proc pid
    [ -n "$prefix" ] || prefix="$(_lp_prefix)"
    while IFS= read -r -d '' proc; do
        pid="${proc#/proc/}"; pid="${pid%/environ}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _lp_pid_is_wine "$pid" || continue
        printf '%s\n' "$pid"
    done < <(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null || true)
    return 0
}
# Live processes of the prefix: _lp_prefix_pids whose command line names
# "Ableton Live…​.exe" (the Live 12 Trial exe, or its installer while phase
# install runs it)
_lp_live_pids() {
    local pid cmd
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmd="$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || true)"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "$pid" ;; esac
    done < <(_lp_prefix_pids "${1:-}")
    return 0
}
# 0 when any Wine process uses the prefix (Live, its wineserver, the installer)
_lp_prefix_busy() {
    [ -n "$(_lp_prefix_pids "${1:-}")" ]
}
# stream TEXT line by line with the "│" prefix to the terminal and the log,
# exactly like `run` does for command output (for read-only probes in check)
_lp_show() {
    local line ts
    [ -n "${1:-}" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        ts="$(now_hms)"
        printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
        _log_file "[$ts]     $G_BAR $line"
    done <<< "$1"
}
# the driver's formula on the current MemAvailable: max(2, (avail − 2 GiB) / 1.2 GiB)
_lp_mem_jobs() {
    local avail_kb j
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || avail_kb=0
    j=$(( (avail_kb - 2 * 1048576) * 10 / (12 * 1048576) ))
    [ "$j" -ge 2 ] || j=2
    printf '%s\n' "$j"
}

# ------------------------------------------------------------- build ----
_build_version() { tr -d '[:space:]' 2>/dev/null < "$REPO_DIR/VERSION" || true; }
_build_tarball() { printf '%s/dist/wine-d2d1-nspa-11.13-%s.tar.zst\n' "$REPO_DIR" "$1"; }
_build_record() { printf '%s/build-audit.env\n' "$PROFILER_STATE_DIR"; }
_build_official_record() { printf '%s/dev/last-official-build\n' "$PROFILER_STATE_DIR"; }
_build_tmpdir() { printf '%s/tmp\n' "$PROFILER_CACHE_DIR"; }
# the locks shared with profiler/dev/build-official.sh and profiler/dev/wine-dev.sh
# (one mutual-exclusion contract for every entry point that runs ./build.sh)
_build_lock() { printf '%s/build.lock\n' "$PROFILER_STATE_DIR"; }
_build_dev_lock() { printf '%s/wine-dev.lock\n' "$PROFILER_STATE_DIR"; }
_build_dev_busy() { printf '%s/wine-dev.building\n' "$PROFILER_STATE_DIR"; }
: "${_BUILD_LOCKED:=0}"
: "${_BUILD_SUM:=}"
: "${_BUILD_AUDIT_SOURCE:=}"

# extra audit arguments: pin the source-tree line to the digest recorded at build
# time (the checkout may have changed since; that is not what the audit is for)
_build_audit_args() {
    local binfo="$REPO_DIR/dist/BUILD-INFO-$1.txt" sha
    sha="$(sed -n 's/^source-tree:  *//p' "$binfo" 2>/dev/null | head -n1)"
    if [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then printf -- '--source-tree-sha\n%s\n' "$sha"; fi
    return 0
}

# read-only: 0 when every dist/ artifact for VERSION exists and the tarball's
# .sha256 verifies; reports what is missing; leaves the checksum in _BUILD_SUM
_build_artifacts_ok() {
    local version="$1" tarball f size
    local -a missing=()
    _BUILD_SUM=""
    tarball="$(_build_tarball "$version")"
    for f in "$tarball" "$tarball.sha256" "$REPO_DIR/dist/BUILD-INFO-$version.txt" \
             "$REPO_DIR/dist/pipewire-version-probe" "$REPO_DIR/dist/ableton-linkd" "$REPO_DIR/dist/cabextract-static"; do
        [ -s "$f" ] || missing+=("${f#"$REPO_DIR"/}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        info "missing in $REPO_DIR: ${missing[*]}"
        return 1
    fi
    size="$(du -h -- "$tarball" 2>/dev/null | cut -f1)"
    kv "tarball" "$tarball (${size:-?})"
    if ! ( cd "$REPO_DIR/dist" && sha256sum -c --status -- "$(basename -- "$tarball").sha256" ); then
        warn "dist/$(basename -- "$tarball").sha256 does not match the tarball (partial copy?)"
        return 1
    fi
    _BUILD_SUM="$(awk '{print $1; exit}' "$tarball.sha256")"
    ok "artifacts present; tarball checksum verified"
    return 0
}

# 0 when a PASSING scripts/build-audit.sh result is recorded for the tarball with
# checksum SUM — by this phase (build-audit.env: tarball_sha256= + result=ok) or
# by profiler/dev/build-official.sh (dev/last-official-build: tarball_sha256= +
# audit=ok); one record serves both. _BUILD_AUDIT_SOURCE names the record.
_build_audit_recorded() {
    local sum="$1" rec
    _BUILD_AUDIT_SOURCE=""
    rec="$(_build_record)"
    if [ -r "$rec" ] && grep -qxF "tarball_sha256=$sum" "$rec" && grep -qxF "result=ok" "$rec"; then
        _BUILD_AUDIT_SOURCE="$rec ($(sed -n 's/^ts=//p' "$rec" | head -n1))"
        return 0
    fi
    rec="$(_build_official_record)"
    if [ -r "$rec" ] && grep -qxF "tarball_sha256=$sum" "$rec" && grep -qxF "audit=ok" "$rec"; then
        _BUILD_AUDIT_SOURCE="$rec ($(sed -n 's/^ts=//p' "$rec" | head -n1), profiler/dev/build-official.sh)"
        return 0
    fi
    return 1
}
# 0 when this phase recorded a FAILED audit for SUM (the artifacts need a rebuild)
_build_audit_failed() {
    local rec
    rec="$(_build_record)"
    [ -r "$rec" ] && grep -qxF "tarball_sha256=$1" "$rec" && grep -qxF "result=failed" "$rec"
}

# write build-audit.env: RESULT (ok|failed) VERSION TARBALL SUM LOG SECONDS JOBS
_build_record_write() {
    local result="$1" version="$2" tarball="$3" sum="$4" log="$5" secs="$6" jobs="$7" rec tmp
    rec="$(_build_record)"
    if is_dry_run; then info "would record result=$result in $rec"; return 0; fi
    tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/build-audit.XXXXXX")" || { fail "mktemp failed"; return 1; }
    {
        printf '# written by profiler/setup/phases/09-build.sh after scripts/build-audit.sh (result=ok|failed)\n'
        printf 'ts=%s\nversion=%s\ntarball=%s\ntarball_sha256=%s\nbuild_log=%s\nbuild_seconds=%s\njobs=%s\nresult=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" "$tarball" "$sum" "$log" "$secs" "$jobs" "$result"
    } > "$tmp"
    if run -- install -D -m 0644 "$tmp" "$rec"; then
        rm -f -- "$tmp"
        ok "audit result ($result) recorded in $rec"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# the audit through `run` (honours --dry-run); the tarball is unpacked under
# ~/.cache/profiler/tmp, never on the /tmp tmpfs
_build_audit_run() {
    local version="$1" tarball="$2" tmpdir
    local -a audit_args=()
    step "auditing the tarball with scripts/build-audit.sh"
    tmpdir="$(_build_tmpdir)"
    run -- mkdir -p -- "$tmpdir" || return 1
    mapfile -t audit_args < <(_build_audit_args "$version")
    run --allow-fail -- env -C "$REPO_DIR" TMPDIR="$tmpdir" ./scripts/build-audit.sh ${audit_args[@]+"${audit_args[@]}"} "$tarball"
}

# 0 when profiler/dev/wine-dev.sh holds its lock (the same probe as
# build-official.sh's _dev_loop_running; the lock file is never created here)
_build_dev_loop_running() {
    local lock
    lock="$(_build_dev_lock)"
    command -v flock >/dev/null 2>&1 || return 1
    [ -e "$lock" ] || return 1
    ! ( exec 8>>"$lock" && flock -n 8 ) 2>/dev/null
}
# take ~/.local/state/profiler/build.lock on fd 9 (flock -n) for this process;
# refuse while another official build (build-official.sh or another driver) holds
# it or while wine-dev.sh is running. Under --dry-run nothing is opened.
_build_lock_acquire() {
    local lock
    lock="$(_build_lock)"
    if _build_dev_loop_running; then
        fail "profiler/dev/wine-dev.sh is running ($(tr '\n' ' ' 2>/dev/null < "$(_build_dev_busy)" || echo 'details unknown')): it shares the image tag and .ccache with ./build.sh — wait for it" || return 1
    fi
    ok "wine-dev.sh is not running"
    if is_dry_run; then
        info "would take $lock (flock -n) for the duration of the build and the audit"
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock not found: the build lock $lock is not enforced"
        return 0
    fi
    mkdir -p -- "$PROFILER_STATE_DIR" 2>/dev/null || true
    if ! exec 9>>"$lock"; then
        fail "cannot open $lock" || return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        fail "another official build is running (lock $lock is held by profiler/dev/build-official.sh or another setup-machine.sh); wait for it" || return 1
    fi
    _BUILD_LOCKED=1
    ok "acquired $lock"
    return 0
}
_build_lock_release() {
    [ "$_BUILD_LOCKED" = 1 ] || return 0
    exec 9>&-
    _BUILD_LOCKED=0
    return 0
}

phase_build_check() {
    local version
    version="$(_build_version)"
    if [ -z "$version" ]; then info "cannot read $REPO_DIR/VERSION (phase repo not done?)"; return 1; fi
    step "checking dist/ artifacts for runtime version $version"
    _build_artifacts_ok "$version" || return 1
    if _build_audit_recorded "$_BUILD_SUM"; then
        ok "build audit recorded for this tarball: $_BUILD_AUDIT_SOURCE"
    elif _build_audit_failed "$_BUILD_SUM"; then
        info "the recorded scripts/build-audit.sh result for this tarball is FAILED (artifacts do not match the patch series): apply rebuilds"
        return 1
    else
        info "no recorded scripts/build-audit.sh result for this tarball: audit pending (apply runs the audit only, not the build)"
        return 1
    fi
    phase_note "dist $version audited"
    return 0
}

phase_build_apply() {
    local rc=0
    _build_apply_inner || rc=$?
    _build_lock_release
    return "$rc"
}

_build_apply_inner() {
    local version tarball jobs mem_jobs ts log t0 secs tmp_avail sum audit_only=0
    require_cmd podman git sha256sum tee zstd tar || return 1
    version="$(_build_version)"
    if [ -z "$version" ]; then
        prereq_fail "cannot read $REPO_DIR/VERSION — run phase repo first" || return 1
        version="VERSION"
    fi
    [ -x "$REPO_DIR/build.sh" ] || prereq_fail "no executable build.sh in $REPO_DIR (phase repo)" || return 1
    [ -x "$REPO_DIR/scripts/build-audit.sh" ] || prereq_fail "missing $REPO_DIR/scripts/build-audit.sh (phase repo)" || return 1
    tarball="$(_build_tarball "$version")"

    # artifacts that already verify need only the audit: the record is missing
    # after an official build that left none (build-official.sh --no-audit, an
    # older build-official.sh) or after a crash between build and audit
    if [ "$FORCE" != 1 ]; then
        step "dist/ artifacts"
        if _build_artifacts_ok "$version" && ! _build_audit_failed "$_BUILD_SUM"; then
            audit_only=1
            skip "the build is skipped: dist/ artifacts for $version verify (--force rebuilds); only the audit runs"
        fi
    fi

    step "locks"
    _build_lock_acquire || return 1

    if [ "$audit_only" -eq 1 ]; then
        log="$(readlink -f -- "$(state_dir)/build-latest.log" 2>/dev/null || echo unknown)"
        secs=0; jobs="${JOBS:-?}"
    else
        step "pre-checks"
        if _lp_prefix_busy; then
            fail "Live or Wine processes are using the prefix $(_lp_prefix); quit Live before building" || return 1
        fi
        ok "no Live/wineserver running"
        tmp_avail="$(df -B1 --output=avail /tmp 2>/dev/null | tail -n1 | tr -d ' ')"
        [[ "$tmp_avail" =~ ^[0-9]+$ ]] || tmp_avail=0
        if [ "$tmp_avail" -lt $(( 2 * 1073741824 )) ]; then
            fail "/tmp has only $(( tmp_avail / 1048576 )) MiB free; build.sh needs >= 2 GiB there (it hard-codes /tmp)" || return 1
        fi
        ok "/tmp has $(( tmp_avail / 1073741824 )) GiB free"
        jobs="$JOBS"
        mem_jobs="$(_lp_mem_jobs)"
        if [ "${JOBS_SOURCE:-auto}" = auto ] && [ "$mem_jobs" -lt "$jobs" ]; then
            info "MemAvailable is lower now than at startup: JOBS $jobs → $mem_jobs"
            jobs="$mem_jobs"
        fi
        kv "jobs" "$jobs (${JOBS_SOURCE:-auto})"
        if podman image exists ableton-wine-build:22.04 2>/dev/null; then
            ok "container image ableton-wine-build:22.04 present"
        else
            info "container image ableton-wine-build:22.04 is built first (network: docker.io, snapshot.ubuntu.com, apt.llvm.org; ~10 min)"
        fi
        if [ -d "$REPO_DIR/.ccache" ]; then
            kv "ccache" "$(du -sh -- "$REPO_DIR/.ccache" 2>/dev/null | cut -f1) in $REPO_DIR/.ccache (warm start)"
        else
            kv "ccache" "empty (cold start)"
        fi
        info "expected duration: ~50–60 min cold on 8 vCPU, ~15–20 min with a warm .ccache"
        info "RULE: do not edit, commit, or create files under $REPO_DIR while the build runs — build.sh snapshots the tree and aborts when it changes"

        ts="$(date -u +%Y%m%dT%H%M%SZ)"
        log="$(state_dir)/build-$ts.log"
        step "building (JOBS=$jobs PIPEASIO_TSAN_MODE=skip ./build.sh; full output in $log)"
        t0="$(_now_s)"
        # 9>&- : build.sh and its podman processes must not inherit the lock fd
        if ! run -- bash -o pipefail -c 'exec 9>&-; cd -- "$1" && JOBS="$2" PIPEASIO_TSAN_MODE=skip ./build.sh 2>&1 | tee -- "$3"' \
                profiler-build "$REPO_DIR" "$jobs" "$log"; then
            info "build log: $log"
            return 1
        fi
        run -- ln -sfn "build-$ts.log" "$(state_dir)/build-latest.log" || true
        secs=$(( $(_now_s) - t0 ))
        is_dry_run || ok "build finished in $(( secs / 60 )) min (log: $log)"
        if ! is_dry_run; then
            [ -s "$tarball.sha256" ] || { fail "build finished but $tarball.sha256 is missing"; return 1; }
        fi
    fi

    _build_audit_run "$version" "$tarball" || {
        info "the audit failed (exit $RUN_STATUS): the artifacts do not match the patch series — a rebuild follows on the next run"
        if ! is_dry_run && [ -s "$tarball.sha256" ]; then
            sum="$(awk '{print $1; exit}' "$tarball.sha256" || true)"
            _build_record_write failed "$version" "$tarball" "$sum" "$log" "$secs" "$jobs" || true
        fi
        fail "scripts/build-audit.sh failed for $tarball" || return 1
    }
    if is_dry_run; then
        info "would record the audit result in $(_build_record)"
        return 0
    fi
    sum="$(awk '{print $1; exit}' "$tarball.sha256")"
    _build_record_write ok "$version" "$tarball" "$sum" "$log" "$secs" "$jobs" || return 1
    if [ "$audit_only" -eq 1 ]; then
        phase_note "dist $version audited (existing build)"
    else
        phase_note "built $version in $(( secs / 60 )) min"
    fi
    return 0
}
