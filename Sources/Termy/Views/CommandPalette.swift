import SwiftUI

/// VSCode-style fuzzy command palette. ⌘⇧P. Indexes:
/// - All open tabs (jump to tab)
/// - Every theme (instant theme switch)
/// - Top-level actions (new tab, split, recent dirs, AI launcher, settings)
struct CommandPalette: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selected: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        DSModal(
            title: "Command Palette",
            titleIcon: "command",
            titleIconColor: DS.Colors.accent,
            footerHint: "↑↓ navigate  ·  ↵ run  ·  ⎋ close",
            onClose: onDismiss
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.body)
                    .focused($focused)

                ScrollView {
                    VStack(spacing: DS.Spacing.xxs) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { idx, item in
                            CommandRow(item: item, isSelected: idx == selected, onPick: { commit(item) })
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
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

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        // Tabs
        for (i, tab) in sessions.tabs.enumerated() {
            let title = (tab.displayCwd as NSString).lastPathComponent
            items.append(PaletteItem(
                kind: .tab,
                title: "Switch to tab \(i + 1) · \(title)",
                subtitle: tab.displayCwd,
                action: { sessions.selectTab(tab.id) }
            ))
        }
        // Themes
        for theme in TerminalTheme.all {
            items.append(PaletteItem(
                kind: .theme,
                title: "Theme: \(theme.name)",
                subtitle: theme.category.rawValue,
                action: { settings.themeID = theme.id }
            ))
        }
        // Top-level actions
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
        return items
    }

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(allItems.prefix(20)) }
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
    enum Kind { case tab, theme, action }
    let kind: Kind
    let title: String
    let subtitle: String
    let action: () -> Void

    var icon: String {
        switch kind {
        case .tab: return "rectangle.stack"
        case .theme: return "paintpalette"
        case .action: return "command"
        }
    }

    var tint: Color {
        switch kind {
        case .tab: return .blue
        case .theme: return .pink
        case .action: return DS.Colors.secondary
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
                    .font(.system(size: 12))
                    .foregroundStyle(item.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Colors.primary)
                    Text(item.subtitle)
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Colors.tertiary)
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isSelected || hovering ? DS.Colors.chipBgHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}
