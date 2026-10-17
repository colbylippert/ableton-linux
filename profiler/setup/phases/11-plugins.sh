#!/usr/bin/env bash
# profiler/setup/phases/11-plugins.sh — phase 11 "plugins": the VST3 plug-ins
# Benchmark_VSTs needs (Dexed.vst3 bundle directory, K1v_x64.vst3 file), driven
# by profiler/setup/plugins.lock:
#
#   # name   url=…   sha256=…   member=…        (one entry per line, # comments)
#   dexed  url=https://github.com/asb2m10/dexed/releases/download/vX/… sha256=<64 hex> member=Dexed.vst3
#   k1v    url=https://www.nilsschneider.de/…/K1v_x64.vst3.zip         sha256=<64 hex> member=K1v_x64.vst3
#
# An entry is "pinned" when sha256= is 64 hex digits; anything else (placeholder,
# empty) is unpinned: the download is accepted, its observed sha256 is printed so
# it can be pinned, and a failed download is a warning, not a phase failure.
# Downloads live in ~/.cache/profiler/downloads/<name>/ (re-used when the pinned
# hash matches); the archive is extracted next to it and the member copied into
# <prefix>/drive_c/Program Files/Common Files/VST3/ (the suite's find_vst path,
# scripts/bench-suite.sh:122-131).
# Uses the _lp_* helpers from 09-build.sh.

phase_register 11 plugins "Dexed + K1v VST3 plug-ins (profiler/setup/plugins.lock)" "install"

: "${_PLUGINS_ATTEMPTED:=0}"        # set by apply: unpinned download failures are then tolerated by check
declare -A _PLUG_URL=() _PLUG_SHA=() _PLUG_MEMBER=() _PLUG_KIND=() _PLUG_SIZE=()
declare -a _PLUG_NAMES=()

