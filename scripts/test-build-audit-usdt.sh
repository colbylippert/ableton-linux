#!/usr/bin/env bash
# Covers build-audit.sh's USDT probe-site rule (usdt_nop10_report,
# --check-usdt-sites, must_usdt_nop10) and the site form that the vendored
# sdt.h copies of patches 0108 and pipeasio/0017 emit. Small shared objects
# are compiled with the host C compiler against the headers taken out of the
# patches; nothing runs, no Wine, no tracer, no build of the runtime.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
audit="$root/scripts/build-audit.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/build-audit-usdt-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

pass=0
check()
{
    local label="$1" got="$2" want="$3"
    if [ "$got" != "$want" ]; then
        printf 'not ok - %s\n  got:  %s\n  want: %s\n' "$label" "$got" "$want" >&2
        exit 1
    fi
    pass=$((pass + 1))
    printf 'ok - %s\n' "$label"
}
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

cc="${CC:-cc}"
command -v "$cc" >/dev/null || fail "no C compiler ($cc): this test builds its ELF fixtures"
command -v readelf >/dev/null || fail "readelf (binutils) is required, as by build-audit.sh"
[ "$(uname -m)" = x86_64 ] || fail "x86_64 only: the 10-byte nop is the x86_64 probe site"

# --- the vendored headers, exactly as the patches add them --------------------
new_file_in_patch()   # <patch> <path>: the content of a file the patch creates
{
    awk -v want="diff --git a/$2 b/$2" '
        $0 == want { found = 1; next }
        found && /^diff --git / { exit }
        found && /^@@ -0,0 \+1/ { body = 1; next }
        found && body && /^\+/ { print substr($0, 2) }' "$1"
}
wine_patch="$root/patches/0108-ntdll-add-static-trace-points.patch"
asio_patch="$root/patches/pipeasio/0017-usdt-block-markers.patch"
mkdir -p "$work/wine" "$work/pipeasio"
new_file_in_patch "$wine_patch" dlls/ntdll/unix/sdt.h > "$work/wine/sdt.h"
new_file_in_patch "$wine_patch" dlls/ntdll/unix/sdt-config.h > "$work/wine/sdt-config.h"
new_file_in_patch "$asio_patch" include/sdt.h > "$work/pipeasio/sdt.h"
new_file_in_patch "$asio_patch" include/sdt-config.h > "$work/pipeasio/sdt-config.h"
new_file_in_patch "$asio_patch" include/pipeasio_probe.h > "$work/pipeasio/pipeasio_probe.h"
for header in wine/sdt.h wine/sdt-config.h pipeasio/sdt.h pipeasio/sdt-config.h pipeasio/pipeasio_probe.h; do
    [ -s "$work/$header" ] || fail "cannot take $header out of its patch: is it still a new file there?"
done

build_so()   # <output> <header dir> <source file>
{
    mkdir -p "$(dirname "$1")"
    "$cc" -std=gnu11 -O2 -fPIC -shared -Wall -Wextra -I"$2" -o "$1" "$3" \
        || fail "cannot compile $(basename "$3") against $2/sdt.h"
}

# ntdll.so's two kinds of site: STAP_PROBE1/2 in C (server.c) and
# STAP_PROBE_ASM inside a global asm function (the dispatchers in
# signal_x86_64.c). SITE_FORM, when set, replaces the header's site to model a
# broken or older build. It is a plain string, so the fixtures depend on the
# header's _SDT_DEF_NOP hook only, not on its helper macros.
cat > "$work/wine-probes.c" <<'EOF'
#include "sdt.h"
#ifdef SITE_FORM
#undef _SDT_DEF_NOP
#define _SDT_DEF_NOP SITE_FORM
#endif
unsigned int server_call(int req_type, unsigned int status)
{
    STAP_PROBE1(wine, server_req_start, req_type);
    STAP_PROBE2(wine, server_req_end, req_type, status);
    return status;
}
__asm__(".text\n\t"
        ".globl dispatcher\n\t"
        ".type dispatcher,@function\n"
        "dispatcher:\n\t"
        "movq %rdi,%rcx\n\t"
        STAP_PROBE_ASM(wine, syscall_entry, -4@176(%rcx) 8@%rcx 8@136(%rcx) 8@112(%rcx))
        "movl 0xb0(%rcx),%eax\n\t"
        STAP_PROBE_ASM(wine, syscall_exit, -4@%eax 8@%rcx -4@176(%rcx) -4@180(%rcx))
        "ret\n\t"
        ".size dispatcher,.-dispatcher\n");
