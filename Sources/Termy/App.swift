import SwiftUI
import AppKit

@main
struct TermyApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) var delegate
    @StateObject private var settings = TerminalSettings()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var workflows = WorkflowStore()
    @StateObject private var updater = Updater()

    /// Only the first window restores persisted tabs; further windows are blank.
    nonisolated(unsafe) static var didRestoreFirstWindow = false

    var body: some Scene {
        // Each WindowGroup window gets its own `TerminalSessions` so multi-window
        // works naturally — Cmd+N opens a separate independent terminal window
        // with its own tab list and shell processes.
        WindowGroup("Termy", id: "terminal") {
            ZStack {
                TerminalWindowRoot()
                // Invisible bridge that hands the AppDelegate the closure it
                // needs to open new WindowGroup windows from the Dock menu.
                DockMenuBridge(delegate: delegate)
            }
            .environmentObject(settings)
            .environmentObject(profiles)
            .environmentObject(workflows)
            .environmentObject(updater)
        }
        .windowStyle(.hiddenTitleBar)
        // .automatic = window can be freely resized; SwiftTerm reflows its
        // grid (rows × cols) automatically as the NSView resizes.
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
                Button("New Tab") {
                    NotificationCenter.default.post(name: .terminalNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                // ⌘W = close the active pane; the tab closes when its last
                // pane goes. Labelled "Close" rather than "Close Tab" because
                // it doesn't always close the whole tab. ⌘⇧W closes the
                // whole window outright.
                Button("Close") {
                    NotificationCenter.default.post(name: .terminalCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
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
                QuickWindowButton()
            }
        }
    }
}

/// Opens a fresh small floating window — a "quick terminal" for one-off
/// commands without disturbing your main session. Keyboard shortcut ⌃` (a
/// common terminal-app convention; ⌘` conflicts with macOS window cycling).
struct QuickWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Quick Terminal") { openWindow(id: "terminal") }
            .keyboardShortcut("`", modifiers: .control)
    }
}

/// `NSDocumentController.newDocument` doesn't work for SwiftUI `WindowGroup`s.
/// The right hook is `@Environment(\.openWindow)`. Wrap in a small View so the
/// environment is available inside `.commands`.
struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Window") { openWindow(id: "terminal") }
            .keyboardShortcut("n", modifiers: .command)
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
    /// Fires when LaunchServices hands us files to open (Finder double-click
    /// on .sh, .command, +x binary). The key window's handler drains
    /// `TerminalAppDelegate.pendingOpenURLs` and opens a tab per file.
    static let terminalOpenFiles = Notification.Name("mees.terminal.openFiles")
}

/// Per-window root. Owns its own TerminalSessions so multi-window works.
struct TerminalWindowRoot: View {
    @StateObject private var sessions = TerminalSessions()
    @EnvironmentObject var profiles: ProfileStore

    var body: some View {
        MainTerminalView()
            .environmentObject(sessions)
            .onAppear {
                // Wire profile resolution into the session model so new tabs
                // honor the user's default profile (shell, env, tag color).
                sessions.profileStore = profiles
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
                // Drain any files LaunchServices queued before this window
                // existed (cold-launch from Finder). The running-app case is
                // handled by the .terminalOpenFiles notification observer.
                if !TerminalAppDelegate.pendingOpenURLs.isEmpty {
                    let urls = TerminalAppDelegate.pendingOpenURLs
                    TerminalAppDelegate.pendingOpenURLs.removeAll()
                    for url in urls { sessions.openFile(url) }
                }
            }
    }
}

final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired from the SwiftUI scene (via `DockMenuBridge`) so AppKit's Dock
    /// menu — which lives outside the SwiftUI environment — can still ask
    /// the scene to spawn a new window.
    var openNewWindow: (() -> Void)?
    /// Live snapshot of the user's profiles, supplied by the scene. Used to
    /// populate the "New Tab with Profile" submenu in the Dock menu.
    var profilesProvider: (() -> [Profile])?
    /// Profile ID requested by the Dock menu — consumed by the next openTab
    /// call in the active window.
    static var pendingDockProfileID: UUID?
    /// Files LaunchServices asked us to open, drained by either the first
    /// window's onAppear (cold-launch case) or the key window's
    /// `.terminalOpenFiles` handler (already-running case).
    static var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hide = UserDefaults.standard.bool(forKey: "termy.hideFromDock")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by LaunchServices when the user double-clicks a file whose UTI
    /// we claim in Info.plist (public.shell-script, public.unix-executable).
    /// We stash the URLs and let the SwiftUI scene drain them — the scene
    /// owns `TerminalSessions`, which is where new tabs actually get added.
    func application(_ application: NSApplication, open urls: [URL]) {
        TerminalAppDelegate.pendingOpenURLs.append(contentsOf: urls)
        NSApp.activate(ignoringOtherApps: true)
        // If a window is already up, the key window's handler picks it up
        // immediately. If we're cold-launching, the first scene's onAppear
        // will drain the queue after it finishes restoring tabs.
        if NSApp.windows.contains(where: { $0.isVisible }) {
            NotificationCenter.default.post(name: .terminalOpenFiles, object: nil)
        } else {
            openNewWindow?()
        }
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

    /// Right-click Termy in the Dock → this menu. macOS appends its own
    /// items (Show All Windows / Hide / Quit / open windows list) below.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let nw = NSMenuItem(title: "New Window", action: #selector(dockNewWindow), keyEquivalent: "")
        nw.target = self
        menu.addItem(nw)

        let nt = NSMenuItem(title: "New Tab", action: #selector(dockNewTab), keyEquivalent: "")
        nt.target = self
        menu.addItem(nt)

        let quick = NSMenuItem(title: "Quick Terminal", action: #selector(dockNewWindow), keyEquivalent: "")
        quick.target = self
        menu.addItem(quick)

        // Profile submenu — only meaningful when the user has > 1 profile,
        // otherwise the entries would all do the same thing as "New Tab".
        if let profs = profilesProvider?(), profs.count > 1 {
            menu.addItem(.separator())
            let sub = NSMenu()
            for p in profs {
                let item = NSMenuItem(title: p.name, action: #selector(dockNewTabWithProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.id.uuidString
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "New Tab with Profile", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        return menu
    }

    @objc private func dockNewWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openNewWindow?()
    }

    @objc private func dockNewTab() {
        NSApp.activate(ignoringOtherApps: true)
        // If there's no open window yet (app launched into accessory mode or
        // all closed), the notification has no handler — fall back to opening
        // a window, which auto-creates a fresh tab.
        if NSApp.windows.contains(where: { $0.isVisible }) {
            NotificationCenter.default.post(name: .terminalNewTab, object: nil)
        } else {
            openNewWindow?()
        }
    }

    @objc private func dockNewTabWithProfile(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        NSApp.activate(ignoringOtherApps: true)
        TerminalAppDelegate.pendingDockProfileID = id
        if NSApp.windows.contains(where: { $0.isVisible }) {
            NotificationCenter.default.post(name: .terminalNewTab, object: nil)
        } else {
            openNewWindow?()
        }
    }
}

/// Bridges AppKit's Dock menu callbacks back into the SwiftUI scene. Lives
/// invisibly inside `TermyApp` so it can capture `@Environment(\.openWindow)`,
/// which is the only sanctioned way to spawn a `WindowGroup` window.
struct DockMenuBridge: View {
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.openWindow) private var openWindow
    let delegate: TerminalAppDelegate

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                delegate.openNewWindow = { openWindow(id: "terminal") }
                delegate.profilesProvider = { profiles.profiles }
            }
    }
}
