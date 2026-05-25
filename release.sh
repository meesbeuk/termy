#!/bin/zsh
# Termy DMG + appcast release flow.
# Run on the build machine that holds the Sparkle EdDSA private key
# (~/Library/Keychains item "https://sparkle-project.org" — auto-created
# by Sparkle's generate_keys on first ever release).
#
# Usage: ./release.sh
# Reads the version + build out of Resources/Termy-Info.plist so there's
# nothing to pass on the command line. Whatever the plist says ships.
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Termy-Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw Resources/Termy-Info.plist)
TAG="v$VERSION"

echo "── Releasing Termy $VERSION (build $BUILD) ──"

# Sanity: GitHub CLI is the only outbound dependency. Bail early with a
# clear message rather than failing five steps in.
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh (GitHub CLI) not found. Install via 'brew install gh', then 'gh auth login'."
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is installed but not authenticated. Run 'gh auth login' first."
    exit 1
fi

# Build the .app first so the rest of the script works against a known-
# good /Applications/Termy.app. build.sh handles compile + bundle +
# codesign + install.
./build.sh

# Sparkle ships generate_keys + sign_update as part of its SPM artifact.
# Locate sign_update so the path doesn't have to be hardcoded — the
# artifacts directory layout includes the Swift version, so wildcard.
SIGN_TOOL=$(find .build/artifacts/sparkle -name sign_update -type f 2>/dev/null | head -1)
if [[ -z "$SIGN_TOOL" ]]; then
    echo "ERROR: sign_update not found under .build/artifacts/sparkle. Re-run 'swift build' to fetch Sparkle artifacts."
    exit 1
fi

# DMG layout: app on the left, Applications symlink on the right. Same
# convention every Mac user recognises — drag-to-install.
echo "── Building DMG ──"
WORK=/tmp/termy-dmg-staging
# Asset name must stay "Termy.dmg" — appcast.xml URLs hard-code that filename
# under each release tag (e.g. /releases/download/vX.Y.Z/Termy.dmg). Anything
# else 404s for existing Sparkle clients.
DMG=/tmp/Termy.dmg
rm -rf "$WORK" "$DMG"
mkdir -p "$WORK"
cp -R /Applications/Termy.app "$WORK/Termy.app"
ln -s /Applications "$WORK/Applications"
hdiutil create -volname "Termy" -srcfolder "$WORK" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$WORK"

LENGTH=$(stat -f%z "$DMG")
echo "── DMG: $DMG ($LENGTH bytes) ──"

# sign_update prints `sparkle:edSignature="…" length="…"` to stdout when
# the keychain holds the private key. If no key exists it errors out
# with "No existing signing key found!" — that means a first-time setup
# is needed (generate_keys) and is too sensitive to do silently here.
echo "── Signing DMG with Sparkle EdDSA key ──"
SIGN_OUTPUT=$("$SIGN_TOOL" "$DMG")
echo "    $SIGN_OUTPUT"
SIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
if [[ -z "$SIG" ]]; then
    echo "ERROR: couldn't parse sparkle:edSignature from sign_update output."
    echo "    Raw output: $SIGN_OUTPUT"
    exit 1
fi

# Inject the new entry into appcast.xml as the first <item> so Sparkle
# clients see it as latest. Python is preinstalled on macOS so no extra
# dependency.
echo "── Updating appcast.xml ──"
python3 release_helpers/update_appcast.py "$VERSION" "$BUILD" "$LENGTH" "$SIG"

# Ensure the GitHub release exists for this tag. `gh release view` exits
# non-zero if missing — create it on the fly so this script also covers
# the case where the tag was pushed without a release.
if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "── Creating GitHub release $TAG ──"
    gh release create "$TAG" --title "$TAG" --notes "Auto-created by release.sh — see appcast.xml for full notes."
fi

echo "── Uploading DMG to GitHub release $TAG ──"
gh release upload "$TAG" "$DMG" --clobber

echo "── Committing + pushing appcast.xml ──"
git add appcast.xml
if ! git diff --cached --quiet; then
    git commit -m "appcast: $TAG ($BUILD)"
    git push origin main
else
    echo "    (appcast.xml had no changes — nothing to commit)"
fi

echo ""
echo "── Done ──"
echo "Release page:  https://github.com/meesbeuk/termy/releases/tag/$TAG"
echo "DMG download:  https://github.com/meesbeuk/termy/releases/download/$TAG/Termy.dmg"
echo "Sparkle users will see the update on next check."
