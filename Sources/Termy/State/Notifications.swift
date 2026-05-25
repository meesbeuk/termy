import Foundation
import UserNotifications
import AppKit

/// Posts macOS user notifications when terminal panes hit interesting
/// transitions:
///
///   - **Bell** — pane emits ASCII 7 (the classic terminal beep). Pair
///     with `precmd() { print -n "\a" }` in zsh to get reliable
///     "command finished" pings.
///
///   - **Idle** — heuristic that fires when a pane was actively producing
///     output and then went quiet for the user-configured threshold. The
///     vibecoder use case: ask Claude / Codex a question, switch apps,
///     come back when the notification lands. No OSC 133 required.
///
/// Permission is requested lazily on first attempt — Apple's HIG says
/// don't pop the dialog at launch without user context. Subsequent
/// requests are no-ops because UNNotificationCenter caches the answer.
@MainActor
final class TermyNotifications {
    static let shared = TermyNotifications()
    private var permissionRequested = false

    /// Bell hook — called from SwiftTerm's `bell(source:)` override.
    func bell(window: NSWindow?, cwd: String?, preview: String? = nil) {
        guard UserDefaults.standard.bool(forKey: "termy.notifyOnBell") else { return }
        if shouldSuppress(window: window) { return }
        post(
            title: "Termy",
            subtitle: "Bell",
            body: composedBody(cwd: cwd, preview: preview),
            sound: soundEnabled()
        )
    }

    /// Idle hook — called by TermyTerminalView when output transitions
    /// from "active" to "settled for N seconds".
    func commandSettled(window: NSWindow?, cwd: String?, preview: String?) {
        guard UserDefaults.standard.bool(forKey: "termy.notifyOnIdle") else { return }
        if shouldSuppress(window: window) { return }
        post(
            title: "Termy",
            subtitle: "Command finished",
            body: composedBody(cwd: cwd, preview: preview),
            sound: soundEnabled()
        )
    }

    /// Trigger hook — called by TermyTerminalView when an active trigger's
    /// regex matched a completed line in the pane's output. We honour the
    /// same focus-scope toggle as bell + idle, and use the trigger's
    /// `urgent` flag to bump priority (sound on, even if global sound is
    /// off — urgent triggers deserve to be heard).
    func triggerFired(trigger: Trigger, matched: String, window: NSWindow?, cwd: String?) {
        if shouldSuppress(window: window) { return }
        if case let .notify(title, urgent) = trigger.action {
            post(
                title: "Termy",
                subtitle: title,
                body: composedBody(cwd: cwd, preview: matched),
                sound: urgent || soundEnabled()
            )
        }
    }

    private func shouldSuppress(window: NSWindow?) -> Bool {
        // Honour the "only when window unfocused" toggle. If the user
        // explicitly opted in to all-pane notifications, fire every time.
        let onlyBackground = UserDefaults.standard.object(forKey: "termy.notifyOnlyBackground") as? Bool ?? true
        guard onlyBackground else { return false }
        return window?.isKeyWindow == true && NSApp.isActive
    }

