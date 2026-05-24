#!/bin/zsh
# Build, package, install Termy
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Termy"
BUNDLE_ID="com.mees.termy"
APP_BUNDLE="/Applications/${APP_NAME}.app"

cd "$PROJECT_DIR"

echo "── Building ${APP_NAME} (release) ──"
swift build -c release --product "${APP_NAME}" 2>&1

BIN="$PROJECT_DIR/.build/release/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
    echo "Build failed: binary missing at $BIN"
    exit 1
fi

echo "── Stopping running instance ──"
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1

echo "── Assembling app bundle ──"
TMP_APP="$PROJECT_DIR/.build/${APP_NAME}.app"
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Resources"
cp "$BIN" "$TMP_APP/Contents/MacOS/${APP_NAME}"
cp "$PROJECT_DIR/Resources/${APP_NAME}-Info.plist" "$TMP_APP/Contents/Info.plist"

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$TMP_APP/Contents/Resources/AppIcon.icns"
fi

echo "── Ad-hoc codesigning ──"
codesign --force --deep --sign - "$TMP_APP"

echo "── Installing to /Applications ──"
rm -rf "$APP_BUNDLE"
cp -R "$TMP_APP" "$APP_BUNDLE"

echo "── Done ──"
echo "App installed at:  $APP_BUNDLE"
echo "Open with:         open ${APP_BUNDLE}"
