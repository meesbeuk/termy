import SwiftUI

/// Keyboard cheatsheet — discoverability for users who don't read README.
/// Restyled in v0.9.17 to match the Settings + Command Palette shell
/// (640×480, .regularMaterial, sidebar+detail) so the whole app's modal
/// chrome reads as one design system. Settings is the canonical reference.
struct CheatsheetPanel: View {
    let onDismiss: () -> Void

    @State private var selectedCategory: ShortcutCategory = .tabs

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.3)
                detail
            }
        }
        .frame(width: 640, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .background(
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Keyboard Shortcuts")
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ShortcutCategory.allCases) { cat in
                CheatsheetSidebarRow(
                    title: cat.title,
                    icon: cat.icon,
                    isSelected: cat == selectedCategory,
                    onTap: { selectedCategory = cat }
                )
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.m)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 170)
        .background(.thickMaterial.opacity(0.3))
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ForEach(selectedCategory.entries, id: \.label) { entry in
                    ShortcutRow(label: entry.label, shortcut: entry.shortcut)
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

enum ShortcutCategory: String, CaseIterable, Identifiable {
    case tabs, splits, search, display, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tabs: return "Tabs"
        case .splits: return "Splits"
        case .search: return "Search & nav"
        case .display: return "Display"
        case .window: return "Windows"
        }
    }
    var icon: String {
        switch self {
        case .tabs: return "rectangle.stack"
        case .splits: return "rectangle.split.2x1"
        case .search: return "magnifyingglass"
        case .display: return "textformat.size"
        case .window: return "macwindow"
        }
    }

    var entries: [(label: String, shortcut: String)] {
        switch self {
        case .tabs: return [
            ("New tab",                   "⌘T"),
            ("Duplicate tab",             "⌘⇧T"),
            ("Reopen closed tab",         "⌘⇧Z"),
            ("Close pane (cascades)",     "⌘W"),
            ("Next / previous tab",       "⌘⇧] / ⌘⇧["),
            ("Jump to tab 1-8",           "⌘1-8"),
            ("Jump to last tab",          "⌘9"),
            ("Rename tab",                "Double-click chip"),
        ]
        case .splits: return [
            ("Split horizontally",        "⌘D"),
            ("Split vertically",          "⌘⇧D"),
            ("Focus next pane",           "⌘⌥]"),
            ("Focus previous pane",       "⌘⌥["),
            ("Broadcast input toggle",    "Tab → right-click"),
        ]
        case .search: return [
            ("Find in scrollback",        "⌘F"),
            ("Next / previous match",     "⌘G / ⌘⇧G"),
            ("Recent directories",        "⌘⌥/"),
            ("Command palette",           "⌘⇧P"),
            ("Cheatsheet (this panel)",   "⌘/"),
        ]
        case .display: return [
            ("Clear screen",              "⌘K"),
            ("Increase font size",        "⌘="),
            ("Decrease font size",        "⌘-"),
            ("Reset font size",           "⌘0"),
            ("Settings",                  "⌘,"),
        ]
        case .window: return [
            ("New window",                "⌘N"),
            ("Close window",              "⌘⇧W"),
            ("Quake drop-down",           "⌃`"),
            ("Toggle always on top",      "Window menu"),
        ]
        }
    }
}

/// Mirrors the Settings/Palette SidebarRow exactly — same dimensions,
/// hover treatment, selection background. Different file to avoid leaking
/// the private struct, but pixel-identical.
private struct CheatsheetSidebarRow: View {
    let title: String
    let icon: String
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

private struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(DS.Typo.body)
                .foregroundStyle(DS.Colors.primary)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS.Colors.chipBg)
                )
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 4)
    }
}
