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
            title: "Termy — bell",
            body: bodyLine(cwd: cwd, preview: preview),
            sound: soundEnabled()
        )
    }

    /// Idle hook — called by TermyTerminalView when output transitions
    /// from "active" to "settled for N seconds".
    func commandSettled(window: NSWindow?, cwd: String?, preview: String?) {
        guard UserDefaults.standard.bool(forKey: "termy.notifyOnIdle") else { return }
        if shouldSuppress(window: window) { return }
        post(
            title: "Termy — command finished",
            body: bodyLine(cwd: cwd, preview: preview),
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
                title: "Termy — \(title)",
                body: bodyLine(cwd: cwd, preview: matched),
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

    private func bodyLine(cwd: String?, preview: String?) -> String {
        let showPreview = UserDefaults.standard.object(forKey: "termy.notifyShowPreview") as? Bool ?? true
        let dirLabel = cwd.map { (($0 as NSString).lastPathComponent) } ?? "terminal"
        if showPreview, let preview, !preview.isEmpty {
            // Truncate preview to ~80 chars so it stays in one notification line.
            let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed
            return "\(dirLabel) — \(snippet)"
        }
        return dirLabel
    }

    private func post(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        if !permissionRequested {
            permissionRequested = true
            var options: UNAuthorizationOptions = [.alert]
            if sound { options.insert(.sound) }
            center.requestAuthorization(options: options) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}
