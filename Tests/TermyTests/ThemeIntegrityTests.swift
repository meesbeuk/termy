import Testing
@testable import Termy

/// Guards the theme catalog: a palette typo (wrong ANSI count, dup id) would
/// otherwise only surface as a broken picker at runtime.
struct ThemeIntegrityTests {
    @Test func everyThemeHas16AnsiColors() {
        for t in TerminalTheme.all {
            #expect(t.ansi.count == 16, "\(t.id) must have 16 ANSI colors, has \(t.ansi.count)")
        }
    }

    @Test func idsAreUnique() {
        let ids = TerminalTheme.all.map { $0.id }
        #expect(Set(ids).count == ids.count, "duplicate theme id in catalog")
    }

    @Test func findRoundTrips() {
        for t in TerminalTheme.all {
            #expect(TerminalTheme.find(id: t.id).id == t.id)
        }
        // Unknown id falls back to the house theme, never crashes.
        #expect(TerminalTheme.find(id: "does-not-exist").id == "termy-glass")
        #expect(TerminalTheme.find(id: nil).id == "termy-glass")
    }

    @Test func newlyAddedThemesArePresent() {
        let ids = Set(TerminalTheme.all.map { $0.id })
        for id in ["rose-pine", "rose-pine-dawn", "catppuccin-latte", "kanagawa",
                   "everforest", "solarized-light", "gruvbox-light"] {
            #expect(ids.contains(id), "missing newly-added theme \(id)")
        }
    }

    @Test func rgbValuesInRange() {
        for t in TerminalTheme.all {
            let all = [t.foreground] + t.ansi + [t.resolvedSelection, t.resolvedCursor, t.resolvedAccent]
            for (r, g, b) in all {
                #expect((0...255).contains(r) && (0...255).contains(g) && (0...255).contains(b),
                        "\(t.id) has an out-of-range RGB component")
            }
        }
    }
}
