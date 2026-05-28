import Testing
@testable import Termy

/// End-to-end (sans shell) checks that spawning a layout produces the right
/// tab + pane structure, and that each pane is primed to launch its command
/// through the reliable pendingInitialCommand path. TerminalSession doesn't
/// fork a shell until its view mounts, so this is safe to run headless.
@MainActor
struct LayoutSpawnIntegrationTests {

    private func freshSessions() -> TerminalSessions {
        // registerWindowKey: false keeps the test out of the window-restore list.
        TerminalSessions(registerWindowKey: false)
    }

    @Test func quadClaudeSpawnsFourPaneGrid() {
        let sessions = freshSessions()
        let quad = LayoutStore.builtIns.first { $0.id == LayoutStore.quadClaudeID }!
        sessions.spawnLayout(quad)

        let tab = sessions.currentTab
        #expect(tab != nil)
        guard let tab else { return }
        #expect(tab.panes.count == 4)
        #expect(tab.gridColumns == 2)
        #expect(tab.gridColFractions.count == 2)
        #expect(tab.gridRowFractions.count == 2)
        #expect(tab.customTitle == "Quad Claude")
        // Every pane is primed to run `claude` once its shell is up.
        #expect(tab.panes.allSatisfy { $0.pendingInitialCommand == "claude" })
    }

    @Test func oneRowLayoutUsesHorizontalSplitNotGrid() {
        let sessions = freshSessions()
        let dual = LayoutStore.builtIns.first { $0.id == LayoutStore.dualClaudeID }!
        sessions.spawnLayout(dual)
        let tab = sessions.currentTab!
        #expect(tab.panes.count == 2)
        // 1 row → reuse the well-tested horizontal split path, no grid.
        #expect(tab.gridColumns == nil)
        #expect(tab.orientation == .horizontal)
    }

    @Test func emptyCwdInheritsCurrentPaneCwd() {
        let sessions = freshSessions()
        sessions.openTab()
        sessions.currentSession?.cwd = "/tmp/projectX"
        let quad = LayoutStore.builtIns.first { $0.id == LayoutStore.quadClaudeID }!
        sessions.spawnLayout(quad)
        let tab = sessions.currentTab!
        #expect(tab.panes.allSatisfy { $0.initialCwd == "/tmp/projectX" })
    }

    @Test func zoomTogglesAndClearsOnCollapse() {
        let sessions = freshSessions()
        sessions.openTab()
        sessions.splitHorizontal()                 // now 2 panes
        let tab = sessions.currentTab!
        #expect(tab.panes.count == 2)
        #expect(tab.zoomedPaneId == nil)

        sessions.toggleZoomActivePane()
        #expect(tab.zoomedPaneId == tab.activePaneId)
        sessions.toggleZoomActivePane()
        #expect(tab.zoomedPaneId == nil)

        // Zoom, then close down to one pane — zoom must clear itself.
        sessions.toggleZoomActivePane()
        #expect(tab.zoomedPaneId != nil)
        _ = tab.removePane(id: tab.panes[0].id)
        #expect(tab.zoomedPaneId == nil)
    }

    @Test func zoomIsNoOpForLonePane() {
        let sessions = freshSessions()
        sessions.openTab()
        sessions.toggleZoomActivePane()
        #expect(sessions.currentTab?.zoomedPaneId == nil)
    }

    @Test func focusPaneSelectsTabAndClearsZoom() {
        // Dashboard click target: focus a pane in a non-selected, zoomed tab.
        let sessions = freshSessions()
        let tabA = sessions.openTab()
        let tabB = sessions.openTab()
        sessions.selectTab(tabB.id)
        tabA.split(orientation: .horizontal)        // tabA now has 2 panes
        tabA.zoomedPaneId = tabA.panes[1].id        // pretend it's zoomed
        let target = tabA.panes[0].id

        sessions.focusPane(tabId: tabA.id, paneId: target)
        #expect(sessions.selectedTabId == tabA.id)
        #expect(tabA.activePaneId == target)
        #expect(tabA.zoomedPaneId == nil)           // zoom cleared so pane is visible
    }
}
