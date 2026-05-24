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
    @State private var hostedWindow: NSWindow?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleStrip(
                    showingSettings: $showingSettings,
                    showLaunchers: settings.vibecoderMode,
                    onLaunch: { launch($0) }
                )
                if settings.showTabBar {
                    TabBar()
                        .frame(height: 32)
                    Divider().opacity(0.25)
                }

                ZStack {
                    if let tab = sessions.currentTab {
                        // No .id() — letting SwiftUI diff in place keeps the
                        // terminal NSView alive across renders so the grid
                        // doesn't get re-instantiated and double-render stale
                        // text on resize.
                        PaneLayout(tab: tab, sessions: sessions, settings: settings)
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
            // Push the VStack up into the title-bar inset so the title strip
            // (with the launchers row) renders at y=0 of the window, level
            // with the traffic lights. Without this, SwiftUI's default safe
            // area pushes the title strip below the traffic lights and the
            // launchers end up in a band beneath them.
            .ignoresSafeArea(.container, edges: .top)

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

            if showingPalette {
                ZStack {
                    Color.black.opacity(0.10).ignoresSafeArea()
                        .onTapGesture { showingPalette = false }
                    CommandPalette(onDismiss: { showingPalette = false })
                        .environmentObject(sessions)
                        .environmentObject(settings)
                        .environmentObject(workflows)
                }
                .transition(.opacity)
                .zIndex(11)
            }
        }
        .frame(minWidth: 480, idealWidth: 920, maxWidth: .infinity,
               minHeight: 320, idealHeight: 620, maxHeight: .infinity)
        .background(WindowBackdrop(hostedWindow: $hostedWindow))
        // Forward the captured NSWindow down so closeTab can target the
        // right window in multi-window setups (NSApp.keyWindow can be a sibling).
        .onChange(of: hostedWindow) { _, new in sessions.hostedWindow = new }
        .modifier(TerminalHandlers(
            sessions: sessions,
            isKeyWindow: { isKeyWindow },
            hostedWindow: { hostedWindow },
            performFind: performFind,
            handleDrop: handleDrop,
            installKeyMonitor: installKeyMonitor,
            removeKeyMonitor: removeKeyMonitor,
            showRecentDirs: { showingRecentDirs = true },
            showPalette: { showingPalette = true }
        ))
        .sheet(isPresented: $showingSettings) {
            TerminalSettingsSheet(onClose: { showingSettings = false })
                .environmentObject(settings)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window == hostedWindow,
                  let tab = sessions.currentTab, tab.broadcastInput,
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

    var body: some View {
        HStack(spacing: 12) {
            // ~52pt for the three traffic-light buttons + comfortable
            // breathing room before the launcher row so the chrome doesn't
            // look cramped against the window controls.
            Color.clear.frame(width: 72, height: 28)
            if showLaunchers {
                InlineLaunchersRow(onLaunch: onLaunch)
            }
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
        .frame(height: 36)
    }
}

/// Compact launchers row that lives inline in the title strip, no separate band.
/// On hover, the active tool's display name appears as an inline pill next to
/// the row — no floating overlay that can get clipped by neighbouring views.
private struct InlineLaunchersRow: View {
    let onLaunch: (AILauncher) -> Void
    @State private var launchers: [AILauncher] = []
    @State private var hoveredID: String?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(launchers) { launcher in
                InlineLaunchChip(
                    launcher: launcher,
                    isHovered: hoveredID == launcher.id,
                    onTap: { onLaunch(launcher) },
                    onHoverChanged: { hovering in
                        if hovering { hoveredID = launcher.id }
                        else if hoveredID == launcher.id { hoveredID = nil }
                    }
                )
            }
            if let id = hoveredID,
               let l = launchers.first(where: { $0.id == id }) {
                Text(l.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(SwiftUI.Color.white.opacity(0.12))
                    )
                    .transition(.opacity)
                    .fixedSize()
            }
        }
        .animation(.easeOut(duration: 0.10), value: hoveredID)
        .onAppear { launchers = AILauncher.installed() }
    }
}

private struct InlineLaunchChip: View {
    let launcher: AILauncher
    let isHovered: Bool
    let onTap: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Button(action: onTap) {
            BrandIcon(assetName: launcher.brandAsset,
                      fallbackSymbol: launcher.icon,
                      size: 13)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(SwiftUI.Color.white.opacity(isHovered ? 0.18 : 0.08))
                )
                .overlay(
                    Circle().strokeBorder(SwiftUI.Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(launcher.displayName) — run `\(launcher.cli)` in active pane")
        .onHover(perform: onHoverChanged)
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
        .contextMenu {
            Menu("Tab Color") {
                ForEach(TabTagColor.allCases) { c in
                    Button(c.displayName) { tab.tagColor = c }
                }
            }
            Toggle("Broadcast Input to All Panes", isOn: $tab.broadcastInput)
        }
    }

    private var displayTitle: String {
        let base = (tab.displayCwd as NSString).lastPathComponent
        let title = tab.displayTitle
        if !base.isEmpty, title == "zsh" || title.isEmpty { return base }
        return title
    }
}
