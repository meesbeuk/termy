import Foundation
import SwiftTerm

/// Color palette + foreground for the terminal. New themes drop in here
/// and become selectable in Settings.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let category: ThemeCategory
    let foreground: (Int, Int, Int)
    /// 16-entry ANSI palette in standard order:
    /// black, red, green, yellow, blue, magenta, cyan, white,
    /// bright-black, bright-red, ..., bright-white.
    let ansi: [(Int, Int, Int)]

    static func == (lhs: TerminalTheme, rhs: TerminalTheme) -> Bool { lhs.id == rhs.id }

    var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { (r, g, b) in
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
    }

    /// Canonical palette ordered by category for the picker.
    static let all: [TerminalTheme] = [
        // Modern dark
        tokyoNight, catppuccinMocha, dracula, nord, oneDark, ayuDark, monokaiPro,
        materialDark, nightOwl, palenight, synthwave84,
        // Classic dark
        defaultDark, gruvbox, solarizedDark,
        // Light
        solarizedLight, gruvboxLight, githubLight,
    ]

    static func find(id: String?) -> TerminalTheme {
        all.first(where: { $0.id == id }) ?? tokyoNight
    }

    // MARK: - Modern dark

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", category: .modernDark,
        foreground: (192, 197, 206),
        ansi: [
            (30, 30, 30), (240, 113, 120), (137, 184, 144), (219, 171, 121),
            (122, 162, 247), (187, 154, 247), (125, 207, 255), (192, 197, 206),
            (80, 84, 95), (255, 117, 127), (158, 206, 106), (224, 175, 104),
            (130, 170, 255), (198, 160, 246), (137, 220, 235), (255, 255, 255),
        ]
    )

    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", category: .modernDark,
        foreground: (205, 214, 244),
        ansi: [
            (49, 50, 68), (243, 139, 168), (166, 227, 161), (249, 226, 175),
            (137, 180, 250), (245, 194, 231), (148, 226, 213), (186, 194, 222),
            (88, 91, 112), (243, 139, 168), (166, 227, 161), (249, 226, 175),
            (137, 180, 250), (245, 194, 231), (148, 226, 213), (205, 214, 244),
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", category: .modernDark,
        foreground: (248, 248, 242),
        ansi: [
            (40, 42, 54), (255, 85, 85), (80, 250, 123), (241, 250, 140),
            (98, 114, 164), (255, 121, 198), (139, 233, 253), (191, 191, 191),
            (68, 71, 90), (255, 110, 110), (105, 255, 148), (255, 255, 165),
            (212, 110, 244), (255, 146, 223), (164, 255, 255), (255, 255, 255),
        ]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord", category: .modernDark,
        foreground: (216, 222, 233),
        ansi: [
            (59, 66, 82), (191, 97, 106), (163, 190, 140), (235, 203, 139),
            (129, 161, 193), (180, 142, 173), (136, 192, 208), (229, 233, 240),
            (76, 86, 106), (191, 97, 106), (163, 190, 140), (235, 203, 139),
            (129, 161, 193), (180, 142, 173), (143, 188, 187), (236, 239, 244),
        ]
    )

    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", category: .modernDark,
        foreground: (171, 178, 191),
        ansi: [
            (40, 44, 52), (224, 108, 117), (152, 195, 121), (229, 192, 123),
            (97, 175, 239), (198, 120, 221), (86, 182, 194), (171, 178, 191),
            (92, 99, 112), (224, 108, 117), (152, 195, 121), (229, 192, 123),
            (97, 175, 239), (198, 120, 221), (86, 182, 194), (255, 255, 255),
        ]
    )

    static let ayuDark = TerminalTheme(
        id: "ayu-dark", name: "Ayu Dark", category: .modernDark,
        foreground: (191, 189, 182),
        ansi: [
            (1, 6, 14), (234, 109, 81), (179, 217, 96), (231, 197, 71),
            (89, 194, 255), (213, 99, 159), (149, 230, 203), (199, 199, 199),
            (104, 104, 104), (240, 113, 120), (134, 178, 88), (255, 180, 84),
            (89, 194, 255), (255, 119, 251), (149, 230, 203), (255, 255, 255),
        ]
    )

    static let monokaiPro = TerminalTheme(
        id: "monokai-pro", name: "Monokai Pro", category: .modernDark,
        foreground: (252, 252, 250),
        ansi: [
            (45, 42, 46), (255, 97, 136), (169, 220, 118), (255, 216, 102),
            (120, 220, 232), (171, 157, 242), (120, 220, 232), (252, 252, 250),
            (105, 105, 105), (255, 97, 136), (169, 220, 118), (255, 216, 102),
            (120, 220, 232), (171, 157, 242), (120, 220, 232), (252, 252, 250),
        ]
    )

    static let materialDark = TerminalTheme(
        id: "material-dark", name: "Material Dark", category: .modernDark,
        foreground: (238, 255, 255),
        ansi: [
            (33, 33, 33), (244, 67, 54), (76, 175, 80), (255, 235, 59),
            (33, 150, 243), (156, 39, 176), (0, 188, 212), (255, 255, 255),
            (102, 102, 102), (239, 83, 80), (102, 187, 106), (255, 238, 88),
            (66, 165, 245), (171, 71, 188), (38, 198, 218), (255, 255, 255),
        ]
    )

    static let nightOwl = TerminalTheme(
        id: "night-owl", name: "Night Owl", category: .modernDark,
        foreground: (214, 222, 235),
        ansi: [
            (1, 22, 39), (239, 83, 80), (34, 218, 110), (255, 235, 153),
            (130, 170, 255), (199, 146, 234), (33, 193, 254), (214, 222, 235),
            (87, 95, 105), (239, 83, 80), (34, 218, 110), (255, 203, 139),
            (130, 170, 255), (199, 146, 234), (122, 220, 251), (255, 255, 255),
        ]
    )

    static let palenight = TerminalTheme(
        id: "palenight", name: "Palenight", category: .modernDark,
        foreground: (146, 152, 192),
        ansi: [
            (41, 45, 62), (244, 92, 102), (195, 232, 141), (255, 203, 107),
            (130, 170, 255), (199, 146, 234), (137, 221, 235), (210, 210, 213),
            (103, 110, 149), (255, 91, 100), (195, 232, 141), (255, 203, 107),
            (130, 170, 255), (199, 146, 234), (137, 221, 235), (255, 255, 255),
        ]
    )

    static let synthwave84 = TerminalTheme(
        id: "synthwave-84", name: "Synthwave '84", category: .modernDark,
        foreground: (243, 243, 245),
        ansi: [
            (37, 32, 71), (254, 65, 81), (114, 247, 124), (252, 238, 87),
            (54, 246, 255), (255, 113, 235), (3, 237, 245), (255, 255, 255),
            (73, 73, 92), (254, 65, 81), (114, 247, 124), (252, 238, 87),
            (54, 246, 255), (255, 113, 235), (3, 237, 245), (255, 255, 255),
        ]
    )

    // MARK: - Classic dark

    static let defaultDark = TerminalTheme(
        id: "default-dark", name: "Default Dark", category: .classicDark,
        foreground: (240, 240, 240),
        ansi: [
            (0, 0, 0), (224, 50, 50), (90, 220, 90), (220, 200, 50),
            (90, 130, 230), (180, 100, 200), (90, 200, 220), (220, 220, 220),
            (80, 80, 80), (255, 100, 100), (130, 250, 130), (255, 230, 100),
            (130, 180, 255), (220, 140, 240), (130, 230, 250), (255, 255, 255),
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", category: .classicDark,
        foreground: (131, 148, 150),
        ansi: [
            (7, 54, 66), (220, 50, 47), (133, 153, 0), (181, 137, 0),
            (38, 139, 210), (211, 54, 130), (42, 161, 152), (238, 232, 213),
            (0, 43, 54), (203, 75, 22), (88, 110, 117), (101, 123, 131),
            (131, 148, 150), (108, 113, 196), (147, 161, 161), (253, 246, 227),
        ]
    )

    static let gruvbox = TerminalTheme(
        id: "gruvbox", name: "Gruvbox Dark", category: .classicDark,
        foreground: (235, 219, 178),
        ansi: [
            (40, 40, 40), (204, 36, 29), (152, 151, 26), (215, 153, 33),
            (69, 133, 136), (177, 98, 134), (104, 157, 106), (168, 153, 132),
            (146, 131, 116), (251, 73, 52), (184, 187, 38), (250, 189, 47),
            (131, 165, 152), (211, 134, 155), (142, 192, 124), (235, 219, 178),
        ]
    )

    // MARK: - Light

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", category: .light,
        foreground: (101, 123, 131),
        ansi: [
            (238, 232, 213), (220, 50, 47), (133, 153, 0), (181, 137, 0),
            (38, 139, 210), (211, 54, 130), (42, 161, 152), (7, 54, 66),
            (253, 246, 227), (203, 75, 22), (88, 110, 117), (101, 123, 131),
            (131, 148, 150), (108, 113, 196), (147, 161, 161), (0, 43, 54),
        ]
    )

    static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light", name: "Gruvbox Light", category: .light,
        foreground: (60, 56, 54),
        ansi: [
            (251, 241, 199), (157, 0, 6), (121, 116, 14), (181, 118, 20),
            (7, 102, 120), (143, 63, 113), (66, 123, 88), (124, 111, 100),
            (146, 131, 116), (157, 0, 6), (121, 116, 14), (181, 118, 20),
            (7, 102, 120), (143, 63, 113), (66, 123, 88), (60, 56, 54),
        ]
    )

    static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", category: .light,
        foreground: (36, 41, 47),
        ansi: [
            (246, 248, 250), (207, 34, 46), (26, 127, 55), (154, 103, 0),
            (9, 105, 218), (130, 80, 223), (31, 136, 153), (110, 119, 129),
            (87, 96, 106), (215, 58, 73), (52, 168, 83), (191, 135, 0),
            (9, 105, 218), (138, 75, 175), (31, 136, 153), (36, 41, 47),
        ]
    )
}

enum ThemeCategory: String, CaseIterable {
    case modernDark = "Modern Dark"
    case classicDark = "Classic Dark"
    case light = "Light"
}
