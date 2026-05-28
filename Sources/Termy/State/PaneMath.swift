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
}
