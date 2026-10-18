# Research — the build system (aceb236)

Verified by reading `build.sh`, `Makefile`, `Containerfile`, `BUILDING.md`, `FLAKE.md`, `flake.nix`, `nix/*.nix`, `scripts/container-build.sh`, `scripts/build-audit.sh`, `scripts/source-tree-digest.sh`, `scripts/installer.sh`, `scripts/install.sh`, `scripts/setup-prefix.sh`, `scripts/lib/config.sh`, `scripts/make-installer.sh`, `scripts/check-release-build-info.sh`, `scripts/test-release-policy.sh`, `patches/BASE.txt`, `patches/SERIES.sha256`, `.github/workflows/*.yml`.

## Read this first

1. **The supported build is a container build.** `build.sh` runs on the host and drives Podman. The actual Wine and PipeASIO build is `scripts/container-build.sh`, inside an Ubuntu 22.04 image built from `Containerfile`. It is not a native Arch build.
2. **Wine source comes only from the vendored tarball.** Nothing is cloned. Patches are applied with `git am --3way`.
3. **Dropping in a new patch file is not enough.** The build applies it automatically, but the audit at the end fails unless `scripts/build-audit.sh` and `patches/SERIES.sha256` are updated too.
4. **No step needs sudo.** Podman runs rootless (needs `/etc/subuid`/`/etc/subgid` entries for the user).
5. **Never copy a Windows checkout to the VM** (CRLF). Clone or bundle.

## `build.sh` (224 lines, host)

No CLI flags. Environment only:

| Variable | Default | Where |
|---|---|---|
| `ENGINE` | `podman` (CI uses `docker`) | :12 |
| `IMAGE` | `ableton-wine-build:22.04` | :13 |
| `JOBS` | `$(nproc)` | :14 |
| `PIPEASIO_TSAN_MODE` | `auto` (or `require` / `skip`) | :17 |
| `INSTALL_PREFIX` | `/opt/wine-d2d1-nspa-11.13` (must end in `/wine-d2d1-nspa-11.13`, container-build.sh:28-31) | :26 |

Phases:
- **Setup (:34-36).** Hard-coded temp dirs `/tmp/ableton-source-paths.*`, `/tmp/ableton-source-snapshot.*`, `/tmp/ableton-build-output.*`. Does not honour `TMPDIR`.
- **[0/7] Freeze the source (:66-108).** `git ls-files -z --cached --others --exclude-standard -- . ':(exclude)dist'` → copies into the snapshot, hashes with `source-tree-digest.sh`, marks read-only. Aborts if the tree changes while the snapshot is taken (:101-106), during the build (:145-152) or during the audit (:190-197). Untracked, non-ignored files ARE included. `*.log` is gitignored.
- **[1/7] Verify vendored inputs (:110-113).** `sha256sum -c` on 8 vendor manifests.
- **[2/7] Build the image (:116).** `podman build -t $IMAGE -f Containerfile <snapshot>`.
- **[3/7] Build installer helpers (:119-127).** `cabextract-static` (from `vendor/cabextract-1.11.tar.gz`, `LDFLAGS=-static`) and `ableton-linkd` (`tools/build_ableton-linkd.sh`, `g++ -std=c++17` against `vendor/link-4.0.tar.zst`). Both executed on the host as a check.
- **[4/7] Build Wine and PipeASIO (:129-143).** `podman run --rm` with snapshot at `/src` (ro), output at `/out`, `$repo/.ccache` at `/ccache`; `,Z` on mounts when `/sys/fs/selinux/enforce` exists; runs `/src/scripts/container-build.sh`.
- **[5/7] Host-side audit (:154-197).** Requires outputs `BUILD-INFO-$VERSION.txt`, `BUILD-INFO.txt`, `ableton-linkd`, `cabextract-static`, `pipewire-version-probe`, `wine-d2d1-nspa-11.13-$VERSION.tar.zst` + `.sha256`; runs `build-audit.sh --source-tree-sha …`.
- **[6/7] Copy outputs into `dist/` (:199-216).** Atomic `mv`.
- **[7/7] Done.** Prints `Next:  ./scripts/installer.sh install --skip-live-install`.

Network: only the first image build (`docker.io/library/ubuntu:22.04@sha256:0e0a0fc6…`, `snapshot.ubuntu.com` at `20260718T000000Z`, `apt.llvm.org` LLVM 21.1.8 pinned). Disk ≈ 10 GB; ccache capped at 5 GB in `<repo>/.ccache`. Nix CI measured 14m53s for the Wine compile on 6 vCPU; container path does more. CI timeouts 120/90 min. **No incremental build**: `/work` is the container's throwaway layer.

## `scripts/container-build.sh` (743 lines)

