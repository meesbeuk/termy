import SwiftUI
import AppKit
import SwiftTerm

/// Top-level window content.
struct MainTerminalView: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var workflows: WorkflowStore
    @State private var showingSettings = false
    @State private var showingRecentDirs = false
    @State private var showingPalette = false
    @State private var showingFind = false
    @State private var showingCheatsheet = false
    @State private var showingSessionLogs = false
    @State private var showingPasteHistory = false
    @State private var showingAgentPanel = false
    @State private var showingQuickSelect = false
    @State private var showingDiagnostics = false
    @State private var showingOnboarding = false
    @State private var findInitialQuery: String?
    @State private var hostedWindow: NSWindow?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleStrip(
                    showingSettings: $showingSettings,
                    showLaunchers: settings.vibecoderMode,
                    onLaunch: { launch($0) },
                    onToggleFind: toggleFind,
                    onOpenPalette: { showingPalette = true },
                    onShowRecentDirs: { showingRecentDirs = true },
                    onSplitH: { sessions.splitHorizontal() },
                    onSplitV: { sessions.splitVertical() },
                    onQuickTerminal: {
                        if let store = sessions.profileStore {
                            QuickTerminalController.shared.toggle(settings: settings, profiles: store)
                        }
                    },
                    onShowCheatsheet: { showingCheatsheet = true }
                )
                if settings.showTabBar {
                    TabBar()
                        .frame(height: 32)
                    Divider().opacity(0.25)
                }

                ZStack(alignment: .topTrailing) {
                    // Render EVERY tab's PaneLayout in a ZStack, only
                    // the selected one visible. SwiftTerm's NSView does
                    // not reliably redraw its scrollback after being
                    // unmounted and re-parented (SwiftUI's behavior when
                    // a different tab becomes current and the previous
                    // tab's NSView is torn down). Keeping all tabs
                    // mounted at all times means the active tab's NSView
                    // never leaves the window — so tab switches preserve
                    // every pane's history with zero re-parenting cost.
                    // Hit-testing is gated to the selected tab so
                    // background tabs can't intercept clicks/keystrokes,
                    // and opacity rather than `if` keeps the view tree
                    // structure stable.
                    ForEach(sessions.tabs) { tab in
                        let isSelected = tab.id == sessions.selectedTabId
                        PaneLayout(tab: tab, sessions: sessions, settings: settings)
                            .padding(.horizontal, settings.paddingPreset.horizontal)
                            .padding(.vertical, settings.paddingPreset.vertical)
                            // Park inactive tabs WAY off-screen so they
                            // stay mounted (no re-parenting → no
                            // scrollback loss) but don't bleed their
                            // clear-bg SwiftTerm draws through the
                            // active tab. compositingGroup + opacity(0)
                            // works for hiding but appears to confuse
                            // SwiftUI's layout passes for the active
                            // tab after pane-count changes (split
                            // close), leaving the visible pane blank
                            // until the next keystroke. An offset is a
                            // plain layout transform that doesn't go
                            // through CALayer compositing, so it doesn't
                            // mess with the active tab's draw path.
                            .offset(x: isSelected ? 0 : -100_000, y: 0)
                            .allowsHitTesting(isSelected)
                            .zIndex(isSelected ? 1 : 0)
                    }
                    if showingFind {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                sessions.currentSession?.terminalView?.clearSearch()
                                showingFind = false
                                findInitialQuery = nil
                            }
                            .zIndex(4)
                        FindBar(
                            view: sessions.currentSession?.terminalView,
                            initialQuery: findInitialQuery,
                            onClose: {
                                sessions.currentSession?.terminalView?.clearSearch()
                                showingFind = false
                                findInitialQuery = nil
                            }
                        )
                        .padding(.top, 10)
                        .padding(.trailing, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: showingFind)

                if settings.showStatusBar {
                    Divider().opacity(0.25)
                    StatusBar()
                }
            }
            // Push the VStack up into the title-bar inset so the title strip
            // (with the launchers row) renders at y=0 of the window, level
            // with the traffic lights. Without this, SwiftUI's default safe
            // area pushes the title strip below the traffic lights and the
            // launchers end up in a band beneath them.
            .ignoresSafeArea(.container, edges: .top)

            overlays
        }
        // Bumped from 480x320 — the previous floor let users drag the
        // window into a state where overlays (palette, onboarding, etc.)
        // collapsed below readable. 560x400 is still compact enough for
        // side-by-side window layouts but leaves room for modal chrome.
        .frame(minWidth: 560, idealWidth: 920, maxWidth: .infinity,
               minHeight: 400, idealHeight: 620, maxHeight: .infinity)
        .background(WindowBackdrop(hostedWindow: $hostedWindow))
        // Forward the captured NSWindow down so closeTab can target the
        // right window in multi-window setups (NSApp.keyWindow can be a sibling).
        // Also (re)install the broadcast-input key monitor here — at .onAppear
        // time hostedWindow is still nil (WindowAccessor sets it via an async
        // dispatch one runloop turn later), so installing in onAppear meant
        // the monitor's window comparison silently failed until a manual
        // reinstall. Tying install to hostedWindow availability guarantees we
        // always have an NSWindow to compare against.
        .onChange(of: hostedWindow) { _, new in
            sessions.hostedWindow = new
            if new != nil {
                removeKeyMonitor()
                installKeyMonitor()
                // First-launch welcome — only ONE window shows it per app
                // launch even if multiple windows restore, because we flip
                // the completed flag the moment we show it. Dispatched
                // async so the window has time to lay out the terminal
                // behind the modal first; a flash-of-empty-window before
                // the sheet would look glitchy.
                if !OnboardingState.isCompleted {
                    OnboardingState.markCompleted()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingOnboarding = true
                    }
                }
            } else {
                removeKeyMonitor()
            }
            syncWindowTitle()
        }
        // Push the active pane's title/cwd into NSWindow.title so the
        // Window menu and Dock can distinguish multiple Termy windows.
        // Without this every window shows up as plain "Termy" — useless
        // when the user has 3+ open.
        .onChange(of: sessions.selectedTabId) { _, _ in
            syncWindowTitle()
            focusActivePane()
        }
        // Pane focus changes inside the current tab (split, focus
        // cycle, close pane) don't propagate through SwiftUI's
        // .onChange chain because they mutate a sub-object's
        // @Published property, not `sessions` itself. The
        // sessions methods post .terminalActivePaneChanged after
        // each mutation; observe it here to claim keyboard focus.
        .onReceive(NotificationCenter.default.publisher(for: .terminalActivePaneChanged)) { _ in
            focusActivePane()
        }
        .onChange(of: sessions.currentSession?.cwd) { _, _ in syncWindowTitle() }
        .onChange(of: sessions.currentSession?.title) { _, _ in syncWindowTitle() }
        .onChange(of: sessions.currentTab?.customTitle) { _, _ in syncWindowTitle() }
        // Window-level Esc handler — Esc never reaches the focused NSTextField
        // in the FindBar because something between the window and the field
        // editor consumes it. Diagnostic logging confirmed
        // doCommandBy:cancelOperation: never fires. Installing a global
        // NSEvent monitor at the app level catches Esc reliably; we
        // additionally store the handle in `KeyMonitorBox` (a class) so the
        // mutation survives the SwiftUI struct rebuild that broke an earlier
        // @State-based attempt.
        .background(EscMonitor(
            isActive: showingFind,
            onEscape: {
                sessions.currentSession?.terminalView?.clearSearch()
                showingFind = false
            }
        ))
        .modifier(TerminalHandlers(
            sessions: sessions,
            isKeyWindow: { isKeyWindow },
            hostedWindow: { hostedWindow },
            performFind: toggleFind,
            findFromSelection: findFromSelection,
            handleDrop: handleDrop,
            installKeyMonitor: installKeyMonitor,
            removeKeyMonitor: removeKeyMonitor,
            showRecentDirs: { showingRecentDirs = true },
            showPalette: { showingPalette = true },
            showCheatsheet: { showingCheatsheet = true },
            showSettings: { showingSettings = true },
            showSessionLogs: { showingSessionLogs = true },
            showPasteHistory: { showingPasteHistory = true },
            showAgentPanel: { showingAgentPanel = true },
            showQuickSelect: { showingQuickSelect = true },
            showDiagnostics: { showingDiagnostics = true },
            showOnboarding: { showingOnboarding = true }
        ))
        .sheet(isPresented: $showingSettings) {
            TerminalSettingsSheet(onClose: { showingSettings = false })
                .environmentObject(settings)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Modal overlays extracted into a single ViewBuilder so the main
    /// body stays under the SwiftUI type-checker's complexity budget.
    /// Adding a 4th conditional caused "expression is too complex" errors
    /// when the @EnvironmentObject roster grew.
    @ViewBuilder private var overlays: some View {
        if showingRecentDirs {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingRecentDirs = false }
                RecentDirsPanel(
                    cwds: sessions.uniqueCwds(),
                    onDismiss: { showingRecentDirs = false },
                    onPick: { path in
                        sessions.openTabIn(cwd: path)
                        showingRecentDirs = false
                    }
                )
                .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(10)
        }
        if showingPalette {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingPalette = false }
                CommandPalette(onDismiss: { showingPalette = false })
                    .environmentObject(sessions)
                    .environmentObject(settings)
                    .environmentObject(workflows)
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(11)
        }
        if showingCheatsheet {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingCheatsheet = false }
                CheatsheetPanel(onDismiss: { showingCheatsheet = false })
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(12)
        }
        if showingSessionLogs {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingSessionLogs = false }
                SessionLogBrowser(onDismiss: { showingSessionLogs = false })
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(13)
        }
        if showingPasteHistory {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingPasteHistory = false }
                PasteHistoryPicker(onDismiss: { showingPasteHistory = false })
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(14)
        }
        if showingAgentPanel {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingAgentPanel = false }
                AgentPanel(onDismiss: { showingAgentPanel = false })
                    .environmentObject(sessions)
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(15)
        }
        if showingQuickSelect {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingQuickSelect = false }
                QuickSelectPicker(onDismiss: { showingQuickSelect = false })
                    .environmentObject(sessions)
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(16)
        }
        if showingDiagnostics {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                    .onTapGesture { showingDiagnostics = false }
                DiagnosticsSheet(onDismiss: { showingDiagnostics = false })
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(17)
        }
        if showingOnboarding {
            ZStack {
                // Slightly stronger backdrop than the other modals — onboarding
                // is intentionally attention-grabbing on first launch and the
                // user shouldn't accidentally tap into the terminal before
                // they've read it.
                Color.black.opacity(0.18).ignoresSafeArea()
                OnboardingSheet(onDismiss: { showingOnboarding = false })
                    .padding(DS.Spacing.l)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /// Promote the active pane's NSView to first responder. Tab switches
    /// otherwise leave the prior tab's view focused (or no view focused at
    /// all on a fresh window), so the user has to click into the terminal
    /// before keystrokes route to the PTY and the caret stays hollow.
    ///
    /// For a brand-new tab (⌘T) the NSView is created lazily by
    /// `TerminalSurface.makeNSView` during the same render pass that fires
    /// this .onChange, so the very first focus attempt finds
    /// `session.terminalView == nil`. Retry on the next few runloop ticks
    /// until the view appears (or we give up after ~250ms). Without the
    /// retry, ⌘T leaves keystroke focus on the PREVIOUS tab's pane and
    /// the user's first typed command lands in the wrong tab.
    private func focusActivePane() {
        attemptFocusActivePane(retriesRemaining: 6)
    }

    private func attemptFocusActivePane(retriesRemaining: Int) {
        DispatchQueue.main.async {
            if let view = sessions.currentSession?.terminalView,
               let window = view.window ?? hostedWindow {
                // Don't gate on `shouldClaimFocus` here. A tab/pane
                // change is an explicit user-driven focus move; the
                // current firstResponder is almost always the
                // PREVIOUS pane's TerminalView (also a TermyTerminalView)
                // which shouldClaimFocus refuses to displace. That
                // guard exists for unrelated render-pass focus claims
                // and would silently strand keystrokes on the wrong
                // pane forever after every ⌘T / ⌘D. Tab-switch handler
                // is authoritative: take focus unconditionally if it's
                // not already on the target view.
                if window.firstResponder !== view {
                    window.makeFirstResponder(view)
                    NotificationCenter.default.post(
                        name: TermyTerminalView.focusChangedNotification,
                        object: view
                    )
                }
                return
            }
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                attemptFocusActivePane(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    /// Map the active pane state to NSWindow.title. Format prefers, in
    /// order: tab custom title, pane title if it differs from "zsh", or
    /// the cwd basename with `~` folding. NSWindow keeps titleVisibility
    /// hidden so this doesn't change the chrome — it only feeds the
    /// Window menu, Dock, and Mission Control labels.
    private func syncWindowTitle() {
        guard let window = hostedWindow else { return }
        let title: String
        if let custom = sessions.currentTab?.customTitle, !custom.isEmpty {
            title = custom
        } else if let paneTitle = sessions.currentSession?.title,
                  !paneTitle.isEmpty, paneTitle != "zsh", paneTitle != "bash" {
            title = paneTitle
        } else if let cwd = sessions.currentSession?.cwd {
            let home = NSHomeDirectory()
            let folded = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            title = (folded as NSString).lastPathComponent
        } else {
            title = "Termy"
        }
        if window.title != title {
            window.title = title
        }
    }

    /// Send the launcher's CLI to the active pane + auto-execute it.
    /// sendToActivePane appends Enter (CR) so the shell actually runs it.
    private func launch(_ launcher: AILauncher) {
        sessions.sendToActivePane(launcher.commandPreview)
    }

    /// Drop a file/folder from Finder → quoted path types into the active pane.
    /// ALWAYS single-quotes the path, even if it has no spaces. A dropped path
    /// like `/tmp/$(rm -rf ~)/file` would otherwise be passed unquoted and
    /// the shell would execute the substitution before the user even read the
    /// command. Single-quoting + escaping any embedded single quotes makes the
    /// whole path a literal under POSIX shells.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Capture the target session NOW, not at dispatch time — if the user
        // switches panes between drop and dispatch, the text otherwise lands
        // in whatever pane is active later.
        let target = sessions.currentSession
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let target else { return }
                let escaped = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                DispatchQueue.main.async {
                    target.terminalView?.send(txt: escaped + " ")
                }
            }
        }
        return true
    }

    /// Local key monitor that mirrors typed characters to all sibling panes
    /// when the active tab has Broadcast Input enabled. Active pane still gets
    /// the keystroke through normal AppKit routing — we only forward to others.
    /// Captures the NSWindow weakly at install time so the closure's window
    /// comparison can't accidentally read a stale (nil) @State value — that
    /// was the v0.9.6 bug where the monitor was installed in onAppear before
    /// WindowAccessor's async dispatch had set hostedWindow.
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        guard let window = hostedWindow else { return }
        let sessionsRef = sessions
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window,
                  let tab = sessionsRef.currentTab, tab.broadcastInput,
                  let chars = event.characters, !chars.isEmpty
            else { return event }
            for pane in tab.panes where pane.id != tab.activePaneId {
                pane.terminalView?.send(txt: chars)
            }
            return event
        }
    }

    /// Only the currently-focused window should react to global notifications.
    /// Without this, every open window would fork a new tab on ⌘T.
    private var isKeyWindow: Bool {
        guard let host = hostedWindow else { return false }
        return host.isKeyWindow
    }

    /// Toggle the inline find bar. If it was already open, close it (and clear
    /// any active search highlight). Otherwise open it. Replaces the v0.9.6
    /// NSFindPanel popup which was both ugly and modal.
    private func toggleFind() {
        if showingFind {
            sessions.currentSession?.terminalView?.clearSearch()
            showingFind = false
            findInitialQuery = nil
        } else {
            findInitialQuery = nil
            showingFind = true
        }
    }

    /// ⌘E — standard macOS "Use Selection for Find". Copies the active
    /// pane's current selection to the find clipboard and opens the find
    /// bar prefilled with it. If there's no selection, behaves like ⌘F.
    private func findFromSelection() {
        guard let view = sessions.currentSession?.terminalView else { return }
        view.copy(NSObject())   // SwiftTerm writes selection to NSPasteboard.general
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        findInitialQuery = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
        showingFind = true
    }
}

