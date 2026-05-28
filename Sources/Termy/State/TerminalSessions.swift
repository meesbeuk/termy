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

    /// True while the pane is actively producing output (claude/codex is
    /// thinking, build is compiling, etc.). Driven from TermyTerminalView's
    /// idle heuristic — same one that powers the "command finished"
    /// notification. PaneLayout reads this to render a thin animated
    /// progress stripe at the top of the active pane.
    @Published var isActive: Bool = false

    /// Coarse runtime state (working / idle / waiting-for-input) used by the
    /// activity stripe and the agent mission-control dashboard. `isActive`
    /// remains the raw "producing output" bit; `activity` adds the
    /// idle-but-waiting-at-a-prompt distinction.
    @Published var activity: PaneActivity = .idle

    /// Last non-empty visible line, captured on the idle transition. Drives the
    /// agent dashboard's per-pane "what's on screen" preview (the prompt it's
    /// waiting on, or the last output line).
    @Published var lastLine: String = ""

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
    @Published var tabs: [TerminalTab] = [] {
        didSet { reobserveTabs() }
    }
    @Published var selectedTabId: UUID?

    // MARK: - Tab-property auto-persist
    //
    // Tab-level edits (rename, tag color, broadcast toggle, orientation,
    // paneFractions) mutate @Published properties on TerminalTab directly from
    // the UI (TabChip context menu, command palette). Those sites don't call
    // persist(), so the changes were lost on quit even though the fields ARE in
    // the persist payload. Observe each tab's objectWillChange and debounce a
    // persist so any tab-property edit survives a relaunch — one place, can't
    // be forgotten at a new mutation site. (Pane streaming churn lives on
    // TerminalSession, not TerminalTab, so it doesn't trip this.)
    private var tabObservers: [AnyCancellable] = []
    private var tabPersistTimer: Timer?

    private func reobserveTabs() {
        tabObservers = tabs.map { tab in
            tab.objectWillChange.sink { [weak self] in
                self?.scheduleTabPersist()
            }
        }
    }

    private func scheduleTabPersist() {
        tabPersistTimer?.invalidate()
        tabPersistTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.persist() }
        }
    }

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

    /// LIFO stack of recently-closed tab snapshots — drives ⌘⇧Z
    /// "Reopen Closed Tab". Capped at 20 so undo history doesn't grow
    /// unbounded across a long Termy session. Per-window because reopening
    /// in a different window than the one the tab was closed in would
    /// surprise users with multi-window setups.
    private var closedTabHistory: [ClosedTabSnapshot] = []
    private let closedHistoryCap = 20

    /// True when there's at least one entry on the closed-tab stack — used
    /// by the menu item / command palette entry to decide whether to enable
    /// the action.
    var canReopenClosedTab: Bool { !closedTabHistory.isEmpty }

    init(restoreKey: String = UUID().uuidString, registerWindowKey: Bool = true) {
        self.restoreKey = restoreKey
        // Ephemeral sessions (the Quick Terminal / Quake window) must NOT join
        // the window-restore list: they never persist a tab payload, so a
        // registered-but-empty key spawned a blank phantom window on every
        // subsequent launch.
        if registerWindowKey {
            Self.registerWindowKey(restoreKey)
        }
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
            notifyActivePaneChanged()
        }
    }

    /// Remove a specific pane from whatever tab contains it. Closes the tab
    /// when its last pane is removed. Called when a pane's shell process
    /// terminates on its own (e.g. user typed `exit`).
    func closePane(_ paneId: UUID) {
        guard let tabIdx = tabs.firstIndex(where: { $0.panes.contains(where: { $0.id == paneId }) })
        else { return }
        let tab = tabs[tabIdx]
        // Route through TerminalTab.removePane so pane-fraction bookkeeping
        // (donate the closed pane's share to its neighbour) matches the
        // keyboard/menu close path. Previously this path removed the pane but
        // left paneFractions stale, so PaneLayout reset the split to equal.
        if tab.removePane(id: paneId) {
            closeTab(tab.id)
        } else {
            persist()
            notifyActivePaneChanged()
        }
    }

    /// Close every tab except the given one. Used by the tab right-click
    /// menu's "Close Other Tabs" item — common terminal-app affordance.
    func closeOtherTabs(keeping id: UUID) {
        // Snapshot each closing tab so ⌘⇧Z can walk back through them
        // (most-recently-closed first — same LIFO semantics as a single
        // close).
        for (idx, tab) in tabs.enumerated() where tab.id != id {
            let snapshot = ClosedTabSnapshot(
                originalIndex: idx,
                orientation: tab.orientation,
                paneCwds: tab.panes.map { $0.cwd },
                paneProfileIDs: tab.panes.map { $0.profileID },
                tagColor: tab.tagColor,
                broadcastInput: tab.broadcastInput,
                customTitle: tab.customTitle,
                paneFractions: tab.paneFractions
            )
            pushClosedSnapshot(snapshot)
            for pane in tab.panes { pane.terminalView?.terminate() }
        }
        tabs.removeAll { $0.id != id }
        selectedTabId = id
        persist()
    }

    /// Pop the most recently closed tab and reinsert it at its original
    /// position (clamped to current bounds). Returns true if anything was
    /// restored — drives the menu/command-palette enabled state via
    /// `canReopenClosedTab`.
    @discardableResult
    func reopenLastClosedTab() -> Bool {
        guard let snapshot = closedTabHistory.popLast() else { return false }
        let resolvedProfiles = snapshot.paneProfileIDs.map { id -> Profile? in
            guard let id else { return nil }
            return profileStore?.profiles.first(where: { $0.id == id })
        }
        // Use the snapshot's cwd-per-pane but fall back to home if the
        // directory has vanished since close (the user `rm -rf`d the
        // working dir between close and reopen).
        let fm = FileManager.default
        let sessions = zip(snapshot.paneCwds, resolvedProfiles).map { cwd, profile -> TerminalSession in
            let resolved = fm.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
            return TerminalSession(initialCwd: resolved, profile: profile)
        }
        let tab = TerminalTab(panes: sessions, orientation: snapshot.orientation)
        tab.tagColor = snapshot.tagColor
        tab.broadcastInput = snapshot.broadcastInput
        tab.customTitle = snapshot.customTitle
        if snapshot.paneFractions.count == sessions.count {
            tab.paneFractions = snapshot.paneFractions
        }
        let insertAt = max(0, min(snapshot.originalIndex, tabs.count))
        tabs.insert(tab, at: insertAt)
        selectedTabId = tab.id
        persist()
        return true
    }

    private func pushClosedSnapshot(_ snapshot: ClosedTabSnapshot) {
        closedTabHistory.append(snapshot)
        if closedTabHistory.count > closedHistoryCap {
            closedTabHistory.removeFirst(closedTabHistory.count - closedHistoryCap)
        }
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Snapshot before tearing down panes so ⌘⇧Z can restore the layout
        // (cwds + orientation + tag + custom title). Shells are NOT restored
        // — that'd require forking a new PTY per pane, which loses scrollback
        // anyway. The reopened tab is a fresh shell in the same cwd.
        let snapshot = ClosedTabSnapshot(
            originalIndex: idx,
            orientation: tabs[idx].orientation,
            paneCwds: tabs[idx].panes.map { $0.cwd },
            paneProfileIDs: tabs[idx].panes.map { $0.profileID },
            tagColor: tabs[idx].tagColor,
            broadcastInput: tabs[idx].broadcastInput,
            customTitle: tabs[idx].customTitle,
            paneFractions: tabs[idx].paneFractions
        )
        pushClosedSnapshot(snapshot)
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
        // Non-destructive clear: home + erase display + erase scrollback.
        // We must NOT call resetToInitialState() (a hard RIS) here: it re-runs
        // terminal setup, wiping the kitty-keyboard / bracketed-paste / focus /
        // application-cursor modes that a live TUI (claude) set ONCE at startup
        // and never re-emits. That silently broke Shift+Enter (kitty
        // disambiguation) and paste after every Cmd+K. ESC[3J erases scrollback
        // via SwiftTerm's dedicated CSI 3J handler without touching any modes.
        // RIS is reserved for an explicit user-invoked "Reset Terminal".
        currentSession?.terminalView?.feed(text: "\u{001B}[H\u{001B}[2J\u{001B}[3J")
    }

    /// Select every cell in the active pane's scrollback + viewport, copy
    /// the resulting text to the system pasteboard. Pairs with the
    /// "Copy Scrollback" command palette entry — obvious user intent of
    /// "give me everything in this pane as text" with one click instead
    /// of a manual click-drag-from-top. SwiftTerm's `selectAll(_:)` +
    /// `copy(_:)` are both `open` instance methods on its MacTerminalView
    /// base class, so they work without poking at internal state.
    func copyCurrentScrollback() {
        guard let view = currentSession?.terminalView else { return }
        view.selectAll(NSObject())
        view.copy(NSObject())
    }

    /// Scroll the active pane to the very top of the scrollback buffer.
    /// SwiftTerm's `scrollTo(row:)` accepts an absolute row; clamps at 0
    /// internally if we ask lower than the buffer start.
    func scrollActiveToTop() {
        currentSession?.terminalView?.scrollTo(row: 0)
    }

    /// Scroll the active pane to the bottom (live viewport).
    /// SwiftTerm's `scrollTo` does NOT clamp the row — passing a
    /// huge value poisons yDisp and produces a blank pane. The
    /// terminal's `displayBuffer.yBase` is internal, so compute the
    /// tail conservatively from `rows`: any large positive value
    /// that's still within Int range and bounded by buffer length
    /// would work, but using `terminal.rows` is a known-safe
    /// upper bound that SwiftTerm itself will accept.
    func scrollActiveToBottom() {
        guard let view = currentSession?.terminalView else { return }
        // Explicit user request to return to the live tail —
        // release the anti-stick-to-bottom lock so subsequent
        // output auto-snaps as expected.
        (view as? TermyTerminalView)?.releaseScrollLock()
        let term = view.getTerminal()
        // rows-1 is the cursor position when at the live tail. The
        // terminal will re-render the live area properly from this.
        view.scrollTo(row: max(0, term.rows - 1))
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

    /// Open a new tab in `cwd` and run `command` once the shell is up, via the
    /// same pendingInitialCommand path used for dropped scripts (real Enter, no
    /// blind timer). Used by "Resume session" in the Agent panel.
    func openTabRunning(cwd: String, command: String) {
        let session = TerminalSession(initialCwd: cwd)
        session.pendingInitialCommand = command.isEmpty ? nil : command
        let tab = TerminalTab(panes: [session])
        tabs.append(tab)
        selectedTabId = tab.id
        persist()
        notifyActivePaneChanged()
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

    // MARK: - Layouts

    /// Spawn a named layout as a NEW tab: one pane per spec, each opened in its
    /// configured cwd (empty = inherit the current pane's cwd) and running its
    /// startup command. The command is delivered via `pendingInitialCommand` —
    /// the same path the app uses to run a dropped script — so it submits with
    /// a real Enter once the shell is up, rather than via blind timed
    /// keystrokes. Grid layouts (e.g. Quad Claude 2×2) set `gridColumns`; 1-row
    /// / 1-column layouts reuse the existing H/V split path.
    func spawnLayout(_ layout: TermyLayout) {
        let baseCwd = currentSession?.cwd ?? NSHomeDirectory()
        let plan = layout.plan(baseCwd: baseCwd)
        guard !plan.panes.isEmpty else { return }

        let panes = plan.panes.map { p -> TerminalSession in
            let profile = p.profileID.flatMap { id in
                profileStore?.profiles.first(where: { $0.id == id })
            }
            let session = TerminalSession(initialCwd: p.cwd, profile: profile)
            session.pendingInitialCommand = p.command
            return session
        }

        let orientation: PaneOrientation
        switch plan.mode {
        case .stack(let o): orientation = o
        default:            orientation = .horizontal
        }
        let tab = TerminalTab(panes: panes, orientation: orientation)
        tab.customTitle = layout.name
        if case .grid(let cols) = plan.mode {
            tab.gridColumns = cols
            tab.gridColFractions = PaneMath.equalFractions(count: cols)
            tab.gridRowFractions = PaneMath.equalFractions(
                count: PaneMath.gridRows(count: panes.count, columns: cols))
        }
        tabs.append(tab)
        selectedTabId = tab.id
        persist()
        notifyActivePaneChanged()
    }

    /// Toggle "zoom" on the active pane: show it full-tab while the siblings
    /// stay mounted (parked off-screen, shells alive). A no-op for a lone pane.
    /// Re-zooms when a different pane is active than the currently-zoomed one.
    func toggleZoomActivePane() {
        guard let tab = currentTab, tab.panes.count > 1, let active = tab.activePaneId else {
            currentTab?.zoomedPaneId = nil
            return
        }
        tab.zoomedPaneId = (tab.zoomedPaneId == active) ? nil : active
        notifyActivePaneChanged()
    }

    /// Whether the current tab has a zoomed pane (drives the title-strip toggle).
    var currentTabIsZoomed: Bool { currentTab?.zoomedPaneId != nil }

    /// Focus a specific pane in a specific tab — used by the agent dashboard
    /// and targeted send-to-pane. Selects the tab, makes the pane active, and
    /// clears any zoom so the pane is visible in its layout.
    func focusPane(tabId: UUID, paneId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
        if tab.panes.contains(where: { $0.id == paneId }) {
            tab.activePaneId = paneId
            tab.zoomedPaneId = nil
        }
        notifyActivePaneChanged()
    }

    /// Render a local image inline in the active pane via SwiftTerm's image
    /// API — the same rendering path the iTerm2/kitty graphics protocols use,
    /// but injected directly (not through the shell's stdin). Returns false if
    /// the file isn't a renderable image. `@discardableResult` so callers can
    /// ignore the outcome.
    @discardableResult
    func showImage(at url: URL) -> Bool {
        guard let view = currentSession?.terminalView else { return false }
        guard let data = try? Data(contentsOf: url),
              InlineImagePolicy.isRenderable(ext: url.pathExtension, byteCount: data.count),
              NSImage(data: data) != nil
        else { return false }
        // Width fits the pane; aspect ratio preserved so tall images don't
        // distort. Rendered into the terminal stream at the cursor.
        view.createImage(source: view.getTerminal(), data: data,
                         width: .percent(100), height: .auto, preserveAspectRatio: true)
        return true
    }

    /// Send a line of text (with the correct Enter) to a specific pane —
    /// the targeted complement to broadcast. Reuses the Vibecoder send path.
    func send(text: String, toPaneId paneId: UUID) {
        for tab in tabs {
            if let pane = tab.panes.first(where: { $0.id == paneId }) {
                pane.terminalView?.send(txt: text + "\r")
                return
            }
        }
    }

    // MARK: - Splits

    func splitHorizontal() {
        currentTab?.split(orientation: .horizontal)
        notifyActivePaneChanged()
    }

    func splitVertical() {
        currentTab?.split(orientation: .vertical)
        notifyActivePaneChanged()
    }

    func focusNextPane() {
        currentTab?.focusNextPane()
        notifyActivePaneChanged()
    }

    func focusPreviousPane() {
        currentTab?.focusPreviousPane()
        notifyActivePaneChanged()
    }

    /// Posts a notification that the active pane has changed, so the
    /// hosting MainTerminalView can re-claim keyboard focus. SwiftUI's
    /// .onChange(of: sessions.currentTab?.activePaneId) does NOT fire
    /// when activePaneId mutates on the tab sub-object — only changes
    /// published from `sessions` itself propagate. Without this
    /// notification, splits / pane focus cycling / pane closure leave
    /// keyboard focus stranded on the previous pane, so the user's
    /// first keystroke after a split lands in the wrong pane.
    private func notifyActivePaneChanged() {
        NotificationCenter.default.post(name: .terminalActivePaneChanged, object: nil)
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
            if let cols = tab.gridColumns, cols > 1 {
                dict["gridColumns"] = cols
                if !tab.gridColFractions.isEmpty { dict["gridColFractions"] = tab.gridColFractions.map { Double($0) } }
                if !tab.gridRowFractions.isEmpty { dict["gridRowFractions"] = tab.gridRowFractions.map { Double($0) } }
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
            if let cols = entry["gridColumns"] as? Int, cols > 1, tab.panes.count > 1 {
                tab.gridColumns = cols
                if let cf = entry["gridColFractions"] as? [Double] { tab.gridColFractions = cf.map { CGFloat($0) } }
                if let rf = entry["gridRowFractions"] as? [Double] { tab.gridRowFractions = rf.map { CGFloat($0) } }
            }
            restored.append(tab)
        }
        guard !restored.isEmpty else { return .staleSaved }
        self.tabs = restored
        self.selectedTabId = restored.first?.id
        return .restored
    }
}

/// Frozen snapshot of a tab at the moment it was closed. Used to back the
/// ⌘⇧Z "Reopen Closed Tab" stack. Carries enough to rebuild the layout
/// (cwds, orientation, divider fractions, tag color, custom title) but not
/// the shell process — that gets re-forked when the tab restores, since
/// SwiftTerm doesn't expose a way to detach + reattach a live PTY.
struct ClosedTabSnapshot {
    let originalIndex: Int
    let orientation: PaneOrientation
    let paneCwds: [String]
    let paneProfileIDs: [UUID?]
    let tagColor: TabTagColor
    let broadcastInput: Bool
    let customTitle: String?
    let paneFractions: [CGFloat]
}
