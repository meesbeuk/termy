import SwiftUI

/// Mission control for multiple agents: every pane across every tab in one
/// glanceable view, each tagged working / idle / waiting-for-input. Click a
/// row to focus that pane. Counts refresh on a 1s tick; rows also observe
/// their pane for instant state changes between ticks. Order is stable (by
/// tab then pane) so cards never jump out from under the pointer.
struct AgentDashboardView: View {
    @ObservedObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    struct PaneRef: Identifiable {
        let id: UUID
        let tabId: UUID
        let tabLabel: String
        let pane: TerminalSession
    }

    private var refs: [PaneRef] {
        var out: [PaneRef] = []
        for (ti, tab) in sessions.tabs.enumerated() {
            let name = tab.customTitle ?? tab.displayTitle
            for (pi, pane) in tab.panes.enumerated() {
                let label = tab.panes.count > 1 ? "\(name) · pane \(pi + 1)" : name
                out.append(PaneRef(id: pane.id, tabId: tab.id, tabLabel: "T\(ti + 1) — \(label)", pane: pane))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            TimelineView(.periodic(from: Date(), by: 1.0)) { _ in
                let rows = refs
                let waiting = rows.filter { $0.pane.activity == .waiting }.count
                let working = rows.filter { $0.pane.activity == .working }.count
                let idle = rows.count - waiting - working
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    header(total: rows.count, waiting: waiting, working: working, idle: idle)
                    ScrollView {
                        VStack(spacing: DS.Spacing.xs) {
                            ForEach(rows) { ref in
                                PaneStatusRow(
                                    pane: ref.pane,
                                    tabLabel: ref.tabLabel,
                                    isCurrent: ref.id == sessions.currentSession?.id,
                                    onFocus: {
                                        sessions.focusPane(tabId: ref.tabId, paneId: ref.id)
                                        onDismiss()
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
        }
        .padding(DS.Modal.padding)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
    }

    private func header(total: Int, waiting: Int, working: Int, idle: Int) -> some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.accent)
                Text("Agent Dashboard").font(DS.Typo.title)
                Text("\(total) pane\(total == 1 ? "" : "s")")
                    .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
            }
            Spacer()
            HStack(spacing: DS.Spacing.m) {
                if waiting > 0 { StatTag(count: waiting, label: "waiting", color: DS.Colors.aiAccent) }
                if working > 0 { StatTag(count: working, label: "working", color: DS.Colors.accent) }
                StatTag(count: idle, label: "idle", color: DS.Colors.secondary)
            }
            DSIconButton(icon: "xmark", action: onDismiss)
        }
    }
}

private struct StatTag: View {
    let count: Int; let label: String; let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label)").font(DS.Typo.tiny).foregroundStyle(DS.Colors.secondary)
        }
    }
}

/// One pane row. Observes its pane so the dot + pill + preview update the
/// instant the pane's state changes, independent of the dashboard's tick.
private struct PaneStatusRow: View {
    @ObservedObject var pane: TerminalSession
    let tabLabel: String
    let isCurrent: Bool
    let onFocus: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: DS.Spacing.m) {
                stateDot
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(tabLabel).font(DS.Typo.caption.weight(.medium)).lineLimit(1)
                        if isCurrent {
                            Text("active").font(DS.Typo.tiny)
                                .foregroundStyle(DS.Colors.accent)
                        }
                    }
                    Text(previewLine).font(DS.Typo.monoMicro).foregroundStyle(DS.Colors.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: DS.Spacing.s)
                statePill
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(hovering ? DS.Colors.chipBgHover
                          : (pane.activity == .waiting ? DS.Colors.aiAccent.opacity(0.10) : DS.Colors.chipBg))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .strokeBorder(pane.activity == .waiting ? DS.Colors.aiAccent.opacity(0.45) : Color.clear,
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
        .help("Focus this pane")
    }

    private var previewLine: String {
        let cwd = (pane.cwd as NSString).lastPathComponent
        if pane.activity == .working { return "working…  ~/\(cwd)" }
        if pane.lastLine.isEmpty { return "~/\(cwd)" }
        return pane.lastLine
    }

    private var stateColor: Color {
        switch pane.activity {
        case .waiting: return DS.Colors.aiAccent
        case .working: return DS.Colors.accent
        case .idle:    return DS.Colors.secondary
        }
    }

    private var stateDot: some View {
        Circle().fill(stateColor).frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
    }

    private var statePill: some View {
        Text(pane.activity.rawValue)
            .font(DS.Typo.tiny.weight(.semibold))
            .foregroundStyle(pane.activity == .idle ? DS.Colors.secondary : .white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(pane.activity == .idle ? DS.Colors.chipBg : stateColor))
    }
}