    private func soundEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "termy.notifySound")
    }

    /// Composes the body line shown beneath title + subtitle. Layout:
    ///   - `<preview>` if the preview is real, useful output (not a
    ///     redrawn prompt) — most informative.
    ///   - Otherwise `in <dir> · <time>` — short, predictable.
    /// macOS truncates the body to ~3 short lines in Notification
    /// Center. Keeping the body terse means it never gets cut off
    /// awkwardly mid-prompt like the previous design did.
    private func composedBody(cwd: String?, preview: String?) -> String {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let dirLabel = cwd.map { foldHome($0) } ?? ""
        let showPreview = UserDefaults.standard.object(forKey: "termy.notifyShowPreview") as? Bool ?? true
        if showPreview,
           let preview,
           let usable = usablePreview(preview, cwd: cwd) {
            // Body = preview + a faint locator. macOS auto-wraps so we
            // can include both without truncating the interesting part.
            if dirLabel.isEmpty {
                return "\(usable) · \(stamp)"
            }
            return "\(usable)\n\(dirLabel) · \(stamp)"
        }
        if dirLabel.isEmpty { return stamp }
        return "in \(dirLabel) · \(stamp)"
    }

    /// Returns a cleaned preview string only if it's actually informative.
    /// Filters out:
    ///   - empty / whitespace-only previews
    ///   - prompt-shaped lines (`user@host ~ %`, `$ `, `❯ ` etc.) — they
    ///     leak when the shell redraws the next prompt after a command
    ///     settles, and they tell the user nothing they don't know
    ///   - duplicates of the cwd label (would be redundant with the
    ///     locator line)
    /// Returns nil to mean "skip the preview", letting the caller fall
    /// back to the short location-only body.
    private func usablePreview(_ raw: String, cwd: String?) -> String? {
        let clean = sanitizeForNotification(raw)
        guard !clean.isEmpty else { return nil }
        if isPromptLine(clean) { return nil }
        if let cwd, clean == foldHome(cwd) || clean == (cwd as NSString).lastPathComponent {
            return nil
        }
        return truncate(clean, to: 100)
    }

    /// Heuristic: does this look like a shell prompt rather than command
    /// output? Common patterns covered:
    ///   - `user@host` + path + sigil ending in `% ` / `$ ` / `# ` / `❯`
    ///   - a bare sigil at the end of an otherwise short line
    ///   - lines that consist mostly of the user@host prefix
    private func isPromptLine(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let sigils: [Character] = ["%", "$", "#", "❯", "›", "»"]
        if let last = trimmed.last, sigils.contains(last), trimmed.count < 200 {
            // Endings like `% ` after a path. Confirm it has the
            // user@host shape or a path prefix to avoid false-positiving
            // on something like `5 + 3 = $`.
            if trimmed.contains("@") || trimmed.contains("/") || trimmed.count < 8 {
                return true
            }
        }
        // user@host alone (no command typed after) is also a prompt
        // redraw fragment.
        let promptRegex = #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+\s*[:~][^A-Za-z]*$"#
        if trimmed.range(of: promptRegex, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Strip CSI / OSC / DCS escape sequences plus the raw ESC / BEL / CR
    /// control characters that survive them. Without this, Claude / TUIs
    /// leak `[?2026h`, `[2D[3B`, etc. into the body of the notification.
    private func sanitizeForNotification(_ input: String) -> String {
        var s = input
        // Drop OSC (ESC ] ... BEL or ESC \) — handles titles, hyperlinks, etc.
        s = s.replacingOccurrences(
            of: "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)",
            with: "",
            options: .regularExpression
        )
        // Drop CSI: ESC [ params final-byte
        s = s.replacingOccurrences(
            of: "\\x1B\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        // Drop standalone ESC sequences (charset selects, cursor save, etc.)
        s = s.replacingOccurrences(
            of: "\\x1B[@-Z\\\\-_]",
            with: "",
            options: .regularExpression
        )
        // Strip remaining control chars except tab. Collapse whitespace runs.
        let scalars = s.unicodeScalars.filter { scalar in
            if scalar.value == 9 { return true }   // keep TAB → becomes space below
            return !((scalar.value < 0x20) || scalar.value == 0x7F)
        }
        var out = String(String.UnicodeScalarView(scalars))
        out = out.replacingOccurrences(of: "\t", with: " ")
        // Collapse repeated whitespace into one space.
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ s: String, to maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        return String(s.prefix(maxChars - 1)) + "…"
    }

    private func foldHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func post(title: String, subtitle: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        if !permissionRequested {
            permissionRequested = true
            var options: UNAuthorizationOptions = [.alert]
            if sound { options.insert(.sound) }
            center.requestAuthorization(options: options) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        if sound { content.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}
