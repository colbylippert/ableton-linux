#!/usr/bin/env bash
# profiler/setup/phases/03-podman.sh — phase 03 "podman": rootless Podman for
# ./build.sh and profiler/dev/wine-dev.sh.
#   * subordinate uid/gid ranges for the user (usermod --add-subuids/--add-subgids
#     100000-165535 when getsubids finds none), then `podman system migrate`
#   * `loginctl enable-linger` so user units (dashboard, PipeWire) survive logouts
#   * `podman info`: rootless, graph driver overlay (vfs would make the Wine
#     build unusably slow), network backend netavark
#   * smoke test: `podman run --rm docker.io/library/alpine:3.20 true` (pulls the
#     image once); the result is recorded in ~/.local/state/profiler/podman.env
#     together with the podman version, so the check needs no container run
# Check (read-only apart from podman's own lazy storage initialisation in
# `podman info`): ranges ≥ 65536 ids, linger on, info as above, and a smoke-test
# record for the installed podman version.

phase_register 03 podman "rootless podman: subuid/subgid, migrate, linger, overlay driver, alpine smoke run" "packages"

: "${P3_SMOKE_IMAGE:=docker.io/library/alpine:3.20}"
: "${P3_SUBID_RANGE:=100000-165535}"

_pod_record() { printf '%s/podman.env\n' "$PROFILER_STATE_DIR"; }
# count of the first subordinate range (getsubids [-g] USER → "0: user start count"); 0 when none
_pod_subids() {
    local out
    out="$(getsubids "$@" 2>/dev/null | awk 'NR == 1 { print $4 }')"
    [[ "$out" =~ ^[0-9]+$ ]] || out=0
    printf '%s\n' "$out"
}
_pod_linger() { [ "$(loginctl show-user "$(_p1_user)" -p Linger --value 2>/dev/null)" = yes ] || [ -e "/var/lib/systemd/linger/$(_p1_user)" ]; }
_pod_version() { podman --version 2>/dev/null | awk '{print $NF; exit}'; }
# "rootless driver native-diff network" from podman info
_pod_info() {
    podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}} {{index .Store.GraphStatus "Native Overlay Diff"}} {{.Host.NetworkBackend}}' 2>/dev/null
}

phase_podman_check() {
    local user uids gids rootless driver native net rec
    user="$(_p1_user)"; rec="$(_pod_record)"
    step "checking rootless podman"
    command -v podman >/dev/null 2>&1 || { info "podman is not installed (phase packages)"; return 1; }
    command -v getsubids >/dev/null 2>&1 || { info "getsubids is missing (shadow)"; return 1; }
    uids="$(_pod_subids "$user")"; gids="$(_pod_subids -g "$user")"
    if [ "$uids" -lt 65536 ] || [ "$gids" -lt 65536 ]; then
        info "subordinate ranges for $user: uids $uids, gids $gids (need >= 65536 each)"
        return 1
    fi
    ok "subuid/subgid ranges for $user ($uids/$gids ids)"
    if _pod_linger; then ok "linger enabled for $user"; else info "linger is off for $user"; return 1; fi
    read -r rootless driver native net <<< "$(_pod_info)"
    kv "podman info" "rootless=${rootless:-?} driver=${driver:-?} native-overlay-diff=${native:-?} network=${net:-?}"
    [ "$rootless" = true ] || { info "podman does not run rootless"; return 1; }
    [ "$driver" = overlay ] || { info "graph driver is '${driver:-?}', expected overlay"; return 1; }
    [ "$native" = true ] || warn "overlay without native diff (fuse-overlayfs?): builds work but are slower"
    [ "$net" = netavark ] || { info "network backend is '${net:-?}', expected netavark"; return 1; }
    ok "rootless, overlay, netavark"
    if [ "$(_p1_record_get "$rec" smoke)" = ok ] && [ "$(_p1_record_get "$rec" podman_version)" = "$(_pod_version)" ]; then
        ok "smoke test recorded for podman $(_pod_version) ($(_p1_record_get "$rec" ts))"
    else
        info "no smoke-test record for podman $(_pod_version) ($rec)"
        return 1
    fi
    phase_note "podman $(_pod_version), overlay, linger"
    return 0
}

phase_podman_apply() {
    local user uids gids rootless driver native net
    user="$(_p1_user)"
    _p1_need_cmds podman getsubids loginctl || return 1
    step "subordinate uid/gid ranges"
    uids=0; gids=0
    if command -v getsubids >/dev/null 2>&1; then uids="$(_pod_subids "$user")"; gids="$(_pod_subids -g "$user")"; fi
    if [ "$uids" -ge 65536 ] && [ "$gids" -ge 65536 ]; then
        skip "$user already has $uids subuids and $gids subgids"
    else
        local -a add=()
        [ "$uids" -ge 65536 ] || add+=(--add-subuids "$P3_SUBID_RANGE")
        [ "$gids" -ge 65536 ] || add+=(--add-subgids "$P3_SUBID_RANGE")
        run --sudo -- usermod "${add[@]}" "$user" || return 1
    fi
    run -- podman system migrate || return 1
    step "linger"
    if _pod_linger; then skip "linger already enabled"; else run --sudo -- loginctl enable-linger "$user" || return 1; fi
    step "storage driver and network backend"
    if is_dry_run && ! command -v podman >/dev/null 2>&1; then
        info "dry run: podman info is checked once podman is installed"
    else
        read -r rootless driver native net <<< "$(_pod_info)"
        kv "podman info" "rootless=${rootless:-?} driver=${driver:-?} native-overlay-diff=${native:-?} network=${net:-?}"
        if [ "$driver" != overlay ]; then
            fail "podman uses the '${driver:-?}' graph driver, expected overlay: check ~/.config/containers/storage.conf and /etc/containers/storage.conf (driver = \"overlay\"), then 'podman system reset' — that deletes all images and containers"
            return 1
        fi
        [ "$rootless" = true ] || { fail "podman info does not report a rootless setup"; return 1; }
        [ "$net" = netavark ] || warn "network backend is '${net:-?}', expected netavark (package netavark)"
    fi
    step "smoke test: podman run --rm $P3_SMOKE_IMAGE true (pulls the image once)"
    run --timeout 900 -- podman run --rm "$P3_SMOKE_IMAGE" true || return 1
    is_dry_run || ok "rootless container runs"
    _p1_record_write "$(_pod_record)" < <(
        printf '# written by profiler/setup/phases/03-podman.sh\n'
        printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'podman_version=%s\n' "$(_pod_version)"
        printf 'image=%s\n' "$P3_SMOKE_IMAGE"
        printf 'driver=%s\n' "${driver:-?}"
        printf 'smoke=ok\n'
    ) || return 1
    phase_note "rootless podman ready"
    return 0
}
