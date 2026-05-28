import Foundation
import SwiftUI
import SwiftTerm

// MARK: - Naming convention
//
// In Termy:
//   - "Cursor" — the user-facing name for the blinking text-input marker.
//     All UI strings use this word (Settings → Appearance → Cursor, the
//     style chips, etc.). When in doubt, this is what to write.
//   - "caret"  — the internal Swift symbol name SwiftTerm uses for the
//     same thing (`caretView`, `caretColor`, `caretTextColor`). Code that
//     touches SwiftTerm directly keeps "caret" to match upstream. Never
//     surfaces in user-visible strings.
//
// Single source of truth: this file. The `cursorStyle`/`cursor` properties
// here are the canonical names; renderers map them to SwiftTerm's
// caretColor/CaretView at the bridge.

/// A Termy color theme.
///
/// Themes used to control just the 16-color ANSI palette + the default
/// foreground. Termy's chrome (tab strip, status bar, find bar, accent
/// highlights) all read from the system accent color, so picking "Synthwave
/// '84" only ever changed cell content — leaving the chrome blue and the
/// app feeling mismatched.
///
/// The expanded model adds three optional surfaces that themes can drive:
///
///   - `selection` — selection background (alpha applied at render time)
///   - `cursor`    — cursor color (defaults to `foreground`)
///   - `accent`    — Termy UI accent (active-pane stroke, activity
///                   stripe, tinted buttons + sliders)
///
/// All three are optional. If unset, they fall back to sensible picks from
/// the ANSI palette (selection → bright-black, cursor → foreground,
/// accent → blue/ansi[4]). Existing themes work unchanged; new themes can
/// opt in to a richer look.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let category: ThemeCategory
    let foreground: (Int, Int, Int)
    /// 16-entry ANSI palette in standard order:
    /// black, red, green, yellow, blue, magenta, cyan, white,
    /// bright-black, bright-red, ..., bright-white.
    let ansi: [(Int, Int, Int)]
    let selection: (Int, Int, Int)?
    let cursor: (Int, Int, Int)?
    let accent: (Int, Int, Int)?

    init(
        id: String,
        name: String,
        category: ThemeCategory,
        foreground: (Int, Int, Int),
        ansi: [(Int, Int, Int)],
        selection: (Int, Int, Int)? = nil,
        cursor: (Int, Int, Int)? = nil,
        accent: (Int, Int, Int)? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.foreground = foreground
        self.ansi = ansi
        self.selection = selection
        self.cursor = cursor
        self.accent = accent
    }

    static func == (lhs: TerminalTheme, rhs: TerminalTheme) -> Bool { lhs.id == rhs.id }

    var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { (r, g, b) in
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
    }

    // MARK: - Derived surfaces (with fallbacks)

    /// Selection background. Falls back to ANSI 8 (bright black), which is
    /// the conventional "dim contrast" color in most palettes.
    var resolvedSelection: (Int, Int, Int) { selection ?? ansi[8] }
    /// Cursor color. Falls back to foreground.
    var resolvedCursor: (Int, Int, Int) { cursor ?? foreground }
    /// Accent color used across Termy's chrome (active-pane stroke,
    /// activity stripe, tinted controls). Falls back to ANSI 4 (blue),
    /// matching the system convention.
    var resolvedAccent: (Int, Int, Int) { accent ?? ansi[4] }

    // MARK: - SwiftUI / NSColor accessors

    var foregroundColor: SwiftUI.Color { Self.color(from: foreground) }
    var selectionColor: SwiftUI.Color { Self.color(from: resolvedSelection) }
    var cursorColor: SwiftUI.Color { Self.color(from: resolvedCursor) }
    var accentColor: SwiftUI.Color { Self.color(from: resolvedAccent) }

    var nsSelectionColor: NSColor {
        let (r, g, b) = resolvedSelection
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    var nsCursorColor: NSColor {
        let (r, g, b) = resolvedCursor
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    var nsAccentColor: NSColor {
        let (r, g, b) = resolvedAccent
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func color(from rgb: (Int, Int, Int)) -> SwiftUI.Color {
        SwiftUI.Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    /// Canonical palette ordered by category for the picker.
    ///
    /// Curated for Termy's glass backdrop: every theme here either has a
    /// distinctive palette identity OR a strong chrome accent that
    /// survives over a busy wallpaper. Pure-background themes (Default
    /// Dark, Material Dark) and washed-out lights (Solarized Light,
    /// Gruvbox Light) were dropped — they didn't differentiate on glass
    /// and made the picker noisy.
    static let all: [TerminalTheme] = [
        // Termy signatures — designed for the glass backdrop
        termyGlass, aurora, sunset, monoPop,
        // Modern dark — popular community palettes that read well over glass
        tokyoNight, catppuccinMocha, rosePine, dracula, nord, oneDark, ayuDark,
        monokaiPro, nightOwl, palenight, kanagawa, everforest, synthwave84,
        // Classic
        solarizedDark, gruvbox,
        // Light — for daylight / high-ambient setups
        githubLight, catppuccinLatte, rosePineDawn, solarizedLight, gruvboxLight,
    ]

    static func find(id: String?) -> TerminalTheme {
        all.first(where: { $0.id == id }) ?? termyGlass
    }

    // MARK: - Termy signature themes

    /// Termy's house theme — deep midnight base, electric cyan accent,
    /// designed to look incredible behind the .hudWindow glass on any
    /// wallpaper. Selection a vivid magenta so it pops without fighting
    /// the cyan accent.
    static let termyGlass = TerminalTheme(
        id: "termy-glass", name: "Termy Glass", category: .signature,
        foreground: (220, 230, 245),
        ansi: [
            (18, 22, 34), (255, 95, 121), (105, 220, 162), (255, 200, 87),
            (94, 199, 255), (210, 130, 255), (66, 240, 230), (200, 210, 225),
            (75, 85, 110), (255, 130, 155), (140, 240, 190), (255, 215, 130),
            (130, 215, 255), (230, 165, 255), (110, 250, 240), (245, 250, 255),
        ],
        selection: (210, 130, 255),
        cursor: (66, 240, 230),
        accent: (94, 199, 255)
    )

    /// Northern-lights palette — teals, greens, soft blues. Calmer than
    /// Termy Glass but still distinctive.
    static let aurora = TerminalTheme(
        id: "aurora", name: "Aurora", category: .signature,
        foreground: (205, 220, 230),
        ansi: [
            (15, 25, 35), (240, 130, 145), (110, 230, 180), (240, 210, 130),
            (110, 180, 230), (165, 145, 230), (80, 220, 220), (200, 215, 225),
            (70, 85, 100), (250, 145, 160), (130, 240, 195), (250, 220, 145),
            (130, 195, 240), (180, 165, 240), (105, 235, 235), (240, 245, 250),
        ],
        selection: (110, 180, 230),
        cursor: (110, 230, 180),
        accent: (80, 220, 220)
    )

    /// Warm magenta-orange palette — feels like a 6PM terminal. Strong
    /// chroma accents that hold up over photographic wallpapers.
    static let sunset = TerminalTheme(
        id: "sunset", name: "Sunset", category: .signature,
        foreground: (240, 225, 220),
        ansi: [
            (28, 18, 28), (255, 110, 95), (200, 220, 130), (255, 195, 110),
            (255, 145, 175), (230, 130, 230), (255, 180, 220), (240, 220, 215),
            (110, 80, 95), (255, 135, 120), (220, 240, 155), (255, 215, 135),
            (255, 170, 195), (245, 155, 245), (255, 200, 235), (255, 245, 240),
        ],
        selection: (255, 145, 175),
        cursor: (255, 195, 110),
        accent: (255, 145, 175)
    )

    /// Minimalist grayscale + a single accent. Looks like a designer's
    /// terminal — boring on purpose, except the one pop of color.
    static let monoPop = TerminalTheme(
        id: "mono-pop", name: "Mono Pop", category: .signature,
        foreground: (235, 235, 240),
        ansi: [
            (18, 18, 22), (220, 220, 220), (220, 220, 220), (220, 220, 220),
            (110, 200, 255), (220, 220, 220), (220, 220, 220), (220, 220, 220),
            (85, 85, 95), (255, 255, 255), (255, 255, 255), (255, 255, 255),
            (140, 215, 255), (255, 255, 255), (255, 255, 255), (255, 255, 255),
        ],
        selection: (110, 200, 255),
        cursor: (110, 200, 255),
        accent: (110, 200, 255)
    )

    // MARK: - Modern dark community themes

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", category: .modernDark,
        foreground: (192, 197, 206),
        ansi: [
            (30, 30, 30), (240, 113, 120), (137, 184, 144), (219, 171, 121),
            (122, 162, 247), (187, 154, 247), (125, 207, 255), (192, 197, 206),
            (80, 84, 95), (255, 117, 127), (158, 206, 106), (224, 175, 104),
            (130, 170, 255), (198, 160, 246), (137, 220, 235), (255, 255, 255),
        ],
        selection: (122, 162, 247),
        accent: (122, 162, 247)
    )

    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", category: .modernDark,
        foreground: (205, 214, 244),
        ansi: [
            (49, 50, 68), (243, 139, 168), (166, 227, 161), (249, 226, 175),
            (137, 180, 250), (245, 194, 231), (148, 226, 213), (186, 194, 222),
            (88, 91, 112), (243, 139, 168), (166, 227, 161), (249, 226, 175),
            (137, 180, 250), (245, 194, 231), (148, 226, 213), (205, 214, 244),
        ],
        selection: (245, 194, 231),
        accent: (203, 166, 247)  // mauve
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", category: .modernDark,
        foreground: (248, 248, 242),
        ansi: [
            (40, 42, 54), (255, 85, 85), (80, 250, 123), (241, 250, 140),
            (98, 114, 164), (255, 121, 198), (139, 233, 253), (191, 191, 191),
            (68, 71, 90), (255, 110, 110), (105, 255, 148), (255, 255, 165),
            (212, 110, 244), (255, 146, 223), (164, 255, 255), (255, 255, 255),
        ],
        // Use Dracula's "Comment" blue, not the canonical (68,71,90)
        // "Current Line" gray. The gray is only ~3 luminance points off
        // the bg — at the full alpha SwiftTerm draws selection with,
        // the highlight effectively disappears against the bg.
        selection: (98, 114, 164),
        accent: (255, 121, 198)  // pink
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord", category: .modernDark,
        foreground: (216, 222, 233),
        ansi: [
            (59, 66, 82), (191, 97, 106), (163, 190, 140), (235, 203, 139),
            (129, 161, 193), (180, 142, 173), (136, 192, 208), (229, 233, 240),
            (76, 86, 106), (191, 97, 106), (163, 190, 140), (235, 203, 139),
            (129, 161, 193), (180, 142, 173), (143, 188, 187), (236, 239, 244),
        ],
        selection: (94, 129, 172),
        accent: (136, 192, 208)
    )

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", category: .modernDark,
        foreground: (171, 178, 191),
        ansi: [
            (40, 44, 52), (224, 108, 117), (152, 195, 121), (229, 192, 123),
            (97, 175, 239), (198, 120, 221), (86, 182, 194), (171, 178, 191),
            (92, 99, 112), (224, 108, 117), (152, 195, 121), (229, 192, 123),
            (97, 175, 239), (198, 120, 221), (86, 182, 194), (255, 255, 255),
        ],
        selection: (97, 175, 239),
        accent: (97, 175, 239)
    )

    static let ayuDark = TerminalTheme(
        id: "ayu-dark", name: "Ayu Dark", category: .modernDark,
        foreground: (191, 189, 182),
        ansi: [
            (1, 6, 14), (234, 109, 81), (179, 217, 96), (231, 197, 71),
            (89, 194, 255), (213, 99, 159), (149, 230, 203), (199, 199, 199),
            (104, 104, 104), (240, 113, 120), (134, 178, 88), (255, 180, 84),
            (89, 194, 255), (255, 119, 251), (149, 230, 203), (255, 255, 255),
        ],
        // Ayu's accent orange (255,180,84) would wash out the cream
        // foreground if used as the selection bg. Switch to Ayu's
        // selection-blue (the "ide-selection" color from the official
        // palette) so cream text on muted blue stays legible.
        selection: (64, 127, 170),
        accent: (255, 180, 84)
    )

    static let monokaiPro = TerminalTheme(
        id: "monokai-pro", name: "Monokai Pro", category: .modernDark,
        foreground: (252, 252, 250),
        ansi: [
            (45, 42, 46), (255, 97, 136), (169, 220, 118), (255, 216, 102),
            (120, 220, 232), (171, 157, 242), (120, 220, 232), (252, 252, 250),
            (105, 105, 105), (255, 97, 136), (169, 220, 118), (255, 216, 102),
            (120, 220, 232), (171, 157, 242), (120, 220, 232), (252, 252, 250),
        ],
        selection: (255, 97, 136),
        accent: (255, 97, 136)
    )

    static let nightOwl = TerminalTheme(
        id: "night-owl", name: "Night Owl", category: .modernDark,
        foreground: (214, 222, 235),
        ansi: [
            (1, 22, 39), (239, 83, 80), (34, 218, 110), (255, 235, 153),
            (130, 170, 255), (199, 146, 234), (33, 193, 254), (214, 222, 235),
            (87, 95, 105), (239, 83, 80), (34, 218, 110), (255, 203, 139),
            (130, 170, 255), (199, 146, 234), (122, 220, 251), (255, 255, 255),
        ],
        selection: (130, 170, 255),
        accent: (33, 193, 254)
    )

    static let palenight = TerminalTheme(
        id: "palenight", name: "Palenight", category: .modernDark,
        foreground: (180, 188, 218),
        ansi: [
            (41, 45, 62), (244, 92, 102), (195, 232, 141), (255, 203, 107),
            (130, 170, 255), (199, 146, 234), (137, 221, 235), (210, 210, 213),
            (103, 110, 149), (255, 91, 100), (195, 232, 141), (255, 203, 107),
            (130, 170, 255), (199, 146, 234), (137, 221, 235), (255, 255, 255),
        ],
        selection: (199, 146, 234),
        accent: (130, 170, 255)
    )

    static let synthwave84 = TerminalTheme(
        id: "synthwave-84", name: "Synthwave '84", category: .modernDark,
        foreground: (243, 243, 245),
        ansi: [
            (37, 32, 71), (254, 65, 81), (114, 247, 124), (252, 238, 87),
            (54, 246, 255), (255, 113, 235), (3, 237, 245), (255, 255, 255),
            (73, 73, 92), (254, 65, 81), (114, 247, 124), (252, 238, 87),
            (54, 246, 255), (255, 113, 235), (3, 237, 245), (255, 255, 255),
        ],
        selection: (255, 113, 235),
        accent: (255, 113, 235)
    )

    // MARK: - Classic dark

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", category: .classicDark,
        foreground: (131, 148, 150),
        ansi: [
            (7, 54, 66), (220, 50, 47), (133, 153, 0), (181, 137, 0),
            (38, 139, 210), (211, 54, 130), (42, 161, 152), (238, 232, 213),
            (0, 43, 54), (203, 75, 22), (88, 110, 117), (101, 123, 131),
            (131, 148, 150), (108, 113, 196), (147, 161, 161), (253, 246, 227),
        ],
        selection: (38, 139, 210),
        accent: (42, 161, 152)
    )

    static let gruvbox = TerminalTheme(
        id: "gruvbox", name: "Gruvbox Dark", category: .classicDark,
        foreground: (235, 219, 178),
        ansi: [
            (40, 40, 40), (204, 36, 29), (152, 151, 26), (215, 153, 33),
            (69, 133, 136), (177, 98, 134), (104, 157, 106), (168, 153, 132),
            (146, 131, 116), (251, 73, 52), (184, 187, 38), (250, 189, 47),
            (131, 165, 152), (211, 134, 155), (142, 192, 124), (235, 219, 178),
        ],
        // Gruvbox's yellow accent would make selected text near-invisible
        // (cream-on-yellow). Use Gruvbox's `bg2` darker neutral — same
        // color vim's :hi Visual uses — so the cream foreground stays
        // clearly readable on the selection.
        selection: (80, 73, 69),
        accent: (250, 189, 47)
    )

    // MARK: - Light (one option, for those who insist)

    static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", category: .light,
        foreground: (36, 41, 47),
        ansi: [
            (246, 248, 250), (207, 34, 46), (26, 127, 55), (154, 103, 0),
            (9, 105, 218), (130, 80, 223), (31, 136, 153), (110, 119, 129),
            (87, 96, 106), (215, 58, 73), (52, 168, 83), (191, 135, 0),
            (9, 105, 218), (138, 75, 175), (31, 136, 153), (36, 41, 47),
        ],
        // GitHub Light's accent blue (9,105,218) at full alpha would
        // render near-black text on dark blue — unreadable. Use the
        // pale-blue tint GitHub's own UI shows for text selection (the
        // visual effect of `#0969da26` over white) so dark foreground
        // text stays high-contrast on the selection.
        selection: (208, 222, 243),
        accent: (9, 105, 218)
    )

    // MARK: - Added in v0.15 (theme audit)

    /// Rosé Pine — the soho-vibes palette everyone asks for. Muted, cosy,
    /// iris/foam/rose accents over a deep mauve base.
    static let rosePine = TerminalTheme(
        id: "rose-pine", name: "Rosé Pine", category: .modernDark,
        foreground: (224, 222, 244),
        ansi: [
            (38, 35, 58), (235, 111, 146), (49, 116, 143), (246, 193, 119),
            (156, 207, 216), (196, 167, 231), (235, 188, 186), (224, 222, 244),
            (110, 106, 134), (235, 111, 146), (49, 116, 143), (246, 193, 119),
            (156, 207, 216), (196, 167, 231), (235, 188, 186), (224, 222, 244),
        ],
        selection: (64, 61, 82),
        accent: (196, 167, 231)  // iris
    )

    /// Kanagawa — Hokusai-wave inspired, warm desaturated palette.
    static let kanagawa = TerminalTheme(
        id: "kanagawa", name: "Kanagawa", category: .modernDark,
        foreground: (220, 215, 186),
        ansi: [
            (22, 22, 29), (195, 64, 67), (118, 148, 106), (192, 163, 110),
            (126, 156, 216), (149, 127, 184), (106, 149, 137), (200, 192, 147),
            (114, 113, 105), (228, 104, 118), (152, 187, 108), (230, 195, 132),
            (124, 156, 216), (149, 127, 184), (122, 168, 159), (220, 215, 186),
        ],
        selection: (45, 79, 103),  // waveBlue
        accent: (126, 156, 216)    // crystalBlue
    )

    /// Everforest — soft, low-contrast forest greens; very easy on the eyes.
    static let everforest = TerminalTheme(
        id: "everforest", name: "Everforest", category: .modernDark,
        foreground: (211, 198, 170),
        ansi: [
            (45, 53, 59), (230, 126, 128), (167, 192, 128), (219, 188, 127),
            (127, 187, 179), (214, 153, 182), (131, 192, 146), (211, 198, 170),
            (94, 108, 112), (230, 126, 128), (167, 192, 128), (219, 188, 127),
            (127, 187, 179), (214, 153, 182), (131, 192, 146), (211, 198, 170),
        ],
        selection: (71, 82, 88),
        accent: (167, 192, 128)
    )

    // MARK: - Light themes (v0.15)

    /// Catppuccin Latte — the beloved light flavour. Crisp, pastel accents.
    static let catppuccinLatte = TerminalTheme(
        id: "catppuccin-latte", name: "Catppuccin Latte", category: .light,
        foreground: (76, 79, 105),
        ansi: [
            (92, 95, 119), (210, 15, 57), (64, 160, 43), (223, 142, 29),
            (30, 102, 245), (136, 57, 239), (23, 146, 153), (172, 176, 190),
            (108, 111, 133), (210, 15, 57), (64, 160, 43), (223, 142, 29),
            (30, 102, 245), (136, 57, 239), (23, 146, 153), (220, 224, 232),
        ],
        // Light bg: dark text needs a pale selection to stay readable.
        selection: (204, 208, 218),
        accent: (136, 57, 239)  // mauve
    )

    /// Rosé Pine Dawn — the light sibling of Rosé Pine.
    static let rosePineDawn = TerminalTheme(
        id: "rose-pine-dawn", name: "Rosé Pine Dawn", category: .light,
        foreground: (87, 82, 121),
        ansi: [
            (242, 233, 222), (180, 99, 122), (40, 105, 131), (234, 157, 52),
            (86, 148, 159), (144, 122, 169), (215, 130, 126), (87, 82, 121),
            (152, 147, 165), (180, 99, 122), (40, 105, 131), (234, 157, 52),
            (86, 148, 159), (144, 122, 169), (215, 130, 126), (87, 82, 121),
        ],
        selection: (223, 218, 217),
        accent: (144, 122, 169)  // iris
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", category: .light,
        foreground: (101, 123, 131),
        ansi: [
            (238, 232, 213), (220, 50, 47), (133, 153, 0), (181, 137, 0),
            (38, 139, 210), (211, 54, 130), (42, 161, 152), (7, 54, 66),
            (253, 246, 227), (203, 75, 22), (88, 110, 117), (101, 123, 131),
            (131, 148, 150), (108, 113, 196), (147, 161, 161), (7, 54, 66),
        ],
        selection: (213, 219, 199),
        accent: (38, 139, 210)
    )

    static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light", name: "Gruvbox Light", category: .light,
        foreground: (60, 56, 54),
        ansi: [
            (251, 241, 199), (157, 0, 6), (121, 116, 14), (181, 118, 20),
            (7, 102, 120), (143, 63, 113), (66, 123, 88), (124, 111, 100),
            (146, 131, 116), (157, 0, 6), (121, 116, 14), (181, 118, 20),
            (7, 102, 120), (143, 63, 113), (66, 123, 88), (60, 56, 54),
        ],
        selection: (235, 219, 178),
        accent: (181, 118, 20)
    )
}

enum ThemeCategory: String, CaseIterable {
    case signature   = "Termy Signature"
    case modernDark  = "Modern Dark"
    case classicDark = "Classic Dark"
    case light       = "Light"
}
