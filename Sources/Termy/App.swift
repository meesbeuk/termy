import SwiftUI
import AppKit

@main
struct TermyApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) var delegate
    @StateObject private var settings = TerminalSettings()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var updater = Updater()

    /// Only the first window restores persisted tabs; further windows are blank.
    nonisolated(unsafe) static var didRestoreFirstWindow = false

    var body: some Scene {
        // Each WindowGroup window gets its own `TerminalSessions` so multi-window
        // works naturally — Cmd+N opens a separate independent terminal window
        // with its own tab list and shell processes.
        WindowGroup("Termy", id: "terminal") {
            TerminalWindowRoot()
                .environmentObject(settings)
                .environmentObject(profiles)
                .environmentObject(updater)
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
                Button("Duplicate Tab") {
                    NotificationCenter.default.post(name: .terminalDuplicateTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Recent Directories…") {
                    NotificationCenter.default.post(name: .terminalRecentDirs, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .option])
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            CommandMenu("Termy") {
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .terminalOpenPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
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
    static let terminalDuplicateTab = Notification.Name("mees.terminal.dupTab")
    static let terminalRecentDirs = Notification.Name("mees.terminal.recentDirs")
    static let terminalOpenPalette = Notification.Name("mees.terminal.palette")
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
        let hide = UserDefaults.standard.bool(forKey: "termy.hideFromDock")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let confirm = UserDefaults.standard.bool(forKey: "termy.confirmOnQuit")
        guard confirm else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Termy?"
        alert.informativeText = "Are you sure you want to quit Termy? All sessions will end."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
