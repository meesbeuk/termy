import SwiftUI
import AppKit
import SwiftTerm

/// Top-level window content.
struct MainTerminalView: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    @State private var showingSettings = false
    @State private var showingAILauncher = false
    @State private var showingRecentDirs = false
    @State private var hostedWindow: NSWindow?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleStrip(showingSettings: $showingSettings,
                           showingAILauncher: $showingAILauncher)
                if settings.vibecoderMode {
                    VibecoderQuickLaunchRow(onLaunch: { launch($0) })
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                if settings.showTabBar {
                    TabBar()
                        .frame(height: 32)
                    Divider().opacity(0.25)
                }

                ZStack {
                    if let tab = sessions.currentTab {
                        PaneLayout(tab: tab, sessions: sessions, settings: settings)
                            .id(tab.id)
                            .padding(.horizontal, settings.paddingPreset.horizontal)
                            .padding(.vertical, settings.paddingPreset.vertical)
                    } else {
                        EmptyView()
                    }
                }

                if settings.showStatusBar {
                    Divider().opacity(0.25)
                    StatusBar()
                }
            }

            if showingAILauncher {
                ZStack {
                    Color.black.opacity(0.10).ignoresSafeArea()
                        .onTapGesture { showingAILauncher = false }
                    AILauncherPanel(
                        onDismiss: { showingAILauncher = false },
                        onLaunch: { launch($0) }
                    )
                }
                .transition(.opacity)
                .zIndex(10)
            }

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
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .frame(minWidth: 480, idealWidth: 920, maxWidth: .infinity,
               minHeight: 320, idealHeight: 620, maxHeight: .infinity)
        .background(WindowBackdrop(hostedWindow: $hostedWindow))
        .onReceive(NotificationCenter.default.publisher(for: .terminalNewTab)) { _ in
            if isKeyWindow { sessions.openTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalCloseTab)) { _ in
            if isKeyWindow { sessions.closeCurrent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalNextTab)) { _ in
            if isKeyWindow { sessions.nextTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalPreviousTab)) { _ in
            if isKeyWindow { sessions.previousTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalClear)) { _ in
            if isKeyWindow { sessions.clearCurrent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalToggleFind)) { _ in
            if isKeyWindow { performFind() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSplitHorizontal)) { _ in
            if isKeyWindow { sessions.splitHorizontal() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSplitVertical)) { _ in
            if isKeyWindow { sessions.splitVertical() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalFocusNextPane)) { _ in
            if isKeyWindow { sessions.focusNextPane() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalFocusPreviousPane)) { _ in
            if isKeyWindow { sessions.focusPreviousPane() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDuplicateTab)) { _ in
            if isKeyWindow { sessions.duplicateCurrentTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalRecentDirs)) { _ in
            if isKeyWindow { showingRecentDirs = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalOpenAILauncher)) { _ in
            if isKeyWindow { showingAILauncher = true }
        }
        .sheet(isPresented: $showingSettings) {
            TerminalSettingsSheet(onClose: { showingSettings = false })
                .environmentObject(settings)
        }
    }

    /// Send the launcher's CLI to the active pane as a typed command.
    private func launch(_ launcher: AILauncher) {
        sessions.sendToActivePane(launcher.commandPreview)
    }

    /// Only the currently-focused window should react to global notifications.
    /// Without this, every open window would fork a new tab on ⌘T.
    private var isKeyWindow: Bool {
        guard let host = hostedWindow else { return false }
        return host.isKeyWindow
    }

    private func performFind() {
        // SwiftTerm's TerminalView responds to performFindPanelAction(_:) and
        // dispatches on sender.tag, looking for NSFindPanelAction.showFindPanel.
        guard let view = sessions.currentSession?.terminalView else { return }
        view.window?.makeFirstResponder(view)
        let sender = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.performFindPanelAction(sender)
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
            // Base glass material — Apple's translucent layer.
            Rectangle()
                .fill(.ultraThinMaterial)
            // Single adaptive tint covering the whole window. Higher opacity
            // on light wallpapers (text gets contrast); lower on dark
            // (more glass through).
            Color.black.opacity(settings.effectiveOpacity)
        }
        .ignoresSafeArea()
        .background(WindowAccessor(hostedWindow: $hostedWindow))
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
    @Binding var showingAILauncher: Bool

    private var displayCwd: String {
        guard let path = sessions.currentSession?.cwd else { return "" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70, height: 28)
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(Int(settings.fontSize))pt")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let session = sessions.currentSession {
                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button(action: { showingAILauncher = true }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Launch AI tool (⌘L)")
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

// MARK: - Vibecoder quick-launch row

private struct VibecoderQuickLaunchRow: View {
    let onLaunch: (AILauncher) -> Void
    @State private var launchers: [AILauncher] = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(launchers) { launcher in
                LaunchChip(launcher: launcher, tint: tintFor(launcher.tint), onTap: { onLaunch(launcher) })
            }
            Spacer()
            if launchers.isEmpty {
                Text("No AI CLIs detected — install `claude`, `cursor`, etc.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { launchers = AILauncher.installed() }
    }

    /// Tiny chip view extracted so the parent's body type-checks in reasonable time.
    private struct LaunchChip: View {
        let launcher: AILauncher
        let tint: SwiftUI.Color
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 5) {
                    Image(systemName: launcher.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                    Text(launcher.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(SwiftUI.Color.primary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(SwiftUI.Color.primary.opacity(0.06), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Run \(launcher.cli) in active pane")
        }
    }

    private func tintFor(_ tint: AILauncherTint) -> SwiftUI.Color {
        switch tint {
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .red: return .red
        case .neutral: return .secondary
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
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) {
            if !cwds.isEmpty { onPick(cwds[selected]) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !cwds.isEmpty { selected = (selected + 1) % cwds.count }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !cwds.isEmpty { selected = (selected - 1 + cwds.count) % cwds.count }
            return .handled
        }
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions.tabs) { tab in
                    TabChip(tab: tab,
                            isActive: tab.id == sessions.selectedTabId,
                            onSelect: { sessions.selectTab(tab.id) },
                            onClose: { sessions.closeTab(tab.id) })
                }
                Button(action: { sessions.openTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.panes.count > 1 {
                Image(systemName: tab.orientation == .horizontal
                      ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(displayTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
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
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isActive ? 0.12 : (isHovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var displayTitle: String {
        let base = (tab.displayCwd as NSString).lastPathComponent
        let title = tab.displayTitle
        if !base.isEmpty, title == "zsh" || title.isEmpty { return base }
        return title
    }
}
