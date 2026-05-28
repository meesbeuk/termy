import Foundation

/// Builds the `claude` command that relaunches a past session. Pure +
/// testable so the resume button can't silently build a broken command.
/// `--resume <id>` reopens a specific conversation; with no id we fall back
/// to `--continue` (most-recent). The session id is sanitised to the
/// characters Claude Code uses for ids (UUID-ish) so nothing odd from a
/// filename can sneak into the shell line.
enum ClaudeResume {
    static func sanitize(_ id: String) -> String {
        String(id.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
                .contains($0)
        })
    }

    static func command(sessionId: String?) -> String {
        if let raw = sessionId {
            let id = sanitize(raw)
            if !id.isEmpty { return "claude --resume \(id)" }
        }
        return "claude --continue"
    }
}
