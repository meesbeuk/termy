import Foundation
import UserNotifications
import AppKit

/// Thin wrapper around UNUserNotificationCenter. Fires when a terminal pane
/// emits a BEL (ASCII 7) in an unfocused Termy window — a common pattern in
/// shell setups where `precmd` rings the bell after long-running commands.
///
/// We don't request permission until the first time we'd post: Apple's HIG
/// says don't pop the permission dialog at launch with no context.
@MainActor
final class TermyNotifications {
    static let shared = TermyNotifications()
    private var permissionRequested = false

    /// Called from SwiftTerm's bell delegate. No-op when the target window is
    /// already focused (the user is looking right at it, no need to interrupt)
    /// or when the user has disabled the toggle in Settings.
    func bell(window: NSWindow?, cwd: String?) {
        guard UserDefaults.standard.bool(forKey: "termy.notifyOnBell") else { return }
        if window?.isKeyWindow == true && NSApp.isActive { return }

        ensurePermissionThenPost(
            title: "Termy",
            body: "Bell in \(cwd.map { (($0 as NSString).lastPathComponent) } ?? "terminal")"
        )
    }

    private func ensurePermissionThenPost(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !permissionRequested {
            permissionRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}
