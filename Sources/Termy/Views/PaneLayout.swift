import SwiftUI

/// Renders a single tab's panes in a horizontal or vertical stack.
/// Single pane = no chrome; multiple panes = thin dividers between, and the
/// active pane gets a subtle accent border to make focus obvious.
struct PaneLayout: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        Group {
            if tab.panes.count == 1, let only = tab.panes.first {
                paneCell(only, single: true)
            } else if tab.orientation == .horizontal {
                HStack(spacing: 4) {
                    ForEach(Array(tab.panes.enumerated()), id: \.element.id) { idx, pane in
                        if idx > 0 { divider }
                        paneCell(pane, single: false)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(tab.panes.enumerated()), id: \.element.id) { idx, pane in
                        if idx > 0 { divider }
                        paneCell(pane, single: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func paneCell(_ pane: TerminalSession, single: Bool) -> some View {
        let isActive = pane.id == tab.activePaneId
        TerminalSurface(session: pane, sessions: sessions, settings: settings)
            .id(pane.id)
            // Per-pane minimum keeps splits from collapsing to an unusable
            // ~20-column terminal at minWindow widths.
            .frame(minWidth: 200, minHeight: 100)
            .overlay(
                Group {
                    if !single {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isActive ? Color.accentColor.opacity(0.55) : Color.clear,
                                lineWidth: 1
                            )
                    }
                }
            )
            .onTapGesture { tab.activePaneId = pane.id }
    }

    /// Uses `Color.primary` rather than hard-coded white so the divider stays
    /// visible on light themes (Solarized Light, GitHub Light, Gruvbox Light).
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(
                width: tab.orientation == .horizontal ? 1 : nil,
                height: tab.orientation == .vertical ? 1 : nil
            )
    }
}
