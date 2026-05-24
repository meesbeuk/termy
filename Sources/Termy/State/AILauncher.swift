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
    let icon: String        // SF Symbol
    let tint: AILauncherTint

    /// Always returns the canonical set so users never lose access to a tool
    /// just because our detection missed a non-standard install path
    /// (npm-global, brew, asdf, mise, etc.). If a tool isn't actually
    /// installed, the shell will surface a "command not found" — that's
    /// faster + more honest feedback than us hiding the button.
    static func installed() -> [AILauncher] {
        all
    }

    /// Static catalog. Add more here to make them available. Each will only
    /// appear in the launcher if the corresponding CLI is on $PATH.
    static let all: [AILauncher] = [
        AILauncher(
            id: "claude",
            displayName: "Claude Code",
            cli: "claude",
            arguments: [],
            icon: "sparkles",
            tint: .orange
        ),
        AILauncher(
            id: "codex",
            displayName: "Codex",
            cli: "codex",
            arguments: [],
            icon: "wand.and.stars",
            tint: .green
        ),
        AILauncher(
            id: "cursor",
            displayName: "Cursor",
            cli: "cursor",
            arguments: ["."],
            icon: "cursorarrow.rays",
            tint: .blue
        ),
        AILauncher(
            id: "code",
            displayName: "VS Code",
            cli: "code",
            arguments: ["."],
            icon: "chevron.left.forwardslash.chevron.right",
            tint: .blue
        ),
        AILauncher(
            id: "gh",
            displayName: "GitHub Copilot",
            cli: "gh",
            arguments: ["copilot", "suggest"],
            icon: "person.fill.questionmark",
            tint: .purple
        ),
        AILauncher(
            id: "aider",
            displayName: "Aider",
            cli: "aider",
            arguments: [],
            icon: "ant.fill",
            tint: .red
        ),
    ]
}

/// SF-symbol tint colors. Resolved at view time so it's pure data here.
enum AILauncherTint: Hashable {
    case orange, green, blue, purple, red, neutral
}
