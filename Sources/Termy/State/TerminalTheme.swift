import Foundation
import SwiftTerm

/// Color palette + foreground color for the terminal. New themes drop in here
/// and become selectable in the Settings sheet.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let foreground: (Int, Int, Int)
    let ansi: [(Int, Int, Int)]   // 16-entry ANSI palette

    static func == (lhs: TerminalTheme, rhs: TerminalTheme) -> Bool { lhs.id == rhs.id }

    var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { (r, g, b) in
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
    }

    static let all: [TerminalTheme] = [tokyoNight, defaultDark, solarizedDark, gruvbox]

    static func find(id: String?) -> TerminalTheme {
        all.first(where: { $0.id == id }) ?? tokyoNight
    }

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        foreground: (192, 197, 206),
        ansi: [
            (30, 30, 30), (240, 113, 120), (137, 184, 144), (219, 171, 121),
            (122, 162, 247), (187, 154, 247), (125, 207, 255), (192, 197, 206),
            (80, 84, 95), (255, 117, 127), (158, 206, 106), (224, 175, 104),
            (130, 170, 255), (198, 160, 246), (137, 220, 235), (255, 255, 255),
        ]
    )

    static let defaultDark = TerminalTheme(
        id: "default-dark",
        name: "Default Dark",
        foreground: (240, 240, 240),
        ansi: [
            (0, 0, 0), (224, 50, 50), (90, 220, 90), (220, 200, 50),
            (90, 130, 230), (180, 100, 200), (90, 200, 220), (220, 220, 220),
            (80, 80, 80), (255, 100, 100), (130, 250, 130), (255, 230, 100),
            (130, 180, 255), (220, 140, 240), (130, 230, 250), (255, 255, 255),
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        foreground: (131, 148, 150),
        ansi: [
            (7, 54, 66), (220, 50, 47), (133, 153, 0), (181, 137, 0),
            (38, 139, 210), (211, 54, 130), (42, 161, 152), (238, 232, 213),
            (0, 43, 54), (203, 75, 22), (88, 110, 117), (101, 123, 131),
            (131, 148, 150), (108, 113, 196), (147, 161, 161), (253, 246, 227),
        ]
    )

    static let gruvbox = TerminalTheme(
        id: "gruvbox",
        name: "Gruvbox Dark",
        foreground: (235, 219, 178),
        ansi: [
            (40, 40, 40), (204, 36, 29), (152, 151, 26), (215, 153, 33),
            (69, 133, 136), (177, 98, 134), (104, 157, 106), (168, 153, 132),
            (146, 131, 116), (251, 73, 52), (184, 187, 38), (250, 189, 47),
            (131, 165, 152), (211, 134, 155), (142, 192, 124), (235, 219, 178),
        ]
    )
}
