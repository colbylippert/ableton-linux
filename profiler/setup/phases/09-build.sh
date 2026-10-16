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
#   _lp_prefix_pids / _lp_live_pids / _lp_prefix_busy
#       process detection modelled on scripts/lib/lifecycle.sh (WINEPREFIX= in
#       /proc/PID/environ, "Ableton Live*.exe" in the command line)
#   _lp_show TEXT        stream captured command output into the terminal + log
#   _lp_mem_jobs         the driver's MemAvailable job clamp, recomputed now
#
# Phase contract (see lib/phase.sh): check is read-only and passes when the
# dist/ artifacts for $REPO_DIR/VERSION exist, their checksum verifies and the
# build audit has passed for exactly this tarball (recorded in
# ~/.local/state/profiler/build-audit.env, or re-run on the spot); apply runs
# the build with pipefail + tee into ~/.local/state/profiler/build-<ts>.log,
# then audits the tarball and records the audit.

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
# pids whose environment carries WINEPREFIX=<prefix> (any runtime), one per line
_lp_prefix_pids() {
    local prefix="${1:-$(_lp_prefix)}" proc pid
    while IFS= read -r -d '' proc; do
        pid="${proc#/proc/}"; pid="${pid%/environ}"
        [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
    done < <(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null || true)
    return 0
}
# pids of every "Ableton Live*.exe" process on the machine
_lp_live_pids() {
    local proc cmd
    for proc in /proc/[0-9]*; do
        cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "${proc#/proc/}" ;; esac
    done
    return 0
}
# 0 when the prefix is in use: any WINEPREFIX=<prefix> process (wineserver,
# the launcher, Wine services) or any Live process at all
_lp_prefix_busy() {
    local pids
    pids="$(_lp_prefix_pids "${1:-}")$(_lp_live_pids)"
    [ -n "$pids" ]
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
# the driver's formula on the current MemAvailable: max(2, (avail GiB − 2) / 1.2)
_lp_mem_jobs() {
    local avail_kb j
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || avail_kb=0
    j=$(( (avail_kb / 1048576 - 2) * 10 / 12 ))
    [ "$j" -ge 2 ] || j=2
    printf '%s\n' "$j"
}

# ------------------------------------------------------------- build ----
_build_version() { tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || true; }
_build_tarball() { printf '%s/dist/wine-d2d1-nspa-11.13-%s.tar.zst\n' "$REPO_DIR" "$1"; }
_build_record() { printf '%s/build-audit.env\n' "$PROFILER_STATE_DIR"; }
_build_tmpdir() { printf '%s/tmp\n' "$PROFILER_CACHE_DIR"; }

# extra audit arguments: pin the source-tree line to the digest recorded at build
# time (the checkout may have changed since; that is not what the audit is for)
_build_audit_args() {
    local binfo="$REPO_DIR/dist/BUILD-INFO-$1.txt" sha
    sha="$(sed -n 's/^source-tree:  *//p' "$binfo" 2>/dev/null | head -n1)"
    if [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then printf -- '--source-tree-sha\n%s\n' "$sha"; fi
    return 0
}

# read-only audit for check: runs scripts/build-audit.sh directly (not through
# `run`, so it also works under --dry-run) and streams its report
_build_audit_direct() {
    local tarball="$1" version="$2" out rc tmp
    local -a args=()
    mapfile -t args < <(_build_audit_args "$version")
    tmp="$(_build_tmpdir)"
    mkdir -p -- "$tmp" 2>/dev/null || tmp="${TMPDIR:-/tmp}"
    out="$(cd "$REPO_DIR" && TMPDIR="$tmp" ./scripts/build-audit.sh ${args[@]+"${args[@]}"} "$tarball" 2>&1)"; rc=$?
    _lp_show "$out"
    return "$rc"
}

phase_build_check() {
    local version tarball f sum rec size
    local -a missing=()
    version="$(_build_version)"
    if [ -z "$version" ]; then info "cannot read $REPO_DIR/VERSION (phase repo not done?)"; return 1; fi
    tarball="$(_build_tarball "$version")"
    step "checking dist/ artifacts for runtime version $version"
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
    sum="$(awk '{print $1; exit}' "$tarball.sha256")"
    ok "artifacts present; tarball checksum verified"
    rec="$(_build_record)"
    if [ -r "$rec" ] && grep -qxF "tarball_sha256=$sum" "$rec" && grep -qxF "result=ok" "$rec"; then
        ok "build audit already recorded for this tarball ($(sed -n 's/^ts=//p' "$rec" | head -n1))"
    else
        step "running scripts/build-audit.sh (no recorded audit for this tarball)"
        if _build_audit_direct "$tarball" "$version"; then
            ok "build audit passed"
        else
            info "build audit failed for $tarball: the artifacts do not match the patch series"
            return 1
        fi
    fi
    phase_note "dist $version audited"
    return 0
}

phase_build_apply() {
    local version tarball jobs mem_jobs ts log t0 secs tmp_avail rec tmp sum tmpdir
    local -a audit_args=()
    require_cmd podman git sha256sum tee zstd tar || return 1
    version="$(_build_version)"
    [ -n "$version" ] || { fail "cannot read $REPO_DIR/VERSION — run phase repo first"; return 1; }
    [ -x "$REPO_DIR/build.sh" ] || { fail "no executable build.sh in $REPO_DIR"; return 1; }
    [ -x "$REPO_DIR/scripts/build-audit.sh" ] || { fail "missing $REPO_DIR/scripts/build-audit.sh"; return 1; }
    tarball="$(_build_tarball "$version")"

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
    if ! run -- bash -o pipefail -c 'cd -- "$1" && JOBS="$2" PIPEASIO_TSAN_MODE=skip ./build.sh 2>&1 | tee -- "$3"' \
            profiler-build "$REPO_DIR" "$jobs" "$log"; then
        info "build log: $log"
        return 1
    fi
    run -- ln -sfn "build-$ts.log" "$(state_dir)/build-latest.log" || true
    secs=$(( $(_now_s) - t0 ))
    is_dry_run || ok "build finished in $(( secs / 60 )) min (log: $log)"

    step "auditing the tarball with scripts/build-audit.sh"
    tmpdir="$(_build_tmpdir)"
    run -- mkdir -p -- "$tmpdir" || return 1
    mapfile -t audit_args < <(_build_audit_args "$version")
    run -- env -C "$REPO_DIR" TMPDIR="$tmpdir" ./scripts/build-audit.sh ${audit_args[@]+"${audit_args[@]}"} "$tarball" || return 1
    if is_dry_run; then
        info "would record the audit result in $(_build_record)"
        return 0
    fi
    [ -s "$tarball.sha256" ] || { fail "build finished but $tarball.sha256 is missing"; return 1; }
    sum="$(awk '{print $1; exit}' "$tarball.sha256")"
    rec="$(_build_record)"
    tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/build-audit.XXXXXX")" || { fail "mktemp failed"; return 1; }
    {
        printf '# written by profiler/setup/phases/09-build.sh after a passing scripts/build-audit.sh\n'
        printf 'ts=%s\nversion=%s\ntarball=%s\ntarball_sha256=%s\nbuild_log=%s\nbuild_seconds=%s\njobs=%s\nresult=ok\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" "$tarball" "$sum" "$log" "$secs" "$jobs"
    } > "$tmp"
    if run -- install -D -m 0644 "$tmp" "$rec"; then
        rm -f -- "$tmp"
        ok "audit recorded in $rec"
    else
        rm -f -- "$tmp"
        return 1
    fi
    phase_note "built $version in $(( secs / 60 )) min"
    return 0
}
