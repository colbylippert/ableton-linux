#!/usr/bin/env bash
# profiler/setup/phases/14-golden.sh — phase 14 "golden": the reference
# snapshots taken with profiler/bin/state:
#   post-install  the state before Live ever ran (phase human takes it right
#                 before the first launch; taken here only if it is missing)
#   golden        the state after the human checklist (licence accepted,
#                 PipeASIO + AbletonOSC selected, Live quit cleanly) — the state
#                 every profiling trial is restored to (`state restore`)
# The golden snapshot is deferred (warning, phase passes) while the human phase
# has not left its evidence (see _human_evidence in 13-human.sh), so that
# --yes runs can finish; a later `setup-machine.sh --only golden` takes it.
# Snapshots live in ~/.local/share/profiler/golden/<name>/ (reflinks on btrfs,
# rsync otherwise; see profiler/bin/state).
# Uses the _lp_* helpers from 09-build.sh and _human_evidence from 13-human.sh.

phase_register 14 golden "post-install and golden snapshots of prefix + runtime (profiler/bin/state)" "human"

: "${_GOLDEN_DEFERRED:=0}"

_golden_state() { printf '%s/bin/state\n' "$PROFILER_ROOT"; }
_golden_has() { "$(_golden_state)" list --names 2>/dev/null | grep -qx -- "$1"; }
_golden_dir() { printf '%s/golden/%s\n' "${PROFILER_SHARE_DIR:-$HOME/.local/share/profiler}" "$1"; }

phase_golden_check() {
    local st created
    st="$(_golden_state)"
    step "checking snapshots in $(_golden_dir '')"
    [ -x "$st" ] || { info "missing $st"; return 1; }
    if _golden_has post-install; then ok "snapshot post-install present"; else info "snapshot post-install missing"; fi
    if _golden_has golden; then
        created="$(sed -n 's/^ *"created": *"\([^"]*\)".*/\1/p' "$(_golden_dir golden)/MANIFEST.json" 2>/dev/null | head -n1)"
        ok "snapshot golden present (${created:-?})"
        kv "golden" "$(_golden_dir golden)"
        phase_note "golden present"
        return 0
    fi
    if ! _human_evidence; then
        if [ "$_GOLDEN_DEFERRED" = 1 ]; then
            warn "golden snapshot deferred until the human first-launch phase is complete"
            phase_note "deferred (human pending)"
            return 0
        fi
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
    if _golden_has post-install; then
        skip "snapshot post-install exists"
    else
        _human_evidence && warn "post-install should precede the human phase; taking it now anyway (Live has already run)"
        step "snapshot post-install"
        run -- "$st" snapshot --name post-install || return 1
    fi
    if ! _human_evidence; then
        _GOLDEN_DEFERRED=1
        warn "the human first-launch phase is not complete (no PipeASIO/'Open: finished' evidence in Log.txt, crash files, or a live wineserver): golden snapshot deferred"
        action_required "after the Live checklist: setup-machine.sh --only golden"
        phase_note "deferred (human pending)"
        return 0
    fi
    step "snapshot golden (the state every trial restores to)"
    run -- "$st" snapshot --name golden || return 1
    is_dry_run || ok "golden snapshot taken: $(_golden_dir golden)"
    info "restore with: $st restore --name golden   ·   drift: $st diff --name golden"
    phase_note "post-install + golden snapshots"
    return 0
}