- Preflight: TSan canary ×3 (:49-130; `skip` skips); compiles Push USB probes `tools/push{,2,3}usb.c` (:132-138).
- **[1/8]** `zstd -dc --long=27 "$SRC/vendor/wine-base-5c23dd1c.tar.zst" | tar -x -C "$WORK/wine-src"` (:140-142). Base = `giang17/wine` `d2d1-dcomp-11.13` @ `5c23dd1c` (patches/BASE.txt); 13,808 entries rooted at `./`, no `.git`, pre-generated `configure`, `./VERSION` = "Wine version 11.13".
- **[2/8]** Apply patches (:144-166): `git init`, commit base as "base 5c23dd1c", then for each `patches/[0-9][0-9][0-9][0-9]-*.patch` then `patches/performance/*.patch` (glob order, no series file) `git am --3way`. Header-less patches get synthetic `From: dist <build@localhost>` + `Date: Thu, 01 Jan 2026 00:00:00 +0000` (:156-164). 82 of 96 patches are header-less.
- **[3/8]** `CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure --prefix="$CONFIGURE_PREFIX" --enable-archs=i386,x86_64 --disable-tests; make -j"$JOBS"; make install DESTDIR="$DESTDIR"` (:168-180). Out-of-tree: `/work/wine-src`, `/work/build`, `/work/stage`. Checks (:182-248): libusb bridge exports (no i386 bridge), `comdlg32.so` portal string, `winealsa.so`, `winegstreamer.so`, `HAVE_LINUX_NTSYNC_H`, "ntsync" in `wineserver` and `ntdll.so`.
- **[4/8]** PipeASIO 1.5.0 (:250-600): extract `vendor/pipeasio-1.5.0.tar.gz --strip-components=1`; `patch -p1 --no-backup-if-mismatch` for `patches/pipeasio/*.patch` (:256-261); staged Wine `bin/` first on PATH (:262); probe builds/tests (:297-361); cmake Ninja with `-DWINEBUILD=$PREFIX_ROOT/bin/winebuild -DWINEGCC=…/winegcc`, `PKG_CONFIG_PATH`/`PKG_CONFIG_SYSROOT_DIR` → `/opt/pipewire-sdk` (:363-373); Release build `-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$CONFIGURE_PREFIX -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined -DBUILD_SETTINGS_PANEL=ON -DBUILD_TESTS=ON` + ctest (:438-459); no-Qt gate (:464-493); ASan (:501-514); TSan (:516-557). `DESTDIR=$DESTDIR cmake --install build` → `lib/wine/x86_64-windows/pipeasio64.dll`, `lib/wine/x86_64-unix/pipeasio64.dll.so`, `pipeasio.*` alias symlinks, `bin/pipeasio-settings`; `bin/pipeasio-register` deleted (:562-563). 64-bit only.
- **[5/8]** Strip and prune (:602-629): strip everything, delete `*.a`, `include/`, `share/man`, `widl winebuild winegcc wineg++ winecpp winedump winemaker wmc wrc`. **The shipped runtime cannot rebuild anything.**
- **[6/8]** Package (:631-698): `ABLETON-WINE-BUILD-PACKAGES.txt`, `ABLETON-WINE-PATCH-STACK.txt` (= `sha256sum` of the three patch globs), `ABLETON-WINE-BUILD-INFO.txt`; `tar … | zstd -T0 -19 --long=27`.
- **[7/8]** Relocation check (:700-725). **[8/8]** `build-audit.sh` (:727-728); modes 0644/0755.

## Vendored inputs

| Input | Used by | How |
|---|---|---|
| `ntsync-uapi/linux/ntsync.h` | Wine build | copied to `/opt/ntsync-uapi` (Containerfile:123), `CPPFLAGS` |
| `pipewire-sdk/*.deb` (Ubuntu 1.6.2) | PipeASIO | unpacked into `/opt/pipewire-sdk` (Containerfile:132-136); link-time only |
| `cabextract-1.11.tar.gz` | helper build | `dist/cabextract-static`; host `cabextract` still needed for a source install |
| `link-4.0.tar.zst` | helper build | `dist/ableton-linkd` |
| `fonts/bitstream-vera/*` | prefix creation (setup-prefix.sh:968-982) | checksum at build time |
| `winetricks` (20260125), `winetricks-cache/` (corefonts, vcrun2022, vcrun6) | `setup-prefix.sh` | not used by the build |
| `llvm-apt-key.asc` | Containerfile only | signs apt.llvm.org |
| `wine-base-5c23dd1c.tar.zst` | 50,048,878 bytes, plain git blob (not LFS), sha256 `349a4fdf…` | |

## Makefile targets

