#!/bin/bash
# build.sh [OUT_DIR]: build BenchDialog.app (main.m) on a Mac with the Command Line Tools' clang, ad-hoc signed, into
# OUT_DIR (default ~/AbletonBench). macOS ties the Accessibility permission to the signed app, so a rebuild that
# changes the binary needs the permission again. bench-mac.py runs it with
#   --dialog-helper 'open -g -a ~/AbletonBench/BenchDialog.app --args 240'
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$HOME/AbletonBench}
app="$out/BenchDialog.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 -arch "$(uname -m)" -framework AppKit -framework ApplicationServices \
  "$here/main.m" -o "$app/Contents/MacOS/BenchDialog"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.profiler.bench-dialog</string>
  <key>CFBundleName</key><string>BenchDialog</string>
  <key>CFBundleExecutable</key><string>BenchDialog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app ($(lipo -archs "$app/Contents/MacOS/BenchDialog"))"
