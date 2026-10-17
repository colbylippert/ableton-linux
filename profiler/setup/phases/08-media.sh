#!/usr/bin/env bash
# profiler/setup/phases/08-media.sh — phase 08 "media": the Ableton Live 12 Trial
# installer the install phase feeds to scripts/installer.sh.
# Expected (LIVE_INSTALLER, default ~/Proprietary/ableton/Ableton Live 12 Trial
# Installer.exe): the Inno Setup .exe plus its disk slices "<name>-1.bin" …
# "-N.bin" beside it (the installer runs it from that folder,
# scripts/installer.sh:1309-1317); N is the number of pinned slices. The project
# pins one installer build, Live 12.4.6 (the canonical bench Sets need >= 12.4.3):
#     exe   6615024 bytes  sha256 e4e334774046d861…
#     -1    2093395200     sha256 1aa672d9b440ea22…
#     -2    2100000000     sha256 15cf4f0d5e47815c…
#     -3    2100000000     sha256 b8ab050ff3f5a4a0…
#     -4     181806740     sha256 4eecfa0e5af0572a…
# (hashed from C:\src\AbletonLinux\AbletonInstaller, 2026-10-16; it replaced the
# 12.3.2 build, which refuses the 12.4.3 Sets). Other media: PROFILER_MEDIA_PIN=0
# keeps only the structural checks.
# Check (read-only, seconds): the files exist with the pinned sizes (every slice
# but the last > 1 GiB), the name contains "live…12" (installer.sh derives the Live
# major from the file name: this .exe carries "Ableton Live 12" only as UTF-16
# text, which its 8-bit `strings` scan misses), "Inno Setup" and no ".wixburn"
# in the first 4 MiB (installer.sh's engine test), "Ableton Live 12" among the
# 8-bit or UTF-16 strings, and ~/.local/state/profiler/media.env records the
# sha256 of every file, matching the pins, for the files' current size and mtime.
# Apply: reports what is missing (the media come from Windows by scp; see
# profiler/setup/bootstrap.md), hashes the installer and its slices (~6 GB, about 15 s) and
# writes media.env. Nothing is ever copied or modified.

phase_register 08 media "Live 12 Trial installer media: .exe + slices, pinned sha256, Inno Setup, Live 12" ""

P8_EXE_SIZE=6615024
P8_EXE_SHA256=e4e334774046d8614f0b37118be6fdf950ab2a838c2723e21f9f916fcabd7db1
P8_SLICE_SIZES=(2093395200 2100000000 2100000000 181806740)
P8_SLICE_SHA256=(1aa672d9b440ea2289cbdc108f61abaa752276f7f632e4708a0da6a3ca2454c8
                 15cf4f0d5e47815c178616d7e14dc168ec14d0738e2d0e0bf6b6484ee46391e4
                 b8ab050ff3f5a4a0494f58846549a441dc93260bf200c86546d167bbd73ea775
                 4eecfa0e5af0572a95c58421c39cc27888f4bced53cb9b8bc30b2bcc7d458dd2)
P8_SLICES=${#P8_SLICE_SIZES[@]}

_med_record() { printf '%s/media.env\n' "$PROFILER_STATE_DIR"; }
_med_pinned() { [ "${PROFILER_MEDIA_PIN:-1}" != 0 ]; }
_med_slice() { local exe="$LIVE_INSTALLER"; printf '%s-%s.bin\n' "${exe%.*}" "$1"; }
_med_files() { local i; printf '%s\n' "$LIVE_INSTALLER"; for ((i = 1; i <= P8_SLICES; i++)); do _med_slice "$i"; done; }
_med_stat() { stat -L -c '%s %Y' -- "$1" 2>/dev/null; }
# sha256 the pin expects for FILE ("" when unpinned)
_med_pin_sha() {
    _med_pinned || return 0
    local i
    [ "$1" = "$LIVE_INSTALLER" ] && { printf '%s\n' "$P8_EXE_SHA256"; return 0; }
    for ((i = 1; i <= P8_SLICES; i++)); do
        [ "$1" = "$(_med_slice "$i")" ] && { printf '%s\n' "${P8_SLICE_SHA256[i-1]}"; return 0; }
    done
    return 0
}
_med_copy_hint() {
    info "copy the installer from Windows (the .exe and all $P8_SLICES slices into one folder):"
    info "  scp \"C:\\src\\AbletonLinux\\AbletonInstaller\\*\" <this-host>:\"${LIVE_INSTALLER%/*}/\"   (see profiler/setup/bootstrap.md)"
}

# structural checks (no hashing); prints the reasons through info, 1 on the first problem
_med_structure() {
    local exe="$LIVE_INSTALLER" base lower n size mtime i f
    local -a extra=()
    base="${exe##*/}"
    [ -f "$exe" ] || { info "Live installer not found: $exe"; return 1; }
    lower="$(tr '[:upper:]' '[:lower:]' <<< "$base")"
    case "$lower" in
        *live*12*.exe) ;;
        *) info "'$base': scripts/installer.sh derives the Live major from the file name (it must contain 'live' and '12', like 'Ableton Live 12 Trial Installer.exe')"; return 1 ;;
    esac
    read -r size mtime <<< "$(_med_stat "$exe")"
    if _med_pinned && [ "$size" != "$P8_EXE_SIZE" ]; then info "$base is $size bytes, the pinned installer is $P8_EXE_SIZE (PROFILER_MEDIA_PIN=0 accepts other media)"; return 1; fi
    for ((i = 1; i <= P8_SLICES; i++)); do
        f="$(_med_slice "$i")"
        [ -f "$f" ] || { info "slice missing: $f (all $P8_SLICES -N.bin slices must sit beside the .exe)"; return 1; }
        read -r size mtime <<< "$(_med_stat "$f")"
        [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] || { info "${f##*/} is empty or unreadable"; return 1; }
        if [ "$i" -lt "$P8_SLICES" ] && [ "$size" -le 1073741824 ]; then info "${f##*/} is only $size bytes (> 1 GiB expected for every slice but the last: a truncated copy?)"; return 1; fi
        if _med_pinned && [ "$size" != "${P8_SLICE_SIZES[i-1]}" ]; then info "${f##*/} is $size bytes, the pinned slice is ${P8_SLICE_SIZES[i-1]} (truncated or different media)"; return 1; fi
    done
    shopt -s nullglob
    extra=("${exe%.*}"-*.bin)
    shopt -u nullglob
    n="${#extra[@]}"
    [ "$n" -eq "$P8_SLICES" ] || { info "found $n '${base%.*}-*.bin' slices beside the .exe, expected exactly $P8_SLICES"; return 1; }
    # process substitution, not a pipe: under pipefail grep -q's early exit would
    # SIGPIPE head/strings and turn a match into a failure
    if grep -qaF '.wixburn' < <(head -c 4194304 -- "$exe"); then info "$base is a WiX bundle (.wixburn), not the Inno Setup installer of Live 12"; return 1; fi
    grep -qa 'Inno Setup' < <(head -c 4194304 -- "$exe") || { info "no 'Inno Setup' signature in the first 4 MiB of $base"; return 1; }
    grep -Eqi 'Ableton[ _-]*Live[ _-]*12' < <({ strings -a -- "$exe"; strings -a -el -- "$exe"; } 2>/dev/null) \
        || { info "no 'Ableton Live 12' string in $base (8-bit or UTF-16)"; return 1; }
    return 0
}

