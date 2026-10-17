#!/usr/bin/env bash
# profiler/setup/phases/14-golden.sh — phase 14 "golden": the reference
# snapshots taken with profiler/bin/state:
#   post-install  the state before Live ever ran (phase human takes it right
#                 before the first launch; taken here only if it is missing)
#   golden        the state after the human checklist (licence accepted,
#                 PipeASIO + AbletonOSC selected, Live quit cleanly) — the state
#                 every profiling trial is restored to (`state restore`)
# An existing snapshot is NEVER replaced by setup — not by a re-run, not by
# --force, not by --force --yes: the golden state is the reference every trial
# restores to, and a silent re-snapshot of a drifted prefix would move the
# baseline under the ledger. A deliberate re-baseline is one explicit command:
#     profiler/bin/state snapshot --name golden --rebaseline
# (the previous snapshot is kept as golden.<UTC timestamp>).
# The golden snapshot is DEFERRED (phase_defer: no done-marker) while the human
# phase has not left its evidence (see _human_evidence in 13-human.sh), so that
# --yes runs can finish; a later `setup-machine.sh --only golden` takes it.
# Snapshots live in ~/.local/share/profiler/golden/<name>/ (reflinks on btrfs,
# rsync otherwise); the Wine runtime is recorded by identity, not copied (see
# profiler/bin/state).
# Uses the _lp_* helpers from 09-build.sh and _human_evidence from 13-human.sh.

phase_register 14 golden "post-install and golden snapshots of the prefix + Live state (profiler/bin/state)" "human"

_golden_state() { printf '%s/bin/state\n' "$PROFILER_ROOT"; }
_golden_has() { "$(_golden_state)" list --names 2>/dev/null | grep -qx -- "$1"; }
_golden_dir() { printf '%s/golden/%s\n' "${PROFILER_SHARE_DIR:-$HOME/.local/share/profiler}" "$1"; }
_golden_created() { sed -n 's/^ *"created": *"\([^"]*\)".*/\1/p' "$(_golden_dir "$1")/MANIFEST.json" 2>/dev/null | head -n1 || true; }
_golden_rebaseline_hint() {
    info "a deliberate re-baseline is explicit: $(_golden_state) snapshot --name golden --rebaseline   (the current snapshot is kept as golden.<UTC>)"
}

phase_golden_check() {
    local st
    st="$(_golden_state)"
    step "checking snapshots in $(_golden_dir '')"
    [ -x "$st" ] || { info "missing $st"; return 1; }
    if _golden_has post-install; then ok "snapshot post-install present ($(_golden_created post-install))"; else info "snapshot post-install missing"; fi
    if _golden_has golden; then
        ok "snapshot golden present ($(_golden_created golden))"
        kv "golden" "$(_golden_dir golden)"
        phase_note "golden present"
        return 0
    fi
    if ! _human_evidence; then
        info "the human phase has not completed (no Log.txt evidence): the golden snapshot cannot be taken yet"
        return 1
    fi
    info "snapshot golden missing"
    return 1
}

phase_golden_apply() {
    local st
    st="$(_golden_state)"
    [ -x "$st" ] || { fail "missing $st"; return 1; }
    if _lp_prefix_busy; then
        fail "Live or Wine processes are using $(_lp_prefix); quit Live before taking a snapshot" || return 1
    fi
    if [ ! -d "$(_lp_prefix)" ]; then
        prereq_fail "prefix $(_lp_prefix) does not exist (phase install)" || return 1
    fi
    if _golden_has post-install; then
        skip "snapshot post-install exists ($(_golden_created post-install)); never replaced by setup"
    else
        if _human_evidence; then warn "post-install should precede the human phase; taking it now anyway (Live has already run)"; fi
        step "snapshot post-install"
        run -- "$st" snapshot --name post-install || return 1
    fi
    if _golden_has golden; then
        # reached only with --force (the check passes otherwise): never re-snapshot implicitly
        skip "snapshot golden exists ($(_golden_created golden)): setup never replaces it, --force included"
        _golden_rebaseline_hint
        phase_note "golden kept ($(_golden_created golden))"
        return 0
    fi
    if ! _human_evidence; then
        warn "the human first-launch phase is not complete (no PipeASIO/'Open: finished' evidence in Log.txt, crash files, or a live wineserver): golden snapshot deferred"
        action_required "after the Live checklist: setup-machine.sh --only golden"
        phase_defer "human first launch pending"
        return 0
    fi
    step "snapshot golden (the state every trial restores to)"
    run -- "$st" snapshot --name golden || return 1
    is_dry_run || ok "golden snapshot taken: $(_golden_dir golden)"
    info "restore with: $st restore --name golden   ·   drift: $st diff --name golden"
    phase_note "post-install + golden snapshots"
    return 0
}
