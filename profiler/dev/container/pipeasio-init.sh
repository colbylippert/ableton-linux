#!/usr/bin/env bash
# profiler/dev/container/pipeasio-init.sh — runs INSIDE the wine-dev container,
# never on the host. profiler/dev/wine-dev.sh copies it to
# /work/.dev/pipeasio-init.sh and runs one STEP at a time:
#
#     unpack | series | configure      (wine-dev.sh pipeasio-init)
#     build | test | install           (wine-dev.sh pipeasio-build [--test])
#
# Mirrors scripts/container-build.sh step [4/8] against the Wine staged by
# init.sh: :250-262 (unpack + patch series, staged Wine bin/ first on PATH),
# :363-373 (the cmake configure function), :438-444 (Release build),
# :379-393 and :418-431 (non-integration CTest with the libpipewire stub),
# :562-563 (install, drop pipeasio-register). The official pipeline's probe and
# sanitizer gates (:293-361, :461-557) are release machinery and are not
# replayed; build-official.sh runs them.
#
# After the series the tree is a git repository tagged series-pipeasio, so
# `wine-dev.sh format-patch --pipeasio` can export HEAD as a patch that
# `patch -p1` (the official pipeline) applies.
set -euo pipefail

SRC=/src
WORK=/work
JOBS="${JOBS:-$(nproc)}"
NAME="wine-d2d1-nspa-11.13"
CONFIGURE_PREFIX="${INSTALL_PREFIX:-/opt/$NAME}"
DESTDIR="$WORK/stage"
PREFIX_ROOT="$DESTDIR$CONFIGURE_PREFIX"
MARK="$WORK/.dev"
PIPEASIO="$WORK/pipeasio"
PW_SDK=/opt/pipewire-sdk
PIPEASIO_TAG="series-pipeasio"
PIPEASIO_BUILD_SETTINGS_PANEL="${PIPEASIO_BUILD_SETTINGS_PANEL:-ON}"
GIT=(git -c user.email=build@localhost -c user.name=dist)

say()     { printf '== %s ==\n' "$*"; }
die()     { printf '!! %s\n' "$*" >&2; exit 1; }
mark()    { date -u +%Y-%m-%dT%H:%M:%SZ > "$MARK/$1.done"; }
done_at() { cat "$MARK/$1.done" 2>/dev/null || true; }

[ "$(basename "$CONFIGURE_PREFIX")" = "$NAME" ] || die "INSTALL_PREFIX must end in /$NAME (got $CONFIGURE_PREFIX)"
[ -d "$SRC/patches/pipeasio" ] && [ -f "$SRC/vendor/pipeasio-1.5.0.tar.gz" ] \
    || die "/src is not the repository (no patches/pipeasio or no vendored PipeASIO tarball)"
[ -d "$WORK" ] && [ -w "$WORK" ] || die "/work is not writable by uid $(id -u)"
case "$PIPEASIO_BUILD_SETTINGS_PANEL" in
    ON|OFF) ;;
    *) die "PIPEASIO_BUILD_SETTINGS_PANEL must be ON or OFF" ;;
esac
[ -x "$PREFIX_ROOT/bin/winebuild" ] && [ -x "$PREFIX_ROOT/bin/winegcc" ] \
    || die "the stage has no winebuild/winegcc at $PREFIX_ROOT/bin — run  wine-dev.sh init  first"
[ -d "$PW_SDK/usr/lib/x86_64-linux-gnu/pkgconfig" ] || die "no PipeWire SDK at $PW_SDK (image built from a different Containerfile?)"
export HOME="${HOME:-$WORK}"
[ -w "$HOME" ] || export HOME="$WORK"
export PATH="$PREFIX_ROOT/bin:$PATH"          # :262 — this Wine's winegcc/winebuild take PATH priority
mkdir -p "$MARK"

pipeasio_cmake_configure() {   # container-build.sh:363-373
    local build_dir="$1"
    shift
    PKG_CONFIG_PATH="$PW_SDK/usr/lib/x86_64-linux-gnu/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="$PW_SDK" \
    CC=gcc CXX=g++ \
    cmake -S . -B "$build_dir" -G Ninja \
        -DWINEBUILD="$PREFIX_ROOT/bin/winebuild" \
        -DWINEGCC="$PREFIX_ROOT/bin/winegcc" \
        "$@"
}