_plugins_lock() { printf '%s/plugins.lock\n' "$SETUP_ROOT"; }
_plugins_vst3_dir() { printf '%s/drive_c/Program Files/Common Files/VST3\n' "$(_lp_prefix)"; }
_plugins_pinned() { [[ "${_PLUG_SHA[$1]:-}" =~ ^[0-9a-f]{64}$ ]]; }
_plugins_url_ok() { [[ "${_PLUG_URL[$1]:-}" =~ ^https?://[^[:space:]\<\>]+$ ]]; }

# parse plugins.lock into the arrays; 1 when missing or malformed
_plugins_parse() {
    local lock line name tok key val
    local -a toks=()
    lock="$(_plugins_lock)"
    _PLUG_NAMES=(); _PLUG_URL=(); _PLUG_SHA=(); _PLUG_MEMBER=(); _PLUG_KIND=(); _PLUG_SIZE=()
    [ -r "$lock" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        [ -n "${line//[[:space:]]/}" ] || continue
        read -r -a toks <<< "$line"
        name="${toks[0]}"
        [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || { fail "plugins.lock: bad entry name '$name'"; return 1; }
        for tok in "${toks[@]:1}"; do
            key="${tok%%=*}"; val="${tok#*=}"
            case "$key" in
                url) _PLUG_URL[$name]="$val" ;;
                sha256) _PLUG_SHA[$name]="${val,,}" ;;
                member) _PLUG_MEMBER[$name]="$val" ;;
                kind) _PLUG_KIND[$name]="$val" ;;
                size) _PLUG_SIZE[$name]="$val" ;;
                *) ;;                      # version=, license= and unknown keys: informational, ignored
            esac
        done
        [ -n "${_PLUG_MEMBER[$name]:-}" ] || { fail "plugins.lock: entry '$name' has no member="; return 1; }
        case "${_PLUG_MEMBER[$name]}" in */*|.|..) fail "plugins.lock: member for '$name' must be a bare name"; return 1 ;; esac
        _PLUG_NAMES+=("$name")
    done < "$lock"
    [ "${#_PLUG_NAMES[@]}" -gt 0 ]
}

phase_plugins_check() {
    local dir name member dest missing=0 pending=0
    if ! _plugins_parse; then info "cannot read $(_plugins_lock)"; return 1; fi
    dir="$(_plugins_vst3_dir)"
    step "checking VST3 plug-ins in $dir"
    for name in "${_PLUG_NAMES[@]}"; do
        member="${_PLUG_MEMBER[$name]}"; dest="$dir/$member"
        if [ -e "$dest" ]; then
            ok "$name: $member present"
        elif [ "$_PLUGINS_ATTEMPTED" = 1 ] && ! _plugins_pinned "$name"; then
            warn "$name: $member not installed (unpinned entry, download failed); Benchmark_VSTs needs it — the suite refuses without --skip-vst-check"
            pending=1
        else
            info "$name: $member missing"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1
    if [ "$pending" -eq 1 ]; then phase_note "unpinned plug-in(s) pending"; else phase_note "${#_PLUG_NAMES[@]} plug-in(s) present"; fi
    return 0
}

phase_plugins_apply() {
    local dir cache name url sha member file extract found actual
    require_cmd curl unzip sha256sum find tar || return 1
    if ! _plugins_parse; then
        fail "cannot parse $(_plugins_lock) (expected: name url=… sha256=… member=… per line)" || return 1
    fi
    [ -d "$(_lp_prefix)/drive_c" ] || prereq_fail "prefix $(_lp_prefix) has no drive_c (phase install)" || return 1
    dir="$(_plugins_vst3_dir)"
    _PLUGINS_ATTEMPTED=1
    run -- mkdir -p -- "$dir" || return 1
    for name in "${_PLUG_NAMES[@]}"; do
        url="${_PLUG_URL[$name]:-}"; sha="${_PLUG_SHA[$name]:-}"; member="${_PLUG_MEMBER[$name]}"
        step "$name → $member"
        if [ -e "$dir/$member" ] && [ "$FORCE" != 1 ]; then skip "$name already installed at $dir/$member"; continue; fi
        if ! _plugins_url_ok "$name"; then
            warn "$name: no usable download URL in plugins.lock ('${url:-}'); install $member by hand into $dir"
            continue
        fi
        cache="$(cache_dir)/downloads/$name"
        file="${url##*/}"; file="${file%%\?*}"; file="$cache/${file:-download}"
        if [ -s "$file" ] && _plugins_pinned "$name" && [ "$(sha256sum < "$file" | cut -d' ' -f1)" = "$sha" ]; then
            ok "$name: cached download matches the pinned sha256 ($file)"
        else
            run -- mkdir -p -- "$cache" || return 1
            kv "url" "$url"
            if ! run --allow-fail --timeout 600 -- curl -fsSL --retry 3 --retry-delay 5 -o "$file.part" -- "$url"; then
                rm -f -- "$file.part"
                if _plugins_pinned "$name"; then
                    fail "$name: download failed (exit $RUN_STATUS): $url" || return 1
                fi
                warn "$name: download failed (exit $RUN_STATUS; unpinned entry): $url — skipped; fix url=/sha256= in plugins.lock or copy $member into $dir by hand"
                continue
            fi
            if is_dry_run; then info "would verify, extract and copy $member into $dir"; continue; fi
            run -- mv -f -- "$file.part" "$file" || return 1
        fi
        if [[ "${_PLUG_SIZE[$name]:-}" =~ ^[0-9]+$ ]] && [ "$(stat -c %s -- "$file" 2>/dev/null || echo 0)" != "${_PLUG_SIZE[$name]}" ]; then
            warn "$name: downloaded size $(stat -c %s -- "$file" 2>/dev/null || echo ?) B differs from size=${_PLUG_SIZE[$name]} in plugins.lock (upstream archive replaced?)"
        fi
        actual="$(sha256sum < "$file" | cut -d' ' -f1)"
        if _plugins_pinned "$name"; then
            if [ "$actual" != "$sha" ]; then
                rm -f -- "$file"
                fail "$name: sha256 mismatch (expected $sha, got $actual) — download discarded" || return 1
            fi
            ok "$name: sha256 verified"
        else
            warn "$name: unpinned entry; observed sha256=$actual for $url — pin it in $(_plugins_lock)"
        fi
        if is_dry_run; then info "would extract $(basename -- "$file") and copy $member into $dir"; continue; fi
        extract="$cache/extract"
        run -- rm -rf -- "$extract" || return 1
        run -- mkdir -p -- "$extract" || return 1
        case "${file,,}" in
            *.zip) run -- unzip -q -o -- "$file" -d "$extract" || return 1 ;;
            *.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.zst|*.tar.bz2) run -- tar -xf "$file" -C "$extract" || return 1 ;;
            *) run -- cp -a -- "$file" "$extract/" || return 1 ;;
        esac
        # shallowest match: a bundle directory can contain a file of the same name (Dexed.vst3/Contents/x86_64-win/Dexed.vst3)
        found="$(find "$extract" -name "$member" -printf '%d\t%p\n' 2>/dev/null | sort -n | head -n1 | cut -f2- || true)"
        [ -n "$found" ] || { fail "$name: $member not found inside $(basename -- "$file")" || return 1; }
        case "${_PLUG_KIND[$name]:-}" in
            bundle) [ -d "$found" ] || warn "$name: plugins.lock says kind=bundle but $member is not a directory" ;;
            file) [ -f "$found" ] || warn "$name: plugins.lock says kind=file but $member is not a regular file" ;;
        esac
        run -- rm -rf -- "$dir/$member" || return 1
        run -- cp -a -- "$found" "$dir/$member" || return 1
        ok "$name: installed $dir/$member"
    done
    phase_note "plug-ins from plugins.lock"
    return 0
}
