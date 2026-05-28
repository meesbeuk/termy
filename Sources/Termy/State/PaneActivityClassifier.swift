import Foundation

/// Coarse runtime state of a pane, used by the activity stripe + the agent
/// mission-control dashboard.
///   • working — actively producing output (claude thinking, a build running)
///   • waiting — idle AND the last thing on screen is a prompt asking the user
///               to decide (claude's y/n, a numbered choice, "proceed?", …)
///   • idle    — settled, nothing demanding attention (sitting at a shell prompt)
enum PaneActivity: String, Equatable {
    case idle
    case working
    case waiting
}

/// Decides whether a pane that has gone idle is actually *waiting on the user*
/// rather than just sitting at a shell prompt. Pure + testable — the patterns
/// are the contract, so false-positive/negative regressions are caught here
/// rather than by eyeballing a live agent.
///
/// Deliberately conservative: it only flags `waiting` on an explicit
/// confirmation/choice cue, because a false "waiting" badge that never clears
/// is worse than occasionally missing one. A plain shell prompt (`$`, `%`,
/// `#`, a bare `❯`) is NOT waiting.
enum PaneActivityClassifier {

    /// Explicit "I'm asking you something" cues (matched case-insensitively
    /// against the tail of recent output). Covers Claude Code / Codex
    /// permission prompts, npm/git/apt confirmations, and common CLI y/n.
    static let cues: [String] = [
        "(y/n)", "[y/n]", "(yes/no)", "[yes/no]", "y/n]", "y/n)",
        "(y/n/a)", "[y/n/a]", "[y/n/c]",
        "do you want", "do you trust", "would you like to proceed",
        "proceed?", "continue?", "overwrite?", "are you sure", "confirm?",
        "press enter to continue", "press return to continue", "press any key",
        "(use arrow keys)", "❯ 1.", "❯ 1)", "1. yes", "1) yes",
        "allow this", "approve this", "approve?", "accept edits", "[a]ccept",
        "esc to interrupt",      // claude's "thinking… (esc to interrupt)" is interactive-blocked
        "waiting for", "enter to send",
    ]

    /// True when the tail of `text` (ANSI already stripped) looks like a prompt
    /// awaiting user input.
    static func isWaitingPrompt(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // A prompt is the most-recent thing on screen; scan only the last few
        // non-empty lines so stale output earlier in the buffer can't match.
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let tail = lines.suffix(12).joined(separator: "\n").lowercased()
        for cue in cues where tail.contains(cue) { return true }
        // Arrow-select menu (claude/codex) with a numbered list is interactive.
        if tail.contains("❯") && (tail.contains("1.") || tail.contains("1)")) { return true }
        return false
    }

    /// Resolve the full activity state from the active flag + recent output.
    static func classify(isActivelyProducing: Bool, recentText: String) -> PaneActivity {
        if isActivelyProducing { return .working }
        return isWaitingPrompt(recentText) ? .waiting : .idle
    }
}