# The SDK's libpipewire was built against a newer glibc than this jammy
# container. The selected unit tests use PipeWire types but make no runtime
# pw_* calls, so give their loader a tiny symbol-compatible stub (:379-393).
pipeasio_make_test_stub() {
    local build_dir="$1" stub_dir="$2" t
    printf '%s\n' 'void pipeasio_pw_test_stub(void) {}' > "$stub_dir/stub.c"
    for t in "$build_dir"/tests/unit/test_*; do
        [ -f "$t" ] && [ -x "$t" ] || continue
        # || true: a statically-satisfied binary makes nm -D return nonzero,
        # and pipefail must not turn that into a false build failure.
        nm -D "$t" 2>/dev/null \
            | awk '$1 == "U" && $2 ~ /^pw_/ { print "void " $2 "(void) {}" }' \
            || true
    done | sort -u >> "$stub_dir/stub.c"
    gcc -shared -fPIC -Wl,-soname,libpipewire-0.3.so.0 \
        -o "$stub_dir/libpipewire-0.3.so.0" "$stub_dir/stub.c"
}

# ---------------------------------------------------------------- unpack ----
step_unpack() {   # container-build.sh:251-253 (+ build.sh:111 checksum)
    if [ -f "$MARK/pipeasio-unpack.done" ] && [ -f "$PIPEASIO/CMakeLists.txt" ]; then
        say "[pipeasio unpack] already done $(done_at pipeasio-unpack)"
        return 0
    fi
    say "[pipeasio unpack] verify + unpack PipeASIO 1.5.0"
    ( cd "$SRC/vendor" && sha256sum -c pipeasio.sha256 )
    rm -rf "$PIPEASIO"
    mkdir -p "$PIPEASIO"
    tar xzf "$SRC/vendor/pipeasio-1.5.0.tar.gz" -C "$PIPEASIO" --strip-components=1
    rm -f "$MARK/pipeasio-series.done" "$MARK/pipeasio-configure.done" "$MARK/pipeasio-build.done" \
          "$MARK/pipeasio-install.done" "$MARK/pipeasio-series.sha256"
    mark pipeasio-unpack
}

