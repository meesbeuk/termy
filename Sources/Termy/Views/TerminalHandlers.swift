import SwiftUI
import AppKit

/// Bundles all NotificationCenter / drop / lifecycle handlers for the
/// main terminal view. Split across two sub-modifiers so each is small enough
/// for the Swift type-checker to handle without choking.
struct TerminalHandlers: ViewModifier {
    let sessions: TerminalSessions
    let isKeyWindow: () -> Bool
    let hostedWindow: () -> NSWindow?
    let performFind: () -> Void
    let findFromSelection: () -> Void
    let handleDrop: ([NSItemProvider]) -> Bool
    let installKeyMonitor: () -> Void
    let removeKeyMonitor: () -> Void
    let showRecentDirs: () -> Void
    let showPalette: () -> Void
    let showCheatsheet: () -> Void
    let showSettings: () -> Void
    let showSessionLogs: () -> Void
    let showPasteHistory: () -> Void
    let showAgentPanel: () -> Void
    let showQuickSelect: () -> Void
    let showDiagnostics: () -> Void
    let showOnboarding: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(LifecycleAndDropHandlers(
                handleDrop: handleDrop,
                installKeyMonitor: installKeyMonitor,
                removeKeyMonitor: removeKeyMonitor
            ))
            .modifier(NotificationHandlersA(
                sessions: sessions,
                isKeyWindow: isKeyWindow,
                performFind: performFind,
                findFromSelection: findFromSelection
            ))
            .modifier(NotificationHandlersB(
                sessions: sessions,
                isKeyWindow: isKeyWindow,
                showRecentDirs: showRecentDirs,
                showPalette: showPalette,
                showCheatsheet: showCheatsheet,
                showSettings: showSettings,
                showSessionLogs: showSessionLogs,
                showPasteHistory: showPasteHistory,
                showAgentPanel: showAgentPanel,
                showQuickSelect: showQuickSelect
            ))
            .modifier(NotificationHandlersC(
                sessions: sessions,
                isKeyWindow: isKeyWindow,
                hostedWindow: hostedWindow,
                showDiagnostics: showDiagnostics,
                showOnboarding: showOnboarding
            ))
    }
}

private struct LifecycleAndDropHandlers: ViewModifier {
    let handleDrop: ([NSItemProvider]) -> Bool
    let installKeyMonitor: () -> Void
    let removeKeyMonitor: () -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            // Install lives on the hostedWindow .onChange in MainTerminalView
            // now — onAppear ran before WindowAccessor's async dispatch set
            // the window, so the monitor's window check no-op'd silently.
            .onDisappear { removeKeyMonitor() }
    }
}

private struct NotificationHandlersA: ViewModifier {
    let sessions: TerminalSessions
    let isKeyWindow: () -> Bool
    let performFind: () -> Void
    let findFromSelection: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .terminalNewTab)) { _ in
                guard isKeyWindow() else { return }
                // Consume any profile ID requested via the Dock menu, then
                // clear it so the next ⌘T uses the default profile again.
                if let id = TerminalAppDelegate.pendingDockProfileID {
                    TerminalAppDelegate.pendingDockProfileID = nil
                    let profile = sessions.profileStore?.profiles.first(where: { $0.id == id })
                    sessions.openTab(profile: profile)
                } else {
                    sessions.openTab()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalCloseTab)) { _ in
                if isKeyWindow() { sessions.closeCurrent() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalNextTab)) { _ in
                if isKeyWindow() { sessions.nextTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalPreviousTab)) { _ in
                if isKeyWindow() { sessions.previousTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalSelectTab)) { notification in
                guard isKeyWindow(), let n = notification.object as? Int else { return }
                sessions.selectTabByPosition(n)
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalClear)) { _ in
                if isKeyWindow() { sessions.clearCurrent() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleFind)) { _ in
                if isKeyWindow() { performFind() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalFindSelection)) { _ in
                if isKeyWindow() { findFromSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalSplitHorizontal)) { _ in
                if isKeyWindow() { sessions.splitHorizontal() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalSplitVertical)) { _ in
                if isKeyWindow() { sessions.splitVertical() }
            }
    }
}

