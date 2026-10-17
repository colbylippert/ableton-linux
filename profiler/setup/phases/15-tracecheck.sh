#!/usr/bin/env bash
# profiler/setup/phases/15-tracecheck.sh — phase 15 "tracecheck": the tracer
# prerequisites report (profiler/bin/trace-prereqs: BTF, bpftool, uprobe PMU,
# bpftrace, USDT notes in ntdll.so/pipeasio64.dll.so — "pending" until patches
# 0108/0017 are built —, perf, clang BPF target, pahole, /dev/ntsync + an
# NTSync-enabled wineserver, sysctls, privilege route, ulimit -l, THP) and the
# repo's scripts/check-ntsync.sh. Hard failures of trace-prereqs fail the phase.
#
# check-ntsync.sh starts a wineserver and runs ntsyncprobe.exe in the prefix it
# is given ("use a separate test prefix", check-ntsync.sh:5). Running it in the
# real prefix would rewrite registry files after phase golden took its snapshot
# (the first `state diff --name golden` would then show drift no trial caused),
# so the probe runs in a throwaway clone: `cp -a --reflink=auto` of the prefix
# into ~/.cache/profiler/ntsync-prefix.<pid> (instant on btrfs, a full copy
# elsewhere), stopped with wineserver -k/-w and deleted afterwards.
#
# The NTSync result is recorded in ~/.local/state/profiler/tracecheck.env
# together with the installed runtime's identity, so check is cheap on re-runs
# and a replaced runtime triggers a new probe. Under PROFILER_NO_SUDO=1 (the
# driver's --dry-run) trace-prereqs skips its sudo probes.
# Uses the _lp_* helpers from 09-build.sh.

phase_register 15 tracecheck "tracer prerequisites (profiler/bin/trace-prereqs) + scripts/check-ntsync.sh" "packages,install"

_tc_tool() { printf '%s/bin/trace-prereqs\n' "$PROFILER_ROOT"; }
_tc_record() { printf '%s/tracecheck.env\n' "$PROFILER_STATE_DIR"; }
# identity of the installed runtime: sha256 of its BUILD-INFO (fallback: mtime of bin/wine)
_tc_runtime_stamp() {
    local rt
    rt="$(_lp_runtime_root)"
    if [ -r "$rt/ABLETON-WINE-BUILD-INFO.txt" ]; then
        sha256sum < "$rt/ABLETON-WINE-BUILD-INFO.txt" | cut -c1-16
    else
        stat -c %Y -- "$rt/bin/wine" 2>/dev/null || printf 'none\n'
    fi
}
_tc_prereq_args() {
    printf -- '--runtime\n%s\n' "$(_lp_runtime_root)"
    [ "${PROFILER_NO_SUDO:-0}" != 1 ] || printf -- '--no-sudo\n'
}

phase_tracecheck_check() {
    local tool out rc=0 rec stamp
    local -a args=()
    tool="$(_tc_tool)"
    [ -x "$tool" ] || { info "missing $tool"; return 1; }
    mapfile -t args < <(_tc_prereq_args)
    step "tracer prerequisites (profiler/bin/trace-prereqs ${args[*]})"
    out="$("$tool" "${args[@]}" 2>&1)" || rc=$?
    _lp_show "$out"
    if [ "$rc" -eq 0 ]; then
        ok "trace-prereqs: no hard failures"
    else
        info "trace-prereqs reports hard failures (exit $rc)"
        return 1
    fi
    rec="$(_tc_record)"; stamp="$(_tc_runtime_stamp)"
    if [ -r "$rec" ] && grep -qxF "ntsync=ok" "$rec" && grep -qxF "runtime=$stamp" "$rec"; then
        ok "scripts/check-ntsync.sh passed for the installed runtime ($(sed -n 's/^ts=//p' "$rec" | head -n1))"
    else
        info "scripts/check-ntsync.sh has not been recorded for the installed runtime"
        return 1
    fi
    phase_note "tracer prerequisites met; NTSync active"
    return 0
}

