import Foundation
import AppKit

/// AI / coding tool that can be launched into the active pane.
/// We deliberately don't filter by "is installed" — the host process doesn't
/// run with the user's --login PATH (no rc-files have sourced), so any probe
/// would have false negatives. The shell prints "command not found" when a
/// tool isn't there, which is honest and one-click recoverable (install +
/// retry without restarting Termy).
struct AILauncher: Identifiable, Hashable {
    let id: String          // CLI name, e.g. "claude"
    let displayName: String
    let cli: String         // command to execute
    let arguments: [String]
    let icon: String        // SF Symbol fallback
    let brandAsset: String? // basename of SVG in Resources/LaunchIcons (no extension)
    let tint: AILauncherTint

    static func installed() -> [AILauncher] { all }

    /// Static catalog. Icon is an SF Symbol used as a placeholder — real brand
    /// marks can be dropped into Resources/Logos/ and referenced by `logoAsset`
    /// when bundled. UI renders all-white regardless of tint.
    static let all: [AILauncher] = [
        AILauncher(id: "claude",  displayName: "Claude Code",     cli: "claude",
                   arguments: [], icon: "sparkle",
                   brandAsset: "claudecode", tint: .neutral),
        AILauncher(id: "codex",   displayName: "Codex",           cli: "codex",
                   arguments: [], icon: "wand.and.stars.inverse",
                   brandAsset: "openai", tint: .neutral),
        AILauncher(id: "cursor",  displayName: "Cursor",          cli: "cursor",
                   arguments: ["."], icon: "cursorarrow.click.2",
                   brandAsset: "cursor", tint: .neutral),
        AILauncher(id: "gemini",  displayName: "Gemini CLI",      cli: "gemini",
                   arguments: [], icon: "diamond.fill",
                   brandAsset: "geminicli", tint: .neutral),
        AILauncher(id: "gh",      displayName: "GitHub Copilot",  cli: "gh",
                   arguments: ["copilot", "suggest"], icon: "circle.hexagongrid.fill",
                   brandAsset: "githubcopilot", tint: .neutral),
        AILauncher(id: "aider",   displayName: "Aider",           cli: "aider",
                   arguments: [], icon: "hammer.fill",
                   brandAsset: nil, tint: .neutral),
    ]
}

/// SF-symbol tint colors. Resolved at view time so it's pure data here.
enum AILauncherTint: Hashable {
    case orange, green, blue, purple, red, neutral
}

extension AILauncher {
    /// What the user actually sees typed into the terminal — the CLI + its args.
    var commandPreview: String {
        ([cli] + arguments).joined(separator: " ")
    }
}
