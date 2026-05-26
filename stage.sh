#!/bin/zsh
# Build Termy and relaunch the staging bundle.
#
# Staging vs prod:
#  - /Applications/Termy.app          — prod, may host the live Claude
#    session; never killed by this script.
#  - /Applications/Termy Dev.app      — staging, bundle id
#    `com.mees.termy.dev`, separate process + prefs domain. Safe to
#    kill/relaunch as many times as we want. This is where every
#    in-progress change lives until it's pushed to prod via
#    `./release.sh`.
#
# Workflow:
#   1. Edit code.
#   2. `./stage.sh`     — debug build → installs/relaunches Termy Dev.
#   3. Test in Termy Dev.
#   4. When green, `./release.sh` cuts a release DMG + appcast + tag
#      and pushes a new version to GitHub. That becomes the next prod.
#
# Usage:
#   ./stage.sh           — rebuild + relaunch staging
#   ./stage.sh --no-run  — rebuild + refresh bundle, don't relaunch
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Termy"
STAGING_NAME="Termy Dev"
STAGING_APP="/Applications/${STAGING_NAME}.app"
STAGING_BUNDLE_ID="com.mees.termy.dev"
NO_RUN=0
[[ "${1:-}" == "--no-run" ]] && NO_RUN=1

# One-time migration: kill + remove any old /tmp/TermyTest.app that
# pre-dates this script's home in /Applications.
if [[ -d /tmp/TermyTest.app ]]; then
    pkill -f /tmp/TermyTest.app 2>/dev/null || true
    rm -rf /tmp/TermyTest.app
fi

cd "$PROJECT_DIR"

# Re-apply the SwiftTerm patches every build. Idempotent — no-op when the
# checkout already has the sentinels. Required after `swift package update`
# (which restores the upstream checkout) and benign on fresh clones.
if [[ -d "$PROJECT_DIR/.build/checkouts/SwiftTerm" ]]; then
    "$PROJECT_DIR/release_helpers/patch-swiftterm.sh"
else
    echo "── First-run: resolving Swift packages ──"
    swift package resolve
    "$PROJECT_DIR/release_helpers/patch-swiftterm.sh"
fi

echo "── Building ${APP_NAME} (debug) ──"
swift build --product "${APP_NAME}" 2>&1 | tail -3

BIN="$PROJECT_DIR/.build/debug/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
    echo "Build failed: binary missing at $BIN"
    exit 1
fi

# Bootstrap bundle structure on first run. Idempotent — `mkdir -p` and
# `cp -R` re-copy each invocation, which is fine since the Info.plist /
# icons rarely change.
if [[ ! -d "$STAGING_APP" ]]; then
    echo "── Bootstrapping staging bundle at $STAGING_APP ──"
fi
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"
mkdir -p "$STAGING_APP/Contents/Frameworks"

cp "$PROJECT_DIR/Resources/${APP_NAME}-Info.plist" "$STAGING_APP/Contents/Info.plist"
# Rebrand so macOS treats this as a separate app from /Applications/Termy.
# Without distinct bundle id + name, `open -n` ends up activating the
# already-running prod instance instead of launching staging.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${STAGING_BUNDLE_ID}" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${STAGING_NAME}" "$STAGING_APP/Contents/Info.plist"
# Optional display-name override so the dock label reads "TermyTest".
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$STAGING_APP/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${STAGING_NAME}" "$STAGING_APP/Contents/Info.plist"
fi

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$PROJECT_DIR/Resources/LaunchIcons" ]]; then
    cp -R "$PROJECT_DIR/Resources/LaunchIcons" "$STAGING_APP/Contents/Resources/"
fi

# Sparkle is loaded via @rpath/Sparkle.framework — without it the binary
# crashes on launch with "Library not loaded". Copy fresh on every stage
# in case the SPM artifact moved between builds.
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    rm -rf "$STAGING_APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$STAGING_APP/Contents/Frameworks/"
fi

# Kill the running staging instance BEFORE we overwrite its binary —
# the prod /Applications/Termy.app stays untouched because we filter by
# the staging path.
if [[ $NO_RUN -eq 0 ]]; then
    echo "── Stopping staging instance (if any) ──"
    pkill -f "${STAGING_APP}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 0.5
fi

echo "── Refreshing binary ──"
cp "$BIN" "$STAGING_APP/Contents/MacOS/${APP_NAME}"

# install_name_tool changes are stamped on the binary, so they get wiped
# every time we cp a fresh build over the top. Re-add the rpath here, in
# the same script that copies the binary, so the bundle is never left in
# a state where it can't find Sparkle.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$STAGING_APP/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "── Ad-hoc codesigning ──"
codesign --force --deep --sign - "$STAGING_APP" 2>&1 | tail -1

if [[ $NO_RUN -eq 1 ]]; then
    echo "── Done (bundle refreshed, not relaunched) ──"
    exit 0
fi

echo "── Launching staging ──"
open -n "$STAGING_APP"
sleep 1
if pgrep -f "${STAGING_APP}/Contents/MacOS/${APP_NAME}" >/dev/null; then
    echo "── Staging is up: $STAGING_APP ──"
else
    echo "── Staging failed to launch — check Console for crash logs ──"
    exit 1
fi