phase_tracecheck_apply() {
    local tool chk rec tmp stamp rt prefix clone rc=0
    local -a args=()
    tool="$(_tc_tool)"; chk="$REPO_DIR/scripts/check-ntsync.sh"
    rt="$(_lp_runtime_root)"; prefix="$(_lp_prefix)"
    [ -x "$tool" ] || { fail "missing $tool"; return 1; }
    [ -x "$chk" ] || prereq_fail "missing $chk (phase repo)" || return 1
    [ -x "$rt/bin/wineserver" ] || prereq_fail "runtime not installed at $rt (phase install)" || return 1
    [ -f "$prefix/system.reg" ] || prereq_fail "prefix $prefix is not set up (phase install)" || return 1
    mapfile -t args < <(_tc_prereq_args)
    step "tracer prerequisites (hard failures stop the phase; install missing packages via phase packages)"
    run --allow-fail -- "$tool" "${args[@]}" || true
    if [ "$RUN_STATUS" -ne 0 ]; then
        fail "trace-prereqs: hard failure(s) — see the table above (exit $RUN_STATUS)" || return 1
    fi
    step "NTSync check (scripts/check-ntsync.sh in a throwaway clone of $prefix)"
    if _lp_prefix_busy "$prefix"; then
        fail "Live or Wine processes are using $prefix; quit Live before the NTSync check" || return 1
    fi
    [ -f "$REPO_DIR/beta/tester-kit/probes/windows/ntsyncprobe.exe" ] \
        || warn "beta/tester-kit/probes/windows/ntsyncprobe.exe is missing; check-ntsync.sh will stop (set ABLETON_NTSYNC_PROBE)"
    clone="$(cache_dir)/ntsync-prefix.$$"
    info "clone: cp -a --reflink=auto (instant on btrfs; $(stat -f -c %T -- "$(dirname -- "$prefix")" 2>/dev/null || echo ?) here) → $clone"
    run -- mkdir -p -- "$(dirname -- "$clone")" || return 1
    run -- rm -rf -- "$clone" || return 1
    run -- cp -a --reflink=auto -- "$prefix" "$clone" || { run --allow-fail -- rm -rf -- "$clone" || true; return 1; }
    run --allow-fail --timeout 300 -- env ABLETON_WINE_ROOT="$rt" ABLETON_WINEPREFIX="$clone" "$chk" || rc="$RUN_STATUS"
    # check-ntsync.sh stops its wineserver itself; make sure nothing of the clone survives
    run --allow-fail --timeout 30 -- env WINEPREFIX="$clone" "$rt/bin/wineserver" -k || true
    run --allow-fail --timeout 60 -- env WINEPREFIX="$clone" "$rt/bin/wineserver" -w || true
    run --allow-fail -- rm -rf -- "$clone" || warn "could not remove $clone"
    if [ "$rc" -ne 0 ]; then
        fail "check-ntsync.sh failed (exit $rc): Wine does not use NTSync with this runtime" || return 1
    fi
    if is_dry_run; then
        info "would record the result in $(_tc_record)"
        return 0
    fi
    ok "NTSync active: wineserver opens /dev/ntsync, sync semantics pass"
    rec="$(_tc_record)"; stamp="$(_tc_runtime_stamp)"
    tmp="$(mktemp "${PROFILER_TMPDIR:-${TMPDIR:-/tmp}}/tracecheck.XXXXXX")" || { fail "mktemp failed"; return 1; }
    {
        printf '# written by profiler/setup/phases/15-tracecheck.sh; read by its check and verify.sh\n'
        printf 'ts=%s\nruntime=%s\nruntime_root=%s\nprefix=%s\nprobe_prefix=clone\nprereqs=ok\nntsync=ok\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stamp" "$rt" "$prefix"
    } > "$tmp"
    if run -- install -D -m 0644 "$tmp" "$rec"; then
        rm -f -- "$tmp"
        ok "recorded in $rec"
    else
        rm -f -- "$tmp"
        return 1
    fi
    phase_note "prerequisites met; NTSync active"
    return 0
}
