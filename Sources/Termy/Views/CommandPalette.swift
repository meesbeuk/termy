import SwiftUI

/// Fuzzy command palette. ⌘⇧P. Chrome matches Settings (DSModal shell + same
/// header / footer / padding tokens) so the whole app reads as one design.
struct CommandPalette: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    // NEW WorkflowStore (Sources/Termy/State/Workflows.swift) — NOT the
    // 2025-deleted Workflow.swift seeded store. This one only reads
    // YAML files from ~/.termy/workflows/ and project-local
    // .termy/workflows/, never injects defaults.
    @EnvironmentObject var workflows: WorkflowStore
    @EnvironmentObject var layouts: LayoutStore
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selected: Int = 0
    @State private var filter: PaletteFilter = .all
    @FocusState private var focused: Bool
    /// Cached SSH hosts so we don't re-parse `~/.ssh/config` on every
    /// keystroke. The palette stays open just long enough that the user's
    /// ssh config isn't going to change under us; if they edit it while
    /// the palette is open they can reopen to refresh.
    @State private var sshHosts: [SSHHost] = []

    var body: some View {
        // Chrome mirrors the Settings sheet exactly: same size, single divider
        // after the header, no internal dividers. Footer hint sits inline at
        // the bottom of the body as muted text (Settings has no footer bar).
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.3)
                content
            }
        }
        .frame(maxWidth: 640, maxHeight: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear {
            focused = true
            // Load SSH hosts once per palette open — off the main thread
            // since it walks the filesystem for `Include` globs.
            Task.detached(priority: .userInitiated) {
                let hosts = SSHHostsReader.read()
                await MainActor.run { sshHosts = hosts }
            }
        }
        // Hidden buttons with keyboard shortcuts — onKeyPress doesn't fire
        // when a TextField has focus (the TextField swallows the event), so
        // we route Escape / Return / Arrows through Buttons which respect
        // shortcuts regardless of focus.
        .background(
            Group {
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    // Clamp in case state lags filter / query updates by a
                    // frame — better than a crash if `selected` somehow
                    // drifted past `filtered.count`.
                    guard !filtered.isEmpty else { return }
                    let idx = min(max(selected, 0), filtered.count - 1)
                    commit(filtered[idx])
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { selected = (selected + 1) % filtered.count }
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { selected = (selected - 1 + filtered.count) % filtered.count }
                }
                .keyboardShortcut(.upArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
        .onChange(of: query) { _, _ in selected = 0 }
        // Switching the sidebar filter can shrink the result list to fewer
        // items than the previous `selected` index — without resetting,
        // pressing ↵ would crash on `filtered[selected]`.
        .onChange(of: filter) { _, _ in selected = 0 }
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "command")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.secondary)
                Text("Command Palette")
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    /// Sidebar mirrors the Settings sheet — list of result-kind filters with
    /// the same row treatment, width, and material so the two modals read as
    /// the same shell with different content.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(PaletteFilter.allCases) { f in
                PaletteSidebarRow(
                    title: f.displayName,
                    icon: f.icon,
                    count: countFor(f),
                    isSelected: filter == f,
                    onTap: { filter = f }
                )
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.m)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 170)
        .background(.thickMaterial.opacity(0.3))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            // Search field styled as inline row, no surrounding divider —
            // Settings doesn't use internal dividers.
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .focused($focused)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { idx, item in
                        CommandRow(item: item,
                                   isSelected: idx == selected,
                                   onPick: { commit(item) })
                    }
                }
            }

            HStack(spacing: DS.Spacing.m) {
                Text("↑↓ navigate · ↵ run · ⎋ close")
                Spacer()
                Text("\(filtered.count) results")
            }
            .font(DS.Typo.tiny)
            .foregroundStyle(DS.Colors.tertiary)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func countFor(_ f: PaletteFilter) -> Int {
        switch f {
        case .all: return allItems.count
        case .tabs: return allItems.filter { $0.kind == .tab }.count
        case .themes: return allItems.filter { $0.kind == .theme }.count
        case .actions: return allItems.filter { $0.kind == .action }.count
        case .ssh: return allItems.filter { $0.kind == .ssh }.count
        case .workflows: return allItems.filter { $0.kind == .workflow }.count
        }
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        for (i, tab) in sessions.tabs.enumerated() {
            let title = (tab.displayCwd as NSString).lastPathComponent
            items.append(PaletteItem(kind: .tab,
                                     title: "Switch to tab \(i + 1) · \(title)",
                                     subtitle: tab.displayCwd,
                                     action: { sessions.selectTab(tab.id) }))
        }
        for theme in TerminalTheme.all {
            items.append(PaletteItem(kind: .theme,
                                     title: "Theme: \(theme.name)",
                                     subtitle: theme.category.rawValue,
                                     action: { settings.themeID = theme.id }))
        }
        items.append(PaletteItem(kind: .action, title: "New Tab", subtitle: "⌘T",
                                 action: { sessions.openTab() }))
        items.append(PaletteItem(kind: .action, title: "Duplicate Tab", subtitle: "⌘⇧T",
                                 action: { sessions.duplicateCurrentTab() }))
        if sessions.canReopenClosedTab {
            items.append(PaletteItem(kind: .action, title: "Reopen Closed Tab",
                                     subtitle: "⌘⇧Z — restore the most recently closed tab",
                                     action: { sessions.reopenLastClosedTab() }))
        }
        items.append(PaletteItem(kind: .action, title: "Split Horizontally", subtitle: "⌘D",
                                 action: { sessions.splitHorizontal() }))
        items.append(PaletteItem(kind: .action, title: "Split Vertically", subtitle: "⌘⇧D",
                                 action: { sessions.splitVertical() }))
        if (sessions.currentTab?.panes.count ?? 0) > 1 {
            items.append(PaletteItem(kind: .action, title: "Focus Next Pane", subtitle: "⌘⌥]",
                                     action: { sessions.focusNextPane() }))
            items.append(PaletteItem(kind: .action, title: "Focus Previous Pane", subtitle: "⌘⌥[",
                                     action: { sessions.focusPreviousPane() }))
            items.append(PaletteItem(kind: .action, title: "Zoom / Restore Pane", subtitle: "⌘⇧↩",
                                     action: { sessions.toggleZoomActivePane() }))
            items.append(PaletteItem(kind: .action, title: "Send Text to Pane…", subtitle: "⌘⇧S",
                                     action: { NotificationCenter.default.post(name: .terminalSendToPane, object: nil) }))
        }
        // Layouts — spawn any named layout (Quad Claude & co.) straight from
        // the palette, plus a visible entry to open the full picker.
        for layout in layouts.all {
            items.append(PaletteItem(kind: .action, title: "Layout: \(layout.name)",
                                     subtitle: "\(layout.shapeLabel) · \(layout.id == layouts.quickLayoutID ? "⌘⌥N" : "spawn")",
                                     action: { sessions.spawnLayout(layout) }))
        }
        items.append(PaletteItem(kind: .action, title: "Layout Picker…",
                                 subtitle: "Browse, edit & save layouts",
                                 action: { NotificationCenter.default.post(name: .terminalOpenLayoutPicker, object: nil) }))
        items.append(PaletteItem(kind: .action, title: "Agent Dashboard…",
                                 subtitle: "⌘⌥A — every pane's state at a glance",
                                 action: { NotificationCenter.default.post(name: .terminalOpenAgentDashboard, object: nil) }))
        items.append(PaletteItem(kind: .action, title: "Show Image…",
                                 subtitle: "Render a local image inline (iTerm2/kitty protocol)",
                                 action: { NotificationCenter.default.post(name: .terminalShowImage, object: nil) }))
        items.append(PaletteItem(kind: .action, title: "Command Blocks…",
                                 subtitle: "⌘⇧B — collapsible command + output history (OSC 133)",
                                 action: { NotificationCenter.default.post(name: .terminalToggleCommandBlocks, object: nil) }))
        items.append(PaletteItem(kind: .action, title: "Clear", subtitle: "⌘K",
                                 action: { sessions.clearCurrent() }))
        items.append(PaletteItem(kind: .action, title: "Toggle Vibecoder Mode",
                                 subtitle: settings.vibecoderMode ? "Currently: on" : "Currently: off",
                                 action: { settings.vibecoderMode.toggle() }))
        items.append(PaletteItem(kind: .action, title: "Toggle Broadcast Input",
                                 subtitle: "Mirror keys to all panes in this tab",
                                 action: { sessions.currentTab?.broadcastInput.toggle() }))
        // Trigger packs — one row per pack so the user can flip them
        // without opening Settings. Subtitle reports current state.
        for pack in TriggerPack.allCases {
            let registry = TriggerRegistry.shared
            let isOn = registry.enabledPacks.contains(pack)
            items.append(PaletteItem(
                kind: .action,
                title: "\(isOn ? "Disable" : "Enable") triggers: \(pack.name)",
                subtitle: pack.description,
                action: { registry.setPack(pack, enabled: !isOn) }
            ))
        }
        items.append(PaletteItem(kind: .action, title: "Session Logs",
                                 subtitle: "⌘⇧L — browse past recordings",
                                 action: {
            NotificationCenter.default.post(name: .terminalOpenSessionLogs, object: nil)
        }))
        items.append(PaletteItem(kind: .action, title: "Diagnostics",
                                 subtitle: "What Termy advertises to tools — paste in a GitHub issue",
                                 action: {
            NotificationCenter.default.post(name: .terminalOpenDiagnostics, object: nil)
        }))
        items.append(PaletteItem(kind: .action, title: "Settings",
                                 subtitle: "⌘, — preferences, themes, profiles, notifications",
                                 action: {
            NotificationCenter.default.post(name: .terminalOpenSettings, object: nil)
        }))
        items.append(PaletteItem(kind: .action, title: "Keyboard Cheatsheet",
                                 subtitle: "⌘/ — every shortcut Termy knows",
                                 action: {
            NotificationCenter.default.post(name: .terminalOpenCheatsheet, object: nil)
        }))
        if let store = sessions.profileStore {
            items.append(PaletteItem(kind: .action, title: "Quake Drop-down",
                                     subtitle: "⌃` — slide-in terminal panel",
                                     action: {
                QuickTerminalController.shared.toggle(settings: settings, profiles: store)
            }))
        }
        items.append(PaletteItem(kind: .action, title: "Toggle Always on Top",
                                 subtitle: "Pin this window above all others",
                                 action: {
            NotificationCenter.default.post(name: .terminalToggleAlwaysOnTop, object: nil)
        }))
        items.append(PaletteItem(kind: .action, title: "Copy Scrollback",
                                 subtitle: "Copy the active pane's full scrollback to the clipboard",
                                 action: {
            NotificationCenter.default.post(name: .terminalCopyScrollback, object: nil)
        }))
        for host in sshHosts {
            items.append(PaletteItem(kind: .ssh,
                                     title: "SSH: \(host.alias)",
                                     subtitle: host.sshCommand,
                                     action: { sessions.sendToActivePane(host.sshCommand) }))
        }
        // YAML-defined workflows from ~/.termy/workflows/. Argument
        // placeholders use their default values when fired from the
        // palette — UI for interactive arg-fill is the next iteration.
        for wf in workflows.workflows {
            let subtitle = wf.description.isEmpty
                ? wf.command
                : "\(wf.description) — \(wf.command)"
            items.append(PaletteItem(kind: .workflow,
                                     title: "Workflow: \(wf.name)",
                                     subtitle: subtitle,
                                     action: {
                let resolved = WorkflowStore.resolve(wf, values: [:])
                sessions.sendToActivePane(resolved)
            }))
        }
        return items
    }

    private var filtered: [PaletteItem] {
        let scoped: [PaletteItem]
        switch filter {
        case .all: scoped = allItems
        case .tabs: scoped = allItems.filter { $0.kind == .tab }
        case .themes: scoped = allItems.filter { $0.kind == .theme }
        case .actions: scoped = allItems.filter { $0.kind == .action }
        case .ssh: scoped = allItems.filter { $0.kind == .ssh }
        case .workflows: scoped = allItems.filter { $0.kind == .workflow }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(scoped.prefix(60)) }
        return scoped.filter { item in
            item.title.lowercased().contains(q) ||
            item.subtitle.lowercased().contains(q)
        }
    }

    private func commit(_ item: PaletteItem) {
        item.action()
        onDismiss()
    }
}

