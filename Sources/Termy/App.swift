import SwiftUI
import AppKit

@main
struct TermyApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) var delegate
    @StateObject private var settings = TerminalSettings()

    /// Only the first window restores persisted tabs; further windows are blank.
    nonisolated(unsafe) static var didRestoreFirstWindow = false

    var body: some Scene {
        // Each WindowGroup window gets its own `TerminalSessions` so multi-window
        // works naturally — Cmd+N opens a separate independent terminal window
        // with its own tab list and shell processes.
        WindowGroup("Termy", id: "terminal") {
            TerminalWindowRoot()
                .environmentObject(settings)
        }
        .windowStyle(.hiddenTitleBar)
        // .automatic = window can be freely resized; SwiftTerm reflows its
        // grid (rows × cols) automatically as the NSView resizes.
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                // Tab actions are dispatched through the focused window's
                // TerminalSessions via the Notification.Name below.
                Button("New Tab") {
                    NotificationCenter.default.post(name: .terminalNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .terminalCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Terminal") {
                Button("Increase Font Size") { settings.bumpFontSize() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { settings.reduceFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { settings.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Next Tab") {
                    NotificationCenter.default.post(name: .terminalNextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .terminalPreviousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Split Horizontally") {
                    NotificationCenter.default.post(name: .terminalSplitHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("Split Vertically") {
                    NotificationCenter.default.post(name: .terminalSplitVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Focus Next Pane") {
                    NotificationCenter.default.post(name: .terminalFocusNextPane, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Focus Previous Pane") {
                    NotificationCenter.default.post(name: .terminalFocusPreviousPane, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                Divider()
                Button("Clear") {
                    NotificationCenter.default.post(name: .terminalClear, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Find") {
                    NotificationCenter.default.post(name: .terminalToggleFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let terminalNewTab = Notification.Name("mees.terminal.newTab")
    static let terminalCloseTab = Notification.Name("mees.terminal.closeTab")
    static let terminalNextTab = Notification.Name("mees.terminal.nextTab")
    static let terminalPreviousTab = Notification.Name("mees.terminal.previousTab")
    static let terminalClear = Notification.Name("mees.terminal.clear")
    static let terminalToggleFind = Notification.Name("mees.terminal.toggleFind")
    static let terminalSplitHorizontal = Notification.Name("mees.terminal.splitH")
    static let terminalSplitVertical = Notification.Name("mees.terminal.splitV")
    static let terminalFocusNextPane = Notification.Name("mees.terminal.focusNext")
    static let terminalFocusPreviousPane = Notification.Name("mees.terminal.focusPrev")
}

/// Per-window root. Owns its own TerminalSessions so multi-window works.
struct TerminalWindowRoot: View {
    @StateObject private var sessions = TerminalSessions()

    var body: some View {
        MainTerminalView()
            .environmentObject(sessions)
            .onAppear {
                if sessions.tabs.isEmpty {
                    // Restore last session's tabs in the first window only —
                    // additional windows (⌘N) open with a single blank tab.
                    if !TermyApp.didRestoreFirstWindow {
                        TermyApp.didRestoreFirstWindow = true
                        if !sessions.restorePersisted() {
                            sessions.openTab()
                        }
                    } else {
                        sessions.openTab()
                    }
                }
            }
    }
}

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