`all`/`build` → `./build.sh`; `install` → `installer.sh install --skip-live-install` (also creates the prefix); `setup` → `installer.sh prefix create`; `refresh` → `prefix update`; `uninstall`; `test` → 22 scripts (Makefile:22-43: test-tsan-policy, test-release-policy, test-config-boundary, test-project-file-installer, test-installer-ui, test-preflight-preferences, test-preflight-menu, test-preflight-integration, test-check-ntsync, test-shortcut-hold, test-cpu-topology, test-live-options, test-pipewire-pro-audio-ab, test-desktop-integration, test-launcher-transactions, test-link-boundary, test-uninstall-boundary, test-nix-packaging, test-installer-lifecycle, test-pipeasio-installer, test-bench-report.py, test-bench-suite); `test-bench`; `bench-compare` (BEFORE/AFTER/OUTPUT); `test-glyph-path`/`test-d2d-resize` (need `x86_64-w64-mingw32-gcc`, Xvfb, `RUNTIME=`); `vendor-cache`; `verify` → pointer-safety-check + vendor sha256; `check` → `tools/pointer-safety-invariants.c`; `clean` (also deletes tracked `dist/BUILD-INFO*.txt`!); `distclean`.

## Dependencies and toolchain

No Arch build dependency list exists in the repo. Podman route host needs: Podman, Git, Bash, Python 3, coreutils, findutils, grep, tar, binutils, zstd, cabextract, a C compiler (`make check`); scripts also use `grep -P`, `readelf`, `diff`/`cmp`, `find -printf`, `sort -z`. Containerfile apt list: `build-essential clang-21 lld-21 llvm-21 ccache flex bison perl gettext pkg-config git xz-utils zstd python3 cmake ninja-build`, X11/GL/Vulkan dev libs, `libfreetype-dev libfontconfig-dev libasound2-dev libpulse-dev qt6-base-dev qt6-base-dev-tools qt6-qpa-plugins libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgnutls28-dev libusb-1.0-0-dev libudev-dev libdbus-1-dev`. GCC builds the Unix side; clang/lld build the PE side; `LLVM_VERSION=21` pinned `1:21.1.8~++20251221…` (ages out eventually → bump `LLVM_PKG_VERSION`). Unversioned `clang`, `lld`, `llvm-*` symlinked (:92-95). ccache shims in `/usr/lib/ccache-shims` (Containerfile:105-118) with `CCACHE_DIR=/ccache`, `CCACHE_MAXSIZE=5G`.

## Patch layout and policy (`scripts/build-audit.sh`)

Wine series 0001–0107 (95 files; declared gaps 0027, 0044, 0072, 0074, 0090-0095, 0097, 0098 at :164-171). Performance series exactly `performance/0001` (locked, :33-34; `test-release-policy.sh:435-439`). PipeASIO 0001–0016 (gaps 0003, 0007, :190-193). Total 110.

Adding Wine patch 0108: (1) `patches/0108-<slug>.patch` (sequential numbering checked :172-186); (2) `REQUIRED_WINE_TAIL` at :13; (3) a `FINGERPRINTS` entry (`patch|ascii|wide|module|literal`, :352-413) or `STAMP_ONLY` (`patch|reason`, :424-481) else "UNLISTED" (:546); (4) `./scripts/build-audit.sh --freeze` rewrites `patches/SERIES.sha256` (:56-67); (5) optionally `patches/BASE.txt`. PipeASIO: `patches/pipeasio/NNNN-*.patch`, `REQUIRED_PIPEASIO_TAIL` (:15), fingerprint, freeze. Caveats: performance patches apply after the main series; the build never runs autoreconf/`make_requests` — patches changing `configure.ac` must patch `configure` too (0032, 0048); protocol changes must include regenerated `server_protocol.h`, `request_handlers.h`, `request_trace.h` (0078). `performance/0001` fingerprint: `WINE_APC_FASTPATH` in `ntdll.so` (:398).

## VERSION, dist/, dev loop

`VERSION` = `2026.08.28.1`, used only for names/records (`build.sh:27`, `container-build.sh:10`); `install.sh:506-512` requires `dist/wine-d2d1-nspa-11.13-$version.tar.zst`. If bumped, CHANGELOG's first `## ` heading must equal it (`test-release-policy.sh:54-58`).

Dev loop: `./build.sh` then `./scripts/installer.sh runtime install [--yes]` (installer.sh:40, 1098-1100): validates checksum/BUILD-INFO (install.sh:503-588), **requires running PipeWire ≥ 1.4.2** (install.sh:642), promotes atomically into `~/.local/opt/wine-d2d1-nspa-11.13` (config.sh:547; `--runtime-root`/`ABLETON_WINE_ROOT`) keeping a backup. The local install does not check the TSan record. `setup-prefix.sh:372-389` requires `ABLETON-WINE-BUILD-INFO.txt`.

After a build, git shows tracked `dist/BUILD-INFO*.txt` and `dist/*.tar.zst.sha256` as modified — never commit them (`git add -A` trap). `dist/` is excluded from the source digest.

## Agent traps

- Don't `git add -A` after a build.
- Don't create non-ignored files in the repo during a build (tree-change checks abort).
- `set -o pipefail; ./build.sh | tee build.log` (notes/ABLETON-WINE-11.11-TO-11.13-BASE-BUMP.md:50-56).
- Running `scripts/build-audit.sh` by hand without `--source-tree-sha` after editing the repo fails the source-tree check.
- `.gitattributes` has stale whitespace entries for removed patches — harmless.
