#!/usr/bin/env bash
# profiler/setup/phases/08-media.sh — phase 08 "media": the Ableton Live 12 Trial
# installer the install phase feeds to scripts/installer.sh.
# Expected (LIVE_INSTALLER, default ~/Proprietary/ableton/Ableton Live 12 Trial
# Installer.exe): the Inno Setup .exe plus exactly three disk slices
# "<name>-1.bin" … "-3.bin" beside it (the installer runs it from that folder,
# scripts/installer.sh:1309-1317). The project pins one installer build:
#     exe   6563056 bytes  sha256 a2652ee454fcf788…
#     -1    2093447424     sha256 8f849e5528616d5d…
#     -2    2100000000     sha256 5555fa3617e66efc…
#     -3    1906010295     sha256 92825f81abba502f…
# (hashed from C:\src\AbletonLinux\AbletonInstaller, 2026-10-16). Other media:
# PROFILER_MEDIA_PIN=0 keeps only the structural checks.
# Check (read-only, seconds): the four files exist with the pinned sizes (each
# slice > 1 GiB), the name contains "live…12" (installer.sh derives the Live
# major from the file name: this .exe carries "Ableton Live 12" only as UTF-16
# text, which its 8-bit `strings` scan misses), "Inno Setup" and no ".wixburn"
# in the first 4 MiB (installer.sh's engine test), "Ableton Live 12" among the
# 8-bit or UTF-16 strings, and ~/.local/state/profiler/media.env records the
# sha256 of every file, matching the pins, for the files' current size and mtime.
# Apply: reports what is missing (the media come from Windows by scp; see
# profiler/setup/bootstrap.md), hashes the four files (~6 GB, about 15 s) and
# writes media.env. Nothing is ever copied or modified.

phase_register 08 media "Live 12 Trial installer media: .exe + 3 slices, pinned sha256, Inno Setup, Live 12" ""

P8_EXE_SIZE=6563056
P8_EXE_SHA256=a2652ee454fcf788abd73d4a19903a9c455b1f28b952966f4f2bcd6249f54092
P8_SLICE_SIZES=(2093447424 2100000000 1906010295)
P8_SLICE_SHA256=(8f849e5528616d5d36918527dece4c0009448bfdb95b08141dcf48e89fe3b547
                 5555fa3617e66efc466151b6d34ec2e4636476d3bdb9202b0bd00f2daecc8f46
                 92825f81abba502f57bbe7184e7c00d52c7f9a00c87d64ff00055c9fd89f8672)

_med_record() { printf '%s/media.env\n' "$PROFILER_STATE_DIR"; }
_med_pinned() { [ "${PROFILER_MEDIA_PIN:-1}" != 0 ]; }
_med_slice() { local exe="$LIVE_INSTALLER"; printf '%s-%s.bin\n' "${exe%.*}" "$1"; }
_med_files() { printf '%s\n' "$LIVE_INSTALLER" "$(_med_slice 1)" "$(_med_slice 2)" "$(_med_slice 3)"; }
_med_stat() { stat -L -c '%s %Y' -- "$1" 2>/dev/null; }
# sha256 the pin expects for FILE ("" when unpinned)
_med_pin_sha() {
    _med_pinned || return 0
    case "$1" in
        "$LIVE_INSTALLER") printf '%s\n' "$P8_EXE_SHA256" ;;
        "$(_med_slice 1)") printf '%s\n' "${P8_SLICE_SHA256[0]}" ;;
        "$(_med_slice 2)") printf '%s\n' "${P8_SLICE_SHA256[1]}" ;;
        "$(_med_slice 3)") printf '%s\n' "${P8_SLICE_SHA256[2]}" ;;
    esac
}
_med_copy_hint() {
    info "copy the installer from Windows (all four files into one folder):"
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
    for i in 1 2 3; do
        f="$(_med_slice "$i")"
        [ -f "$f" ] || { info "slice missing: $f (the three -N.bin slices must sit beside the .exe)"; return 1; }
        read -r size mtime <<< "$(_med_stat "$f")"
        [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1073741824 ] || { info "${f##*/} is only ${size:-?} bytes (> 1 GiB expected: a truncated copy?)"; return 1; }
        if _med_pinned && [ "$size" != "${P8_SLICE_SIZES[i-1]}" ]; then info "${f##*/} is $size bytes, the pinned slice is ${P8_SLICE_SIZES[i-1]} (truncated or different media)"; return 1; fi
    done
    shopt -s nullglob
    extra=("${exe%.*}"-*.bin)
    shopt -u nullglob
    n="${#extra[@]}"
    [ "$n" -eq 3 ] || { info "found $n '${base%.*}-*.bin' slices beside the .exe, expected exactly 3"; return 1; }
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
    ok "installer + 3 slices present, Inno Setup, Live 12$(_med_pinned && printf ', pinned sizes')"
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
    ok "sha256 of all four files recorded and $(_med_pinned && printf 'matching the pins' || printf 'unpinned (PROFILER_MEDIA_PIN=0)') ($(_p1_record_get "$rec" ts))"
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
