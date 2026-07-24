#!/bin/bash
# Assembles a runnable macOS .app bundle from the SwiftPM release build.
# Menu-bar-only (LSUIElement) app; no code signing (local use).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PR Review Reminder"
BUNDLE_ID="kr.fastlane.prreviewreminder"
EXECUTABLE="PRReviewReminder"
BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

echo "==> Generating app icon"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-reminder-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
qlmanage -t -s 1024 -o "$ICON_WORK" "$ROOT/Assets/AppIcon.svg" >/dev/null 2>&1
MASTER_ICON="$ICON_WORK/AppIcon.svg.png"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    read -r size filename <<< "$spec"
    sips -z "$size" "$size" "$MASTER_ICON" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
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

echo "==> Ad-hoc code signing (required for notifications & Keychain-backed gh)"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $APP_DIR"
echo "    Run: open \"$APP_DIR\""
