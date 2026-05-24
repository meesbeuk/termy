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

    private static let restoreKey = "mees.terminal.restoreTabs.v2"

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
    func openTab(profile: Profile? = nil) -> TerminalTab {
        let cwd = currentSession?.cwd ?? NSHomeDirectory()
        // Fall back to the default profile so new tabs honor profile settings
        // (shell, args, env, tag color) without callers needing to thread it.
        let resolvedProfile = profile ?? profileStore?.defaultProfile
        let tab = TerminalTab(initialCwd: cwd, profile: resolvedProfile)
        tabs.append(tab)
        selectedTabId = tab.id
        persist()
        return tab
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
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
    /// close the tab too. If it was the last tab, close the window — the app
    /// delegate handles app termination when the last window closes.
    func closeCurrent() {
        guard let tab = currentTab else { return }
        let shouldCloseTab = tab.closeActivePane()
        if shouldCloseTab {
            closeTab(tab.id)
        }
        persist()
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

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        for pane in tabs[idx].panes { pane.terminalView?.terminate() }
        let wasSelected = selectedTabId == id
        tabs.remove(at: idx)
        if tabs.isEmpty {
            persist()
            // Close THIS sessions' window specifically — not whichever window
            // happens to be NSApp.keyWindow, which could be a sibling window.
            (hostedWindow ?? NSApp.keyWindow)?.close()
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

    /// Persist current tabs (panes' cwds + orientation) for restoration.
    func persist() {
        let payload: [[String: Any]] = tabs.map { tab in
            [
                "orientation": tab.orientation.rawValue,
                "cwds": tab.panes.map { $0.cwd },
            ]
        }
        UserDefaults.standard.set(payload, forKey: Self.restoreKey)
    }

    @discardableResult
    func restorePersisted() -> Bool {
        guard let raw = UserDefaults.standard.array(forKey: Self.restoreKey) as? [[String: Any]],
              !raw.isEmpty
        else { return false }
        var restored: [TerminalTab] = []
        for entry in raw {
            let orientationStr = entry["orientation"] as? String ?? "horizontal"
            let orientation = PaneOrientation(rawValue: orientationStr) ?? .horizontal
            let cwds = (entry["cwds"] as? [String]) ?? []
            let validCwds = cwds.filter { FileManager.default.fileExists(atPath: $0) }
            guard !validCwds.isEmpty else { continue }
            let panes = validCwds.map { TerminalSession(initialCwd: $0) }
            restored.append(TerminalTab(panes: panes, orientation: orientation))
        }
        guard !restored.isEmpty else { return false }
        self.tabs = restored
        self.selectedTabId = restored.first?.id
        return true
    }
}