/// Installs a global NSEvent local monitor for Escape whenever `isActive` is
/// true, and removes it when false. Coordinator-backed so the monitor handle
/// lives in reference storage (an @State-backed variant lost the handle to
/// SwiftUI's struct rebuilds and never tore down).
private struct EscMonitor: NSViewRepresentable {
    let isActive: Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.sync(isActive: isActive, onEscape: onEscape)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(isActive: isActive, onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coord) {
        coordinator.tearDown()
    }

    final class Coord {
        private var monitor: Any?
        private var onEscape: (() -> Void) = {}

        func sync(isActive: Bool, onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            if isActive && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    // keyCode 53 = Esc. Also accept Cmd+. (keyCode 47 with cmd)
                    // as the macOS-standard "cancel" combo — works in cases
                    // where bare Esc is being absorbed by the system text-
                    // input layer for an editing NSTextField.
                    let isEsc = event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                    let isCmdPeriod = event.keyCode == 47 && event.modifierFlags.contains(.command)
                    guard isEsc || isCmdPeriod else { return event }
                    DispatchQueue.main.async { self.onEscape() }
                    return nil
                }
            } else if !isActive, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        func tearDown() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        deinit { tearDown() }
    }
}

/// One uniform window surface. The whole window shares this material — chrome
/// (title strip, tab bar, status bar) and terminal area sit ON TOP without any
/// extra backgrounds, so opacities don't stack and the look stays consistent.
/// The adaptive tint darkens slightly when the wallpaper is light and lightens
/// when it's dark — applied across the entire window, not per-element.
private struct WindowBackdrop: View {
    @Binding var hostedWindow: NSWindow?
    @EnvironmentObject var settings: TerminalSettings

