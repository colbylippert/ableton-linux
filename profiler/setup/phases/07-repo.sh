#!/usr/bin/env bash
# profiler/setup/phases/07-repo.sh — phase 07 "repo": the ableton-linux checkout
# the build uses ($REPO_DIR, default ~/Projects/ableton-linux).
#   * no checkout yet: clone the bootstrap bundle (~/profiler-bootstrap.bundle or
#     $PROFILER_BUNDLE; see profiler/setup/bootstrap.md) on branch profiler and
#     point origin at GitHub — or, without a bundle, clone GitHub
#   * core.autocrlf=false, core.eol=lf (the scripts must stay LF)
#   * branch profiler checked out (a trial/* branch of the agent loop is left
#     alone); aceb236 must be an ancestor of HEAD
#   * bench/ (deleted upstream in aceb236, still used by scripts/bench-suite.sh)
#     restored from aceb236^ with `git archive | tar -x`, verified against
#     bench/SHA256SUMS, and kept out of git and out of build.sh's source snapshot
#     through .git/info/exclude (never .gitignore: nothing of it may be committed)
# Check (read-only; git runs with --no-optional-locks so not even the index is
# refreshed): branch, ancestry, line-ending config, exclude entry, bench/
# verifies and is not listed by git status. Other uncommitted changes are a
# warning only (build.sh snapshots them; this phase cannot decide about them).

phase_register 07 repo "checkout: branch profiler, aceb236 ancestry, LF config, bench/ restored from aceb236^ and excluded" "packages"

: "${P7_BASE:=aceb236}"
: "${P7_BENCH_REV:=aceb236^}"
: "${P7_UPSTREAM:=https://github.com/shibco/ableton-linux}"

