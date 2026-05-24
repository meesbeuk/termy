import SwiftUI

/// ⌘⇧V picker showing the last N strings copied to the pasteboard.
/// Same chrome as Settings / Command Palette / Cheatsheet / Session
/// Logs (640×480, .regularMaterial, rounded modal, accent header).
/// Pick → sent to active pane. Recent on top.
struct PasteHistoryPicker: View {
    @EnvironmentObject var history: PasteHistoryStore
    @EnvironmentObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selected: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 640, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear { focused = true }
        .background(
            Group {
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { pick(filtered[selected]) }
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
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Paste History")
                    .font(DS.Typo.title)
            }
            Spacer()
            Button("Clear") { history.clear(); selected = 0 }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Filter clipboard history…", text: $query)
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
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 24))
                                .foregroundStyle(DS.Colors.tertiary)
                            Text(history.entries.isEmpty
                                 ? "Nothing on the clipboard yet."
                                 : "No matches.")
                                .font(DS.Typo.body)
                                .foregroundStyle(DS.Colors.tertiary)
                            if history.entries.isEmpty {
                                Text("Copy something — Termy keeps the last 20 items here.")
                                    .font(DS.Typo.tiny)
                                    .foregroundStyle(DS.Colors.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.xl)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, entry in
                            PasteRow(entry: entry,
                                     isSelected: idx == selected,
                                     onPick: { pick(entry) })
                        }
                    }
                }
            }

            HStack(spacing: DS.Spacing.m) {
                Text("↑↓ navigate · ↵ paste into active pane · ⎋ close")
                Spacer()
                Text("\(filtered.count) of \(history.entries.count)")
            }
            .font(DS.Typo.tiny)
            .foregroundStyle(DS.Colors.tertiary)
        }
        .padding(DS.Spacing.xl)
    }

    private var filtered: [PasteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.preview.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    private func pick(_ entry: PasteEntry) {
        sessions.sendToActivePane(entry.text)
        onDismiss()
    }
}

private struct PasteRow: View {
    let entry: PasteEntry
    let isSelected: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.tertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.Colors.primary)
                        .lineLimit(1)
                    Text(entry.sizeString)
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
                isSelected ? DS.Colors.chipBgHover
                    : (hovering ? DS.Colors.chipBg : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
        .contextMenu {
            Button("Paste") { onPick() }
            Button("Copy to clipboard") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.text, forType: .string)
            }
        }
    }
}
