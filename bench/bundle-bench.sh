#!/bin/bash
# Assemble bench.app (ad-hoc signed, LSUIElement) from the SwiftPM `bench`
# executable, mirroring ../Scripts/bundle.sh.
#
# WHY A BUNDLE: bench posts synthetic trackpad gestures and mouse clicks via
# CGEventPost, which requires Accessibility. If you `swift run` bench directly,
# macOS attributes the TCC (Accessibility) grant to your *terminal*, which is
# both messy and unreliable across rebuilds. A stable-identity .app bundle lets
# you grant Accessibility to "bench" once in System Settings and keep it.
#
# Usage:
#   ./bundle-bench.sh          # build + assemble build/bench.app
# Then drag build/bench.app to /Applications (or run it in place), launch once,
# and grant it Accessibility. Re-run this script after code changes; because the
# bundle identity is stable you should NOT need to re-grant every time (unlike
# the terminal-attributed `swift run` path).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="bench"
BUNDLE_ID="dev.ekotov.jumpcut.bench"
BIN_NAME="bench"

BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
YEAR="$(date +%Y)"

# Debug build is fine for a measurement tool; the numbers come from real system
# switch latency, not from bench's own compute. Use release if you prefer.
BUILD_FLAGS=(-c release --arch arm64)

echo "==> Building bench (release, arm64)…"
swift build "${BUILD_FLAGS[@]}"

BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$BIN_NAME"

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
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $YEAR Riley Hennigh. Dev/measurement tool, not part of the shipped strafe app.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
codesign --force --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo ""
echo "Next:"
echo "  1. Launch it once (open '$APP_DIR' --args specs) or just: open '$APP_DIR'"
echo "  2. Grant it Accessibility in System Settings > Privacy & Security > Accessibility."
echo "  3. Run a subcommand, e.g.:"
echo "       '$MACOS_DIR/$BIN_NAME' windows"
echo "       '$MACOS_DIR/$BIN_NAME' run --mode strafe --trials 20"
echo ""
echo "Running the binary inside the bundle (the MacOS/ path above) keeps the"
echo "Accessibility grant attributed to bench.app rather than your terminal."
