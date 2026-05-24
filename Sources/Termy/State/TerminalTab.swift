import Foundation
import Combine

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

    init(initialCwd: String = NSHomeDirectory()) {
        let first = TerminalSession(initialCwd: initialCwd)
        self.panes = [first]
        self.activePaneId = first.id
    }

    init(panes: [TerminalSession], orientation: PaneOrientation = .horizontal) {
        self.panes = panes
        self.orientation = orientation
        self.activePaneId = panes.first?.id
    }

    var activePane: TerminalSession? {
        panes.first(where: { $0.id == activePaneId }) ?? panes.first
    }

    /// Split the active pane: append a new pane with the active pane's cwd.
    /// First split also sets the orientation; subsequent splits append in the
    /// existing orientation.
    func split(orientation: PaneOrientation) {
        let cwd = activePane?.cwd ?? NSHomeDirectory()
        let newPane = TerminalSession(initialCwd: cwd)
        if panes.count == 1 {
            self.orientation = orientation
        }
        panes.append(newPane)
        activePaneId = newPane.id
    }

    /// Close the active pane. Returns true if the tab should be closed too
    /// (i.e. the last pane is being removed).
    @discardableResult
    func closeActivePane() -> Bool {
        guard let active = activePane,
              let idx = panes.firstIndex(where: { $0.id == active.id })
        else { return panes.isEmpty }
        active.terminalView?.terminate()
        panes.remove(at: idx)
        if panes.isEmpty { return true }
        activePaneId = panes[min(idx, panes.count - 1)].id
        return false
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
