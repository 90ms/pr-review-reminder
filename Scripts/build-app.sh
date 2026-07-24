#!/bin/bash
# Assembles a runnable macOS .app bundle from the SwiftPM release build.
# Menu-bar-only (LSUIElement) app; ad-hoc signed for local use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PR Review Reminder"
BUNDLE_ID="kr.fastlane.prreviewreminder"
EXECUTABLE="PRReviewReminder"
BUILD_DIR="$ROOT/.build/release"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
if [[ "$OUTPUT_DIR" = /* ]]; then
    DIST_DIR="$OUTPUT_DIR"
else
    DIST_DIR="$ROOT/$OUTPUT_DIR"
fi
if [[ -z "$DIST_DIR" || "$DIST_DIR" == "/" || "$DIST_DIR" == "$ROOT" ]]; then
    echo "Refusing unsafe OUTPUT_DIR: $DIST_DIR" >&2
    exit 2
fi
APP_DIR="$DIST_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-0.2.2}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Building release binary"
cd "$ROOT"
SWIFT_ARGS=(build -c release)
if [[ "${SWIFT_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_ARGS+=(--disable-sandbox)
fi
swift "${SWIFT_ARGS[@]}"

echo "==> Assembling $APP_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

echo "==> Installing app icon"
cp "$ROOT/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Fastlane</string>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<< "APPL????"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with Developer ID"
    codesign --force --deep --options runtime --timestamp \
        --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "==> Ad-hoc code signing (local build)"
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Done: $APP_DIR"
echo "    Run: open \"$APP_DIR\""
