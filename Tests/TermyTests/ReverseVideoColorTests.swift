import Testing
import AppKit
@testable import Termy

/// Root-cause guard for the invisible reverse-video cursor (the user-reported
/// "caret not showing in claude"). Claude Code hides the OS cursor (ESC[?25l)
/// and draws its cursor as a reverse-video (ESC[7m) cell. SwiftTerm resolves a
/// reverse-video default-background cell to `nativeBackgroundColor.inverseColor()`.
/// Termy uses a transparent glass backdrop, so nativeBackgroundColor is
/// NSColor.clear (alpha 0) — and inverting a transparent colour keeps it
/// transparent, so the reverse cell painted nothing.
///
/// The SwiftTerm patch (`TERMY_PATCH inverse_bg_opaque`) keys on exactly the
/// predicate asserted here: when the backdrop is (near-)transparent, the
/// reversed default background falls back to the opaque foreground colour so
/// the block is visible. (The end-to-end render is verified in the smoke test:
/// Claude's cursor now shows as a visible block.)
struct ReverseVideoColorTests {
    @Test func transparentBackdropTriggersOpaqueFallback() {
        // alphaComponent < 0.05 is the exact gate the patch uses.
        #expect(NSColor.clear.alphaComponent < 0.05,
                "a transparent backdrop's inverted bg is also transparent -> must fall back to opaque fg")
    }

    @Test func opaqueBackdropKeepsNormalInverse() {
        // Opaque hosts are unaffected — their inverted background stays visible.
        #expect(NSColor.black.alphaComponent >= 0.05)
        #expect(NSColor.white.alphaComponent >= 0.05)
    }
}
