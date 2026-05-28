import Testing
import CoreGraphics
@testable import Termy

/// Geometry for the grid layout that backs "Quad Claude" (2×2) and any
/// user-defined N-column layout. All pure functions in PaneMath, so the exact
/// pixel arithmetic — the part that determines whether 4 panes tile cleanly
/// without gaps, overlaps, or sub-pixel drift — is pinned here.
struct GridLayoutTests {

    @Test func rowsRoundUp() {
        #expect(PaneMath.gridRows(count: 4, columns: 2) == 2)   // Quad Claude
        #expect(PaneMath.gridRows(count: 5, columns: 2) == 3)
        #expect(PaneMath.gridRows(count: 3, columns: 3) == 1)
        #expect(PaneMath.gridRows(count: 6, columns: 3) == 2)
        #expect(PaneMath.gridRows(count: 0, columns: 2) == 0)
    }

    @Test func cellsPerRowHandlesPartialLastRow() {
        // Perfect 2×2.
        #expect(PaneMath.gridCellsInRow(count: 4, columns: 2, row: 0) == 2)
        #expect(PaneMath.gridCellsInRow(count: 4, columns: 2, row: 1) == 2)
        // 5 panes / 2 cols → rows of 2, 2, 1.
        #expect(PaneMath.gridCellsInRow(count: 5, columns: 2, row: 2) == 1)
        // 3 panes / 2 cols → rows of 2, 1.
        #expect(PaneMath.gridCellsInRow(count: 3, columns: 2, row: 1) == 1)
    }

    @Test func quadGridTilesExactlyWithNoOverlap() {
        let total = CGSize(width: 1000, height: 800)
        let rects = PaneMath.gridCellRects(count: 4, columns: 2,
                                           colFractions: [0.5, 0.5], rowFractions: [0.5, 0.5],
                                           total: total)
        #expect(rects.count == 4)
        // Row 0 spans the full width including the divider gap.
        #expect(rects[0].minX == 0)
        #expect(rects[0].maxX + PaneMath.dividerWidth == rects[1].minX)
        #expect(rects[1].maxX == total.width)
        // Row 1 sits below row 0 with exactly one divider between.
        #expect(rects[2].minY == rects[0].maxY + PaneMath.dividerWidth)
        #expect(rects[2].minY == rects[3].minY)
        // Bottom row reaches the bottom edge.
        #expect(rects[2].maxY == total.height)
        // No horizontal overlap within a row.
        #expect(rects[0].maxX <= rects[1].minX)
    }

    @Test func unevenColumnFractionsAreHonoured() {
        // A 70/30 column split must put ~70% of the usable width in column 0.
        let total = CGSize(width: 1004, height: 400) // 1004 - 4px divider = 1000 usable
        let rects = PaneMath.gridCellRects(count: 2, columns: 2,
                                           colFractions: [0.7, 0.3], rowFractions: [1.0],
                                           total: total)
        #expect(abs(rects[0].width - 700) <= 1)
        #expect(abs(rects[1].width - 300) <= 1)
    }

    @Test func partialLastRowCellFillsRowWidth() {
        // 3 panes / 2 cols: the lone last-row cell should span the whole width,
        // not sit at half width with a gap.
        let total = CGSize(width: 1000, height: 900)
        let rects = PaneMath.gridCellRects(count: 3, columns: 2,
                                           colFractions: [0.5, 0.5], rowFractions: [0.5, 0.5],
                                           total: total)
        #expect(rects.count == 3)
        #expect(rects[2].minX == 0)
        #expect(rects[2].width == total.width)
    }

    @Test func dividerCountsMatchGridShape() {
        // 2 columns → 1 vertical divider; 2 rows → 1 horizontal divider.
        #expect(PaneMath.gridColumnDividerXs(columns: 2, colFractions: [0.5, 0.5], totalWidth: 1000).count == 1)
        #expect(PaneMath.gridRowDividerYs(rows: 2, rowFractions: [0.5, 0.5], totalHeight: 800).count == 1)
        // A single column / single row has no draggable divider.
        #expect(PaneMath.gridColumnDividerXs(columns: 1, colFractions: [1.0], totalWidth: 1000).isEmpty)
        #expect(PaneMath.gridRowDividerYs(rows: 1, rowFractions: [1.0], totalHeight: 800).isEmpty)
        // 3 columns → 2 dividers, sitting strictly inside the bounds, in order.
        let xs = PaneMath.gridColumnDividerXs(columns: 3, colFractions: [0.34, 0.33, 0.33], totalWidth: 1200)
        #expect(xs.count == 2)
        #expect(xs[0] > 0 && xs[0] < xs[1] && xs[1] < 1200)
    }

    @Test func partialRowFractionsRenormalise() {
        // Leading-column fractions for a 1-cell row must sum to 1.
        let f = PaneMath.gridRowColumnFractions([0.5, 0.5], cellsInRow: 1)
        #expect(f.count == 1)
        #expect(abs(f[0] - 1.0) < 0.0001)
    }
}
