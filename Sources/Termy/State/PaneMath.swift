import CoreGraphics

/// Pure geometry for the split-pane layout, extracted from `PaneLayout` so it
/// can be unit-tested without a view hierarchy. All functions are referentially
/// transparent — no UIKit/SwiftUI state.
enum PaneMath {
    static let minFraction: CGFloat = 0.10
    static let dividerWidth: CGFloat = 4

    /// Minimum fraction a pane may occupy, derived from a hard pixel floor
    /// (PaneCellView pins each pane to minWidth 200 / minHeight 100). Tying the
    /// drag clamp to the same pixel floor stops a divider drag from shrinking a
    /// pane below its SwiftUI minimum — which made the children's sizes exceed
    /// the parent and clip / detach the divider from the edge. Capped at 0.45 so
    /// a two-pane split is always satisfiable on a small window.
    static func minFraction(minPixels: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return minFraction }
        return min(0.45, max(0.04, minPixels / total))
    }

    /// Even split for `count` panes.
    static func equalFractions(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / CGFloat(count), count: count)
    }

    /// Renormalise stored fractions to sum to 1, repairing length mismatches
    /// (split/close in flight, or a restore from an older save).
    static func normalised(_ fractions: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        if fractions.count != count { return equalFractions(count: count) }
        let sum = fractions.reduce(0, +)
        guard sum > 0 else { return equalFractions(count: count) }
        return fractions.map { $0 / sum }
    }

    /// Convert fractions to absolute pixel sizes that, together with the
    /// dividers, fill `total` exactly. The final pane absorbs the rounding
    /// remainder so a column of dividers never drifts the layout off by a
    /// pixel per drag (the old `round($0 * usable)` per-element rounding
    /// accumulated error into the last pane).
    static func absoluteSizes(fractions: [CGFloat], total: CGFloat) -> [CGFloat] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let dividerCount = max(0, count - 1)
        let usable = max(0, total - CGFloat(dividerCount) * dividerWidth)
        var sizes = fractions.map { round($0 * usable) }
        // Push the leftover (positive or negative) onto the last pane so the
        // sum is exactly `usable` regardless of rounding direction.
        let assigned = sizes.reduce(0, +)
        if count > 0 {
            sizes[count - 1] += (usable - assigned)
            if sizes[count - 1] < 0 { sizes[count - 1] = 0 }
        }
        return sizes
    }

    /// Move `deltaFraction` of the total from pane `idx` to pane `idx+1`,
    /// clamped so neither drops below `minFraction`. Returns the updated
    /// fractions, or `nil` if the move is impossible (out of range) — a
    /// clamped move is *partially* applied so the divider tracks the cursor
    /// up to the clamp boundary instead of refusing to move at all.
    static func resized(_ fractions: [CGFloat], at idx: Int, deltaFraction: CGFloat,
                        minFraction: CGFloat = minFraction) -> [CGFloat]? {
        guard idx >= 0, idx + 1 < fractions.count else { return nil }
        var out = fractions
        // Clamp the delta to the room available on both sides so dragging
        // hard against the edge pins the divider at the boundary rather than
        // dropping the whole gesture (the old code early-returned, which made
        // a fast drag past the clamp feel "stuck").
        let maxRight = out[idx + 1] - minFraction          // how far we can grow left
        let maxLeft = out[idx] - minFraction               // how far we can grow right
        let clamped = max(-maxLeft, min(deltaFraction, maxRight))
        guard clamped != 0 else { return out }
        out[idx] += clamped
        out[idx + 1] -= clamped
        return out
    }

    // MARK: - Grid layout (Quad Claude & named layout presets)
    //
    // The default pane model is a flat array with a single orientation per
    // tab. A grid layout ("Quad Claude" = 2×2) lays the same flat `panes`
    // array out row-major into `columns` columns. All geometry is computed
    // here as pure functions of (count, columns, fractions, size) so the
    // renderer can position each pane by an absolute rect — keeping every
    // pane a stable leaf in ONE id-keyed ForEach, so a grid reflow never
    // re-parents (and thus never remounts / restarts) a pane's shell.

    /// Rows needed to lay `count` panes into `columns` columns, row-major.
    static func gridRows(count: Int, columns: Int) -> Int {
        guard columns > 0, count > 0 else { return 0 }
        return (count + columns - 1) / columns
    }

    /// Number of panes in `row` — the last row may be partial.
    static func gridCellsInRow(count: Int, columns: Int, row: Int) -> Int {
        let rows = gridRows(count: count, columns: columns)
        guard columns > 0, row >= 0, row < rows else { return 0 }
        if row < rows - 1 { return columns }
        let last = count - (rows - 1) * columns
        return last == 0 ? columns : last
    }

    /// Column fractions to use for a row: full rows use all columns; a
    /// partial last row uses the leading columns renormalised to fill width
    /// (so a 5-into-2 grid's lone last cell still spans the row).
    static func gridRowColumnFractions(_ colFractions: [CGFloat], cellsInRow: Int) -> [CGFloat] {
        guard cellsInRow > 0 else { return [] }
        if cellsInRow >= colFractions.count { return normalised(colFractions, count: colFractions.count) }
        return normalised(Array(colFractions.prefix(cellsInRow)), count: cellsInRow)
    }

    /// One rect per pane (index-aligned with the pane array) for a row-major
    /// grid sized by per-column / per-row fractions with `dividerWidth` gaps.
    /// Cells + dividers fill `total` exactly (the trailing cell/row absorbs
    /// the rounding remainder, as in `absoluteSizes`).
    static func gridCellRects(count: Int, columns: Int,
                              colFractions: [CGFloat], rowFractions: [CGFloat],
                              total: CGSize) -> [CGRect] {
        guard count > 0, columns > 0 else { return [] }
        let rows = gridRows(count: count, columns: columns)
        let cols = normalised(colFractions, count: columns)
        let rws = normalised(rowFractions, count: rows)
        let rowHeights = absoluteSizes(fractions: rws, total: total.height)
        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        var y: CGFloat = 0
        for r in 0..<rows {
            let cells = gridCellsInRow(count: count, columns: columns, row: r)
            let rowCols = gridRowColumnFractions(cols, cellsInRow: cells)
            let colWidths = absoluteSizes(fractions: rowCols, total: total.width)
            var x: CGFloat = 0
            for c in 0..<cells {
                rects.append(CGRect(x: x, y: y, width: colWidths[c], height: rowHeights[r]))
                x += colWidths[c] + dividerWidth
            }
            y += rowHeights[r] + dividerWidth
        }
        return rects
    }

    /// X positions (left edge) of the `columns - 1` vertical dividers.
    static func gridColumnDividerXs(columns: Int, colFractions: [CGFloat], totalWidth: CGFloat) -> [CGFloat] {
        guard columns > 1 else { return [] }
        let widths = absoluteSizes(fractions: normalised(colFractions, count: columns), total: totalWidth)
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for b in 0..<(columns - 1) { x += widths[b]; xs.append(x); x += dividerWidth }
        return xs
    }

    /// Y positions (top edge) of the `rows - 1` horizontal dividers.
    static func gridRowDividerYs(rows: Int, rowFractions: [CGFloat], totalHeight: CGFloat) -> [CGFloat] {
        guard rows > 1 else { return [] }
        let heights = absoluteSizes(fractions: normalised(rowFractions, count: rows), total: totalHeight)
        var ys: [CGFloat] = []
        var y: CGFloat = 0
        for b in 0..<(rows - 1) { y += heights[b]; ys.append(y); y += dividerWidth }
        return ys
    }
}
