import Foundation
import Combine
import SwiftUI

/// Orientation of split panes inside a tab.
/// `.horizontal` = panes side-by-side (split happens left→right).
/// `.vertical`   = panes stacked top→bottom.
enum PaneOrientation: String, Codable {
    case horizontal
    case vertical
}

/// A tab in the terminal window. Holds one or more terminal sessions
/// (panes) and the orientation they're laid out in.
///
/// Constraint by design: a tab has a single orientation — no nested splits.
/// You can have N horizontal panes OR N vertical panes per tab, not a mix.
/// Covers ~95% of real terminal usage and keeps the model + UI simple.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var panes: [TerminalSession]
    @Published var orientation: PaneOrientation = .horizontal
    @Published var activePaneId: UUID?
    /// Optional color tag shown as a dot on the tab chip.
    @Published var tagColor: TabTagColor = .none
    /// Mirror keystrokes typed into the active pane to all panes (iTerm2-style).
    @Published var broadcastInput: Bool = false
    /// User-set name override. When non-nil, the tab chip shows this
    /// instead of the cwd-derived auto-title. Useful for long-running
    /// panes ("claude code", "metrics", "logs") that benefit from a
    /// stable human label. Persisted across launches.
    @Published var customTitle: String?

    /// Per-pane size fractions, summing to 1.0. Defaults to equal
    /// distribution (1/N for N panes) but updates as the user drags the
    /// divider between panes. Persisted so a 70/30 split survives
    /// relaunches. Length always matches panes.count; defensively
    /// re-normalised on split/close.
    @Published var paneFractions: [CGFloat] = []

    init(initialCwd: String = NSHomeDirectory(), profile: Profile? = nil) {
        let first = TerminalSession(initialCwd: initialCwd, profile: profile)
        self.panes = [first]
        self.activePaneId = first.id
        self.paneFractions = [1.0]
        if let profile, profile.tagColor != .none { self.tagColor = profile.tagColor }
    }

    init(panes: [TerminalSession], orientation: PaneOrientation = .horizontal) {
        self.panes = panes
        self.orientation = orientation
        self.activePaneId = panes.first?.id
        self.paneFractions = Self.equalFractions(count: panes.count)
    }

    /// Equal-distribution helper used when fractions aren't otherwise
    /// known (new tab, new split, restore without persisted fractions).
    static func equalFractions(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / CGFloat(count), count: count)
    }

    var activePane: TerminalSession? {
        panes.first(where: { $0.id == activePaneId }) ?? panes.first
    }

    /// Split the active pane: append a new pane with the active pane's cwd.
    /// First split also sets the orientation; subsequent splits append in the
    /// existing orientation. New pane takes half of the previously-active
    /// pane's space — equivalent to "split here" rather than "add equal
    /// share for all", which would shrink unrelated panes the user is
    /// already happy with.
    func split(orientation: PaneOrientation) {
        let cwd = activePane?.cwd ?? NSHomeDirectory()
        let newPane = TerminalSession(initialCwd: cwd)
        if panes.count == 1 {
            self.orientation = orientation
        }
        // Carve half of the active pane's fraction for the new pane.
        if let activeIdx = panes.firstIndex(where: { $0.id == activePaneId }),
           activeIdx < paneFractions.count {
            let activeShare = paneFractions[activeIdx]
            paneFractions[activeIdx] = activeShare / 2
            paneFractions.append(activeShare / 2)
        } else {
            paneFractions = Self.equalFractions(count: panes.count + 1)
        }
        panes.append(newPane)
        activePaneId = newPane.id
    }

    /// Remove the pane with `id`, donating its size fraction to the neighbour
    /// that inherits focus, and fixing up activePaneId. Returns true if the tab
    /// is now empty (caller should close the tab). This is the SINGLE source of
    /// truth for pane removal — both the active-pane path (keyboard/menu) and
    /// the close-button / shell-exit path route through it, so they can't
    /// diverge. (The close-button path used to skip paneFractions bookkeeping
    /// entirely, which silently reset a custom split back to equal.)
    @discardableResult
    func removePane(id: UUID) -> Bool {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return panes.isEmpty }
        panes[idx].terminalView?.terminate()
        let removedWasActive = (activePaneId == id)
        panes.remove(at: idx)
        if panes.isEmpty {
            paneFractions = []
            activePaneId = nil
            return true
        }
        let freed = idx < paneFractions.count ? paneFractions.remove(at: idx) : 0
        let focusIdx = min(idx, panes.count - 1)
        if focusIdx < paneFractions.count {
            paneFractions[focusIdx] += freed
        }
        // Only move focus if the removed pane had it (or focus is now stale).
        if removedWasActive || !panes.contains(where: { $0.id == activePaneId }) {
            activePaneId = panes[focusIdx].id
        }
        return false
    }

    /// Close the active pane. Returns true if the tab should be closed too.
    @discardableResult
    func closeActivePane() -> Bool {
        guard let active = activePane else { return panes.isEmpty }
        return removePane(id: active.id)
    }

    /// Cycle focus to the next pane in display order.
    func focusNextPane() {
        guard !panes.isEmpty else { return }
        let i = panes.firstIndex(where: { $0.id == activePaneId }) ?? 0
        activePaneId = panes[(i + 1) % panes.count].id
    }

    func focusPreviousPane() {
        guard !panes.isEmpty else { return }
        let i = panes.firstIndex(where: { $0.id == activePaneId }) ?? 0
        activePaneId = panes[(i - 1 + panes.count) % panes.count].id
    }

    /// First pane's cwd — used as the tab's display label.
    var displayCwd: String {
        activePane?.cwd ?? panes.first?.cwd ?? NSHomeDirectory()
    }

    var displayTitle: String {
        activePane?.title ?? panes.first?.title ?? "zsh"
    }
}

/// Tab tag color — a small set of recognizable hues for fast at-a-glance ID.
enum TabTagColor: String, CaseIterable, Identifiable, Codable {
    case none, red, orange, yellow, green, blue, purple, pink, gray
    var id: String { rawValue }
    var swiftColor: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
    var displayName: String { rawValue.capitalized }
}
