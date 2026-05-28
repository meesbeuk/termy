import Testing
@testable import Termy

/// The layout model + store. Built-ins (esp. Quad Claude) are the committed
/// headline, so their exact shape is pinned here. Store mutation is asserted
/// as deltas so the tests don't depend on leftover UserDefaults state from a
/// prior run.
@MainActor
struct LayoutStoreTests {

    @Test func quadClaudeIsTwoByTwoFourClaudes() {
        let quad = LayoutStore.builtIns.first { $0.id == LayoutStore.quadClaudeID }
        #expect(quad != nil)
        guard let quad else { return }
        #expect(quad.columns == 2)
        #expect(quad.paneCount == 4)
        #expect(quad.rows == 2)
        #expect(quad.shapeLabel == "2×2")
        #expect(quad.panes.allSatisfy { $0.command == "claude" })
        // Each pane is a distinct spec (distinct ids) — not four aliases of one.
        #expect(Set(quad.panes.map { $0.id }).count == 4)
    }

    @Test func builtInsHaveStableDistinctIDs() {
        let ids = LayoutStore.builtIns.map { $0.id }
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(LayoutStore.quadClaudeID))
        #expect(LayoutStore.builtIns.allSatisfy { $0.isBuiltIn })
    }

    @Test func shapeLabelAndRows() {
        let oneRow = TermyLayout(name: "Pair", columns: 2,
                                 panes: [LayoutPaneSpec(), LayoutPaneSpec()])
        #expect(oneRow.rows == 1)
        #expect(oneRow.shapeLabel == "1×2")

        let oneCol = TermyLayout(name: "Stack", columns: 1,
                                 panes: [LayoutPaneSpec(), LayoutPaneSpec(), LayoutPaneSpec()])
        #expect(oneCol.rows == 3)
        #expect(oneCol.shapeLabel == "3×1")
    }

    @Test func allListsBuiltInsThenUser() {
        let store = LayoutStore()
        let baseCount = store.userLayouts.count
        let mine = TermyLayout(name: "Mine", columns: 2,
                               panes: [LayoutPaneSpec(command: "claude"), LayoutPaneSpec()])
        store.add(mine)
        #expect(store.userLayouts.count == baseCount + 1)
        // Added layouts are forced non-built-in regardless of the input flag.
        #expect(store.userLayouts.last?.isBuiltIn == false)
        // `all` always leads with the built-ins.
        #expect(store.all.prefix(LayoutStore.builtIns.count).map { $0.id }
                == LayoutStore.builtIns.map { $0.id })
        store.remove(mine.id)
        #expect(store.userLayouts.count == baseCount)
    }

    @Test func removingQuickLayoutResetsToQuadClaude() {
        let store = LayoutStore()
        let mine = TermyLayout(name: "Temp", columns: 2,
                               panes: [LayoutPaneSpec(), LayoutPaneSpec()])
        store.add(mine)
        store.setQuick(mine.id)
        #expect(store.quickLayoutID == mine.id)
        store.remove(mine.id)
        // Quick layout must fall back to a layout that still exists.
        #expect(store.quickLayoutID == LayoutStore.quadClaudeID)
        #expect(store.layout(id: store.quickLayoutID) != nil)
    }

    @Test func quickLayoutAlwaysResolves() {
        let store = LayoutStore()
        #expect(store.layout(id: store.quickLayoutID) != nil)
    }
}
