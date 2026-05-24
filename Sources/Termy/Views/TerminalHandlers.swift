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
    let handleDrop: ([NSItemProvider]) -> Bool
    let installKeyMonitor: () -> Void
    let removeKeyMonitor: () -> Void
    let showRecentDirs: () -> Void
    let showPalette: () -> Void

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
                performFind: performFind
            ))
            .modifier(NotificationHandlersB(
                sessions: sessions,
                isKeyWindow: isKeyWindow,
                hostedWindow: hostedWindow,
                showRecentDirs: showRecentDirs,
                showPalette: showPalette
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
            .onAppear { installKeyMonitor() }
            .onDisappear { removeKeyMonitor() }
    }
}

private struct NotificationHandlersA: ViewModifier {
    let sessions: TerminalSessions
    let isKeyWindow: () -> Bool
    let performFind: () -> Void

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
            .onReceive(NotificationCenter.default.publisher(for: .terminalClear)) { _ in
                if isKeyWindow() { sessions.clearCurrent() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleFind)) { _ in
                if isKeyWindow() { performFind() }
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
            // Window resize is handled by SwiftTerm directly via autoresizing
            // mask set in TerminalSurface.makeNSView — no manual observer needed.
    }
}
