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
        // Always render through the same GeometryReader + ForEach path,
        // even for a single pane. The earlier fast-path that returned
        // `paneCell(only)` directly for the single-pane case meant that
        // switching between two single-pane tabs left the same
        // NSViewRepresentable position in place — SwiftUI would call
        // updateNSView with the new session but never makeNSView, so the
        // old tab's NSView stayed mounted and displayed while the new
        // tab's TerminalSession.terminalView remained nil (no shell
        // ever started). Same root cause wiped history on the first
        // split: going from the direct paneCell branch to the ForEach
        // branch was a structural change that tore down the existing
        // pane's view tree position. Unifying the path makes
        // ForEach's `id: \.element.id` the sole identity source, so
        // both tab switches and splits diff correctly per pane.
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

    /// The actual children for the H/V stack: each pane + a draggable
    /// resizer in between. Sizes are pre-computed from fractions so the
    /// drag can target a specific pair without re-measuring on each
    /// frame.
    @ViewBuilder
    private func contents(sizes: [CGFloat], isHorizontal: Bool, total: CGFloat) -> some View {
        let single = tab.panes.count == 1
        ForEach(Array(tab.panes.enumerated()), id: \.element.id) { idx, pane in
            if idx > 0 {
                ResizableDivider(
                    isHorizontal: isHorizontal,
                    onDrag: { delta in resize(at: idx - 1, delta: delta, total: total) }
                )
            }
            paneCell(pane, single: single)
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
        PaneCellView(
            pane: pane,
            tab: tab,
            sessions: sessions,
            settings: settings,
            single: single,
            copySelection: { copySelection(from: $0) },
            pasteInto: { pasteInto(pane: $0) },
            selectAll: { selectAll(in: $0) },
            hasSelection: { hasSelection(in: $0) }
        )
    }

    /// SwiftTerm's `selection` is internal — we can't query it directly.
    /// Always enable Copy; if there's no selection SwiftTerm's copy(_:)
    /// implementation no-ops gracefully (writes empty string).
    private func hasSelection(in pane: TerminalSession) -> Bool { true }

    private func copySelection(from pane: TerminalSession) {
        // SwiftTerm's MacTerminalView declares `open func copy(_:)` that
        // pulls selection text and writes to NSPasteboard. Calling it
        // directly avoids the internal-access wall while still honoring
        // SwiftTerm's row/column handling.
        pane.terminalView?.copy(NSObject())
    }

    private func pasteInto(pane: TerminalSession) {
        pane.terminalView?.paste(NSObject())
    }

    private func selectAll(in pane: TerminalSession) {
        // NSView.selectAll(_:) routes to MacTerminalView's override.
        pane.terminalView?.selectAll(NSObject())
    }
}

/// One pane cell — extracted from PaneLayout so SwiftUI can observe the
/// session's `@Published var isActive` and animate the activity stripe.
/// Inline overlays inside a parent View can't observe a leaf ObservableObject
/// without a dedicated child view holding the @ObservedObject.
private struct PaneCellView: View {
    @ObservedObject var pane: TerminalSession
    @ObservedObject var tab: TerminalTab
    let sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings
    let single: Bool
    let copySelection: (TerminalSession) -> Void
    let pasteInto: (TerminalSession) -> Void
    let selectAll: (TerminalSession) -> Void
    let hasSelection: (TerminalSession) -> Bool

    var body: some View {
        let isActivePane = pane.id == tab.activePaneId
        TerminalSurface(session: pane, sessions: sessions, settings: settings)
            .frame(minWidth: 200, minHeight: 100)
            .overlay(
                Group {
                    if !single {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isActivePane ? Color.accentColor.opacity(0.55) : Color.clear,
                                lineWidth: 1
                            )
                    }
                }
            )
            // Thin animated indeterminate progress stripe along the top
            // edge of the pane while it's actively producing output
            // (claude / codex / build / etc.). Same idle heuristic that
            // fires "command finished" notifications — works for *any*
            // long-running command without shell integration.
            .overlay(alignment: .top) {
                if settings.showActivityBar {
                    ActivityStripe(active: pane.isActive)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !single {
                    PaneCloseButton {
                        sessions.closePane(pane.id)
                    }
                    // Sit in the top-right corner. The scrollbar has
                    // been shortened from the top by `paneCloseTopInset`
                    // (TerminalSurface.swift) so the X has clear space
                    // here without overlapping the scroll thumb.
                    .padding(.top, 4)
                    .padding(.trailing, 3)
                    .zIndex(10)
                }
            }
            .onTapGesture {
                tab.activePaneId = pane.id
                if let view = pane.terminalView {
                    view.window?.makeFirstResponder(view)
                    NotificationCenter.default.post(
                        name: TermyTerminalView.focusChangedNotification,
                        object: view
                    )
                }
            }
            .contextMenu {
                Button("Copy") { copySelection(pane) }
                    .disabled(!hasSelection(pane))
                Button("Paste") { pasteInto(pane) }
                Button("Select All") { selectAll(pane) }
                Divider()
                Button("Find in Scrollback") {
                    NotificationCenter.default.post(name: .terminalToggleFind, object: nil)
                }
                Button("Clear") { sessions.clearCurrent() }
                Divider()
                Button("New Tab") { sessions.openTab() }
                Button("Split Horizontally") { sessions.splitHorizontal() }
                Button("Split Vertically") { sessions.splitVertical() }
            }
    }
}

/// Thin (2pt) animated indeterminate progress stripe driven by the
/// wall clock via `TimelineView`. Phase is computed from `Date()` so
/// the animation can't ever desync — toggling `active` on/off rapidly
/// just fades the stripe in/out without resetting or duplicating any
/// animation state. The previous implementation used
/// `withAnimation(.linear.repeatForever)` which left running animations
/// behind on toggle and could visibly glitch.
///
/// Visual: a soft 22%-width pulse traverses left→right every ~1.4s.
/// Fades to 0 opacity 250 ms after the pane goes idle; the
/// TimelineView keeps producing frames during the fade so the pulse
/// completes its in-progress sweep instead of jumping mid-stride. The
/// view itself remains in the hierarchy at all times — no insertion /
/// removal flicker.
private struct ActivityStripe: View {
    let active: Bool
    /// Wall-clock anchor for the animation. Set when the stripe first
    /// becomes visible so the pulse always starts from the leading edge
    /// on a fresh activity burst, not mid-stride.
    @State private var anchor: Date = .distantPast

    /// Cycle length in seconds. Slower = calmer; faster = more urgent.
    /// 1.4s sits in iTerm/Xcode territory — present but not jittery.
    private let period: Double = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let segment = max(80, w * 0.22)
                let elapsed = context.date.timeIntervalSince(anchor)
                // Normalised phase 0..1. Use `truncatingRemainder` so we
                // never accumulate floating-point error over long runs.
                let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: period) / period)
                let travel = w + segment
                let offset = phase * travel - segment

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.10))
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0),
                            Color.accentColor.opacity(0.95),
                            Color.accentColor.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: segment)
                    .offset(x: offset)
                }
                .frame(height: 2)
                .clipped()
            }
        }
        .frame(height: 2)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: active)
        .onChange(of: active) { _, isActive in
            // Anchor on the rising edge so each new activity burst
            // starts the pulse cleanly from the left rather than
            // wherever the previous run happened to land.
            if isActive { anchor = Date() }
        }
        .onAppear {
            if active { anchor = Date() }
        }
        .accessibilityHidden(true)
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