    var body: some View {
        ZStack {
            // NSVisualEffectView with .hudWindow material — the dark-blurry
            // surface macOS uses for HUDs. Unlike SwiftUI's .ultraThinMaterial
            // (which goes near-white over white backdrops and renders terminal
            // text unreadable), .hudWindow stays dark-glassy regardless of
            // what's behind the window. We can't sample what's literally
            // behind without screen-recording entitlements, so picking a
            // material that's contrast-stable is the right tradeoff.
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            // Extra tint on top — still drives auto/manual opacity range,
            // but the floor is bumped so we never go below readable contrast.
            Color.black.opacity(settings.effectiveOpacity)
        }
        .ignoresSafeArea()
        .background(WindowAccessor(hostedWindow: $hostedWindow))
    }
}

/// NSViewRepresentable wrapper around NSVisualEffectView. SwiftUI's `.material`
/// modifier doesn't expose blendingMode or the HUD-style material.
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var hostedWindow: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = AccessorView()
        v.configure = { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            DispatchQueue.main.async { self.hostedWindow = window }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { configure?(w) }
        }
    }
}

// MARK: - Title strip

private struct TitleStrip: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    @Binding var showingSettings: Bool
    let showLaunchers: Bool
    let onLaunch: (AILauncher) -> Void
    // Action affordances — every keyboard shortcut also gets a visible
    // clickable icon. Users who don't memorise ⌘F / ⌘D / ⌘⇧P / ⌃` need a way
    // to discover features by scanning the chrome.
    let onToggleFind: () -> Void
    let onOpenPalette: () -> Void
    let onShowRecentDirs: () -> Void
    let onSplitH: () -> Void
    let onSplitV: () -> Void
    let onQuickTerminal: () -> Void
    let onShowCheatsheet: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // ~52pt for the three traffic-light buttons + comfortable
            // breathing room before the launcher row so the chrome doesn't
            // look cramped against the window controls.
            Color.clear.frame(width: 72, height: 28)
            if showLaunchers {
                InlineLaunchersRow(onLaunch: onLaunch)
                ChromeDivider()
            }
            // Quick-action icons grouped by purpose with thin dividers so
            // the row reads as logical clusters rather than a wall of
            // glyphs. Group 1: navigation/search. Group 2: layout. Group
            // 3: help. Future-proof: when we add a new icon, drop it into
            // the right group (or start a new one + add a divider) — the
            // user shouldn't have to re-scan the whole row to find what
            // changed.

            // Navigation & search
            ChromeIconButton(symbol: "magnifyingglass",
                             tooltip: "Find in scrollback (⌘F)",
                             action: onToggleFind)
            ChromeIconButton(symbol: "command",
                             tooltip: "Command Palette (⌘⇧P)",
                             action: onOpenPalette)
            ChromeIconButton(symbol: "clock.arrow.circlepath",
                             tooltip: "Recent Directories (⌘⌥/)",
                             action: onShowRecentDirs)

            ChromeDivider()

            // Layout / windowing
            ChromeIconButton(symbol: "rectangle.split.2x1",
                             tooltip: "Split Horizontally (⌘D)",
                             action: onSplitH)
            ChromeIconButton(symbol: "rectangle.split.1x2",
                             tooltip: "Split Vertically (⌘⇧D)",
                             action: onSplitV)
            ChromeIconButton(symbol: "chevron.down.square",
                             tooltip: "Quick Drop-down Terminal (⌃`)",
                             action: onQuickTerminal)

            ChromeDivider()

            // Help
            ChromeIconButton(symbol: "questionmark.circle",
                             tooltip: "Keyboard shortcuts cheatsheet (⌘/)",
                             action: onShowCheatsheet)
            Spacer()
            // cwd lives in the status bar — no need to duplicate it up top.
            Text("\(Int(settings.fontSize))pt")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let session = sessions.currentSession {
                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1) // give up width first on narrow windows
            }
            ChromeIconButton(symbol: "gearshape",
                             tooltip: "Settings",
                             action: { showingSettings = true })
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

private struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 14)
    }
}

/// Standard chrome icon button. Renders as a flat SF Symbol with a hover
/// background, 22pt hit target, and tooltip. Every action in the title strip
/// uses this so weights/sizing/hover treatment stay consistent.
/// Tooltip text doubles as the VoiceOver label — same string, two
/// audiences (hovering pointer users + screen-reader users).
private struct ChromeIconButton: View {
    let symbol: String
    let tooltip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

/// Compact launchers row that lives inline in the title strip. Each launcher
/// uses the same flat rounded-square chrome treatment as the feature icons
/// (search / palette / splits / etc.) so the title-strip reads as one
/// consistent control row rather than a chips-then-icons mix.
private struct InlineLaunchersRow: View {
    let onLaunch: (AILauncher) -> Void
    @State private var launchers: [AILauncher] = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(launchers) { launcher in
                InlineLaunchChip(
                    launcher: launcher,
                    onTap: { onLaunch(launcher) }
                )
            }
        }
        .onAppear { launchers = AILauncher.installed() }
    }
}

private struct InlineLaunchChip: View {
    let launcher: AILauncher
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            BrandIcon(assetName: launcher.brandAsset,
                      fallbackSymbol: launcher.icon,
                      size: 13)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(launcher.displayName) — run `\(launcher.cli)` in active pane")
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

// MARK: - Recent Directories panel

private struct RecentDirsPanel: View {
    let cwds: [String]
    let onDismiss: () -> Void
    let onPick: (String) -> Void

