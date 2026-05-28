/// Decides whether a full-screen erase (`ESC[2J`) should be followed by a
/// scrollback erase (`ESC[3J`). Extracted from `TermyTerminalView` so the
/// decision is unit-testable.
///
/// Context: apps that don't use the alternate screen (claude in particular)
/// repaint their whole UI inline on every frame, leaving every previous render
/// stacked in scrollback. Termy detects a repaint *burst* (3+ `ESC[2J` in 5s)
/// and erases scrollback after each clear to keep history tidy. The bug: once
/// the burst flips `tuiModeActive` on, it stuck for 30s — so an isolated `clear`
/// run a few seconds later still fired `ESC[3J` and silently wiped the real
/// scrollback the user had just built. The fix requires the burst to still be
/// *live* (≥2 clears in the rolling window) at fire time.
enum TUIClearPolicy {
    /// Minimum number of recent clears (within the rolling detection window)
    /// required to treat a `ESC[2J` as part of an active repaint burst.
    static let minBurstClears = 2

    static func shouldEraseScrollback(recentClearCount: Int, tuiModeActive: Bool) -> Bool {
        tuiModeActive && recentClearCount >= minBurstClears
    }
}
