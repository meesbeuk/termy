/// Pure decision logic for the anti-stick-to-bottom scroll lock, extracted
/// from `TermyTerminalView` so it can be unit-tested without a PTY.
///
/// The lock exists so that when the user scrolls up to read while a command
/// (claude/codex/build) is still streaming, incoming output doesn't yank the
/// viewport back to the bottom. The decision MUST be made from the LIVE buffer
/// position (`yDisp` vs `yBase`), never from `scrollPosition`/`displayBuffer`:
/// during a DECSET 2026 synchronized-output frame `displayBuffer` returns a
/// FROZEN snapshot, so a `scrollPosition`-based check can read "not at tail"
/// while the live tail is actually at the bottom — which spuriously engaged the
/// lock, pinned `yDisp`, and scrolled the live input (and caret) off-screen.
enum ScrollLockLogic {
    /// Given the live buffer position, return the row to lock the viewport to,
    /// or `nil` to release (viewport is at — or below — the live tail, or the
    /// buffer can't scroll). `yDisp` is the top visible scrollback row; `yBase`
    /// is the top row of the live (non-scrollback) region. They're equal when
    /// the viewport is pinned to the live tail.
    static func lockTarget(yDisp: Int, yBase: Int, canScroll: Bool) -> Int? {
        guard canScroll else { return nil }
        // yDisp can never exceed yBase, so `>=` is "at the live tail".
        return yDisp >= yBase ? nil : yDisp
    }
}
