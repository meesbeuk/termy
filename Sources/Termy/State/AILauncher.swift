import Foundation
import AppKit

/// AI / coding tool that can be launched into the active pane.
/// Each tool detects whether it's installed (via `which <cli>`) so we only
/// surface ones the user actually has.
struct AILauncher: Identifiable, Hashable {
    let id: String          // CLI name, e.g. "claude"
    let displayName: String
    let cli: String         // command to execute
    let arguments: [String]
    let icon: String        // SF Symbol fallback
    let brandAsset: String? // basename of SVG in Resources/LaunchIcons (no extension)
    let tint: AILauncherTint

    /// Always returns the canonical set so users never lose access to a tool
    /// just because our detection missed a non-standard install path
    /// (npm-global, brew, asdf, mise, etc.). If a tool isn't actually
    /// installed, the shell will surface a "command not found" — that's
    /// faster + more honest feedback than us hiding the button.
    static func installed() -> [AILauncher] {
        all
    }

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
