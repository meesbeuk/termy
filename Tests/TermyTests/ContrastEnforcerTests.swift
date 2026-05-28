import Testing
import AppKit
@testable import Termy

/// Smoke test that proves `@testable import Termy` links against the
/// executable target AND that the WCAG contrast floor actually lifts a
/// low-contrast foreground. If this compiles and runs, the whole harness
/// works for the rest of the suite.
struct ContrastEnforcerTests {
    private func ratio(_ fg: NSColor, _ bg: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            let s = c.usingColorSpace(.sRGB)!
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(Double(s.redComponent)) + 0.7152 * lin(Double(s.greenComponent)) + 0.0722 * lin(Double(s.blueComponent))
        }
        let l1 = lum(fg), l2 = lum(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func aboveFloorIsUnchanged() {
        let fg = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let bg = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let out = ContrastEnforcer.enforce(foreground: fg, background: bg, minRatio: 4.5)
        #expect(out == fg, "white-on-black already exceeds 4.5; must pass through untouched")
    }

    @Test func lowContrastIsLifted() {
        let bg = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        let fg = NSColor(srgbRed: 0.32, green: 0.32, blue: 0.32, alpha: 1)
        #expect(ratio(fg, bg) < 4.5, "precondition: starting pair is below the floor")
        let out = ContrastEnforcer.enforce(foreground: fg, background: bg, minRatio: 4.5)
        #expect(ratio(out, bg) >= 4.5 - 0.15,
                "enforcer must lift the foreground to (approximately) the requested floor")
    }
}
