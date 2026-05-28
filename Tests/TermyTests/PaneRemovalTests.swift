import Testing
import CoreGraphics
@testable import Termy

/// The close-button / shell-exit path (TerminalSessions.closePane) used to
/// remove a pane without touching paneFractions, so PaneLayout detected the
/// length mismatch and reset a custom split back to equal. Both paths now route
/// through TerminalTab.removePane, which donates the closed pane's share to its
/// neighbour.
@MainActor
struct PaneRemovalTests {
    private func makeTab(fractions: [CGFloat], activeIndex: Int) -> (TerminalTab, [TerminalSession]) {
        let sessions = (0..<fractions.count).map { _ in TerminalSession(initialCwd: "/tmp") }
        let tab = TerminalTab(panes: sessions)
        tab.paneFractions = fractions
        tab.activePaneId = sessions[activeIndex].id
        return (tab, sessions)
    }

    @Test func removingMiddlePaneDonatesToNeighbourNotEqualReset() {
        let (tab, s) = makeTab(fractions: [0.6, 0.2, 0.2], activeIndex: 0)
        let closed = tab.removePane(id: s[1].id)
        #expect(!closed)
        #expect(tab.panes.count == 2)
        #expect(abs(tab.paneFractions.reduce(0, +) - 1.0) < 1e-9)
        #expect(abs(tab.paneFractions[0] - 0.6) < 1e-9, "must keep custom split, not reset to 0.5/0.5")
        #expect(abs(tab.paneFractions[1] - 0.4) < 1e-9, "0.2 donated to the neighbour")
        #expect(tab.activePaneId == s[0].id, "removing a non-active pane keeps focus")
    }

    @Test func activeAndByIdRemovalAgree() {
        let (t1, _) = makeTab(fractions: [0.5, 0.3, 0.2], activeIndex: 1)
        t1.closeActivePane()
        let (t2, s2) = makeTab(fractions: [0.5, 0.3, 0.2], activeIndex: 1)
        _ = t2.removePane(id: s2[1].id)
        #expect(t1.paneFractions == t2.paneFractions, "active-pane close and by-id close must agree")
    }

    @Test func lastPaneRemovalSignalsTabClose() {
        let (tab, s) = makeTab(fractions: [1.0], activeIndex: 0)
        #expect(tab.removePane(id: s[0].id) == true)
        #expect(tab.paneFractions.isEmpty)
        #expect(tab.activePaneId == nil)
    }
}