# ---------------------------------------------------------------- series ----
step_series() {   # container-build.sh:254-261 (patch -p1, every *.patch sorted; the glob is the contract)
    local nasio p
    if [ -f "$MARK/pipeasio-series.done" ] \
       && git -C "$PIPEASIO" rev-parse -q --verify "refs/tags/$PIPEASIO_TAG" >/dev/null 2>&1; then
        say "[pipeasio series] already applied $(done_at pipeasio-series): $(git -C "$PIPEASIO" log --oneline -1)"
        return 0
    fi
    if [ -d "$PIPEASIO/.git" ] || [ ! -f "$PIPEASIO/CMakeLists.txt" ]; then
        # a half-applied series cannot be unwound (patch -p1 leaves no history): start from the tarball
        rm -f "$MARK/pipeasio-unpack.done"
        step_unpack
    fi
    cd "$PIPEASIO"
    nasio="$( { ls "$SRC"/patches/pipeasio/*.patch 2>/dev/null || true; } | wc -l)"
    [ "$nasio" -gt 0 ] || die "no pipeasio patches found in $SRC/patches/pipeasio"
    say "[pipeasio series] apply $nasio patch(es) with patch -p1"
    for p in "$SRC"/patches/pipeasio/*.patch; do
        echo "   applying $(basename "$p")"
        patch -p1 --no-backup-if-mismatch -i "$p"
    done
    git init -q
    "${GIT[@]}" add -A
    "${GIT[@]}" commit -q -m "pipeasio 1.5.0 + patches/pipeasio series"
    git tag -f "$PIPEASIO_TAG" >/dev/null
    ( cd "$SRC/patches" && sha256sum pipeasio/*.patch ) > "$MARK/pipeasio-series.sha256"
    echo "   HEAD: $(git log --oneline -1)  ($nasio patches, tag $PIPEASIO_TAG)"
    mark pipeasio-series
}

# ------------------------------------------------------------- configure ----
step_configure() {   # container-build.sh:438-443 (the production configure; cmake re-runs are cheap)
    [ -f "$PIPEASIO/CMakeLists.txt" ] || die "no PipeASIO tree: run the unpack and series steps first"
    say "[pipeasio configure] cmake -G Ninja (Release, panel=$PIPEASIO_BUILD_SETTINGS_PANEL, tests on) against $PREFIX_ROOT"
    cd "$PIPEASIO"
    pipeasio_cmake_configure build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$CONFIGURE_PREFIX" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
        -DBUILD_SETTINGS_PANEL="$PIPEASIO_BUILD_SETTINGS_PANEL" \
        -DBUILD_TESTS=ON
    mark pipeasio-configure
}

# ----------------------------------------------------------------- build ----
step_build() {   # container-build.sh:444-452
    local panel_state
    [ -f "$PIPEASIO/build/build.ninja" ] || die "PipeASIO is not configured: run the configure step first"
    say "[pipeasio build] cmake --build build -j $JOBS"
    cd "$PIPEASIO"
    cmake --build build -j "$JOBS"
    panel_state="skipped (disabled)"
    if [ -x build/gui/pipeasio-settings ]; then
        panel_state="built"
    elif [ "$PIPEASIO_BUILD_SETTINGS_PANEL" = ON ]; then
        panel_state="skipped (Qt6 Widgets unavailable)"
    fi
    echo "   panel: $panel_state"
    mark pipeasio-build
}

# ------------------------------------------------------------------ test ----
step_test() {   # container-build.sh:418-431 + :459 — upstream's complete non-integration CTest scope
    local stub_dir rc=0
    [ -f "$PIPEASIO/build/build.ninja" ] || die "PipeASIO is not built: run the build step first"
    say "[pipeasio test] ctest -LE '^integration$' (unit, registration/layout, ABI, headless panel when built)"
    cd "$PIPEASIO"
    stub_dir="$(mktemp -d /tmp/pipeasio-ctest.XXXXXX)"
    pipeasio_make_test_stub build "$stub_dir"
    env LD_LIBRARY_PATH="$stub_dir" \
        ctest --test-dir build -LE '^integration$' \
            --no-tests=error --output-on-failure || rc=$?
    case "$stub_dir" in
        /tmp/pipeasio-ctest.*) rm -rf -- "${stub_dir:?}" ;;
        *) echo "!! refusing to remove unexpected test stub path: $stub_dir" >&2 ;;
    esac
    [ "$rc" -eq 0 ] || die "PipeASIO CTest failed (exit $rc)"
}

# --------------------------------------------------------------- install ----
step_install() {   # container-build.sh:562-571 (+ the alias checks of :482-485)
    local unix_half
    [ -f "$PIPEASIO/build/build.ninja" ] || die "PipeASIO is not built: run the build step first"
    say "[pipeasio install] DESTDIR=$DESTDIR cmake --install build; drop bin/pipeasio-register"
    cd "$PIPEASIO"
    # Install through upstream CMake so its layout, Qt data files and Wine alias
    # contract are exercised. The project has its own atomic registration path, so
    # discard upstream's generic helper after testing its install rule.
    DESTDIR="$DESTDIR" cmake --install build
    rm -f -- "$PREFIX_ROOT/bin/pipeasio-register"
    unix_half="$PREFIX_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so"
    test -s "$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio64.dll"
    test -s "$unix_half"
    test "$(readlink "$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio.dll")" = pipeasio64.dll
    test "$(readlink "$PREFIX_ROOT/lib/wine/x86_64-unix/pipeasio.dll.so")" = pipeasio64.dll.so
    # Must link the host's PipeWire by soname, with no SDK/build path baked in.
    readelf -d "$unix_half" | grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null \
        || die "pipeasio64.dll.so does not link libpipewire-0.3.so.0 by soname"
    if readelf -d "$unix_half" | grep -qE 'RPATH|RUNPATH'; then
        die "pipeasio64.dll.so carries an rpath into the build container"
    fi
    echo "   PipeASIO: PE $(sha256sum "$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio64.dll" | cut -c1-16)… / Unix $(sha256sum "$unix_half" | cut -c1-16)…"
    echo "   usdt: pipeasio64.dll.so carries $(readelf -n "$unix_half" 2>/dev/null | grep -c stapsdt || true) stapsdt note line(s) (0 until patch pipeasio/0017)"
    mark pipeasio-install
}

# ------------------------------------------------------------------ main ----
step="${1:-init}"
case "$step" in
    unpack|series|configure|build|test|install) "step_$step" ;;
    init) step_unpack; step_series; step_configure ;;
    all) step_unpack; step_series; step_configure; step_build; step_test; step_install ;;
    *) die "usage: pipeasio-init.sh unpack|series|configure|build|test|install|init|all" ;;
esac
