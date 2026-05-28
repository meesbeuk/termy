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
BUFFER_FILE="$CHECKOUT/Sources/SwiftTerm/Buffer.swift"
TERMINAL_FILE="$CHECKOUT/Sources/SwiftTerm/Terminal.swift"

# SwiftPM marks some checkout files read-only; make the ones we patch writable.
chmod u+w "$MAC_FILE" "$APPLE_FILE" "$BUFFER_FILE" "$TERMINAL_FILE" 2>/dev/null || true

# Idempotent — bail if already applied.
if grep -q "TERMY_PATCH_BEGIN line_spacing" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH host-controlled extra leading" "$APPLE_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH_BEGIN font_thicken" "$APPLE_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH preserve_selection_on_layout" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH preserve_selection_on_keydown" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH return_key_enter" "$MAC_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH public_ybase" "$BUFFER_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH sync_active_internal" "$TERMINAL_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH caret_sync_consistency" "$APPLE_FILE" 2>/dev/null && \
   grep -q "TERMY_PATCH caret_single_owner" "$MAC_FILE" 2>/dev/null; then
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

# --- map the main Return key to the kitty .enter functional key ----------
# Under the kitty keyboard protocol (which Claude Code, neovim, fish, etc.
# enable via `CSI > 1 u`), modified Enter must be disambiguated from plain
# Enter. SwiftTerm's `kittyFunctionalKey(from:)` mapped keypad-Enter and the
# arrow/F keys but NOT the main Return key (kVK_Return = 36). So Shift+Enter
# fell through keyDown's kitty branch into `interpretKeyEvents` ->
# `doCommand(insertNewline:)` -> `sendKittyFunctionalKey(.enter)` with NO
# modifiers — the Shift bit was dropped, so Claude (and any kitty-aware app)
# received a plain Enter and couldn't tell it apart. Result: Shift+Enter
# submitted instead of inserting a newline.
#
# Mapping kVK_Return -> .enter routes it through the kitty functional-key
# path in keyDown, which encodes WITH the real modifiers:
#   plain Enter      -> CR (0x0d)            [legacySpecialKeySequence]
#   Shift+Enter      -> ESC [ 1 3 ; 2 u      [encodeCsiU, exactly what Claude wants]
# Unmodified Enter is unchanged (still CR), so there's no regression for
# shells/REPLs. When kitty mode is OFF the whole branch is skipped, so normal
# terminals are entirely unaffected.
python3 - "$MAC_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH return_key_enter" in text:
    sys.exit(0)
anchor = """        switch Int(event.keyCode) {
        case kVK_ANSI_Keypad0:
            return .keypad0"""
patch = """        switch Int(event.keyCode) {
        // TERMY_PATCH return_key_enter — main Return is a kitty functional key
        // so Shift/Ctrl/Alt+Enter disambiguate (e.g. Shift+Enter => ESC[13;2u).
        case kVK_Return:
            return .enter
        case kVK_ANSI_Keypad0:
            return .keypad0"""
if anchor not in text:
    sys.exit("kittyFunctionalKey keyCode switch anchor missing")
open(path, "w").write(text.replace(anchor, patch, 1))
PY

# --- expose Buffer.yBase for reading from the host module ----------------
# Termy's scroll lock needs to know whether the viewport is at the LIVE tail
# (buffer.yDisp == buffer.yBase). It can't use SwiftTerm's `scrollPosition`
# because that reads `terminal.displayBuffer`, which is the FROZEN snapshot
# during a DECSET 2026 synchronized-output frame — making it lie about the
# tail mid-frame and spuriously engage the lock (scrolling claude's input +
# caret off-screen). `yDisp` is already public; make `yBase`'s getter public
# (setter stays internal) so the host can compute the true live-tail state.
python3 - "$BUFFER_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH public_ybase" in text:
    sys.exit(0)
old = """    /// has access to are `lines [yBase..(yBase+rows)]`
    var yBase: Int {"""
new = """    /// has access to are `lines [yBase..(yBase+rows)]`
    // TERMY_PATCH public_ybase — getter exposed so the host can detect the
    // live tail without going through the sync-frozen displayBuffer.
    public internal(set) var yBase: Int {"""
if old not in text:
    sys.exit("yBase anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

# --- expose Terminal.synchronizedOutputActive to the rest of the module ---
# updateCursorPosition (in AppleTerminalView.swift, same module but a different
# file) needs to know whether a DECSET 2026 frame is in flight. The flag is
# file-private to Terminal.swift; widen it to internal (read stays in-module).
python3 - "$TERMINAL_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH sync_active_internal" in text:
    sys.exit(0)
old = "    private var synchronizedOutputActive: Bool = false"
new = "    // TERMY_PATCH sync_active_internal — readable across the module so the\n    // caret logic can defer while a synchronized-output frame is in flight.\n    var synchronizedOutputActive: Bool = false"
if old not in text:
    sys.exit("synchronizedOutputActive anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

# --- caret reflects only fully-committed frames (DECSET 2026) -------------
# updateCursorPosition takes ALL its geometry from terminal.displayBuffer,
# which during a synchronized-output frame is the FROZEN snapshot, while it
# reads terminal.cursorHidden LIVE — an inconsistent mix that mis-positions or
# removes the caret mid-frame (claude wraps every repaint in ESC[?2026h..l).
# Defer all caret mutation until the frame commits; endSynchronizedOutput()
# fires synchronizedOutputChanged -> queuePendingDisplay, which re-runs this off
# the now-live buffer once the whole frame has landed.
python3 - "$APPLE_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH caret_sync_consistency" in text:
    sys.exit(0)
old = """    func updateCursorPosition()
    {
        guard let caretView else { return }"""
new = """    func updateCursorPosition()
    {
        guard let caretView else { return }
        // TERMY_PATCH caret_sync_consistency
        // During a DECSET 2026 synchronized-output frame, terminal.displayBuffer
        // is a frozen snapshot while terminal.cursorHidden is read live. Mixing
        // stale geometry with a live visibility flag mis-positions or removes the
        // caret mid-frame. Leave it exactly as-is until the frame commits — the
        // post-sync queuePendingDisplay re-runs this off the live buffer.
        if terminal.synchronizedOutputActive { return }"""
if old not in text:
    sys.exit("updateCursorPosition anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

# --- updateCursorPosition is the SINGLE owner of caret attach/detach ------
# showCursor/hideCursor (the DECTCEM ESC[?25h/l delegate callbacks) used to
# poke caretView.superview directly with NO viewport check and NO reposition —
# so showCursor re-attached the caret at its STALE frame origin and raced the
# async updateCursorPosition (two owners of the same view). Route both through
# updateCursorPosition, which already does viewport + position + cursorHidden +
# sync gating. cursorHidden is set before these callbacks fire (Terminal.swift),
# so updateCursorPosition sees the correct visibility.
python3 - "$MAC_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "TERMY_PATCH caret_single_owner" in text:
    sys.exit(0)
old = """    open func showCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        caretView.removeFromSuperview()
    }"""
new = """    open func showCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        // TERMY_PATCH caret_single_owner — route through the single owner so the
        // caret is re-attached at the CURRENT position (not its stale frame) and
        // honours the viewport + sync gating instead of racing updateCursorPosition.
        updateCursorPosition()
    }

    open func hideCursor(source: Terminal) {
        if useMetalRenderer {
            queueMetalDisplay()
            return
        }
        // TERMY_PATCH caret_single_owner
        updateCursorPosition()
    }"""
if old not in text:
    sys.exit("showCursor/hideCursor anchor missing")
open(path, "w").write(text.replace(old, new, 1))
PY

echo "patch-swiftterm: done"
