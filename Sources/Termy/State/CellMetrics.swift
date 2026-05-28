import CoreGraphics

/// Cell-dimension math that MUST stay byte-for-byte identical to SwiftTerm's
/// `computeFontDimensions()` (Apple/AppleTerminalView.swift). Termy predicts
/// whether a window resize will change the cell grid (`wouldChangeCellGrid`) so
/// it can avoid redundant reflow work; if this prediction disagrees with
/// SwiftTerm's actual `(cols × rows)`, resizes either over-fire (jank) or
/// under-fire (stale wrap). The prediction previously omitted the `lineSpacing`
/// term that SwiftTerm's patched cell height includes, so the predicted row
/// count was systematically wrong whenever the user set vertical spacing > 0.
enum CellMetrics {
    /// SwiftTerm: `cellHeight = ceil(ascent + descent + leading + lineSpacing)`,
    /// then snapped to the pixel grid and clamped.
    static func snappedCellHeight(ascent: CGFloat, descent: CGFloat, leading: CGFloat,
                                  lineSpacing: CGFloat, scale: CGFloat) -> CGFloat {
        let cellHeight = ceil(ascent + descent + leading + lineSpacing)
        let snapped = ceil(cellHeight * scale) / scale
        return max(min(snapped, 8192), 1)
    }

    /// SwiftTerm: `cellWidth = advancement("W")`, snapped to the pixel grid.
    static func snappedCellWidth(advance: CGFloat, scale: CGFloat) -> CGFloat {
        max(1, ceil(advance * scale) / scale)
    }
}
