#!/bin/bash
# build.sh ORIGINAL.vst3 [OUT_DIR]: wrap Nils' K1v's macOS VST3 (NilsK1v-MacOS-VST3.zip from nilsschneider.de) in the
# entry shim (shim.c) so Live 12 loads it: OUT_DIR/NilsK1v.vst3 (default ~/Library/Audio/Plug-Ins/VST3) gets the
# original's Info.plist and PkgInfo with CFBundleExecutable set to the shim, the shim (universal, ad-hoc signed), and
# the original bundle whole and unchanged as Contents/Resources/K1vOriginal.bundle. An existing NilsK1v.vst3 there is
# moved aside first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
orig=${1:?usage: build.sh ORIGINAL.vst3 [OUT_DIR]}
out=${2:-$HOME/Library/Audio/Plug-Ins/VST3}
bin=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$orig/Contents/Info.plist")
[ "$bin" = NilsK1vVST3 ] || { echo "build.sh: expected K1v's NilsK1vVST3, found $bin"; exit 1; }
codesign --verify --strict "$orig" || { echo "build.sh: the original's signature does not verify"; exit 1; }
work=$(mktemp -d /tmp/k1v-shim.XXXX)
bundle="$work/NilsK1v.vst3"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$orig/Contents/Info.plist" "$bundle/Contents/Info.plist"
[ ! -f "$orig/Contents/Pkginfo" ] || cp "$orig/Contents/Pkginfo" "$bundle/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable NilsK1vShim" "$bundle/Contents/Info.plist"
ditto "$orig" "$bundle/Contents/Resources/K1vOriginal.bundle"
clang -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -fvisibility=hidden -framework CoreFoundation \
  "$here/shim.c" -o "$bundle/Contents/MacOS/NilsK1vShim"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle/Contents/Resources/K1vOriginal.bundle" && echo "the original bundle's signature still verifies"
nm -gU -arch "$(uname -m)" "$bundle/Contents/MacOS/NilsK1vShim" | grep -E "bundleEntry|bundleExit|GetPluginFactory"
mkdir -p "$out"
if [ -e "$out/NilsK1v.vst3" ]; then mv "$out/NilsK1v.vst3" "$work/NilsK1v.vst3.replaced"; fi
ditto "$bundle" "$out/NilsK1v.vst3"
echo "installed $out/NilsK1v.vst3 (replaced bundle kept in $work)"
