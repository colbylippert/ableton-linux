#!/usr/bin/env bash
# profiler/setup/lib/phase.sh — phase registry, runner, markers, options and host
# helpers for profiler/setup/setup-machine.sh. Sourced after lib/log.sh.
#
# ============================== WRITING A PHASE ==============================
#
# A phase is one file profiler/setup/phases/NN-<name>.sh (NN = two digits, name =
# [a-z][a-z0-9_]*). The driver sources every phase file in lexical order, so a
# phase file only DEFINES things at source time — never runs anything. Layout:
#
#   phase_register 04 limits "RT limits, sysctls and the realtime group" "packages"
#
#   phase_limits_check() {            # READ-ONLY. 0 = desired state present.
#       step "checking RT limits"
#       [ -f /etc/security/limits.d/90-profiler.conf ] || return 1
#       id -nG | grep -qw realtime || return 1
#       ok "limits present"
#   }
#   phase_limits_apply() {            # mutations; every one through `run`
#       write_template "$TEMPLATES_DIR/limits-profiler.conf" \
#           /etc/security/limits.d/90-profiler.conf --sudo --mode 0644 || return 1
#       run --sudo -- usermod -aG realtime,audio "$USER" || return 1
#       need_relogin
#       phase_note "added $USER to realtime,audio"
#   }
#
# The contract:
#   * phase_register NN NAME DESCRIPTION [DEPS]  — DEPS is a comma list of phase
#     names that must be done (marker present) or selected earlier in this run.
#     "all" means every phase registered before this one.
#   * The runner calls `check`; when it passes and --force is absent the phase is
#     skipped. Otherwise it calls `apply`, then `check` again, which must pass.
#     Then it writes the advisory marker ~/.local/state/profiler/phases/NN-NAME.done
#     (ts=… stamp=…). A later run always re-evaluates `check`, so phases must be
#     idempotent: apply only what is missing, re-running must be harmless.
#   * `check` runs under --dry-run too (it is read-only); `apply` runs as well but
#     every `run` just prints "[dry-run]" and the post-check is skipped.
#   * Return codes matter: the runner invokes check/apply as conditions, which
#     means `set -e` is NOT in effect inside them. Chain every step that must
#     abort the phase: `run -- cmd || return 1`, `fail "why" || return 1`.
#     As a safety net the runner also fails the phase when FAIL_COUNT grew during
#     apply, even if apply returned 0.
#   * Output only through step/ok/warn/fail/skip/info/kv (never a raw echo), and
#     commands that change the host only through `run`. `run --sudo -- cmd` uses
#     `sudo -n` (phase 01 "sudo" guarantees it works; the keepalive renews it).
#     The keepalive starts lazily at the first `run --sudo` (or --sudo probe of
#     write_template/ensure_line): NOPASSWD → nothing to do, otherwise one
#     `sudo -v` prompt on the terminal, so a selection without sudo never asks.
#     Read-only probes in `check` call commands directly (they must still work
#     under --dry-run, when `run` executes nothing). `run` gives the command
#     stdin from /dev/null and waits until its stdout/stderr close, so a command
#     that leaves a daemon behind must detach it with its own redirections
#     (e.g. `run -- sh -c 'setsid cmd >/dev/null 2>&1 &'`), and anything that
#     needs a terminal (sudo prompts, `read`) must not go through `run`.
#   * need_relogin / need_reboot flag that the user must log in again / reboot;
#     the summary prints it and the driver exits 3. phase_note TEXT puts a short
#     note in the summary row. action_required TEXT adds a line to the summary's
#     ACTIONS REQUIRED block. ask_continue PROMPT waits for Enter (not with --yes).
#   * State lives outside the repo (build.sh snapshots the tree and aborts on
#     changes): $(state_dir) = ~/.local/state/profiler (markers, logs, facts),
#     $(share_dir) = ~/.local/share/profiler (runs, snapshots), $(cache_dir) =
#     ~/.cache/profiler (downloads), $(config_dir) = ~/.config/profiler.
#   * Options: cfg_get KEY [DEFAULT] reads ~/.config/profiler/setup.conf; the
#     driver already exported the common ones. cfg_set KEY VALUE persists a value
#     (e.g. user_library=…) for later phases and verify.sh.
#   * Variables exported by the driver: PROFILE (vm|baremetal), REPO_DIR, MEDIA_DIR,
#     LIVE_INSTALLER, JOBS, AUDIO_BUFFER, PASSWORDLESS_SUDO (0|1), AUTOLOGIN (0|1),
#     VM_RAM_CHECK (0|1), ASSUME_YES (0|1), DRY_RUN (0|1), FORCE (0|1), SETUP_ROOT
#     (profiler/setup), PROFILER_ROOT (profiler/), TEMPLATES_DIR (profiler/setup/
#     templates), PROFILER_STATE_DIR, PROFILER_TMPDIR (scratch directory the driver
#     creates before the first phase and removes on exit; use it for temp files).
#     Helpers: profile_is vm|baremetal, is_dry_run, require_cmd CMD… .
#   * Templates: write_template SRC DST [--sudo] [--mode M] [--owner U:G] renders
#     @@VAR@@ tokens from the environment (unresolved tokens are an error), does
#     nothing when DST already has that content, otherwise installs it through
#     `run` (temp file + install -D). ensure_line FILE LINE [--sudo] appends a
#     line once. With --sudo both probe and read DST as root (`sudo -n test/cat`),
#     so files in root-only directories such as /etc/sudoers.d are seen; under
#     --dry-run sudo is never invoked and such files count as absent.
#
# Public API (besides the above): phase_select, phase_run NAME, phases_run_all,
# phase_list, phase_is_done NAME, sudo_keepalive_start, sudo_keepalive_stop.
# Variables owned: PHASE_NUMS[] PHASE_NAMES[] PHASE_DESCS[] PHASE_DEPS[]
# PHASE_INDEX[] PHASES_SELECTED[] CURRENT_PHASE PHASE_NOTE NEED_RELOGIN NEED_REBOOT
# SUDO_KEEPALIVE_PID SUDO_KEEPALIVE_TRIED PROFILER_TMPDIR_OWNER PHASE_SUMMARY_ON_EXIT.
# Selection inputs: ONLY SKIP FROM FORCE.
# ==========================================================================