enum PaletteFilter: String, CaseIterable, Identifiable {
    case all, tabs, themes, actions, ssh, workflows
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .tabs: return "Tabs"
        case .themes: return "Themes"
        case .actions: return "Actions"
        case .ssh: return "SSH Hosts"
        case .workflows: return "Workflows"
        }
    }
    var icon: String {
        switch self {
        case .all: return "command"
        case .tabs: return "rectangle.stack"
        case .themes: return "paintpalette"
        case .actions: return "bolt"
        case .ssh: return "network"
        case .workflows: return "wand.and.stars"
        }
    }
}

private struct PaletteSidebarRow: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typo.body)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
                Spacer()
                Text("\(count)")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isSelected ? DS.Colors.chipBgActive : (hovering ? DS.Colors.chipBgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

struct PaletteItem {
    enum Kind { case tab, theme, action, ssh, workflow }
    let kind: Kind
    let title: String
    let subtitle: String
    let action: () -> Void

    var icon: String {
        switch kind {
        case .tab: return "rectangle.stack"
        case .theme: return "paintpalette"
        case .action: return "command"
        case .ssh: return "network"
        case .workflow: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch kind {
        case .tab: return .blue
        case .theme: return .pink
        case .action: return DS.Colors.secondary
        case .ssh: return .green
        case .workflow: return .orange
        }
    }
}

private struct CommandRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(item.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Colors.primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Colors.tertiary)
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .background(
                isSelected ? DS.Colors.chipBgHover :
                    (hovering ? DS.Colors.chipBg : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}
