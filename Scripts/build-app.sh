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
APP_VERSION="${APP_VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Building release binary"
cd "$ROOT"
SWIFT_ARGS=(build -c release)
if [[ "${SWIFT_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_ARGS+=(--disable-sandbox)
fi
swift "${SWIFT_ARGS[@]}"

for tool in qlmanage sips iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required macOS packaging tool not found: $tool" >&2
        exit 1
    fi
done

echo "==> Assembling $APP_DIR"
mkdir -p "$DIST_DIR"
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