_repo_bundle() { printf '%s\n' "${PROFILER_BUNDLE:-$HOME/profiler-bootstrap.bundle}"; }
_repo_git() { git -C "$REPO_DIR" --no-optional-locks "$@"; }
_repo_present() { [ -e "$REPO_DIR/.git" ] && _repo_git rev-parse --git-dir >/dev/null 2>&1; }
_repo_branch() { _repo_git symbolic-ref --short -q HEAD 2>/dev/null || true; }
_repo_exclude_file() {
    local p
    p="$(_repo_git rev-parse --git-path info/exclude 2>/dev/null)" || return 1
    case "$p" in /*) ;; *) p="$REPO_DIR/$p" ;; esac
    printf '%s\n' "$p"
}
_repo_bench_ok() { [ -f "$REPO_DIR/bench/SHA256SUMS" ] && ( cd -- "$REPO_DIR" && sha256sum -c --status bench/SHA256SUMS ) >/dev/null 2>&1; }
# 0 when REPO_DIR is the checkout this setup script runs from
_repo_is_own_checkout() { [ "$(readlink -f -- "$REPO_DIR" 2>/dev/null)" = "$(readlink -f -- "$(dirname -- "$PROFILER_ROOT")" 2>/dev/null)" ]; }

phase_repo_check() {
    local branch excl dirt
    step "checking the checkout $REPO_DIR"
    _repo_present || { info "no git checkout at $REPO_DIR"; return 1; }
    branch="$(_repo_branch)"
    case "$branch" in
        profiler) ok "branch profiler ($(_repo_git rev-parse --short HEAD 2>/dev/null))" ;;
        trial/*) ok "branch $branch (an agent trial: left checked out)" ;;
        *) info "branch is '${branch:-detached HEAD}', expected profiler"; return 1 ;;
    esac
    _repo_git merge-base --is-ancestor "$P7_BASE" HEAD 2>/dev/null || { info "$P7_BASE is not an ancestor of HEAD: not the fork's history"; return 1; }
    ok "$P7_BASE is an ancestor of HEAD"
    if [ "$(_repo_git config --get core.autocrlf 2>/dev/null)" != false ] || [ "$(_repo_git config --get core.eol 2>/dev/null)" != lf ]; then
        info "core.autocrlf / core.eol are not false / lf"
        return 1
    fi
    ok "core.autocrlf=false core.eol=lf"
    excl="$(_repo_exclude_file)" || { info "cannot locate info/exclude"; return 1; }
    grep -qxF 'bench/' "$excl" 2>/dev/null || { info "bench/ is not listed in $excl"; return 1; }
    _repo_bench_ok || { info "bench/SHA256SUMS is missing or does not verify"; return 1; }
    [ -z "$(_repo_git status --porcelain -- bench 2>/dev/null)" ] || { info "git status still lists files under bench/"; return 1; }
    ok "bench/ restored ($(grep -c . "$REPO_DIR/bench/SHA256SUMS") assets verify) and excluded ($excl)"
    [ -z "$(_repo_git ls-files -- bench 2>/dev/null)" ] || warn "files under bench/ are tracked by git: they must never be committed (git rm -r --cached bench)"
    dirt="$(_repo_git status --porcelain 2>/dev/null | grep -vE '^.. dist/(BUILD-INFO[^ ]*\.txt|[^ ]*\.sha256)$' || true)"
    if [ -n "$dirt" ]; then
        warn "the working tree has $(grep -c . <<< "$dirt") uncommitted change(s)/untracked file(s): build.sh snapshots every non-ignored file"
        _p1_show "$(head -n 10 <<< "$dirt")"
    fi
    phase_note "branch $branch, bench/ verified"
    return 0
}

phase_repo_apply() {
    local branch excl bundle
    _p1_need_cmds git tar sha256sum || return 1
    bundle="$(_repo_bundle)"
    if ! _repo_present; then
        if [ -e "$REPO_DIR" ] && [ -n "$(ls -A -- "$REPO_DIR" 2>/dev/null)" ]; then
            fail "$REPO_DIR exists but is not a git checkout: move it away or pass --repo-dir"
            return 1
        fi
        if [ -f "$bundle" ]; then
            step "cloning the bootstrap bundle $bundle (branch profiler)"
            run -- git clone -b profiler -- "$bundle" "$REPO_DIR" || return 1
            run -- git -C "$REPO_DIR" remote set-url origin "$P7_UPSTREAM" || return 1
        else
            step "cloning $P7_UPSTREAM (no bootstrap bundle at $bundle)"
            run --timeout 1800 -- git clone -- "$P7_UPSTREAM" "$REPO_DIR" || return 1
        fi
    fi
    step "line endings (core.autocrlf=false, core.eol=lf)"
    [ "$(_repo_git config --get core.autocrlf 2>/dev/null)" = false ] || run -- git -C "$REPO_DIR" config core.autocrlf false || return 1
    [ "$(_repo_git config --get core.eol 2>/dev/null)" = lf ] || run -- git -C "$REPO_DIR" config core.eol lf || return 1
    step "branch profiler"
    branch="$(_repo_branch)"
    case "$branch" in
        profiler|trial/*) skip "on branch $branch" ;;
        *)
            if _repo_is_own_checkout; then
                fail "$REPO_DIR is on '${branch:-detached HEAD}' and is the checkout running this setup: switch it by hand (git -C $REPO_DIR switch profiler) and re-run"
                return 1
            fi
            if ! _repo_git rev-parse -q --verify refs/heads/profiler >/dev/null 2>&1; then
                if [ -f "$bundle" ]; then
                    run -- git -C "$REPO_DIR" fetch "$bundle" profiler:profiler || return 1
                else
                    warn "no branch profiler and no bundle: creating it at $P7_BASE, which has no profiler/ directory (bootstrap from the bundle: profiler/setup/bootstrap.md)"
                    run -- git -C "$REPO_DIR" branch profiler "$P7_BASE" || return 1
                fi
            fi
            run -- git -C "$REPO_DIR" checkout profiler || return 1 ;;
    esac
    if ! is_dry_run && ! _repo_git merge-base --is-ancestor "$P7_BASE" HEAD 2>/dev/null; then
        fail "$P7_BASE is not an ancestor of HEAD in $REPO_DIR: this is not the fork's history (re-clone from the bootstrap bundle)"
        return 1
    fi
    step "bench/ from $P7_BENCH_REV (kept out of git through info/exclude)"
    if excl="$(_repo_exclude_file)"; then
        ensure_line "$excl" 'bench/' || return 1
    elif is_dry_run; then
        info "dry run: would add bench/ to $REPO_DIR/.git/info/exclude"
    else
        fail "cannot locate $REPO_DIR's info/exclude"; return 1
    fi
    if _repo_bench_ok; then
        skip "bench/SHA256SUMS verifies"
    else
        if ! is_dry_run && ! _repo_git cat-file -e "${P7_BENCH_REV}^{commit}" 2>/dev/null; then
            fail "the history lacks $P7_BENCH_REV (shallow clone?): git -C $REPO_DIR fetch --unshallow origin, then re-run"
            return 1
        fi
        # shellcheck disable=SC2016  # $1/$2 belong to the inner bash
        run -- bash -o pipefail -c 'git -C "$1" archive "$2" bench | tar -x -C "$1"' bench-restore "$REPO_DIR" "$P7_BENCH_REV" || return 1
        # shellcheck disable=SC2016
        run -- bash -c 'cd -- "$1" && sha256sum -c --quiet bench/SHA256SUMS' bench-verify "$REPO_DIR" || return 1
        is_dry_run || ok "bench/ restored and verified"
    fi
    phase_note "checkout ready"
    return 0
}
