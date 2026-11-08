#!/bin/bash
# Build a signed JumpCut.app bundle from the SwiftPM executable.
set -euo pipefail

# Resolve repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="JumpCut"
BUNDLE_ID="dev.ekotov.jumpcut"
BIN_NAME="JumpCut"

BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
YEAR="$(date +%Y)"

# Single source of truth for the version, shared with Scripts/release.sh. Read
# it here rather than hardcoding, so a dev bundle and a signed release built
# from the same commit cannot report different versions.
if [[ ! -f "$ROOT_DIR/VERSION" ]]; then
  echo "error: VERSION file not found at $ROOT_DIR/VERSION" >&2
  exit 1
fi
VERSION="$(tr -d ' \t\n\r' < "$ROOT_DIR/VERSION")"

# Release build flags (shipped binary only; the plain `swift build` dev path is
# unchanged). -Osize optimizes for size, -dead_strip drops unreachable code, and
# a post-link `strip` removes debug/local symbols — together ~30% smaller binary.
RELEASE_FLAGS=(-c release --arch arm64 -Xswiftc -Osize -Xlinker -dead_strip)

echo "==> Building release (arm64, -Osize, dead-strip)…"
swift build "${RELEASE_FLAGS[@]}"

BIN_PATH="$(swift build "${RELEASE_FLAGS[@]}" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app (version $VERSION)…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$BIN_NAME"

# Strip symbols from the SHIPPED copy (not the .build artifact) BEFORE signing —
# stripping mutates the binary and would invalidate a prior signature. -rSTx
# removes debug, local, and section symbols while keeping it a valid Mach-O.
echo "==> Stripping symbols from shipped binary…"
BEFORE_BYTES="$(stat -f%z "$MACOS_DIR/$BIN_NAME")"
strip -rSTx "$MACOS_DIR/$BIN_NAME"
AFTER_BYTES="$(stat -f%z "$MACOS_DIR/$BIN_NAME")"
echo "    binary size: ${BEFORE_BYTES} -> ${AFTER_BYTES} bytes"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $YEAR Egor Kotov. Based on Riley Hennigh's strafe (MIT).</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
# Sign the app bundle directly. `--deep` is deprecated; modern codesign signs
# nested code correctly, and this bundle has no nested code anyway.
codesign --force --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
