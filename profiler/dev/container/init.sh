#!/usr/bin/env bash
# profiler/dev/container/init.sh — runs INSIDE the wine-dev container, never on
# the host. profiler/dev/wine-dev.sh copies it to /work/.dev/init.sh and runs
#
#     podman exec … bash /work/.dev/init.sh STEP
#
# one STEP at a time: unpack | series | configure | build | install | check
# ("all" runs them in order). Each step mirrors scripts/container-build.sh
# [1/8]-[3/8] (lines 140-180, checks 182-248) and leaves a marker in
# /work/.dev/<step>.done, so a re-run skips finished work and a run that stopped
# half-way resumes. build and install always run (they are incremental).
#
# Environment (set on the container by wine-dev.sh / the image): JOBS,
# INSTALL_PREFIX (/opt/wine-d2d1-nspa-11.13), CCACHE_DIR=/ccache, and PATH with
# /usr/lib/ccache-shims first (hence `bash -c`, never `bash -l`: Ubuntu's
# /etc/profile resets PATH). Paths: /src = repository (read-only),
# /work/wine-src, /work/build, /work/stage (DESTDIR).
set -euo pipefail

SRC=/src
WORK=/work
JOBS="${JOBS:-$(nproc)}"
NAME="wine-d2d1-nspa-11.13"
CONFIGURE_PREFIX="${INSTALL_PREFIX:-/opt/$NAME}"
DESTDIR="$WORK/stage"
PREFIX_ROOT="$DESTDIR$CONFIGURE_PREFIX"
MARK="$WORK/.dev"
SERIES_TAG="series-aceb236"
GIT=(git -c user.email=build@localhost -c user.name=dist)

say()     { printf '== %s ==\n' "$*"; }
die()     { printf '!! %s\n' "$*" >&2; exit 1; }
mark()    { date -u +%Y-%m-%dT%H:%M:%SZ > "$MARK/$1.done"; }
done_at() { cat "$MARK/$1.done" 2>/dev/null || true; }

[ "$(basename "$CONFIGURE_PREFIX")" = "$NAME" ] || die "INSTALL_PREFIX must end in /$NAME (got $CONFIGURE_PREFIX)"
[ -d "$SRC/patches" ] && [ -f "$SRC/vendor/wine-base-5c23dd1c.tar.zst" ] \
    || die "/src is not the repository (no patches/ or no vendored Wine base)"
[ -d "$WORK" ] && [ -w "$WORK" ] || die "/work is not writable by uid $(id -u) (container created without --userns=keep-id?)"
case ":$PATH:" in
    *:/usr/lib/ccache-shims:*) ;;
    *) echo "!! warning: /usr/lib/ccache-shims is not on PATH; ccache is bypassed (was this started with bash -l?)" >&2 ;;
esac
# --userns=keep-id runs this as the host uid, which owns nothing under / but
# /work; `git config --global` (container-build.sh:149) needs a writable HOME.
export HOME="${HOME:-$WORK}"
[ -w "$HOME" ] || export HOME="$WORK"
mkdir -p "$MARK"

# ---------------------------------------------------------------- unpack ----
step_unpack() {   # container-build.sh:140-142 (+ build.sh:111 checksum)
    if [ -f "$MARK/unpack.done" ] && [ -f "$WORK/wine-src/configure" ]; then
        say "[unpack] already done $(done_at unpack)"
        return 0
    fi
    say "[unpack] verify + unpack pristine Wine base (giang17 d2d1-dcomp-11.13 @ 5c23dd1c)"
    ( cd "$SRC/vendor" && sha256sum -c wine-base.sha256 )
    rm -rf "$WORK/wine-src"
    mkdir -p "$WORK/wine-src"
    zstd -dc --long=27 "$SRC/vendor/wine-base-5c23dd1c.tar.zst" | tar -x -C "$WORK/wine-src"
    rm -f "$MARK/series.done" "$MARK/configure.done" "$MARK/build.done" "$MARK/install.done" \
          "$MARK/check.done" "$MARK/series.sha256"
    echo "   $(cat "$WORK/wine-src/VERSION")"
    mark unpack
}

