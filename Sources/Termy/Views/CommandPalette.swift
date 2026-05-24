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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            searchField
            Divider().opacity(0.3)
            list
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 560, height: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) {
            if !filtered.isEmpty { commit(filtered[selected]) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !filtered.isEmpty { selected = (selected + 1) % filtered.count }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !filtered.isEmpty { selected = (selected - 1 + filtered.count) % filtered.count }
            return .handled
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "command")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Command Palette")
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    private var searchField: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.tertiary)
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Typo.body)
                .focused($focused)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(filtered.enumerated()), id: \.offset) { idx, item in
                    CommandRow(item: item, isSelected: idx == selected, onPick: { commit(item) })
                }
            }
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.m) {
            Text("↑↓ navigate")
            Text("·")
            Text("↵ run")
            Text("·")
            Text("⎋ close")
            Spacer()
            Text("\(filtered.count) results")
        }
        .font(DS.Typo.tiny)
        .foregroundStyle(DS.Colors.tertiary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
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
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(allItems.prefix(40)) }
        return allItems.filter { item in
            item.title.lowercased().contains(q) ||
            item.subtitle.lowercased().contains(q)
        }
    }

    private func commit(_ item: PaletteItem) {
        item.action()
        onDismiss()
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
