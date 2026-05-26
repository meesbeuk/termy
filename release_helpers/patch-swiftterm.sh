#!/bin/zsh
# Patches the SwiftTerm checkout in .build/checkouts/SwiftTerm to add the
# three host-controlled rendering knobs Termy needs but upstream doesn't
# expose:
#
#   lineSpacing  — extra pixels added to cell height
#   fontThicken  — strokeWidth boost for "font-thicken" (Ghostty-style)
#
# Patches are detected by sentinel comments (TERMY_PATCH_*) so re-running is
# a no-op. `swift package update` blows away .build/checkouts; this script
# is the recovery hook — call it from stage.sh / build.sh / release.sh
# before `swift build`.
#
# To pin a new SwiftTerm version, bump Package.swift, run `swift package
# resolve`, then re-run this script.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$PROJECT_DIR/.build/checkouts/SwiftTerm"

if [[ ! -d "$CHECKOUT" ]]; then
    echo "patch-swiftterm: SwiftTerm checkout not found at $CHECKOUT"
    echo "patch-swiftterm: run 'swift package resolve' first"
    exit 1
fi

MAC_FILE="$CHECKOUT/Sources/SwiftTerm/Mac/MacTerminalView.swift"
APPLE_FILE="$CHECKOUT/Sources/SwiftTerm/Apple/AppleTerminalView.swift"

# Idempotent — bail if already applied.
if grep -q "TERMY_PATCH_BEGIN line_spacing" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH host-controlled extra leading" "$APPLE_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH_BEGIN font_thicken" "$APPLE_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH preserve_selection_on_layout" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH preserve_selection_on_keydown" "$MAC_FILE" 2>/dev/null; then
    echo "patch-swiftterm: already applied"
    exit 0
fi

echo "patch-swiftterm: applying patches..."

# --- Mac/MacTerminalView.swift -------------------------------------------
# Insert lineSpacing + fontThicken stored properties on TerminalView.
python3 - "$MAC_FILE" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH_BEGIN line_spacing" in text:
    sys.exit(0)
anchor = "    public var disableFullRedrawOnAnyChanges = false\n    var fontSet: FontSet"
patch = """    public var disableFullRedrawOnAnyChanges = false

    // TERMY_PATCH_BEGIN line_spacing
    /// Extra pixels added to the natural cell height (ascent+descent+leading).
    /// Lets the host inject "vertical character spacing" the way iTerm and
    /// Ghostty expose it. Setting this re-runs the font-dimension calc.
    public var lineSpacing: CGFloat = 0 {
        didSet {
            guard lineSpacing != oldValue else { return }
            resetFont()
        }
    }
    /// 0 = off. >0 strokes glyph outlines with this width using the
    /// foreground color, producing the "font-thicken" effect popularized by
    /// Ghostty: heavier-looking glyphs on dark backgrounds without swapping
    /// in a Bold weight. Typical values: 0.5–1.5. Larger values clobber
    /// glyph shapes. Setting this invalidates the attribute cache.
    public var fontThicken: CGFloat = 0 {
        didSet {
            guard fontThicken != oldValue else { return }
            resetCaches()
            needsDisplay = true
        }
    }
    // TERMY_PATCH_END line_spacing
    var fontSet: FontSet"""
if anchor not in text:
    sys.exit("anchor missing in MacTerminalView.swift")
open(path, "w").write(text.replace(anchor, patch, 1))
PY

# --- Apple/AppleTerminalView.swift ---------------------------------------
# 1) computeFontDimensions: add `+ lineSpacing` to cellHeight.
python3 - "$APPLE_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH host-controlled extra leading" in text:
    sys.exit(0)
