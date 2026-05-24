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
            // Per-pane close × in the top-right when the tab has multiple
            // panes. Without it, users have to know "click the pane to
            // focus, then ⌘W" — non-obvious. The × hovers in over the
            // terminal area and only appears on hover so it doesn't
            // clutter the active workspace.
            .overlay(alignment: .topTrailing) {
                if !single {
                    PaneCloseButton {
                        sessions.closePane(pane.id)
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                }
            }
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

/// Per-pane close button. Hover-revealed so it doesn't decorate the
/// terminal when not needed. Sized ~18pt, glass-backed for legibility on
/// any terminal background, accessible.
private struct PaneCloseButton: View {
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .opacity(hovering ? 0.95 : 0.55)
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close this pane")
        .accessibilityLabel("Close pane")
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}