    @State private var selected: Int = 0

    var body: some View {
        DSModal(
            title: "Recent Directories",
            titleIcon: "folder.fill",
            titleIconColor: .blue,
            footerHint: "↑↓ navigate  ·  ↵ open in new tab  ·  ⎋ close",
            onClose: onDismiss
        ) {
            if cwds.isEmpty {
                Text("No directories to remember yet.")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
            } else {
                VStack(spacing: DS.Spacing.xxs) {
                    ForEach(Array(cwds.enumerated()), id: \.offset) { idx, path in
                        Button(action: { onPick(path) }) {
                            HStack(spacing: DS.Spacing.s) {
                                Image(systemName: "folder")
                                    .font(DS.Typo.caption)
                                    .foregroundStyle(DS.Colors.tertiary)
                                Text(display(path))
                                    .font(DS.Typo.monoCaption)
                                    .foregroundStyle(DS.Colors.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if idx == selected {
                                    Image(systemName: "return")
                                        .font(DS.Typo.micro)
                                        .foregroundStyle(DS.Colors.tertiary)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.m)
                            .padding(.vertical, DS.Spacing.s)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.s)
                                    .fill(idx == selected ? DS.Colors.chipBgHover : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Use hidden keyboard-shortcut buttons rather than .onKeyPress —
        // child Buttons in the list can steal focus and prevent the modifier
        // from firing. keyboardShortcut works regardless of focus.
        .background(
            Group {
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    if !cwds.isEmpty { onPick(cwds[selected]) }
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if !cwds.isEmpty { selected = (selected + 1) % cwds.count }
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                Button("") {
                    if !cwds.isEmpty { selected = (selected - 1 + cwds.count) % cwds.count }
                }
                .keyboardShortcut(.upArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @EnvironmentObject var sessions: TerminalSessions
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    var body: some View {
        // Overlay scroll-cue chevrons when the tab list overflows the
        // visible width. Without this, users with 20+ tabs had no
        // indication that more tabs existed offscreen — scrolling was
        // discoverable only by trackpad swipe.
        ZStack(alignment: .leading) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { idx, tab in
                            TabChip(tab: tab,
                                    isActive: tab.id == sessions.selectedTabId,
                                    onSelect: { sessions.selectTab(tab.id) },
                                    onClose: { sessions.closeTab(tab.id) },
                                    onCloseOthers: { sessions.closeOtherTabs(keeping: tab.id) })
                                .onDrag {
                                    return NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    destinationIndex: idx,
                                    sessions: sessions
                                ))
                                .id(tab.id)
                        }
                        Button(action: { sessions.openTab() }) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New tab (⌘T) — right-click to choose profile")
                        .accessibilityLabel("New tab")
                        .contextMenu {
                            if let store = sessions.profileStore {
                                Button("New Tab (Default)") { sessions.openTab() }
                                if store.profiles.count > 1 {
                                    Divider()
                                    ForEach(store.profiles) { p in
                                        Button(p.name) { sessions.openTab(profile: p) }
                                    }
                                }
                            } else {
                                Button("New Tab") { sessions.openTab() }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .preference(key: TabContentWidthKey.self, value: contentGeo.size.width)
                                .preference(key: TabScrollOffsetKey.self,
                                            value: -contentGeo.frame(in: .named("tabScroll")).minX)
                        }
                    )
                }
                .coordinateSpace(name: "tabScroll")
                .background(
                    GeometryReader { viewportGeo in
                        Color.clear
                            .preference(key: TabVisibleWidthKey.self, value: viewportGeo.size.width)
                    }
                )
                .onPreferenceChange(TabContentWidthKey.self) { contentWidth = $0 }
                .onPreferenceChange(TabVisibleWidthKey.self) { visibleWidth = $0 }
                .onPreferenceChange(TabScrollOffsetKey.self) { scrollOffset = $0 }
                .onChange(of: sessions.selectedTabId) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }

            // Left chevron — visible only when there's content scrolled
            // off the left edge. Click scrolls back.
            if scrollOffset > 4 {
                ScrollCueChevron(direction: .leading)
            }
            // Right chevron — visible when there's more content off the
            // right edge.
            if contentWidth - scrollOffset - visibleWidth > 4 {
                HStack { Spacer(); ScrollCueChevron(direction: .trailing) }
            }
        }
    }
}

/// Subtle gradient + chevron at the edge of the tab bar, visible only
/// when there are tabs scrolled off in that direction. Pure visual cue —
/// click-through to the scroll content underneath.
private struct ScrollCueChevron: View {
    enum Direction { case leading, trailing }
    let direction: Direction

    var body: some View {
        ZStack(alignment: direction == .leading ? .leading : .trailing) {
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.12),
                    Color.primary.opacity(0.0),
                ],
                startPoint: direction == .leading ? .leading : .trailing,
                endPoint:   direction == .leading ? .trailing : .leading
            )
            .frame(width: 28)
            .allowsHitTesting(false)
            Image(systemName: direction == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .allowsHitTesting(false)
        }
    }
}

private struct TabContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TabVisibleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TabScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Receives a tab UUID payload and reorders the tab list to slot in at
/// the destination index. Built as a DropDelegate so dropEntered/exited
/// could later drive a live insertion-line preview; for now we just
/// commit on drop. Tab UUID strings are routed as `.text` to avoid the
/// `.url` parser SwiftUI uses for `.fileURL`.
private struct TabDropDelegate: DropDelegate {
    let destinationIndex: Int
    let sessions: TerminalSessions

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.text])
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let id = UUID(uuidString: str) else { return }
            DispatchQueue.main.async {
                sessions.moveTab(id, to: destinationIndex)
            }
        }
        return true
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let dot = tab.tagColor.swiftColor {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            if tab.panes.count > 1 {
                Image(systemName: tab.orientation == .horizontal
                      ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if tab.broadcastInput {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Broadcast input on — keystrokes go to all panes")
            }
            if isRenaming {
                TextField("Tab name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .focused($renameFocused)
                    .frame(minWidth: 60, idealWidth: 100)
                    .onSubmit { commitRename() }
                    // Esc cancels via .onExitCommand which fires inside
                    // a non-modal field reliably in macOS 15+.
                    .onExitCommand { isRenaming = false }
            } else {
                Text(displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            if tab.panes.count > 1 {
                Text("·\(tab.panes.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(isHovering || isActive ? 1.0 : 0.0)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close tab \(displayTitle)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? "Active tab: \(displayTitle)" : "Tab: \(displayTitle)")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isActive ? 0.12 : (isHovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        // Single tap selects. Double-tap-to-rename was removed —
        // SwiftUI's combined single+double tap gesture introduces a
        // ~250ms delay on every tab switch (waiting to see if a
        // second click arrives), and even with the delay users were
        // accidentally entering rename mode every time they
        // double-clicked too quickly to switch tabs. Rename lives in
        // the right-click context menu now — predictable, no
        // sensitivity, no delay on tab selection.
        .onTapGesture { onSelect() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Rename Tab…") { startRename() }
            Button("Duplicate Tab") {
                NotificationCenter.default.post(name: .terminalDuplicateTab, object: nil)
            }
            Button("Reveal cwd in Finder") {
                let url = URL(fileURLWithPath: tab.displayCwd)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Copy cwd path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(tab.displayCwd, forType: .string)
            }
            if tab.customTitle != nil {
                Button("Reset to auto title") { tab.customTitle = nil }
            }
            Divider()
            Menu("Tab Color") {
                ForEach(TabTagColor.allCases) { c in
                    Button(c.displayName) { tab.tagColor = c }
                }
            }
            Toggle("Broadcast Input to All Panes", isOn: $tab.broadcastInput)
            Divider()
            Button("Close Other Tabs") { onCloseOthers() }
            Button("Close Tab", role: .destructive) { onClose() }
        }
    }

    private func startRename() {
        renameDraft = tab.customTitle ?? displayTitle
        isRenaming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        isRenaming = false
    }

    private var displayTitle: String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        let base = (tab.displayCwd as NSString).lastPathComponent
        let title = tab.displayTitle
        if !base.isEmpty, title == "zsh" || title.isEmpty { return base }
        return title
    }
}