old = "        let lineLeading = CTFontGetLeading (fontSet.normal)\n        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)"
new = "        let lineLeading = CTFontGetLeading (fontSet.normal)\n        // TERMY_PATCH host-controlled extra leading\n        let cellHeight = ceil(lineAscent + lineDescent + lineLeading + lineSpacing)"
if old not in text:
    sys.exit("computeFontDimensions anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

# 2) getAttributes: append strokeWidth/strokeColor when fontThicken > 0.
python3 - "$APPLE_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH_BEGIN font_thicken" in text:
    sys.exit(0)
anchor = """        if withUrl {
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
            nsattr [.underlineColor] = fgColor
            nsattr [SwiftTermUnderlineStyleKey] = Int(UnderlineStyle.dashed.rawValue)

            // Add to cache
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache
            attributes [attribute] = nsattr
        }
        return nsattr
    }"""
patch = """        // TERMY_PATCH_BEGIN font_thicken
        // Negative strokeWidth = fill AND stroke with the foreground color,
        // producing the "font-thicken" effect (Ghostty-style). Positive
        // would draw outline-only. Scale the stored value into the
        // NSAttributedString convention (percentage of point size, negative).
        // MUST be set BEFORE the cache write below, otherwise only the
        // first draw of each attribute combination sees the strokeWidth
        // (subsequent draws return the cached no-stroke dict, making
        // the effect invisible after the first frame).
        if fontThicken > 0 {
            nsattr [.strokeWidth] = -fontThicken
            nsattr [.strokeColor] = fgColor
        }
        // TERMY_PATCH_END font_thicken
        if withUrl {
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
            nsattr [.underlineColor] = fgColor
            nsattr [SwiftTermUnderlineStyleKey] = Int(UnderlineStyle.dashed.rawValue)

            // Add to cache
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache
            attributes [attribute] = nsattr
        }
        return nsattr
    }"""
if anchor not in text:
    sys.exit("getAttributes anchor missing")
open(path, "w").write(text.replace(anchor, patch, 1))
PY

# --- preserve selection on layout passes ---------------------------------
# SwiftTerm's resizeSubviews unconditionally clears selection (line ~724).
# AppKit fires resizeSubviews on every setFrameSize tick — including
# sub-pixel ticks from SwiftUI re-renders that don't actually reflow the
# cell grid. The clear here was killing the user's drag-selection mid-
# drag. processSizeChange (called via the setFrameSize path) ALREADY
# clears selection when the cell grid (cols×rows) actually changes — the
# only case where stored start/end positions would no longer correspond
# to the same cells. So the clear in resizeSubviews is redundant for
# correctness AND broken for usability; remove it outright.
python3 - "$MAC_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH preserve_selection_on_layout" in text:
    sys.exit(0)
old = """    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        selection.active = false
        updateProgressBarFrame()
    }"""
new = """    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        // TERMY_PATCH preserve_selection_on_layout
        // Selection-clear deliberately removed. The original behavior
        // (`selection.active = false` here) wiped the user's selection
        // on EVERY layout pass, including sub-pixel ones triggered by
        // SwiftUI re-renders that don't actually reflow the cell grid.
        // processSizeChange (called from setFrameSize) already clears
        // selection when newCols/newRows differ from terminal.cols/rows
        // — the only case where the selection's start/end positions
        // would no longer correspond to the same cells. So removing
        // the unconditional clear here doesn't lose any necessary
        // safety; it just stops killing the selection on no-op layout
        // ticks.
        updateProgressBarFrame()
    }"""
if old not in text:
    sys.exit("resizeSubviews anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

# --- preserve selection across keypresses --------------------------------
# SwiftTerm's keyDown override starts with `selection.active = false`
# (line ~935), which kills the selection on any keystroke including the
# Cmd+C that the user is presumably about to press to copy it. Cmd+C
# routes through `copy(_:)` which reads `selection.getSelectedText()`
# — but copy(_:) is dispatched via the responder chain AFTER keyDown
# has already cleared the selection. Net: select-then-cmd-C reliably
# copies an empty string. Patch keyDown to only clear when the
# keystroke isn't a copy-equivalent shortcut.
python3 - "$MAC_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH preserve_selection_on_keydown" in text:
    sys.exit(0)
old = """    public override func keyDown(with event: NSEvent) {
        selection.active = false"""
new = """    public override func keyDown(with event: NSEvent) {
        // TERMY_PATCH preserve_selection_on_keydown
        // Don't clear the active selection on Cmd-modified keys — the
        // most common case is the user just selected text and is about
        // to press ⌘C to copy it. Clearing here makes copy(_:) read
        // empty. Pure cmd-key passthroughs (⌘F, ⌘T, etc.) don't type
        // characters and shouldn't reset the user's selection either.
        // For real typed characters, original behavior is preserved.
        if !event.modifierFlags.contains(.command) {
            selection.active = false
        }"""
if old not in text:
    sys.exit("keyDown anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

echo "patch-swiftterm: done"
