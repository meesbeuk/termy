import SwiftUI

/// Targeted send-to-pane — the focused complement to broadcast input. Pick one
/// pane (across any tab) and send it a line of text, submitted with a real
/// Enter via the same path Vibecoder uses. Handy for driving one Claude in a
/// Quad layout, or answering a single agent's y/n without leaving the keyboard.
struct SendToPaneView: View {
    @ObservedObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var text: String = ""
    @State private var target: UUID?
    @FocusState private var fieldFocused: Bool

    struct Row: Identifiable { let id: UUID; let tabId: UUID; let label: String; let pane: TerminalSession }

    private var rows: [Row] {
        var out: [Row] = []
        for (ti, tab) in sessions.tabs.enumerated() {
            let name = tab.customTitle ?? tab.displayTitle
            for (pi, pane) in tab.panes.enumerated() {
                let label = tab.panes.count > 1 ? "\(name) · pane \(pi + 1)" : name
                out.append(Row(id: pane.id, tabId: tab.id, label: "T\(ti + 1) — \(label)", pane: pane))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "paperplane").font(.system(size: 13)).foregroundStyle(DS.Colors.accent)
                    Text("Send Text to Pane").font(DS.Typo.title)
                }
                Spacer()
                DSIconButton(icon: "xmark", action: onDismiss)
            }

            DSFormRow("Target pane") {
                ScrollView {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(rows) { row in
                            paneRow(row)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            DSFormRow("Text", hint: "Sent with a real Return, like typing it into the pane.") {
                TextField("e.g. claude, or y to confirm", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.monoCaption)
                    .focused($fieldFocused)
                    .onSubmit(send)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || rows.isEmpty)
            }
        }
        .padding(DS.Modal.padding)
        .frame(width: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear {
            // Preselect the active pane; focus the text field straight away.
            target = sessions.currentSession?.id ?? rows.first?.id
            fieldFocused = true
        }
    }

    private func paneRow(_ row: Row) -> some View {
        let selected = row.id == target
        return Button { target = row.id } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11)).foregroundStyle(selected ? DS.Colors.accent : DS.Colors.tertiary)
                Text(row.label).font(DS.Typo.caption).lineLimit(1)
                Spacer()
                Text(row.pane.activity.rawValue).font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
            }
            .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.xs)
                .fill(selected ? DS.Colors.chipBgActive : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func send() {
        guard let target else { return }
        sessions.send(text: text, toPaneId: target)
        onDismiss()
    }
}
