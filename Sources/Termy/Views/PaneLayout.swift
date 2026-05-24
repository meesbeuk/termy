import SwiftUI

/// Renders a single tab's panes in a horizontal or vertical stack.
/// Single pane = no chrome; multiple panes = draggable resizable
/// dividers between (so the user can change a 50/50 split to 70/30 by
/// dragging), and the active pane gets a subtle accent border to make
/// focus obvious.
struct PaneLayout: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        Group {
            if tab.panes.count == 1, let only = tab.panes.first {
                paneCell(only, single: true)
            } else {
                GeometryReader { geo in
                    let isHorizontal = tab.orientation == .horizontal
                    let total = isHorizontal ? geo.size.width : geo.size.height
                    let fractions = normalisedFractions(panes: tab.panes.count)
                    let sizes = absoluteSizes(fractions: fractions, total: total)
                    Group {
                        if isHorizontal {
                            HStack(spacing: 0) { contents(sizes: sizes, isHorizontal: true, total: total) }
                        } else {
                            VStack(spacing: 0) { contents(sizes: sizes, isHorizontal: false, total: total) }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    /// The actual children for the H/V stack: each pane + a draggable
    /// resizer in between. Sizes are pre-computed from fractions so the
    /// drag can target a specific pair without re-measuring on each
    /// frame.
    @ViewBuilder
    private func contents(sizes: [CGFloat], isHorizontal: Bool, total: CGFloat) -> some View {
        ForEach(Array(tab.panes.enumerated()), id: \.element.id) { idx, pane in
            if idx > 0 {
                ResizableDivider(
                    isHorizontal: isHorizontal,
                    onDrag: { delta in resize(at: idx - 1, delta: delta, total: total) }
                )
            }
            paneCell(pane, single: false)
                .frame(
                    width: isHorizontal ? sizes[idx] : nil,
                    height: isHorizontal ? nil : sizes[idx]
                )
        }
    }

    /// Reads the tab's persisted fractions, defensively re-normalises if
    /// the length doesn't match the current pane count (split/close in
    /// flight, or restore from older saves). Mutates `tab.paneFractions`
    /// so subsequent renders see the correct count.
    private func normalisedFractions(panes count: Int) -> [CGFloat] {
        if tab.paneFractions.count != count {
            tab.paneFractions = TerminalTab.equalFractions(count: count)
        }
        let sum = tab.paneFractions.reduce(0, +)
        guard sum > 0 else { return TerminalTab.equalFractions(count: count) }
        return tab.paneFractions.map { $0 / sum }
    }

    private func absoluteSizes(fractions: [CGFloat], total: CGFloat) -> [CGFloat] {
        // Subtract divider widths so the panes + dividers exactly fill
        // the parent — without this, drag jitter accumulates rounding
        // error and the last pane drifts.
        let dividerCount = max(0, fractions.count - 1)
        let dividerWidth: CGFloat = 4
        let usable = max(0, total - CGFloat(dividerCount) * dividerWidth)
        return fractions.map { round($0 * usable) }
    }

    /// Drag handler: moves a fraction `delta` (signed, in absolute
    /// pixels) from pane `idx` to pane `idx+1`. Clamped so each pane
    /// can't go below 10% — small enough to fit a one-column terminal,
    /// large enough that the divider stays grabbable.
    private func resize(at idx: Int, delta: CGFloat, total: CGFloat) {
        guard total > 0, idx + 1 < tab.paneFractions.count else { return }
        let deltaFraction = delta / total
        let minFraction: CGFloat = 0.10
        var fractions = tab.paneFractions
        let newLeft = fractions[idx] + deltaFraction
        let newRight = fractions[idx + 1] - deltaFraction
        if newLeft < minFraction || newRight < minFraction { return }
        fractions[idx] = newLeft
        fractions[idx + 1] = newRight
        tab.paneFractions = fractions
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
            // panes. Hover-revealed so it doesn't clutter the active
            // workspace.
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
}

/// Draggable divider between two adjacent panes. Renders as a 1-px line
/// with a wider invisible hit zone so the cursor change feels generous.
/// Calls back with the absolute pixel delta along the orientation axis;
/// the parent maps that to a fraction shift.
private struct ResizableDivider: View {
    let isHorizontal: Bool
    let onDrag: (CGFloat) -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if isHorizontal {
                Rectangle()
                    .fill(Color.primary.opacity(hovering ? 0.25 : 0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle().offset(x: -2).size(CGSize(width: 5, height: 0)))
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(hovering ? 0.25 : 0.12))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle().offset(y: -2).size(CGSize(width: 0, height: 5)))
            }
        }
        .frame(width: isHorizontal ? 4 : nil, height: isHorizontal ? nil : 4)
        .background(Color.primary.opacity(0.001))  // make the whole 4px width grabbable
        .onHover { hovering in
            self.hovering = hovering
            // Cursor feedback so users discover it's draggable.
            if hovering {
                if isHorizontal { NSCursor.resizeLeftRight.set() }
                else { NSCursor.resizeUpDown.set() }
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let delta = isHorizontal ? value.translation.width : value.translation.height
                    onDrag(delta)
                }
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