[ -n "${BASH_VERSION:-}" ] || { echo "phase.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }
declare -F fail >/dev/null 2>&1 || { echo "phase.sh: source lib/log.sh first" >&2; return 1 2>/dev/null || exit 1; }

declare -a PHASE_NUMS=() PHASE_NAMES=() PHASE_DESCS=() PHASE_DEPS=() PHASES_SELECTED=()
declare -A PHASE_INDEX=()
: "${CURRENT_PHASE:=}"
: "${PHASE_NOTE:=}"
: "${NEED_RELOGIN:=0}"
: "${NEED_REBOOT:=0}"
: "${SUDO_KEEPALIVE_PID:=}"
: "${SUDO_KEEPALIVE_TRIED:=0}"
: "${PHASE_SUMMARY_ON_EXIT:=0}"
: "${ONLY:=}"
: "${SKIP:=}"
: "${FROM:=}"
: "${FORCE:=0}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${PROFILE:=}"
: "${PROFILER_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/profiler}"
: "${PROFILER_SHARE_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/profiler}"
: "${PROFILER_CACHE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/profiler}"
: "${PROFILER_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/profiler}"
: "${PROFILER_SETUP_CONF:=$PROFILER_CONFIG_DIR/setup.conf}"
: "${PROFILER_TMPDIR:=}"
: "${PROFILER_TMPDIR_OWNER:=}"      # pid of the shell that created PROFILER_TMPDIR (only it removes the dir)
export PROFILER_STATE_DIR PROFILER_SHARE_DIR PROFILER_CACHE_DIR PROFILER_CONFIG_DIR PROFILER_SETUP_CONF

# ------------------------------------------------------------ helpers ----
state_dir()  { mkdir -p -- "$PROFILER_STATE_DIR" 2>/dev/null || true; printf '%s\n' "$PROFILER_STATE_DIR"; }
share_dir()  { mkdir -p -- "$PROFILER_SHARE_DIR" 2>/dev/null || true; printf '%s\n' "$PROFILER_SHARE_DIR"; }
cache_dir()  { mkdir -p -- "$PROFILER_CACHE_DIR" 2>/dev/null || true; printf '%s\n' "$PROFILER_CACHE_DIR"; }
config_dir() { mkdir -p -- "$PROFILER_CONFIG_DIR" 2>/dev/null || true; printf '%s\n' "$PROFILER_CONFIG_DIR"; }
profile_is() { [ "$PROFILE" = "$1" ]; }
is_dry_run() { [ "${DRY_RUN:-0}" = 1 ]; }
need_relogin() { NEED_RELOGIN=1; action_required "log out and back in (group/limit changes take effect at login)"; }
need_reboot()  { NEED_REBOOT=1;  action_required "reboot (kernel/package changes take effect at boot)"; }
phase_note()   { PHASE_NOTE="${PHASE_NOTE:+$PHASE_NOTE; }$*"; }

require_cmd() {
    local c missing=()
    for c in "$@"; do command -v -- "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ "${#missing[@]}" -eq 0 ] || { fail "missing command(s): ${missing[*]}"; return 1; }
    return 0
}

# true when /dev/tty can actually be opened (permission bits alone lie without a controlling terminal)
_have_tty() { { : < /dev/tty; } 2>/dev/null && { : > /dev/tty; } 2>/dev/null; }

# _tmpdir: create the per-run scratch directory once (in THIS shell — never call it
# inside a command substitution, or the variable stays empty in the parent and the
# directory leaks past the EXIT trap) and print its path. The driver calls it right
# after log_init so every phase inherits PROFILER_TMPDIR; write_template calls it
# again for its side effect, which is a no-op once the directory exists.
_tmpdir() {
    if [ -z "$PROFILER_TMPDIR" ] || [ ! -d "$PROFILER_TMPDIR" ]; then
        PROFILER_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/profiler-setup.XXXXXX")" \
            || { PROFILER_TMPDIR=""; fail "cannot create a temporary directory under ${TMPDIR:-/tmp}"; return 1; }
        PROFILER_TMPDIR_OWNER="$$"
        export PROFILER_TMPDIR
    fi
    printf '%s\n' "$PROFILER_TMPDIR"
}

ask_continue() {
    local prompt="${1:-Press Enter to continue}"
    if [ "$ASSUME_YES" = 1 ]; then info "$prompt — continuing (--yes)"; return 0; fi
    if is_dry_run; then info "$prompt — continuing (dry run)"; return 0; fi
    if ! _have_tty; then warn "no terminal to wait on; continuing without confirmation"; return 0; fi
    printf '%s%s%s %s [Enter] %s' "$C_BOLD" "$C_CYAN" "$G_STEP" "$prompt" "$C_RESET" > /dev/tty
    IFS= read -r _ < /dev/tty || true
    _log_file "[$(now_hms)]   $G_STEP $prompt [Enter]"
    return 0
}

# ------------------------------------------------------------- config ----
_cfg_key_ok() { [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]]; }

cfg_get() {
    local key="$1" default="${2:-}" line value found=0
    _cfg_key_ok "$key" || { printf '%s\n' "$default"; return 0; }
    if [ -r "$PROFILER_SETUP_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$key="*) value="${line#*=}"; found=1 ;; esac
        done < "$PROFILER_SETUP_CONF"
    fi
    if [ "$found" -eq 1 ]; then printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
}

cfg_set() {
    local key="$1" value="${2:-}" tmp line replaced=0
    _cfg_key_ok "$key" || { fail "cfg_set: bad key '$key'"; return 1; }
    case "$value" in *$'\n'*) fail "cfg_set: value for $key contains a newline"; return 1 ;; esac
    if is_dry_run; then return 0; fi
    mkdir -p -- "$PROFILER_CONFIG_DIR" || { fail "cannot create $PROFILER_CONFIG_DIR"; return 1; }
    tmp="$(mktemp "$PROFILER_CONFIG_DIR/.setup.conf.XXXXXX")" || { fail "cfg_set: mktemp failed"; return 1; }
    if [ -r "$PROFILER_SETUP_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*) [ "$replaced" -eq 1 ] && continue; printf '%s=%s\n' "$key" "$value"; replaced=1 ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < "$PROFILER_SETUP_CONF" > "$tmp"
    fi
    [ "$replaced" -eq 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$PROFILER_SETUP_CONF" || { rm -f -- "$tmp"; fail "cannot write $PROFILER_SETUP_CONF"; return 1; }
    return 0
}

# ----------------------------------------------------------- templates ----
# render_template SRC  → prints the rendered text; returns 1 on unresolved tokens
render_template() {
    local src="$1" text name re='@@([A-Za-z_][A-Za-z0-9_]*)@@' unresolved=()
    [ -r "$src" ] || { fail "template not found: $src"; return 1; }
    text="$(cat -- "$src"; printf x)"; text="${text%x}"
    while [[ $text =~ $re ]]; do
        name="${BASH_REMATCH[1]}"
        if [ -n "${!name+x}" ]; then
            text="${text//"${BASH_REMATCH[0]}"/${!name}}"
        else
            unresolved+=("$name")
            text="${text//"${BASH_REMATCH[0]}"/}"
        fi
    done
    [ "${#unresolved[@]}" -eq 0 ] || { fail "unresolved template token(s) in ${src##*/}: @@${unresolved[*]}@@"; return 1; }
    printf '%s' "$text"
}

write_template() {
    local src="$1" dst="$2" use_sudo=0 mode="" owner="" rendered current exists tmp n line
    local -a inst=() runopt=()
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --sudo) use_sudo=1 ;;
            --mode) mode="$2"; shift ;;
            --mode=*) mode="${1#*=}" ;;
            --owner) owner="$2"; shift ;;
            --owner=*) owner="${1#*=}" ;;
            *) fail "write_template: unknown option $1"; return 1 ;;
        esac
        shift
    done
    rendered="$(render_template "$src" && printf x)" || return 1
    rendered="${rendered%x}"
    current=""; exists=0
    if [ -r "$dst" ]; then
        exists=1
        current="$(cat -- "$dst"; printf x)"; current="${current%x}"
    elif [ "$use_sudo" -eq 1 ] && ! is_dry_run; then
        # a root-only parent (e.g. /etc/sudoers.d, 0750) hides its entries from this user: probe and read as root
        sudo_keepalive_start || true
        if sudo -n test -e "$dst" 2>/dev/null; then
            exists=1
            current="$(sudo -n cat -- "$dst" 2>/dev/null; printf x)"; current="${current%x}"
        fi
    elif [ -e "$dst" ]; then
        exists=1      # present but unreadable without sudo: treated as different
    fi
    if [ "$exists" -eq 1 ] && [ "$rendered" = "$current" ]; then
        skip "$dst already up to date"
        return 0
    fi
    _tmpdir >/dev/null || return 1      # in this shell, so the directory is removed on exit
    tmp="$(mktemp "$PROFILER_TMPDIR/tpl.XXXXXX")" || { fail "write_template: mktemp failed"; return 1; }
    printf '%s' "$rendered" > "$tmp"
    if is_dry_run; then
        n="$(wc -l < "$tmp" | tr -d ' ')"
        info "would write $dst ($n lines) from ${src##*/}:"
        while IFS= read -r line || [ -n "$line" ]; do
            printf '%s[%s]%s     %s%s%s %s\n' "$C_DIM" "$(now_hms)" "$C_RESET" "$C_DIM" "$G_BAR" "$C_RESET" "$line" >&"$LOG_FD"
            _log_file "[$(now_hms)]     $G_BAR $line"
        done < "$tmp"
    fi
    inst=(install -D)
    [ -z "$mode" ] || inst+=(-m "$mode")
    [ -z "$owner" ] || inst+=(-o "${owner%%:*}" -g "${owner#*:}")
    [ "$use_sudo" -eq 0 ] || runopt=(--sudo)
    if run "${runopt[@]}" -- "${inst[@]}" "$tmp" "$dst"; then
        rm -f -- "$tmp"
        is_dry_run || ok "wrote $dst"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