EOF
# 5-byte nop: the 0108 site before the 10-byte form (WINE_USDT_V1).
{ cat <<'EOF'
#define SITE_FORM "990: .byte 0x0f, 0x1f, 0x44, 0x00, 0x00\n"
EOF
  cat "$work/wine-probes.c"; } > "$work/wine-nop5.c"
# Ten bytes, but not the one nop the kernel optimizes (nopw + nop).
{ cat <<'EOF'
#define SITE_FORM "990: .byte 0x66, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90\n"
EOF
  cat "$work/wine-probes.c"; } > "$work/wine-near.c"

# PipeASIO's path: PIPEASIO_PROBE -> STAP_PROBEV through pipeasio_probe.h.
cat > "$work/asio-probes.c" <<'EOF'
#include <stdint.h>
#include "pipeasio_probe.h"
void block(uint64_t seq, uint32_t flags, uint32_t missed)
{
    PIPEASIO_PROBE(block_start, seq, flags);
    PIPEASIO_PROBE(block_end, seq, flags, missed);
}
EOF

# The page rule at its boundary: a site that starts at page offset 0xff6 ends
# on the last byte of the page; one at 0xff7 crosses into the next, and Linux
# 7.2.9 puts no uprobe at all on such a site. The header's alignment would
# never put a site there, so the site form is the bare 10-byte nop.
cat > "$work/edge.c" <<'EOF'
#include "sdt.h"
#undef _SDT_DEF_NOP
#define _SDT_DEF_NOP "990: .byte 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00\n"
__asm__(".text\n\t"
        ".balign 4096\n\t"
        ".skip 0xff6\n\t"
        STAP_PROBE_ASM(wine, last_start_in_page, 8@%rdi)
        ".balign 4096\n\t"
        ".skip 0xff7\n\t"
        STAP_PROBE_ASM(wine, crosses_page, 8@%rdi)
        "ret\n");
EOF

# Hand-written descriptors: a prelinked one (location and base both moved by
# the same distance: libbpf, and the audit, correct by .stapsdt.base), one
# with a stale base that lands in int3 filler, and one pointing into .data.
cat > "$work/notes.c" <<'EOF'
#include "sdt.h"
#define NOTE(name, loc, base) \
    ".pushsection .note.stapsdt,\"?\",\"note\"\n\t" \
    ".balign 4\n\t" \
    ".4byte 992f-991f, 994f-993f, 3\n" \
    "991:\t.asciz \"stapsdt\"\n" \
    "992:\t.balign 4\n" \
    "993:\t.8byte " loc "\n\t" \
    ".8byte " base "\n\t" \
    ".8byte 0\n\t" \
    ".asciz \"wine\"\n\t" \
    ".asciz \"" name "\"\n\t" \
    ".asciz \"\"\n" \
    "994:\t.balign 4\n\t" \
    ".popsection\n\t"
void anchor(int x)
{
    STAP_PROBE1(wine, anchor, x);
}
__asm__(".text\n\t"
        ".balign 16\n"
        "manual_site:\n\t"
        ".byte 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00\n\t"
        ".fill 0x76, 1, 0xcc\n\t"
        ".pushsection .data\n"
        "manual_data:\n\t"
        ".byte 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00\n\t"
        ".popsection\n\t"
        NOTE("prelinked", "manual_site - 0x40", "_.stapsdt.base - 0x40")
        NOTE("stale_base", "manual_site", "_.stapsdt.base - 0x40")
        NOTE("in_data", "manual_data", "_.stapsdt.base"));
EOF

good="$work/good/lib/wine/x86_64-unix"
old="$work/old/lib/wine/x86_64-unix"
build_so "$good/ntdll.so" "$work/wine" "$work/wine-probes.c"
build_so "$good/pipeasio64.dll.so" "$work/pipeasio" "$work/asio-probes.c"
# The audit runs on the stripped tree the container packs.
strip --strip-unneeded "$good/ntdll.so" "$good/pipeasio64.dll.so" 2>/dev/null \
    || fail "strip --strip-unneeded failed on the fixtures"