# ---------------------------------------------------------------- series ----
step_series() {   # container-build.sh:144-166
    local base p npatch nperf
    local -a performance_patches=()
    if [ -f "$MARK/series.done" ] \
       && git -C "$WORK/wine-src" rev-parse -q --verify "refs/tags/$SERIES_TAG" >/dev/null 2>&1; then
        say "[series] already applied $(done_at series): $(git -C "$WORK/wine-src" log --oneline -1) (tag $SERIES_TAG)"
        return 0
    fi
    [ -f "$WORK/wine-src/configure" ] || die "no unpacked tree: run the unpack step first"
    npatch="$(ls "$SRC"/patches/[0-9][0-9][0-9][0-9]-*.patch | wc -l)"
    performance_patches=("$SRC"/patches/performance/*.patch)
    nperf="${#performance_patches[@]}"
    say "[series] git init + apply the $npatch-patch fix series + $nperf bounded performance patch(es)"
    cd "$WORK/wine-src"
    # Rootless podman can bind-mount /work owned by a UID outside the container's
    # user namespace; git (>=2.35.2) refuses to operate on a tree it doesn't own.
    # Scoped to this exact path, not a global opt-out. (With --userns=keep-id the
    # uids match and this is a harmless no-op.)
    git config --global --add safe.directory "$WORK/wine-src"
    if [ -d .git ]; then
        # an earlier run stopped half-way through the series: back to the base commit
        git am --abort >/dev/null 2>&1 || true
        base="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
        git reset -q --hard "$base"
        git clean -qfd
        git tag -d "$SERIES_TAG" >/dev/null 2>&1 || true
        echo "   reset to $(git log --oneline -1)"
    else
        git init -q
        "${GIT[@]}" add -A
        "${GIT[@]}" commit -q -m "base 5c23dd1c"
    fi
    # The series ships without From:/Date: mail headers; git am refuses to commit
    # with an empty author, so supply a fixed neutral ident (fixed date keeps the
    # apply reproducible). Patches that still carry headers keep their own.
    for p in "$SRC"/patches/[0-9][0-9][0-9][0-9]-*.patch "${performance_patches[@]}"; do
        if head -8 "$p" | grep -q '^From: '; then
            "${GIT[@]}" am --3way "$p"
        else
            { printf 'From: dist <build@localhost>\nDate: Thu, 01 Jan 2026 00:00:00 +0000\n'
              cat "$p"
            } | "${GIT[@]}" am --3way
        fi
    done
    git tag -f "$SERIES_TAG" >/dev/null
    ( cd "$SRC/patches" && sha256sum [0-9][0-9][0-9][0-9]-*.patch performance/*.patch ) > "$MARK/series.sha256"
    echo "   HEAD: $(git log --oneline -1)  ($((npatch + nperf)) patches, tag $SERIES_TAG)"
    mark series
}

# ------------------------------------------------------------- configure ----
step_configure() {   # container-build.sh:168-175 (+ the ntsync header gate :227-230)
    if [ -f "$MARK/configure.done" ] && [ -f "$WORK/build/include/config.h" ] && [ -f "$WORK/build/Makefile" ]; then
        say "[configure] already done $(done_at configure)"
        return 0
    fi
    [ -f "$WORK/wine-src/configure" ] || die "no unpacked tree: run the unpack step first"
    say "[configure] CPPFLAGS=-I/opt/ntsync-uapi ../wine-src/configure --prefix=$CONFIGURE_PREFIX --enable-archs=i386,x86_64 --disable-tests"
    mkdir -p "$WORK/build" && cd "$WORK/build"
    # CPPFLAGS: the vendored ntsync UAPI header (Containerfile), nothing else in
    # that dir, so the 5.15 system headers stay authoritative for everything else.
    CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure \
        --prefix="$CONFIGURE_PREFIX" \
        --enable-archs=i386,x86_64 \
        --disable-tests
    grep -q '^#define HAVE_LINUX_NTSYNC_H 1' include/config.h \
        || die "HAVE_LINUX_NTSYNC_H not set; linux/ntsync.h not seen at configure time (every NT wait would be a wineserver round trip)"
    echo "   ntsync: linux/ntsync.h found at configure time"
    mark configure
}

# ----------------------------------------------------------------- build ----
step_build() {   # container-build.sh:176 — incremental, always runs
    [ -f "$WORK/build/Makefile" ] || die "not configured: run the configure step first"
    say "[build] make -j$JOBS (WoW64: clang/lld PE, gcc Unix; ccache in ${CCACHE_DIR:-?})"
    cd "$WORK/build"
    make -j"$JOBS"
    mark build
}

# --------------------------------------------------------------- install ----
step_install() {   # container-build.sh:177,180 — Wine's install rules copy every file each time
    [ -f "$WORK/build/Makefile" ] || die "not configured: run the configure step first"
    say "[install] make install DESTDIR=$DESTDIR"
    cd "$WORK/build"
    make install DESTDIR="$DESTDIR"
    "$PREFIX_ROOT/bin/wine" --version
    mark install
}

# ----------------------------------------------------------------- check ----
step_check() {   # the presence/ntsync gates of container-build.sh:182-248
    local f ntsync_srv ntsync_ntd usdt
    say "[check] staged tree $PREFIX_ROOT"
    for f in bin/wine bin/wineserver bin/winebuild bin/winegcc \
             lib/wine/x86_64-windows/libusb-1.0.dll lib/wine/x86_64-unix/libusb-1.0.so \
             lib/wine/x86_64-unix/comdlg32.so lib/wine/x86_64-unix/winealsa.so \
             lib/wine/x86_64-unix/winegstreamer.so \
             lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/ntdll.dll lib/wine/i386-windows/ntdll.dll; do
        [ -s "$PREFIX_ROOT/$f" ] || die "missing in the stage: $f (winealsa/winegstreamer: configure dropped a backend; see container-build.sh:208-221)"
    done
    [ ! -e "$PREFIX_ROOT/lib/wine/i386-windows/libusb-1.0.dll" ] || die "Push USB bridge unexpectedly built for i386"
    strings "$PREFIX_ROOT/lib/wine/x86_64-unix/comdlg32.so" | grep -F 'org.freedesktop.portal.FileChooser' >/dev/null \
        || die "comdlg32.so lacks the XDG portal string"
    # grep -c, not grep -q: -q exits on first match, strings dies of SIGPIPE and
    # pipefail turns the success into a false "missing" (container-build.sh:231-242).
    ntsync_srv="$(strings "$PREFIX_ROOT/bin/wineserver" | grep -c ntsync || true)"
    ntsync_ntd="$(strings "$PREFIX_ROOT/lib/wine/x86_64-unix/ntdll.so" | grep -c ntsync || true)"
    [ "${ntsync_srv:-0}" -gt 0 ] || die "no ntsync in wineserver; waits would fall back to server round trips"
    [ "${ntsync_ntd:-0}" -gt 0 ] || die "no ntsync in ntdll.so; waits would fall back to server round trips"
    echo "   ntsync: compiled in (wineserver $ntsync_srv, ntdll.so $ntsync_ntd references; header $(sha256sum /opt/ntsync-uapi/linux/ntsync.h | cut -c1-16)…)"
    usdt="$(readelf -n "$PREFIX_ROOT/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null | grep -c stapsdt || true)"
    echo "   usdt: ntdll.so carries ${usdt:-0} stapsdt note line(s) (0 until patch 0108 is in the tree)"
    echo "   wine: $("$PREFIX_ROOT/bin/wine" --version)"
    ccache -s 2>/dev/null | head -n 6 || true
    mark check
}

# ------------------------------------------------------------------ main ----
step="${1:-all}"
case "$step" in
    unpack|series|configure|build|install|check) "step_$step" ;;
    all) for s in unpack series configure build install check; do "step_$s"; done ;;
    *) die "usage: init.sh unpack|series|configure|build|install|check|all" ;;
esac