phase_media_check() {
    local rec f st sum want
    rec="$(_med_record)"
    step "checking the Live installer media (${LIVE_INSTALLER%/*})"
    command -v strings >/dev/null 2>&1 || { info "strings is missing (binutils)"; return 1; }
    _med_structure || return 1
    ok "installer + $P8_SLICES slices present, Inno Setup, Live 12$(_med_pinned && printf ', pinned sizes')"
    while IFS= read -r f; do
        st="$(_med_stat "$f")"
        sum="$(_p1_record_get "$rec" "sha256.${f##*/}")"
        if [ "$(_p1_record_get "$rec" "stat.${f##*/}")" != "$st" ] || [ -z "$sum" ]; then
            info "no sha256 recorded for ${f##*/} as it is now ($rec)"
            return 1
        fi
        want="$(_med_pin_sha "$f")"
        if [ -n "$want" ] && [ "$sum" != "$want" ]; then info "${f##*/}: recorded sha256 ${sum:0:16}… is not the pinned ${want:0:16}…"; return 1; fi
    done < <(_med_files)
    ok "sha256 of all $((P8_SLICES + 1)) files recorded and $(_med_pinned && printf 'matching the pins' || printf 'unpinned (PROFILER_MEDIA_PIN=0)') ($(_p1_record_get "$rec" ts))"
    phase_note "Live 12 Trial media verified"
    return 0
}

phase_media_apply() {
    local f sum want bad=0
    local -a lines=()
    _p1_need_cmds sha256sum strings head stat || return 1
    kv "live installer" "$LIVE_INSTALLER"
    if ! _med_structure; then
        _med_copy_hint
        fail "the Live installer media are missing or incomplete (see above)"
        return 1
    fi
    step "hashing the installer and its slices (~6 GB, about 15 s)"
    while IFS= read -r f; do
        sum="$(sha256sum -- "$f" | cut -c1-64)" || { fail "cannot read $f"; return 1; }
        want="$(_med_pin_sha "$f")"
        if [ -n "$want" ] && [ "$sum" != "$want" ]; then
            fail "${f##*/}: sha256 ${sum:0:16}… differs from the pinned ${want:0:16}… (corrupt or truncated copy: copy it again)"
            bad=1
        else
            ok "${f##*/} ${sum:0:16}…$([ -n "$want" ] && printf ' (pinned)')"
        fi
        lines+=("stat.${f##*/}=$(_med_stat "$f")" "sha256.${f##*/}=$sum")
    done < <(_med_files)
    if [ "$bad" -eq 1 ]; then _med_copy_hint; return 1; fi
    _p1_record_write "$(_med_record)" < <(
        printf '# written by profiler/setup/phases/08-media.sh (stat = size mtime)\n'
        printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'installer=%s\n' "$LIVE_INSTALLER"
        printf 'pinned=%s\n' "$(_med_pinned && echo 1 || echo 0)"
        printf '%s\n' "${lines[@]}"
    ) || return 1
    phase_note "media verified$(_med_pinned && printf ' against the pins')"
    return 0
}
