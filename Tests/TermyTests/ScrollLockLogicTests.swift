import Testing
@testable import Termy

/// The scroll lock keeps the viewport put when the user scrolls up while output
/// streams. The bug: the at-tail decision was read from `scrollPosition`
/// (terminal.displayBuffer), which is FROZEN during claude's per-frame DECSET
/// 2026 synchronized-output blocks — so it could read "not at tail" while the
/// live tail was at the bottom, engaging the lock and scrolling the live input
/// (and caret) off-screen. The fix decides from the live buffer's yDisp/yBase.
struct ScrollLockLogicTests {

    @Test func atLiveTailReleases() {
        // yDisp == yBase: viewport pinned to the live tail -> no lock.
        #expect(ScrollLockLogic.lockTarget(yDisp: 100, yBase: 100, canScroll: true) == nil)
    }

    @Test func scrolledUpLocksToCurrentRow() {
        // User scrolled up: lock to exactly where they are.
        #expect(ScrollLockLogic.lockTarget(yDisp: 40, yBase: 100, canScroll: true) == 40)
    }

    @Test func cannotScrollNeverLocks() {
        // No scrollback (or alternate buffer): nothing to lock to.
        #expect(ScrollLockLogic.lockTarget(yDisp: 0, yBase: 0, canScroll: false) == nil)
        #expect(ScrollLockLogic.lockTarget(yDisp: 0, yBase: 50, canScroll: false) == nil)
    }

    /// Regression for the exact failure: a stale 2026 snapshot would have said
    /// "scrolled away" (e.g. a snapshot yDisp below yBase) and locked. The fix
    /// uses the LIVE buffer, where at-tail means yDisp == yBase, so a live tail
    /// never locks regardless of what a frozen snapshot would report.
    @Test func liveTailNeverLocksEvenWhenScrollbackIsDeep() {
        // Deep scrollback (large yBase) but the live viewport is at the tail.
        #expect(ScrollLockLogic.lockTarget(yDisp: 5000, yBase: 5000, canScroll: true) == nil)
    }
}