usdt()   # <file> <provider>: "<exit status>|<stdout and stderr>" of the CLI rule
{
    local out rc=0
    out="$(bash "$audit" --check-usdt-sites "$1" "$2" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
site()   # <report> <provider:name>: that site's verdict and detail, without addresses
{
    printf '%s\n' "$1" | awk -v want="$2" '$1 == "ok" || $1 == "bad" {
        if ($2 != want) next
        line = $1; for (i = 5; i <= NF; i++) line = line " " $i
        print line }'
}

# --- the patched headers emit sites the kernel optimizes ----------------------
result="$(usdt "$good/ntdll.so" wine)"
check "0108's sdt.h: every C and asm site of a stripped .so passes" "${result%%|*}" 0
check "0108's sdt.h: all four sites are counted" \
    "$(printf '%s\n' "${result#*|}" | tail -1)" \
    "OK: all 4 wine: probe sites in $good/ntdll.so are the 10-byte nop and none crosses a 4 KiB page."
for probe in server_req_start server_req_end syscall_entry syscall_exit; do
    check "0108's sdt.h: wine:$probe is a 10-byte nop" "$(site "${result#*|}" "wine:$probe")" "ok"
done
result="$(usdt "$good/pipeasio64.dll.so" pipeasio)"
check "0017's sdt.h through PIPEASIO_PROBE: both sites pass" "${result%%|*}" 0
check "0017's sdt.h: pipeasio:block_end is a 10-byte nop" "$(site "${result#*|}" pipeasio:block_end)" "ok"
# The alignment that keeps every header site off a page boundary.
for so in "$good/ntdll.so" "$good/pipeasio64.dll.so"; do
    unaligned="$(bash "$audit" --check-usdt-sites "$so" "$(case "$so" in *pipeasio*) echo pipeasio ;; *) echo wine ;; esac)" \
        | sed -n 's/.* vaddr=\(0x[0-9a-f]*\) .*/\1/p' \
        | while read -r vaddr; do [ $(( vaddr % 16 )) -eq 0 ] || echo "$vaddr"; done)"
    check "$(basename "$so"): every header site is 16-byte aligned" "$unaligned" ""
done

# --- what the rule refuses ------------------------------------------------------
build_so "$old/ntdll.so" "$work/wine" "$work/wine-nop5.c"
strip --strip-unneeded "$old/ntdll.so" 2>/dev/null || fail "strip --strip-unneeded failed on the fixtures"
build_so "$work/near.so" "$work/wine" "$work/wine-near.c"
build_so "$work/edge.so" "$work/wine" "$work/edge.c"
build_so "$work/notes.so" "$work/wine" "$work/notes.c"
result="$(usdt "$old/ntdll.so" wine)"
check "a 5-byte-nop ntdll.so fails" "${result%%|*}" 1
check "the failure says what is wrong" \
    "$(printf '%s\n' "${result#*|}" | tail -1)" \
    "!! 4 of 4 wine: probe sites in $old/ntdll.so are not the 10-byte nop the kernel optimizes, or cross a 4 KiB page"
check "each 5-byte site is named with its bytes" \
    "$(site "${result#*|}" wine:syscall_entry | cut -d' ' -f1-7)" "bad bytes 0f 1f 44 00 00"
check "each failing site carries its file offset" \
    "$(printf '%s\n' "${result#*|}" | grep -c ' bad wine:[a-z_]* vaddr=0x[0-9a-f]* offset=0x[0-9a-f]*: bytes ')" 4

result="$(usdt "$work/near.so" wine)"
check "ten bytes that are not the optimizable nop fail" "${result%%|*}" 1
check "the near miss is reported with its bytes" \
    "$(site "${result#*|}" wine:server_req_end)" \
    "bad bytes 66 0f 1f 84 00 00 00 00 00 90, not the 10-byte nop 66 2e 0f 1f 84 00 00 00 00 00"

result="$(usdt "$work/edge.so" wine)"
check "a site crossing a 4 KiB page fails" "${result%%|*}" 1
check "a site starting at page offset 0xff6 stays in its page" \
    "$(site "${result#*|}" wine:last_start_in_page)" "ok"
check "a site starting at page offset 0xff7 crosses the page" \
    "$(site "${result#*|}" wine:crosses_page)" "bad its 10 bytes cross a 4 KiB page boundary"
check "the crossing site's page offset is 0xff7" \
    "$(printf '%s\n' "${result#*|}" | sed -n 's/.* bad wine:crosses_page vaddr=0x[0-9a-f]*\([0-9a-f]\{3\}\) .*/\1/p')" ff7

result="$(usdt "$work/notes.so" wine)"
check "a prelinked descriptor is corrected by .stapsdt.base" "$(site "${result#*|}" wine:prelinked)" "ok"
check "a stale base is followed to the bytes it names" \
    "$(site "${result#*|}" wine:stale_base | cut -d, -f1)" "bad bytes cc cc cc cc cc cc cc cc cc cc"
check "a site outside executable code fails" \
    "$(site "${result#*|}" wine:in_data)" "bad not in an executable segment"

result="$(usdt "$good/ntdll.so" nosuch)"
check "a provider with no sites fails rather than passing empty" \
    "${result#*|}" "!! no nosuch: probe sites in $good/ntdll.so"
printf 'not an ELF file\n' > "$work/text"
result="$(usdt "$work/text" wine)"
check "a file readelf cannot parse fails, not aborts" "$result" "1|!! no wine: probe sites in $work/text"

# --- the audit's own check: must_usdt_nop10 over a tree --------------------------
lift()   # <file> <function name>
{
    local body
    body="$(sed -n "/^$2() {/,/^}/p" "$1")"
    [ -n "$body" ] || fail "cannot lift $2() out of $1 — has its definition changed shape?"
    printf '%s\n' "$body"
}
audit_verdict()   # <tree> <tree-relative .so> <provider>
(
    # SC2034: read by the functions lifted in below.
    # shellcheck disable=SC2034
    tree="$1"
    ok()  { printf 'PASS|%s|%s\n' "$1" "$2"; }
    bad() { printf 'FAIL|%s|%s\n' "$1" "$2"; }
    eval "$(grep '^readonly USDT_NOP10=' "$audit")"
    eval "$(lift "$audit" usdt_nop10_report)"
    eval "$(lift "$audit" must_usdt_nop10)"
    must_usdt_nop10 "$2" "$3"
)
check "the audit passes a tree of 10-byte sites" \
    "$(audit_verdict "$work/good" lib/wine/x86_64-unix/ntdll.so wine)" \
    "PASS|lib/wine/x86_64-unix/ntdll.so nop10|4 wine: sites are the 10-byte nop, none crosses a 4 KiB page"
verdict="$(audit_verdict "$work/old" lib/wine/x86_64-unix/ntdll.so wine)"
check "the audit fails a tree of 5-byte sites" \
    "$(printf '%s\n' "$verdict" | head -1)" \
    "FAIL|lib/wine/x86_64-unix/ntdll.so nop10|4 of 4 wine: sites not optimizable by the kernel:"
check "the audit lists every failing site under its FAIL line" \
    "$(printf '%s\n' "$verdict" | grep -c '^        wine:[a-z_]* vaddr=0x[0-9a-f]* offset=0x[0-9a-f]*: bytes 0f 1f 44 00 00 ')" 4
check "the audit reports a missing .so instead of passing it" \
    "$(audit_verdict "$work/old" lib/wine/x86_64-unix/pipeasio64.dll.so pipeasio)" \
    "FAIL|lib/wine/x86_64-unix/pipeasio64.dll.so nop10|missing: $work/old/lib/wine/x86_64-unix/pipeasio64.dll.so"
check "the audit checks ntdll.so and pipeasio64.dll.so" \
    "$(grep -c '^    must_usdt_nop10 lib/wine/x86_64-unix/\(ntdll\.so wine\|pipeasio64\.dll\.so pipeasio\)$' "$audit")" 2

printf 'PASS: %d build-audit USDT site checks\n' "$pass"