ensure_line() {
    local file="$1" line="$2" use_sudo=0
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in --sudo) use_sudo=1 ;; *) fail "ensure_line: unknown option $1"; return 1 ;; esac; shift
    done
    if [ -r "$file" ]; then
        if grep -qxF -- "$line" "$file"; then skip "$file already contains: $line"; return 0; fi
    elif [ "$use_sudo" -eq 1 ] && ! is_dry_run; then
        # the file may sit in a root-only directory, so look as root (a missing file just fails the grep)
        sudo_keepalive_start || true
        if sudo -n grep -qxF -- "$line" "$file" 2>/dev/null; then skip "$file already contains: $line"; return 0; fi
    fi
    if [ "$use_sudo" -eq 1 ]; then
        run --sudo -- sh -c 'printf "%s\n" "$1" >> "$2"' ensure_line "$line" "$file" || return 1
    else
        run -- sh -c 'printf "%s\n" "$1" >> "$2"' ensure_line "$line" "$file" || return 1
    fi
    is_dry_run || ok "appended to $file: $line"
}

# ------------------------------------------------------------- sudo ----
# Started lazily: `run --sudo` (lib/log.sh) and the --sudo probes above call it on
# first use, so a selection that never needs sudo (e.g. --only claude) neither
# prompts nor warns. Decided once per run (SUDO_KEEPALIVE_TRIED): NOPASSWD in force
# → nothing to keep alive; otherwise `sudo -v` once on the terminal (unless a
# credential is already cached) and a background refresher that dies with this shell.
sudo_keepalive_start() {
    [ "$SUDO_KEEPALIVE_TRIED" -eq 0 ] || return 0
    is_dry_run && return 0
    command -v sudo >/dev/null 2>&1 || return 0
    SUDO_KEEPALIVE_TRIED=1
    if sudo -n -k true 2>/dev/null; then return 0; fi       # -k ignores the cache: succeeds only with NOPASSWD
    if ! sudo -n true 2>/dev/null; then                      # no cached credential either: ask once
        if ! _have_tty; then warn "sudo needs a password but there is no terminal (use ssh -t); sudo commands will fail"; return 0; fi
        info "sudo needs your password once; the credential is refreshed in the background"
        sudo -v < /dev/tty || { fail "sudo -v failed"; return 1; }
    fi
    ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || exit; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
sudo_keepalive_stop() {
    [ -n "$SUDO_KEEPALIVE_PID" ] || return 0
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
}

# ----------------------------------------------------------- registry ----
phase_register() {
    local num="$1" name="$2" desc="${3:-}" deps="${4:-}"
    [[ "$num" =~ ^[0-9][0-9]$ ]] || die "phase_register: number must be two digits (got '$num')" 2
    [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || die "phase_register: bad phase name '$name'" 2
    [ -z "${PHASE_INDEX[$name]+x}" ] || die "phase_register: phase '$name' registered twice" 2
    [[ "$deps" =~ ^[a-z0-9_,]*$ ]] || die "phase_register: bad dependency list '$deps' for $name" 2
    PHASE_INDEX[$name]="${#PHASE_NAMES[@]}"
    PHASE_NUMS+=("$num"); PHASE_NAMES+=("$name"); PHASE_DESCS+=("$desc"); PHASE_DEPS+=("$deps")
}

phase_marker() { printf '%s/phases/%s-%s.done\n' "$PROFILER_STATE_DIR" "${PHASE_NUMS[${PHASE_INDEX[$1]}]}" "$1"; }
phase_is_done() { [ -n "${PHASE_INDEX[$1]+x}" ] && [ -f "$(phase_marker "$1")" ]; }
_phase_last_num() { local n="00"; [ "${#PHASE_NUMS[@]}" -eq 0 ] || n="${PHASE_NUMS[$(( ${#PHASE_NUMS[@]} - 1 ))]}"; printf '%s\n' "$n"; }

_phase_deps_of() {   # expands "all"
    local name="$1" deps i out=()
    deps="${PHASE_DEPS[${PHASE_INDEX[$name]}]}"
    if [ "$deps" = all ]; then
        for (( i = 0; i < PHASE_INDEX[$name]; i++ )); do out+=("${PHASE_NAMES[i]}"); done
        printf '%s\n' "${out[@]}"
    elif [ -n "$deps" ]; then
        printf '%s\n' "${deps//,/$'\n'}"
    fi
}

phase_list() {
    local i marker st
    printf '%-4s %-11s %-9s %s\n' "#" "phase" "state" "description (needs)"
    for (( i = 0; i < ${#PHASE_NAMES[@]}; i++ )); do
        st="-"
        if [ -f "$PROFILER_STATE_DIR/phases/${PHASE_NUMS[i]}-${PHASE_NAMES[i]}.done" ]; then st="done"; fi
        printf '%-4s %-11s %-9s %s%s\n' "${PHASE_NUMS[i]}" "${PHASE_NAMES[i]}" "$st" "${PHASE_DESCS[i]}" "${PHASE_DEPS[i]:+  (needs: ${PHASE_DEPS[i]})}"
    done
}

_in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

phase_select() {
    local -a only=() skipl=() sel=() want=()
    local n i d from_idx=-1 missing
    [ "${#PHASE_NAMES[@]}" -gt 0 ] || die "no phases registered" 2
    IFS=',' read -r -a only <<< "${ONLY}"
    IFS=',' read -r -a skipl <<< "${SKIP}"
    for n in "${only[@]}" "${skipl[@]}" ${FROM:+"$FROM"}; do
        [ -z "$n" ] && continue
        [ -n "${PHASE_INDEX[$n]+x}" ] || die "unknown phase '$n' (see --list-phases)" 2
    done
    [ -z "$FROM" ] || from_idx="${PHASE_INDEX[$FROM]}"
    for (( i = 0; i < ${#PHASE_NAMES[@]}; i++ )); do
        n="${PHASE_NAMES[i]}"
        [ "$i" -ge "$from_idx" ] || continue
        if [ -n "$ONLY" ]; then _in_list "$n" "${only[@]}" || continue; fi
        if [ -n "$SKIP" ] && _in_list "$n" "${skipl[@]}"; then continue; fi
        sel+=("$n")
    done
    [ "${#sel[@]}" -gt 0 ] || die "the selection leaves no phase to run" 2
    for n in "${sel[@]}"; do
        missing=""
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            [ -n "${PHASE_INDEX[$d]+x}" ] || die "phase '$n' depends on unknown phase '$d'" 2
            _in_list "$d" "${sel[@]}" && continue
            phase_is_done "$d" && continue
            missing="${missing:+$missing,}$d"
        done < <(_phase_deps_of "$n")
        if [ -n "$missing" ]; then
            if [ "$FORCE" = 1 ]; then
                warn "phase '$n' needs '$missing' (neither done nor selected); continuing because of --force"
            else
                die "phase '$n' needs '$missing', which is neither done (no marker) nor selected. Add it to --only, run without --only/--skip, or use --force." 2
            fi
        fi
    done
    PHASES_SELECTED=("${sel[@]}")
}

# ------------------------------------------------------------- runner ----
_now_s() { if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s\n' "${EPOCHREALTIME%%.*}"; else date +%s; fi; }

phase_stamp() {   # sha256 over the templates, the phase file and setup.conf
    local name="$1" idx f
    idx="${PHASE_INDEX[$name]}"
    command -v sha256sum >/dev/null 2>&1 || { printf 'none\n'; return 0; }
    {
        for f in "${TEMPLATES_DIR:-/nonexistent}"/* "${SETUP_ROOT:-.}/phases/${PHASE_NUMS[idx]}-$name.sh" "$PROFILER_SETUP_CONF"; do
            [ -f "$f" ] && sha256sum -- "$f"
        done
        printf 'profile=%s\n' "$PROFILE"
    } 2>/dev/null | sha256sum | cut -c1-16
}

_phase_write_marker() {
    local name="$1" marker
    marker="$(phase_marker "$name")"
    mkdir -p -- "$(dirname -- "$marker")" || { warn "cannot create $(dirname -- "$marker")"; return 0; }
    printf 'ts=%s\nstamp=%s\nprofile=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(phase_stamp "$name")" "$PROFILE" > "$marker" \
        || warn "cannot write marker $marker"
}

phase_run() {
    local name="$1" idx num t0 secs warn0 fail0 status="ok" marker ts
    [ -n "${PHASE_INDEX[$name]+x}" ] || die "phase_run: unknown phase '$name'" 2
    idx="${PHASE_INDEX[$name]}"; num="${PHASE_NUMS[idx]}"
    declare -F "phase_${name}_check" >/dev/null || die "phase '$name' defines no phase_${name}_check" 2
    declare -F "phase_${name}_apply" >/dev/null || die "phase '$name' defines no phase_${name}_apply" 2
    section "$num" "$(_phase_last_num)" "$name"
    CURRENT_PHASE="$name"; PHASE_NOTE=""
    t0="$(_now_s)"; warn0="$WARN_COUNT"; fail0="$FAIL_COUNT"
    marker="$(phase_marker "$name")"
    if [ -f "$marker" ]; then
        ts="$(sed -n 's/^ts=//p' "$marker" 2>/dev/null | head -n1)"
        info "marker present (done ${ts:-earlier})$([ "$FORCE" = 1 ] && printf '; --force re-applies')"
    fi
    if [ "$FORCE" != 1 ] && "phase_${name}_check"; then
        skip "already in the desired state"
        secs=$(( $(_now_s) - t0 ))
        [ "$WARN_COUNT" -eq "$warn0" ] || status="warn"
        [ "$status" = warn ] && summary_add "$name" "warn" "$secs" "${PHASE_NOTE:-skipped: already done}" || summary_add "$name" "skipped" "$secs" "${PHASE_NOTE:-already done}"
        CURRENT_PHASE=""
        return 0
    fi
    [ "$FAIL_COUNT" -eq "$fail0" ] || info "check reported failures above; applying"
    fail0="$FAIL_COUNT"
    step "applying $name"
    if "phase_${name}_apply" && [ "$FAIL_COUNT" -eq "$fail0" ]; then
        if is_dry_run; then
            status="dry-run"
            ok "$name: dry run complete (post-check skipped)"
        elif "phase_${name}_check"; then
            _phase_write_marker "$name"
            [ "$WARN_COUNT" -eq "$warn0" ] || status="warn"
            ok "$name done"
        else
            fail "$name: check still fails after apply" || true
            status="failed"
        fi
    else
        [ "$FAIL_COUNT" -gt "$fail0" ] || fail "$name: apply failed" || true
        status="failed"
    fi
    secs=$(( $(_now_s) - t0 ))
    summary_add "$name" "$status" "$secs" "$PHASE_NOTE"
    CURRENT_PHASE=""
    [ "$status" != failed ]
}

phases_run_all() {
    local n failed=0 i
    [ "${#PHASES_SELECTED[@]}" -gt 0 ] || phase_select
    for (( i = 0; i < ${#PHASES_SELECTED[@]}; i++ )); do
        n="${PHASES_SELECTED[i]}"
        if [ "$failed" -eq 1 ]; then summary_add "$n" "not-run" 0 "after failure"; continue; fi
        phase_run "$n" || failed=1          # the sudo keepalive starts at the first `run --sudo`, not here
    done
    if [ "$failed" -eq 1 ]; then return 1; fi
    if [ "$NEED_RELOGIN" = 1 ] || [ "$NEED_REBOOT" = 1 ]; then return 3; fi
    return 0
}

# --------------------------------------------------------------- traps ----
_phase_on_exit() {
    local rc=$?
    sudo_keepalive_stop
    if [ "$PHASE_SUMMARY_ON_EXIT" = 1 ]; then
        [ -z "$CURRENT_PHASE" ] || summary_add "$CURRENT_PHASE" "failed" 0 "interrupted (exit $rc)"
        summary_table
    fi
    # only the shell that created the scratch dir removes it (a child that sources
    # this file inherits the exported path and must leave it alone)
    if [ -n "$PROFILER_TMPDIR" ] && [ "$PROFILER_TMPDIR_OWNER" = "$$" ]; then
        rm -rf -- "$PROFILER_TMPDIR" 2>/dev/null || true
    fi
    return 0
}
_phase_on_int() {
    printf '\n' >&"$LOG_FD"
    warn "interrupted"
    exit 130
}
trap _phase_on_exit EXIT
trap _phase_on_int INT TERM