private struct NotificationHandlersB: ViewModifier {
    let sessions: TerminalSessions
    let isKeyWindow: () -> Bool
    let showRecentDirs: () -> Void
    let showPalette: () -> Void
    let showCheatsheet: () -> Void
    let showSettings: () -> Void
    let showSessionLogs: () -> Void
    let showPasteHistory: () -> Void
    let showAgentPanel: () -> Void
    let showQuickSelect: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .terminalFocusNextPane)) { _ in
                if isKeyWindow() { sessions.focusNextPane() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalFocusPreviousPane)) { _ in
                if isKeyWindow() { sessions.focusPreviousPane() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalDuplicateTab)) { _ in
                if isKeyWindow() { sessions.duplicateCurrentTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalReopenClosed)) { _ in
                if isKeyWindow() { sessions.reopenLastClosedTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalRecentDirs)) { _ in
                if isKeyWindow() { showRecentDirs() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenPalette)) { _ in
                if isKeyWindow() { showPalette() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenCheatsheet)) { _ in
                if isKeyWindow() { showCheatsheet() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenSettings)) { _ in
                if isKeyWindow() { showSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenSessionLogs)) { _ in
                if isKeyWindow() { showSessionLogs() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenPasteHistory)) { _ in
                if isKeyWindow() { showPasteHistory() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalJumpPrevPrompt)) { _ in
                guard isKeyWindow(),
                      let view = sessions.currentSession?.terminalView as? TermyTerminalView else { return }
                view.jumpToPreviousPrompt()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalJumpNextPrompt)) { _ in
                guard isKeyWindow(),
                      let view = sessions.currentSession?.terminalView as? TermyTerminalView else { return }
                view.jumpToNextPrompt()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenAgentPanel)) { _ in
                if isKeyWindow() { showAgentPanel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenQuickSelect)) { _ in
                if isKeyWindow() { showQuickSelect() }
            }
    }
}

/// New-in-v0.11 handlers (Diagnostics, onboarding, scroll, copy, termy://,
/// always-on-top toggle). Split from NotificationHandlersB so neither
/// modifier's `body` exceeds Swift's chained-modifier type-check budget.
/// Adding more here is fine until ~15-ish onReceives; beyond that, split
/// again.
private struct NotificationHandlersC: ViewModifier {
    let sessions: TerminalSessions
    let isKeyWindow: () -> Bool
    let hostedWindow: () -> NSWindow?
    let showDiagnostics: () -> Void
    let showOnboarding: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenDiagnostics)) { _ in
                if isKeyWindow() { showDiagnostics() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalShowOnboarding)) { _ in
                if isKeyWindow() { showOnboarding() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalCopyScrollback)) { _ in
                if isKeyWindow() { sessions.copyCurrentScrollback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalScrollToTop)) { _ in
                if isKeyWindow() { sessions.scrollActiveToTop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalScrollToBottom)) { _ in
                if isKeyWindow() { sessions.scrollActiveToBottom() }
            }
            // LaunchServices handed us files to open (Finder double-click on
            // .sh, .command, +x binary). Only the key window opens the tabs
            // so each file produces exactly one tab regardless of how many
            // windows Termy has open.
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenFiles)) { _ in
                guard isKeyWindow() else { return }
                let urls = TerminalAppDelegate.pendingOpenURLs
                TerminalAppDelegate.pendingOpenURLs.removeAll()
                for url in urls { sessions.openFile(url) }
            }
            // termy:// URLs — `termy://open?cwd=…`, `termy://run?command=…&cwd=…`,
            // `termy://new`, `termy://palette`. Same key-window-only drain
            // pattern so a queue handed in during cold launch doesn't fire
            // in every restored window.
            .onReceive(NotificationCenter.default.publisher(for: .terminalOpenTermyURL)) { _ in
                guard isKeyWindow() else { return }
                let urls = TerminalAppDelegate.pendingTermyURLs
                TerminalAppDelegate.pendingTermyURLs.removeAll()
                for url in urls { TermyURLDispatcher.handle(url, in: sessions) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleAlwaysOnTop)) { _ in
                guard isKeyWindow(), let window = hostedWindow() else { return }
                Self.toggleAlwaysOnTop(window)
            }
    }

    /// Hoisted into a static helper so it lives outside the @ViewBuilder
    /// expression tree — the inline ternary inside an onReceive closure
    /// was tipping the type checker over its complexity budget.
    private static func toggleAlwaysOnTop(_ window: NSWindow) {
        // .floating keeps the window above all normal windows;
        // .normal sends it back into the standard z-order.
        let newLevel: NSWindow.Level = (window.level == .floating) ? .normal : .floating
        window.level = newLevel
    }
}
