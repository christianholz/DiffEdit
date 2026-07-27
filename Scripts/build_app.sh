#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"
MODULE_CACHE_DIR="$PROJECT_DIR/.cache/clang/ModuleCache"
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"

# Prefer the full Xcode toolchain when the active developer directory only
# points at Command Line Tools. This avoids compiler/SDK mismatches.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcrun swift build
BIN_DIR=$(xcrun swift build --show-bin-path)

APP_DIR="build/DiffEdit.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/DiffEdit" "$MACOS_DIR/DiffEdit"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DiffEdit</string>
    <key>CFBundleIdentifier</key>
    <string>local.diffedit.app</string>
    <key>CFBundleName</key>
    <string>DiffEdit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$APP_DIR"
