import Testing
import CoreGraphics
@testable import Termy

/// Locks the cell-dimension formula to SwiftTerm's. The headline regression:
/// the resize prediction omitted the lineSpacing term, so the predicted row
/// count was wrong whenever vertical spacing > 0 and window resizes over-fired.
struct CellMetricsTests {
    @Test func lineSpacingIncreasesCellHeight() {
        let base = CellMetrics.snappedCellHeight(ascent: 10, descent: 3, leading: 1, lineSpacing: 0, scale: 2)
        let spaced = CellMetrics.snappedCellHeight(ascent: 10, descent: 3, leading: 1, lineSpacing: 6, scale: 2)
        #expect(spaced > base, "lineSpacing must add to the cell height (the omitted term)")
        #expect(spaced - base >= 6 - 1, "added height tracks lineSpacing (within pixel snapping)")
    }

    @Test func matchesSwiftTermFormula() {
        // SwiftTerm: ceil(ceil(a+d+l+ls) * scale) / scale, clamped to [1, 8192].
        let a: CGFloat = 12.4, d: CGFloat = 3.1, l: CGFloat = 0.6, ls: CGFloat = 4, scale: CGFloat = 2
        let expected = max(min(ceil(ceil(a + d + l + ls) * scale) / scale, 8192), 1)
        #expect(CellMetrics.snappedCellHeight(ascent: a, descent: d, leading: l, lineSpacing: ls, scale: scale) == expected)
    }

    @Test func widthSnapsToPixelGrid() {
        // advance 7.3 @2x -> ceil(14.6)/2 = 15/2 = 7.5
        #expect(CellMetrics.snappedCellWidth(advance: 7.3, scale: 2) == 7.5)
    }

    @Test func heightNeverZero() {
        #expect(CellMetrics.snappedCellHeight(ascent: 0, descent: 0, leading: 0, lineSpacing: 0, scale: 2) >= 1)
    }
}
