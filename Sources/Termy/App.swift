import SwiftUI
import AppKit
import CoreImage

@main
struct TermyApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) var delegate
    @StateObject private var settings = TerminalSettings()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var workflows = WorkflowStore()
    @StateObject private var pasteHistory = PasteHistoryStore()
    @StateObject private var updater = Updater()
    @StateObject private var layouts = LayoutStore()

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
            .environmentObject(pasteHistory)
            .environmentObject(updater)
            .environmentObject(layouts)
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
                // ⌘1…⌘8 jump to tab N; ⌘9 jumps to the last tab regardless
                // of count (standard browser convention; muscle memory for
                // anyone coming from iTerm2 / Chrome / Safari / Firefox).
                ForEach(1...8, id: \.self) { n in
                    Button("Tab \(n)") {
                        NotificationCenter.default.post(name: .terminalSelectTab, object: n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Button("Last Tab") {
                    NotificationCenter.default.post(name: .terminalSelectTab, object: Int.max)
                }
                .keyboardShortcut("9", modifiers: .command)
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
                Button("New Layout: \(layouts.quickLayout.name)") {
                    NotificationCenter.default.post(name: .terminalSpawnQuickLayout, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Menu("New Layout") {
                    ForEach(layouts.all) { layout in
                        Button("\(layout.name)  ·  \(layout.shapeLabel)") {
                            NotificationCenter.default.post(name: .terminalSpawnLayout,
                                                            object: layout.id.uuidString)
                        }
                    }
                    Divider()
                    Button("Layout Picker…") {
                        NotificationCenter.default.post(name: .terminalOpenLayoutPicker, object: nil)
                    }
                }
                Button("Agent Dashboard…") {
                    NotificationCenter.default.post(name: .terminalOpenAgentDashboard, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Zoom / Restore Pane") {
                    NotificationCenter.default.post(name: .terminalZoomPane, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Send Text to Pane…") {
                    NotificationCenter.default.post(name: .terminalSendToPane, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Show Image…") {
                    NotificationCenter.default.post(name: .terminalShowImage, object: nil)
                }
                Button("Command Blocks…") {
                    NotificationCenter.default.post(name: .terminalToggleCommandBlocks, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Duplicate Tab") {
                    NotificationCenter.default.post(name: .terminalDuplicateTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Reopen Closed Tab") {
                    NotificationCenter.default.post(name: .terminalReopenClosed, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
                Button("Jump to Previous Prompt") {
                    NotificationCenter.default.post(name: .terminalJumpPrevPrompt, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Jump to Next Prompt") {
                    NotificationCenter.default.post(name: .terminalJumpNextPrompt, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Use Selection for Find") {
                    NotificationCenter.default.post(name: .terminalFindSelection, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Scroll to Top") {
                    NotificationCenter.default.post(name: .terminalScrollToTop, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Scroll to Bottom") {
                    NotificationCenter.default.post(name: .terminalScrollToBottom, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                Button("Copy Scrollback") {
                    NotificationCenter.default.post(name: .terminalCopyScrollback, object: nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .terminalOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Termy Help on GitHub") {
                    if let url = URL(string: "https://github.com/meesbeuk/termy#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Keyboard Cheatsheet…") {
                    NotificationCenter.default.post(name: .terminalOpenCheatsheet, object: nil)
                }
                Button("Welcome to Termy…") {
                    // Re-show the first-launch welcome whenever the user
                    // asks for it. Doesn't un-flip `OnboardingState.isCompleted`
                    // — we just route the same notification that auto-fires
                    // on a real first launch.
                    NotificationCenter.default.post(name: .terminalShowOnboarding, object: nil)
                }
                Divider()
                Button("Run Diagnostics…") {
                    NotificationCenter.default.post(name: .terminalOpenDiagnostics, object: nil)
                }
                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/meesbeuk/termy/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Release Notes") {
                    if let url = URL(string: "https://github.com/meesbeuk/termy/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandMenu("Termy") {
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .terminalOpenPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Keyboard Cheatsheet…") {
                    NotificationCenter.default.post(name: .terminalOpenCheatsheet, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
                Button("Session Logs…") {
                    NotificationCenter.default.post(name: .terminalOpenSessionLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Paste from History…") {
                    NotificationCenter.default.post(name: .terminalOpenPasteHistory, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Agent Sessions…") {
                    NotificationCenter.default.post(name: .terminalOpenAgentPanel, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Claude Usage…") {
                    NotificationCenter.default.post(name: .terminalOpenClaudeUsage, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                Button("Quick Select…") {
                    NotificationCenter.default.post(name: .terminalOpenQuickSelect, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
                QuickTerminalToggleButton(settings: settings, profiles: profiles)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Always on Top") {
                    NotificationCenter.default.post(name: .terminalToggleAlwaysOnTop, object: nil)
                }
            }
        }
    }
}

/// Toggles the Quake-style drop-down terminal. ⌃` (⌘` collides with macOS
/// window cycling). The panel is a persistent NSPanel — see
/// `QuickTerminalController`. Replaces the v0.9.6 behavior of opening a
/// regular second WindowGroup window with the same id, which was indistinguishable
/// from ⌘N.
struct QuickTerminalToggleButton: View {
    @ObservedObject var settings: TerminalSettings
    @ObservedObject var profiles: ProfileStore
    var body: some View {
        Button("Quick Terminal") {
            QuickTerminalController.shared.toggle(settings: settings, profiles: profiles)
        }
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
    static let terminalSelectTab = Notification.Name("mees.terminal.selectTab")
    static let terminalToggleAlwaysOnTop = Notification.Name("mees.terminal.toggleAlwaysOnTop")
    static let terminalOpenCheatsheet = Notification.Name("mees.terminal.openCheatsheet")
    static let terminalOpenSettings = Notification.Name("mees.terminal.openSettings")
    static let terminalOpenSessionLogs = Notification.Name("mees.terminal.openSessionLogs")
    static let terminalFindSelection = Notification.Name("mees.terminal.findSelection")
    static let terminalOpenPasteHistory = Notification.Name("mees.terminal.openPasteHistory")
    static let terminalJumpPrevPrompt = Notification.Name("mees.terminal.jumpPrevPrompt")
    static let terminalJumpNextPrompt = Notification.Name("mees.terminal.jumpNextPrompt")
    static let terminalOpenAgentPanel = Notification.Name("mees.terminal.openAgentPanel")
    static let terminalOpenQuickSelect = Notification.Name("mees.terminal.openQuickSelect")
    static let terminalClear = Notification.Name("mees.terminal.clear")
    static let terminalToggleFind = Notification.Name("mees.terminal.toggleFind")
    static let terminalSplitHorizontal = Notification.Name("mees.terminal.splitH")
    static let terminalSplitVertical = Notification.Name("mees.terminal.splitV")
    static let terminalFocusNextPane = Notification.Name("mees.terminal.focusNext")
    static let terminalFocusPreviousPane = Notification.Name("mees.terminal.focusPrev")
    static let terminalDuplicateTab = Notification.Name("mees.terminal.dupTab")
    static let terminalReopenClosed = Notification.Name("mees.terminal.reopenClosed")
    static let terminalOpenDiagnostics = Notification.Name("mees.terminal.openDiagnostics")
    static let terminalCopyScrollback = Notification.Name("mees.terminal.copyScrollback")
    static let terminalScrollToTop = Notification.Name("mees.terminal.scrollToTop")
    static let terminalScrollToBottom = Notification.Name("mees.terminal.scrollToBottom")
    static let terminalCopyLastOutput = Notification.Name("mees.terminal.copyLastOutput")
    // Agents & layouts (v0.15)
    static let terminalSpawnQuickLayout = Notification.Name("mees.terminal.spawnQuickLayout")
    static let terminalSpawnLayout = Notification.Name("mees.terminal.spawnLayout")
    static let terminalOpenLayoutPicker = Notification.Name("mees.terminal.openLayoutPicker")
    static let terminalOpenAgentDashboard = Notification.Name("mees.terminal.openAgentDashboard")
    static let terminalZoomPane = Notification.Name("mees.terminal.zoomPane")
    static let terminalSendToPane = Notification.Name("mees.terminal.sendToPane")
    static let terminalToggleCommandBlocks = Notification.Name("mees.terminal.toggleCommandBlocks")
    static let terminalShowImage = Notification.Name("mees.terminal.showImage")
    static let terminalOpenClaudeUsage = Notification.Name("mees.terminal.openClaudeUsage")
    /// Posted when LaunchServices hands us one or more `termy://` URLs (or
    /// when an in-app menu like the command palette wants to simulate one
    /// for testing). Key window drains `TerminalAppDelegate.pendingTermyURLs`.
    static let terminalOpenTermyURL = Notification.Name("mees.terminal.openTermyURL")
    /// Help → "Welcome to Termy…" — manually re-shows the onboarding sheet.
    static let terminalShowOnboarding = Notification.Name("mees.terminal.showOnboarding")
    /// Used by `--snapshot-pane=<name>` to drive the Settings sheet's
    /// pane selection from the CLI. The sheet's SwiftUI view observes this
    /// and updates `selectedCategory`. Object is the raw value string.
    static let terminalSettingsSelectPane = Notification.Name("mees.terminal.settings.selectPane")
    /// Fired when the active pane changes via split / focus cycling /
    /// pane closure. MainTerminalView observes this to claim keyboard
    /// focus for the new active pane. .onChange on the published
    /// activePaneId of the current tab doesn't fire reliably because
    /// SwiftUI only tracks `sessions`-level publishes, not changes on
    /// sub-objects accessed through it.
    static let terminalActivePaneChanged = Notification.Name("mees.terminal.activePaneChanged")
    static let terminalRecentDirs = Notification.Name("mees.terminal.recentDirs")
    static let terminalOpenPalette = Notification.Name("mees.terminal.palette")
    /// Fires when LaunchServices hands us files to open (Finder double-click
    /// on .sh, .command, +x binary). The key window's handler drains
    /// `TerminalAppDelegate.pendingOpenURLs` and opens a tab per file.
    static let terminalOpenFiles = Notification.Name("mees.terminal.openFiles")
}

/// Per-window root. Owns its own TerminalSessions so multi-window works.
/// Each window claims its own restoreKey — either popped off the
/// `pendingRestoreKeys` queue (one slot per previously-saved window on a
/// cold launch) or generated fresh (a brand-new window created by ⌘N
/// after the queue is drained).
struct TerminalWindowRoot: View {
    @StateObject private var sessions: TerminalSessions = {
        // First window pops the most-recently-active key off the queue so
        // it restores the layout the user was last looking at. Subsequent
        // restored windows pop the rest in order; fresh ⌘N windows get a
        // new UUID and won't collide.
        if !TerminalSessions.pendingRestoreKeys.isEmpty {
            let key = TerminalSessions.pendingRestoreKeys.removeFirst()
            return TerminalSessions(restoreKey: key)
        }
        return TerminalSessions()
    }()
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainTerminalView()
            .environmentObject(sessions)
            .onDisappear {
                // The user closed this window explicitly (⌘⇧W or X). Forget
                // its restoreKey so we don't reopen a window for it on next
                // launch. App-quit paths set isTerminating first so this
                // skips and every window's key is preserved.
                if !TerminalAppDelegate.isTerminating {
                    sessions.unregisterWindow()
                }
            }
            .onAppear {
                // Wire profile resolution into the session model so new tabs
                // honor the user's default profile (shell, env, tag color).
                sessions.profileStore = profiles
                if sessions.tabs.isEmpty {
                    if !TermyApp.didRestoreFirstWindow {
                        TermyApp.didRestoreFirstWindow = true
                        restoreOrSeed()
                        // Spawn one additional window per remaining saved
                        // key so every previously-open window comes back on
                        // launch. Each spawn pops the next key in the queue
                        // via the @StateObject initializer above.
                        for _ in TerminalSessions.pendingRestoreKeys {
                            openWindow(id: "terminal")
                        }
                    } else {
                        restoreOrSeed()
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
                // Same for any pending termy:// URLs handed in during cold
                // launch — drain them into TermyURLDispatcher.
                if !TerminalAppDelegate.pendingTermyURLs.isEmpty {
                    let urls = TerminalAppDelegate.pendingTermyURLs
                    TerminalAppDelegate.pendingTermyURLs.removeAll()
                    for url in urls { TermyURLDispatcher.handle(url, in: sessions) }
                }
            }
    }

    private func restoreOrSeed() {
        switch sessions.restorePersisted() {
        case .restored:
            break
        case .noSavedState:
            sessions.openTab()
        case .staleSaved:
            // Saved layout exists but its cwds aren't reachable right now
            // (likely an unmounted external drive). Open a default tab
            // without persisting so the saved layout comes back next launch.
            sessions.openTab(persistChange: false)
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
    /// `termy://` URLs queued by LaunchServices — drained the same way as
    /// pendingOpenURLs but routed through the key window's
    /// `.terminalOpenTermyURL` handler instead, since their semantics are
    /// different (open a tab in a path, run a command, etc.).
    static var pendingTermyURLs: [URL] = []
    /// Set when the app is shutting down so window .onDisappear handlers
    /// don't unregister their restoreKey — we want them preserved so each
    /// window comes back on the next launch.
    static var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot=/path/to/file.png` — Termy renders itself for ~3s, captures
        // the active pane to PNG, then quits. Lets QA / CI / claude verify
        // text rendering without needing Screen-Recording permission for the
        // calling process — the app is capturing its own NSView, not the
        // screen. Optional `--snapshot-text=...` writes a payload into the
        // pane first so the snapshot has something interesting to show.
        if let path = Self.cliArg("--snapshot=") {
            Self.scheduleSnapshot(toPath: path, payload: Self.cliArg("--snapshot-text="))
        }
        let hide = UserDefaults.standard.bool(forKey: "termy.hideFromDock")
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        // When running as Termy Dev (the staging bundle from stage.sh),
        // invert the dock icon so it's visually distinct from prod —
        // same artwork, photo-negative palette. Keeps the source tree
        // single-icon while making the dock + ⌘-Tab cycle unambiguous.
        if Bundle.main.bundleIdentifier == "com.mees.termy.dev",
           let icon = NSApp.applicationIconImage {
            NSApp.applicationIconImage = Self.invertedIcon(icon)
        }
        // One-shot local mouse-down monitor: every click in the app
        // posts a focus-changed notification so each TermyTerminalView
        // re-evaluates its inactive-caret overlay. Catches the case
        // where clicking directly on a sibling pane's text area
        // changes first responder via AppKit (not SwiftUI's tap
        // gesture, which is where we'd otherwise post the notification).
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: TermyTerminalView.focusChangedNotification,
                    object: nil
                )
            }
            return event
        }
        // Load every saved window key so each can spawn its own window in
        // launch order. The first window pops the head; the per-window
        // root opens additional windows for the tail. Limited to 8 to
        // bound runaway accumulation. Also garbage-collect orphan keys
        // beyond the cap so their UserDefaults entries don't leak forever.
        let saved = UserDefaults.standard.stringArray(forKey: TerminalSessions.windowKeysKey) ?? []
        // Skip keys with no saved tab payload — e.g. a leaked Quick Terminal key
        // (older builds registered it but it never persisted tabs). Without this
        // a payload-less key reopens a blank phantom window on every launch.
        // The payload is written under the key itself (persist() -> forKey:
        // restoreKey), so object(forKey:) == nil means "nothing to restore".
        let withPayload = saved.filter { UserDefaults.standard.object(forKey: $0) != nil }
        let kept = Array(withPayload.prefix(8))
        if kept != saved {
            UserDefaults.standard.set(kept, forKey: TerminalSessions.windowKeysKey)
            for orphan in saved where !kept.contains(orphan) {
                UserDefaults.standard.removeObject(forKey: orphan)
            }
        }
        TerminalSessions.pendingRestoreKeys = kept
        // Upgrade-safety: if any persisted state exists (per-window keys,
        // the legacy single-key restore payload, or even a custom theme /
        // font size the user set), they're not a first-launch user. Mark
        // onboarding as completed so the welcome sheet never appears
        // mid-upgrade. Fresh installs see none of these → we leave the
        // onboarding flag unset and MainTerminalView pops the sheet.
        let defaults = UserDefaults.standard
        let legacyEvidence = !saved.isEmpty
            || defaults.array(forKey: "mees.terminal.restoreTabs.v2") != nil
            || defaults.string(forKey: "termy.themeID") != nil
            || defaults.double(forKey: "termy.fontSize") > 0
            || defaults.data(forKey: "termy.profiles.v1") != nil
        if legacyEvidence && !OnboardingState.isCompleted {
            OnboardingState.markCompleted()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by LaunchServices when the user double-clicks a file whose UTI
    /// we claim in Info.plist (public.shell-script, public.unix-executable),
    /// OR clicks a `termy://` URL anywhere on the system. File URLs land in
    /// the same queue the SwiftUI scene drains; termy:// URLs are routed
    /// through `handleTermyURL` so they can dispatch into the current
    /// session model (cwd new tab, send command, etc.).
    func application(_ application: NSApplication, open urls: [URL]) {
        var fileURLs: [URL] = []
        var termyURLs: [URL] = []
        for url in urls {
            if url.scheme?.lowercased() == "termy" {
                termyURLs.append(url)
            } else {
                fileURLs.append(url)
            }
        }
        if !fileURLs.isEmpty {
            TerminalAppDelegate.pendingOpenURLs.append(contentsOf: fileURLs)
        }
        if !termyURLs.isEmpty {
            TerminalAppDelegate.pendingTermyURLs.append(contentsOf: termyURLs)
        }
        NSApp.activate(ignoringOtherApps: true)
        // If a window is already up, the key window's handler picks it up
        // immediately. If we're cold-launching, the first scene's onAppear
        // will drain the queue after it finishes restoring tabs.
        if NSApp.windows.contains(where: { $0.isVisible }) {
            // `NSApp.activate` is asynchronous — when the user just clicked
            // a `termy://` URL from another app, the receiving window
            // doesn't become key for ~100ms. Firing notifications synchronously
            // here means the `isKeyWindow()` guard in TerminalHandlers
            // silently drops them. A short asyncAfter lets activation
            // settle before we post.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !fileURLs.isEmpty {
                    NotificationCenter.default.post(name: .terminalOpenFiles, object: nil)
                }
                if !termyURLs.isEmpty {
                    NotificationCenter.default.post(name: .terminalOpenTermyURL, object: nil)
                }
            }
        } else {
            openNewWindow?()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let confirm = UserDefaults.standard.bool(forKey: "termy.confirmOnQuit")
        guard confirm else {
            Self.isTerminating = true
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit Termy?"
        alert.informativeText = "Are you sure you want to quit Termy? All sessions will end."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed { Self.isTerminating = true }
        return confirmed ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-braces — some quit paths skip applicationShouldTerminate
        // (e.g. system shutdown / log out).
        Self.isTerminating = true
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

    // MARK: - --snapshot CLI support
    //
    // Lets Termy capture its own rendered output to disk so the typography
    // changes can be verified without Screen-Recording permission for the
    // invoking process. Termy snapshots its own NSWindow's contentView via
    // `bitmapImageRepForCachingDisplay` (no external capture API needed),
    // then exits.

    static func cliArg(_ prefix: String) -> String? {
        for arg in CommandLine.arguments where arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    static func scheduleSnapshot(toPath path: String, payload: String?) {
        // 2.0s window: enough for the shell to print its prompt, optional
        // payload to type-and-render, and the activity bar / caret to
        // settle. Keep it generous — first-launch initialization is slower
        // than steady state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // `--snapshot-pane=appearance|behavior|profiles|quake|advanced`
            // opens the Settings sheet and switches to that pane before
            // capture. Lets QA grab one pane at a time without manual
            // clicking.
            if let pane = cliArg("--snapshot-pane=") {
                NotificationCenter.default.post(name: .terminalOpenSettings, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    setSettingsPane(pane)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Self.captureAndExit(path: path)
                    }
                }
                return
            }
            if let payload, let window = NSApp.windows.first(where: { $0.isVisible }) {
                if let view = window.contentView,
                   let term = Self.findTermyTerminalView(view) {
                    term.send(txt: payload)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.captureAndExit(path: path)
            }
        }
    }

    /// Posts the pane-selection notification — TerminalSettingsSheet
    /// observes this and updates `selectedCategory` directly. Used by
    /// `--snapshot-pane=<name>` from the CLI snapshot path. Accepts an
    /// optional `:filter` suffix (e.g. `appearance:cursor`) to also
    /// set the search query for cropping a single section.
    static func setSettingsPane(_ name: String) {
        let parts = name.split(separator: ":", maxSplits: 1)
        let pane = String(parts[0]).lowercased()
        let filter = parts.count > 1 ? String(parts[1]) : ""
        NotificationCenter.default.post(
            name: .terminalSettingsSelectPane,
            object: ["pane": pane, "filter": filter] as [String: String]
        )
    }

    static func captureAndExit(path: String) {
        // Prefer the newest visible window (typically the sheet) over the
        // main window so settings/sheet panes capture correctly. Fall back
        // to first visible if none of the newer ones qualify.
        let candidates = NSApp.windows.reversed().filter { $0.isVisible }
        guard let window = candidates.first,
              let view = window.contentView else {
            fputs("snapshot: no visible window\n", stderr)
            exit(2)
        }
        // Force-flush any pending draw before capture so the bitmap
        // reflects post-layout text.
        view.displayIfNeeded()
        let bounds = view.bounds

        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            fputs("snapshot: bitmapImageRepForCachingDisplay returned nil\n", stderr)
            exit(2)
        }
        view.cacheDisplay(in: bounds, to: rep)
        // Note: SwiftTerm's CaretView renders via CALayer-delegate
        // `draw(_:in:)` with an empty AppKit `draw(_:)`, so the cursor
        // glyph won't appear in this bitmap. That's a snapshot
        // limitation — the live app paints the cursor fine. To verify
        // cursor settings, run Termy Dev interactively.
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot: PNG encode failed\n", stderr)
            exit(2)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            fputs("snapshot: wrote \(data.count) bytes to \(path)\n", stderr)
        } catch {
            fputs("snapshot: write failed: \(error)\n", stderr)
            exit(2)
        }
        exit(0)
    }

    /// Recursively walks the view tree looking for SwiftTerm's
    /// `LocalProcessTerminalView` (or our subclass). Returns the first one
    /// found — fine because the snapshot path only fires when one window
    /// is up. Returns nil before the SwiftUI scene has finished mounting.
    static func findTermyTerminalView(_ root: NSView) -> TermyTerminalView? {
        if let t = root as? TermyTerminalView { return t }
        for sub in root.subviews {
            if let t = findTermyTerminalView(sub) { return t }
        }
        return nil
    }

    /// Returns a color-inverted copy of an NSImage, used to brand the
    /// staging dock icon. Implemented via CIFilter.colorInvert across
    /// every representation so all icon sizes (16/32/128/256/512/1024)
    /// stay crisp at retina scale; falls back to the original on any
    /// filter failure. Preserves alpha (no halo on the transparent
    /// rounded-rect corners that AppKit uses for dock icons).
    static func invertedIcon(_ image: NSImage) -> NSImage {
        let size = image.size
        let inverted = NSImage(size: size)
        inverted.lockFocus()
        defer { inverted.unlockFocus() }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorInvert") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return image }
        let ctx = CIContext()
        guard let invertedCG = ctx.createCGImage(output, from: output.extent) else { return image }
        let rep = NSBitmapImageRep(cgImage: invertedCG)
        rep.size = size
        NSGraphicsContext.current?.cgContext.draw(invertedCG, in: NSRect(origin: .zero, size: size))
        return inverted
    }
}

/// Decodes Termy's `termy://` URL scheme and dispatches actions against
/// the supplied `TerminalSessions`. Recognised verbs:
///
///   - `termy://open?cwd=/path`            — open a fresh tab in that cwd
///   - `termy://run?command=ls&cwd=/path`  — open tab in cwd, run command
///   - `termy://new`                        — open a default tab
///   - `termy://palette`                    — open the command palette
///   - `termy://settings`                   — open Settings
///
/// Unknown verbs are ignored silently rather than throwing — a URL
/// payload coming from outside the app shouldn't be able to crash Termy.
@MainActor
enum TermyURLDispatcher {
    static func handle(_ url: URL, in sessions: TerminalSessions) {
        guard url.scheme?.lowercased() == "termy" else { return }
        // `host` carries the verb (`open`, `run`, ...); `path` is unused.
        let verb = (url.host ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func param(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        switch verb {
        case "new", "":
            sessions.openTab()
        case "open":
            if let cwd = param("cwd"), !cwd.isEmpty,
               FileManager.default.fileExists(atPath: cwd) {
                sessions.openTabIn(cwd: cwd)
            } else {
                sessions.openTab()
            }
        case "run":
            // Need a command to be useful — fall back to plain new tab
            // when the URL forgot the param.
            guard let cmd = param("command"), !cmd.isEmpty else {
                sessions.openTab()
                return
            }
            if let cwd = param("cwd"), !cwd.isEmpty,
               FileManager.default.fileExists(atPath: cwd) {
                sessions.openTabIn(cwd: cwd)
            } else {
                sessions.openTab()
            }
            // The PTY needs a beat to print its prompt before we type into
            // it — same 400 ms delay used by `pendingInitialCommand`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sessions.sendToActivePane(cmd)
            }
        case "palette":
            NotificationCenter.default.post(name: .terminalOpenPalette, object: nil)
        case "settings":
            NotificationCenter.default.post(name: .terminalOpenSettings, object: nil)
        case "welcome", "onboarding":
            // Re-show the first-launch welcome sheet on demand, same path
            // as Help → "Welcome to Termy…". Useful for scripted tours
            // and for testing the sheet without resetting state.
            NotificationCenter.default.post(name: .terminalShowOnboarding, object: nil)
        case "diagnostics":
            NotificationCenter.default.post(name: .terminalOpenDiagnostics, object: nil)
        case "cheatsheet":
            NotificationCenter.default.post(name: .terminalOpenCheatsheet, object: nil)
        default:
            break
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
