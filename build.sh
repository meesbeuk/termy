#!/bin/zsh
# Build, package, install Termy
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Termy"
BUNDLE_ID="com.mees.termy"
APP_BUNDLE="/Applications/${APP_NAME}.app"

cd "$PROJECT_DIR"

# Re-apply SwiftTerm patches in case `swift package update` blew them away.
if [[ -d "$PROJECT_DIR/.build/checkouts/SwiftTerm" ]]; then
    "$PROJECT_DIR/release_helpers/patch-swiftterm.sh"
else
    echo "── First-run: resolving Swift packages ──"
    swift package resolve
    "$PROJECT_DIR/release_helpers/patch-swiftterm.sh"
fi

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
mkdir -p "$TMP_APP/Contents/Frameworks"
cp "$BIN" "$TMP_APP/Contents/MacOS/${APP_NAME}"
cp "$PROJECT_DIR/Resources/${APP_NAME}-Info.plist" "$TMP_APP/Contents/Info.plist"

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$TMP_APP/Contents/Resources/AppIcon.icns"
fi

# Bundle LobeHub brand SVG icons for the vibecoder quick launchers.
if [[ -d "$PROJECT_DIR/Resources/LaunchIcons" ]]; then
    cp -R "$PROJECT_DIR/Resources/LaunchIcons" "$TMP_APP/Contents/Resources/"
fi

# Bundle any frameworks built via SPM artifacts (Sparkle, etc.) so the binary
# resolves its @rpath references at runtime. Without this the app crashes
# on launch trying to load Sparkle.framework.
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    cp -R "$SPARKLE_FRAMEWORK" "$TMP_APP/Contents/Frameworks/"
fi

# Add the rpath for bundled frameworks. Without this the dyld loader can't
# find Sparkle.framework at @rpath/Sparkle.framework... and the app crashes
# on launch with "cannot be opened because of a problem".
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$TMP_APP/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "── Ad-hoc codesigning ──"
codesign --force --deep --sign - "$TMP_APP"

echo "── Installing to /Applications ──"
rm -rf "$APP_BUNDLE"
cp -R "$TMP_APP" "$APP_BUNDLE"

echo "── Done ──"
echo "App installed at:  $APP_BUNDLE"
echo "Open with:         open ${APP_BUNDLE}"
