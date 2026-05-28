import Testing
import CoreGraphics
@testable import Termy

/// Regression tests for split-pane geometry. The headline bug: dragging a
/// divider accelerated/overshot because the gesture fed CUMULATIVE
/// translation into a function that treated each call as an INCREMENTAL
/// delta. These tests lock down the pure math so the divider tracks 1:1.
struct PaneMathTests {

    // MARK: normalisation

    @Test func equalFractionsSumToOne() {
        for n in 1...6 {
            let f = PaneMath.equalFractions(count: n)
            #expect(f.count == n)
            #expect(abs(f.reduce(0, +) - 1.0) < 1e-9)
        }
    }

    @Test func normalisedRepairsLengthMismatch() {
        // Stored 2 fractions but now 3 panes -> reset to equal thirds.
        let out = PaneMath.normalised([0.6, 0.4], count: 3)
        #expect(out.count == 3)
        #expect(abs(out.reduce(0, +) - 1.0) < 1e-9)
        #expect(abs(out[0] - 1.0/3.0) < 1e-9)
    }

    @Test func normalisedRescalesToOne() {
        let out = PaneMath.normalised([2, 2], count: 2)
        #expect(abs(out[0] - 0.5) < 1e-9)
        #expect(abs(out[1] - 0.5) < 1e-9)
    }

    // MARK: absolute sizing — must fill the parent exactly

    @Test func absoluteSizesFillParentExactlyNoDrift() {
        // Two panes, odd total so rounding bites: 50/50 of (501 - 4 divider).
        let sizes = PaneMath.absoluteSizes(fractions: [0.5, 0.5], total: 501)
        let usable = 501.0 - PaneMath.dividerWidth
        #expect(abs(sizes.reduce(0, +) - usable) < 1e-6,
                "panes + divider must fill the parent with zero accumulated drift")
    }

    @Test func absoluteSizesThreePanesFill() {
        let sizes = PaneMath.absoluteSizes(fractions: [1.0/3, 1.0/3, 1.0/3], total: 1000)
        let usable = 1000.0 - 2 * PaneMath.dividerWidth
        #expect(abs(sizes.reduce(0, +) - usable) < 1e-6)
    }

    // MARK: the resize bug — incremental deltas track 1:1, no acceleration

    @Test func resizeMovesExactlyTheRequestedFraction() {
        let start: [CGFloat] = [0.5, 0.5]
        // Move 0.1 of the total from pane 0 to pane 1.
        let out = PaneMath.resized(start, at: 0, deltaFraction: 0.1)!
        #expect(abs(out[0] - 0.6) < 1e-9)
        #expect(abs(out[1] - 0.4) < 1e-9)
        #expect(abs(out.reduce(0, +) - 1.0) < 1e-9)
    }

    /// The core regression: applying a *sequence of small incremental* deltas
    /// that sum to D must equal one move of D. (Before the fix the gesture
    /// fed cumulative translation, so N frames of a drag applied ~N²/2× the
    /// intended movement.)
    @Test func incrementalDeltasComposeLinearly() {
        var f: [CGFloat] = [0.5, 0.5]
        let steps: [CGFloat] = [0.02, 0.02, 0.02, 0.02, 0.02]  // sums to 0.10
        for s in steps { f = PaneMath.resized(f, at: 0, deltaFraction: s)! }
        #expect(abs(f[0] - 0.6) < 1e-9, "5×0.02 incremental moves == one 0.10 move, not accelerated")
        #expect(abs(f[1] - 0.4) < 1e-9)
    }

    @Test func resizeClampsToMinFractionInsteadOfRefusing() {
        // Try to over-drag: move 0.9 from pane 0 (only ~0.4 of room above the
        // 0.10 floor). Must clamp pane 0 to the floor, not drop the gesture.
        let out = PaneMath.resized([0.5, 0.5], at: 0, deltaFraction: -0.9)!
        #expect(out[0] >= PaneMath.minFraction - 1e-9)
        #expect(out[1] <= 1.0 - PaneMath.minFraction + 1e-9)
        #expect(abs(out.reduce(0, +) - 1.0) < 1e-9, "clamped move still conserves total")
    }

    @Test func resizeRejectsOutOfRangeIndex() {
        #expect(PaneMath.resized([0.5, 0.5], at: 1, deltaFraction: 0.1) == nil)
        #expect(PaneMath.resized([1.0], at: 0, deltaFraction: 0.1) == nil)
    }
}
