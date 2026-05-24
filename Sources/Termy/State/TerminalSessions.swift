import Foundation
import SwiftUI
import Combine
import SwiftTerm

/// One terminal pane — a local shell process + display state.
/// Owns the LocalProcessTerminalView so its lifecycle survives SwiftUI re-renders.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "zsh"
    @Published var cwd: String

    /// The actual SwiftTerm view. Created lazily once the SwiftUI representable
    /// is mounted so we don't fork a shell we never display.
    var terminalView: LocalProcessTerminalView?

    /// Shell + args to launch. Honor $SHELL, fall back to /bin/zsh.
    let shellPath: String
    let shellArgs: [String]
    /// Working directory the shell should start in.
    let initialCwd: String

    /// Extra env vars to inject on top of the inherited environment.
    private let envExtras: [String: String]
    /// Profile this session was opened with — nil = ambient defaults.
    let profileID: UUID?

    /// Optional command typed into the shell right after it boots — used when
    /// the session was created to run a file the OS asked us to open (.sh,
    /// .command, +x binary). Cleared after the first send.
    var pendingInitialCommand: String?

    init(initialCwd: String = NSHomeDirectory(), profile: Profile? = nil) {
        if let profile {
            self.shellPath = profile.effectiveShellPath
            self.shellArgs = profile.shellArgs.isEmpty ? ["--login"] : profile.shellArgs
            let resolved = initialCwd.isEmpty || initialCwd == NSHomeDirectory() ? profile.effectiveCwd : initialCwd
            self.initialCwd = resolved
            self.cwd = resolved
            self.envExtras = profile.environmentExtras
            self.profileID = profile.id
        } else {
            if let envShell = ProcessInfo.processInfo.environment["SHELL"], !envShell.isEmpty {
                self.shellPath = envShell
            } else {
                self.shellPath = "/bin/zsh"
            }
            self.shellArgs = ["--login"]
            self.initialCwd = initialCwd
            self.cwd = initialCwd
            self.envExtras = [:]
            self.profileID = nil
        }
    }

    var processEnvironment: [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        // Advertise as iTerm.app so tools like imgcat / viu / yazi / chafa
        // — which hardcode TERM_PROGRAM=iTerm.app as their OSC 1337
        // detection check — actually render images instead of silently
        // falling back to ASCII art. SwiftTerm renders OSC 1337, Sixel,
        // AND Kitty natively, so the impersonation is technically honest
        // about image-protocol support. This is the same approach
        // WezTerm and Ghostty take for the same compatibility reason.
        //
        // The dedicated `TERMY` env var lets shell config detect that
        // they're actually inside Termy (for prompt customisation, OSC
        // 133 hookup, etc.) without confusing the image-tool ecosystem.
        env["TERM_PROGRAM"] = "iTerm.app"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        env["TERM_PROGRAM_VERSION"] = version
        env["TERMY"] = version
        env["LC_TERMINAL"] = "iTerm2"
        env["LC_TERMINAL_VERSION"] = version
        env["TERM_FEATURES"] = "title,sixel,kitty,iterm2"
        for (k, v) in envExtras { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// Top-level model: list of open tabs + which one is selected.
/// Each tab contains 1..N panes (splits).
@MainActor
final class TerminalSessions: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabId: UUID?

    /// Weak ref to the NSWindow hosting these sessions. Set from the SwiftUI
    /// view via WindowAccessor. Used so multi-window setups close the *right*
    /// window when their last tab closes, not whichever window is `keyWindow`
    /// at the moment.
    weak var hostedWindow: NSWindow?

    /// Profile store for resolving the default profile when openTab() is called
    /// without an explicit profile (⌘T, command palette, etc.).
    weak var profileStore: ProfileStore?

    /// UserDefaults key for THIS window's persisted tab/pane layout. Each
    /// window now owns its own key (UUID-suffixed) so multi-window setups
    /// stop trampling each other's saved state — through v0.9.8 every
    /// window wrote to the same key, and the last save won.
    let restoreKey: String

    /// Master list of every known window's restoreKey. Persisted so we can
    /// rehydrate every saved window on launch, not just the most recently
    /// touched one.
    static let windowKeysKey = "mees.terminal.windowKeys.v1"

    /// Queue of restoreKeys waiting to be claimed by newly-opened windows
    /// on launch. The first window pops the most-recently-active key; each
    /// programmatic openWindow call drains the next one. New windows
    /// opened by the user (via ⌘N etc.) after the queue empties generate a
    /// fresh key.
    nonisolated(unsafe) static var pendingRestoreKeys: [String] = []

    /// Set once a window has consumed the legacy single-key restore
    /// payload, so no sibling window restores the same state.
    nonisolated(unsafe) static var legacyKeyConsumed: Bool = false

    init(restoreKey: String = UUID().uuidString) {
        self.restoreKey = restoreKey
        Self.registerWindowKey(restoreKey)
    }

    private static func registerWindowKey(_ key: String) {
        var existing = UserDefaults.standard.stringArray(forKey: windowKeysKey) ?? []
        if !existing.contains(key) {
            existing.append(key)
            UserDefaults.standard.set(existing, forKey: windowKeysKey)
        }
    }

    /// Remove this window's key from the master list — called when the
    /// window is closed by the user (⌘⇧W or last-tab cascade off). Without
    /// this, abandoned window keys accumulate forever.
    func unregisterWindow() {
        UserDefaults.standard.removeObject(forKey: restoreKey)
        var existing = UserDefaults.standard.stringArray(forKey: Self.windowKeysKey) ?? []
        existing.removeAll { $0 == restoreKey }
        UserDefaults.standard.set(existing, forKey: Self.windowKeysKey)
    }

    var currentTab: TerminalTab? {
        guard let id = selectedTabId else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    /// Active session = active pane of the active tab.
    var currentSession: TerminalSession? {
        currentTab?.activePane
    }

    // MARK: - Tab lifecycle

    @discardableResult
    func openTab(profile: Profile? = nil, persistChange: Bool = true) -> TerminalTab {
        let cwd = currentSession?.cwd ?? NSHomeDirectory()
        // Fall back to the default profile so new tabs honor profile settings
        // (shell, args, env, tag color) without callers needing to thread it.
        let resolvedProfile = profile ?? profileStore?.defaultProfile
        let tab = TerminalTab(initialCwd: cwd, profile: resolvedProfile)
        tabs.append(tab)
        selectedTabId = tab.id
        if persistChange { persist() }
        return tab
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
    }

    /// Move the tab with the given id to a new position in the tab list.
    /// `toIndex` is the destination index in the array AFTER removing the
    /// dragged tab. Bounds-clamped so a stale drop destination can't trap.
    func moveTab(_ id: UUID, to toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: from)
        let target = max(0, min(toIndex, tabs.count))
        tabs.insert(removed, at: target)
        persist()
    }

    /// Jump to the tab at the given 1-indexed position. Returns silently if
    /// `n` is out of range. `n == .max` selects the last tab regardless of
    /// count (matches the standard ⌘9-is-last browser convention).
    func selectTabByPosition(_ n: Int) {
        guard !tabs.isEmpty else { return }
        let idx: Int
        if n == Int.max {
            idx = tabs.count - 1
        } else if n >= 1 && n <= tabs.count {
            idx = n - 1
        } else {
            return
        }
        selectedTabId = tabs[idx].id
    }

    func nextTab() {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        selectedTabId = tabs[(i + 1) % tabs.count].id
    }

    func previousTab() {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        selectedTabId = tabs[(i - 1 + tabs.count) % tabs.count].id
    }

    /// ⌘W behavior: close the active pane. If it was the last pane in the tab,
    /// close the tab too. If it was the last tab, `closeTab` opens a rescue
    /// blank tab without persisting — so we must NOT call persist() here in
    /// that branch, or we'd immediately write the rescue layout back over the
    /// user's saved tabs.
    func closeCurrent() {
        guard let tab = currentTab else { return }
        let shouldCloseTab = tab.closeActivePane()
        if shouldCloseTab {
            closeTab(tab.id)   // handles its own persist policy
        } else {
            persist()           // only a pane closed, tab survives
        }
    }

    /// Remove a specific pane from whatever tab contains it. Closes the tab
    /// when its last pane is removed. Called when a pane's shell process
    /// terminates on its own (e.g. user typed `exit`).
    func closePane(_ paneId: UUID) {
        guard let tabIdx = tabs.firstIndex(where: { $0.panes.contains(where: { $0.id == paneId }) })
        else { return }
        let tab = tabs[tabIdx]
        guard let paneIdx = tab.panes.firstIndex(where: { $0.id == paneId }) else { return }
        tab.panes[paneIdx].terminalView?.terminate()
        tab.panes.remove(at: paneIdx)
        if tab.panes.isEmpty {
            closeTab(tab.id)
        } else {
            // If we removed the active pane, focus the neighbour.
            if tab.activePaneId == paneId {
                tab.activePaneId = tab.panes[min(paneIdx, tab.panes.count - 1)].id
            }
            persist()
        }
    }

    /// Close every tab except the given one. Used by the tab right-click
    /// menu's "Close Other Tabs" item — common terminal-app affordance.
    func closeOtherTabs(keeping id: UUID) {
        for tab in tabs where tab.id != id {
            for pane in tab.panes { pane.terminalView?.terminate() }
        }
        tabs.removeAll { $0.id != id }
        selectedTabId = id
        persist()
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        for pane in tabs[idx].panes { pane.terminalView?.terminate() }
        let wasSelected = selectedTabId == id
        tabs.remove(at: idx)
        if tabs.isEmpty {
            // Don't close the window — opening a fresh blank tab keeps a
            // misclicked ⌘W from cascading into "close window → terminate
            // app" (we set applicationShouldTerminateAfterLastWindowClosed
            // = true and confirmOnQuit defaults off, so a stray ⌘W on a
            // single-tab window would otherwise quit Termy without warning).
            // The user can still close the window outright with ⌘⇧W.
            //
            // Critically, don't persist the rescue tab — if this close was
            // accidental, the user's previous layout (which we just wiped
            // from `tabs`) should survive on next launch via whatever was
            // already persisted before. Wipe persistence ONLY when the user
            // explicitly quits with an empty window.
            openTab(persistChange: false)
            return
        }
        if wasSelected {
            selectedTabId = tabs[min(idx, tabs.count - 1)].id
        }
        persist()
    }

    func clearCurrent() {
        currentSession?.terminalView?.terminal.resetToInitialState()
        currentSession?.terminalView?.feed(text: "\u{001B}[2J\u{001B}[H")
    }

    /// Type a string + Enter into the active pane's shell. Terminals use CR
    /// (\r) for Enter — \n alone is interpreted as a literal newline without
    /// executing the command. Used by AI quick-launch + command palette.
    func sendToActivePane(_ command: String) {
        guard let view = currentSession?.terminalView else { return }
        view.send(txt: command + "\r")
    }

    /// All distinct cwds across all open tabs/panes — used for the Recent
    /// Directories quick switcher. Most-recently-active first.
    func uniqueCwds() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let ordered = (currentTab.map { [$0] } ?? []) + tabs.filter { $0.id != currentTab?.id }
        for tab in ordered {
            let activeFirst = (tab.activePane.map { [$0] } ?? []) +
                              tab.panes.filter { $0.id != tab.activePane?.id }
            for pane in activeFirst {
                if seen.insert(pane.cwd).inserted { out.append(pane.cwd) }
            }
        }
        return out
    }

    /// Duplicate the current tab — same orientation, copy of every pane,
    /// each starting in its source pane's cwd.
    func duplicateCurrentTab() {
        guard let tab = currentTab else { return }
        let copies = tab.panes.map { TerminalSession(initialCwd: $0.cwd) }
        let newTab = TerminalTab(panes: copies, orientation: tab.orientation)
        tabs.append(newTab)
        selectedTabId = newTab.id
        persist()
    }

    /// Open a new tab whose initial cwd is the given path (rather than
    /// inheriting from the current pane). Used by Recent Directories.
    func openTabIn(cwd: String) {
        let session = TerminalSession(initialCwd: cwd)
        let tab = TerminalTab(panes: [session])
        tabs.append(tab)
        selectedTabId = tab.id
        persist()
    }

    /// Open a file the OS asked us to handle — typically a .sh / .command /
    /// +x binary double-clicked in Finder. Opens a new tab in the file's
    /// parent dir and queues the file path as the first shell command, so
    /// the user sees the script run instead of a bare prompt.
    func openFile(_ url: URL) {
        let dir = url.deletingLastPathComponent().path
        let session = TerminalSession(initialCwd: dir)
        // Single-quote the path and escape any literal single quotes inside
        // it. Works for any filename including spaces / special chars.
        let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
        session.pendingInitialCommand = "'" + escaped + "'"
        let tab = TerminalTab(panes: [session])
        tabs.append(tab)
        selectedTabId = tab.id
        persist()
    }

    // MARK: - Splits

    func splitHorizontal() {
        currentTab?.split(orientation: .horizontal)
    }

    func splitVertical() {
        currentTab?.split(orientation: .vertical)
    }

    func focusNextPane() {
        currentTab?.focusNextPane()
    }

    func focusPreviousPane() {
        currentTab?.focusPreviousPane()
    }

    // MARK: - Persistence

    /// Persist current tabs (panes' cwds + orientation + per-pane profile)
    /// for restoration. The profile is stored as its UUID string so we can
    /// re-resolve through `profileStore` on launch and reapply the right
    /// shell / env / tag color — splits no longer lose their profile after
    /// a relaunch. Writes go to this window's per-window restoreKey so
    /// multi-window setups don't trample each other.
    func persist() {
        let payload: [[String: Any]] = tabs.map { tab in
            let panePayload: [[String: Any]] = tab.panes.map { pane in
                var entry: [String: Any] = ["cwd": pane.cwd]
                if let pid = pane.profileID { entry["profileID"] = pid.uuidString }
                return entry
            }
            var dict: [String: Any] = [
                "orientation": tab.orientation.rawValue,
                "panes": panePayload,
                // Legacy "cwds" key — older Termy builds read this. Keep
                // writing it so a fresh build → downgrade round-trips
                // without losing all tabs. Newer code reads "panes" first.
                "cwds": tab.panes.map { $0.cwd },
            ]
            if tab.tagColor != .none { dict["tagColor"] = tab.tagColor.rawValue }
            if tab.broadcastInput { dict["broadcastInput"] = true }
            if let title = tab.customTitle, !title.isEmpty { dict["customTitle"] = title }
            if tab.paneFractions.count == tab.panes.count, !tab.paneFractions.isEmpty {
                dict["paneFractions"] = tab.paneFractions.map { Double($0) }
            }
            return dict
        }
        UserDefaults.standard.set(payload, forKey: restoreKey)
    }

    /// Outcome of an attempted restore. The distinction between `.noSavedState`
    /// and `.staleSaved` matters: on `.staleSaved` we open a blank tab WITHOUT
    /// persisting, so the saved layout survives a launch where its cwds are
    /// temporarily unreachable (external drive unmounted, repo cloned to a
    /// different host). Persisting an empty tab there would permanently wipe
    /// the layout the user expects to come back next time the paths exist.
    enum RestoreOutcome {
        case restored
        case noSavedState
        case staleSaved
    }

    func restorePersisted() -> RestoreOutcome {
        // Read this window's own per-window key. Falls back to the legacy
        // v0.9.8 shared key for upgraders — but only ONCE per launch and
        // only for the first window, otherwise every fresh window on an
        // upgrade would restore the same legacy state into a duplicate.
        var raw = UserDefaults.standard.array(forKey: restoreKey) as? [[String: Any]]
        if (raw == nil || raw?.isEmpty == true) && !Self.legacyKeyConsumed {
            let legacyKey = "mees.terminal.restoreTabs.v2"
            raw = UserDefaults.standard.array(forKey: legacyKey) as? [[String: Any]]
            if raw != nil {
                // Drain it so no sibling window can also claim the legacy
                // state. Once consumed, subsequent launches stop consulting
                // it entirely (the entry is removed).
                UserDefaults.standard.removeObject(forKey: legacyKey)
                Self.legacyKeyConsumed = true
            }
        }
        guard let raw, !raw.isEmpty else { return .noSavedState }
        var restored: [TerminalTab] = []
        for entry in raw {
            let orientationStr = entry["orientation"] as? String ?? "horizontal"
            let orientation = PaneOrientation(rawValue: orientationStr) ?? .horizontal

            // New format: panes carry cwd + profileID per entry. Fall back
            // to legacy "cwds" array for pre-0.9.9 saves.
            let panePayloads: [(cwd: String, profileID: UUID?)]
            if let panes = entry["panes"] as? [[String: Any]] {
                panePayloads = panes.compactMap { p in
                    guard let cwd = p["cwd"] as? String else { return nil }
                    let pid = (p["profileID"] as? String).flatMap(UUID.init(uuidString:))
                    return (cwd, pid)
                }
            } else {
                let cwds = (entry["cwds"] as? [String]) ?? []
                panePayloads = cwds.map { ($0, nil) }
            }

            let validPanes = panePayloads.filter { FileManager.default.fileExists(atPath: $0.cwd) }
            guard !validPanes.isEmpty else { continue }
            let sessions = validPanes.map { p -> TerminalSession in
                let profile = p.profileID.flatMap { id in
                    profileStore?.profiles.first(where: { $0.id == id })
                }
                return TerminalSession(initialCwd: p.cwd, profile: profile)
            }
            let tab = TerminalTab(panes: sessions, orientation: orientation)
            if let colorRaw = entry["tagColor"] as? String,
               let color = TabTagColor(rawValue: colorRaw) {
                tab.tagColor = color
            }
            if let broadcast = entry["broadcastInput"] as? Bool, broadcast {
                tab.broadcastInput = true
            }
            if let title = entry["customTitle"] as? String, !title.isEmpty {
                tab.customTitle = title
            }
            if let fractions = entry["paneFractions"] as? [Double],
               fractions.count == tab.panes.count {
                tab.paneFractions = fractions.map { CGFloat($0) }
            }
            restored.append(tab)
        }
        guard !restored.isEmpty else { return .staleSaved }
        self.tabs = restored
        self.selectedTabId = restored.first?.id
        return .restored
    }
}
