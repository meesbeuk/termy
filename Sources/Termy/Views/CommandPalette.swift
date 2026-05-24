import SwiftUI

/// Fuzzy command palette. ⌘⇧P. Chrome matches Settings (DSModal shell + same
/// header / footer / padding tokens) so the whole app reads as one design.
struct CommandPalette: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var workflows: WorkflowStore
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selected: Int = 0
    @State private var filter: PaletteFilter = .all
    @FocusState private var focused: Bool

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
        .frame(width: 640, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear { focused = true }
        // Hidden buttons with keyboard shortcuts — onKeyPress doesn't fire
        // when a TextField has focus (the TextField swallows the event), so
        // we route Escape / Return / Arrows through Buttons which respect
        // shortcuts regardless of focus.
        .background(
            Group {
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { commit(filtered[selected]) }
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
        case .workflows: return allItems.filter { $0.kind == .workflow }.count
        case .ssh: return allItems.filter { $0.kind == .ssh }.count
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
        items.append(PaletteItem(kind: .action, title: "Split Horizontally", subtitle: "⌘D",
                                 action: { sessions.splitHorizontal() }))
        items.append(PaletteItem(kind: .action, title: "Split Vertically", subtitle: "⌘⇧D",
                                 action: { sessions.splitVertical() }))
        items.append(PaletteItem(kind: .action, title: "Clear", subtitle: "⌘K",
                                 action: { sessions.clearCurrent() }))
        items.append(PaletteItem(kind: .action, title: "Toggle Vibecoder Mode",
                                 subtitle: settings.vibecoderMode ? "Currently: on" : "Currently: off",
                                 action: { settings.vibecoderMode.toggle() }))
        items.append(PaletteItem(kind: .action, title: "Toggle Broadcast Input",
                                 subtitle: "Mirror keys to all panes in this tab",
                                 action: { sessions.currentTab?.broadcastInput.toggle() }))
        for wf in workflows.workflows {
            items.append(PaletteItem(kind: .workflow,
                                     title: "Workflow: \(wf.name)",
                                     subtitle: wf.command,
                                     action: { sessions.sendToActivePane(wf.command) }))
        }
        for host in SSHHostsReader.read() {
            items.append(PaletteItem(kind: .ssh,
                                     title: "SSH: \(host.alias)",
                                     subtitle: host.sshCommand,
                                     action: { sessions.sendToActivePane(host.sshCommand) }))
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
        case .workflows: scoped = allItems.filter { $0.kind == .workflow }
        case .ssh: scoped = allItems.filter { $0.kind == .ssh }
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
    case all, tabs, themes, actions, workflows, ssh
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .tabs: return "Tabs"
        case .themes: return "Themes"
        case .actions: return "Actions"
        case .workflows: return "Workflows"
        case .ssh: return "SSH Hosts"
        }
    }
    var icon: String {
        switch self {
        case .all: return "command"
        case .tabs: return "rectangle.stack"
        case .themes: return "paintpalette"
        case .actions: return "bolt"
        case .workflows: return "wand.and.stars"
        case .ssh: return "network"
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
    enum Kind { case tab, theme, action, workflow, ssh }
    let kind: Kind
    let title: String
    let subtitle: String
    let action: () -> Void

    var icon: String {
        switch kind {
        case .tab: return "rectangle.stack"
        case .theme: return "paintpalette"
        case .action: return "command"
        case .workflow: return "bolt"
        case .ssh: return "network"
        }
    }

    var tint: Color {
        switch kind {
        case .tab: return .blue
        case .theme: return .pink
        case .action: return DS.Colors.secondary
        case .workflow: return .yellow
        case .ssh: return .green
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
