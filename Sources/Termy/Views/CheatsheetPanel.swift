import SwiftUI

/// Modal sheet showing every keyboard shortcut and the icon that triggers
/// the same action — discoverability for users who don't read README.
struct CheatsheetPanel: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ForEach(sections, id: \.title) { section in
                        ShortcutSection(section: section)
                    }
                }
                .padding(DS.Spacing.xl)
            }
        }
        .frame(width: 520, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        // Hidden Esc dismiss (modal-level shortcut works because there's no
        // focused text field stealing keystrokes).
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

    private var sections: [Section] {
        [
            Section(title: "Tabs & windows", entries: [
                (label: "New tab", shortcut: "⌘T"),
                (label: "Duplicate tab", shortcut: "⌘⇧T"),
                (label: "Close pane (cascades to tab)", shortcut: "⌘W"),
                (label: "Close window", shortcut: "⌘⇧W"),
                (label: "Next / previous tab", shortcut: "⌘⇧] / ⌘⇧["),
                (label: "New window", shortcut: "⌘N"),
                (label: "Quake drop-down", shortcut: "⌃`"),
            ]),
            Section(title: "Splits", entries: [
                (label: "Split horizontally", shortcut: "⌘D"),
                (label: "Split vertically", shortcut: "⌘⇧D"),
                (label: "Focus next / previous pane", shortcut: "⌘⌥] / ⌘⌥["),
            ]),
            Section(title: "Search & navigation", entries: [
                (label: "Find in scrollback", shortcut: "⌘F"),
                (label: "Next / previous match", shortcut: "⌘G / ⌘⇧G"),
                (label: "Recent directories", shortcut: "⌘⌥/"),
                (label: "Command palette", shortcut: "⌘⇧P"),
            ]),
            Section(title: "Display", entries: [
                (label: "Clear screen", shortcut: "⌘K"),
                (label: "Increase font", shortcut: "⌘="),
                (label: "Decrease font", shortcut: "⌘-"),
                (label: "Reset font", shortcut: "⌘0"),
            ]),
        ]
    }

    struct Section {
        let title: String
        let entries: [(label: String, shortcut: String)]
    }
}

private struct ShortcutSection: View {
    let section: CheatsheetPanel.Section

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(section.title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .textCase(.uppercase)
                .opacity(0.7)
            VStack(spacing: DS.Spacing.xxs) {
                ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.label)
                            .font(DS.Typo.body)
                            .foregroundStyle(DS.Colors.primary)
                        Spacer()
                        Text(entry.shortcut)
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
        }
    }
}
