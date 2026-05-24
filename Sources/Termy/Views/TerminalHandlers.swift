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
                hostedWindow: hostedWindow,
                showRecentDirs: showRecentDirs,
                showPalette: showPalette,
                showCheatsheet: showCheatsheet,
                showSettings: showSettings,
                showSessionLogs: showSessionLogs,
                showPasteHistory: showPasteHistory
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
    let hostedWindow: () -> NSWindow?
    let showRecentDirs: () -> Void
    let showPalette: () -> Void
    let showCheatsheet: () -> Void
    let showSettings: () -> Void
    let showSessionLogs: () -> Void
    let showPasteHistory: () -> Void

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
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleAlwaysOnTop)) { _ in
                guard isKeyWindow(), let window = hostedWindow() else { return }
                // .floating keeps the window above all normal windows;
                // .normal sends it back into the standard z-order. Toggle.
                window.level = (window.level == .floating) ? .normal : .floating
            }
            // Window resize is handled by SwiftTerm directly via autoresizing
            // mask set in TerminalSurface.makeNSView — no manual observer needed.
    }
}
