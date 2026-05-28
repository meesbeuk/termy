# Termy hardening + parity pass — changelog

Branch: `harden/parity-pass`. Goal: match/beat iTerm2 on correctness, input, performance, UX with zero regressions. Every fix is backed by an automated test (Swift Testing; the suite runs via `./test.sh`).

## Test harness
- **No test harness existed.** Added a `TermyTests` target (`Package.swift`) using **Swift Testing** (`import Testing`), since this machine has Command Line Tools only (no Xcode → no XCTest).
- `test.sh` re-applies the SwiftTerm source patches, then runs `swift test --disable-xctest --enable-swift-testing` with explicit `-F`/`-rpath` flags for `Testing.framework` + `lib_TestingInterop.dylib` (CLT doesn't put them on the default search paths).
- `@testable import Termy` works against the executable target, so internal logic is testable directly.

## Fixes

### P0 — Shift+Enter submitted instead of inserting a newline (Claude/REPLs)
- **Cause:** Claude Code enables the kitty keyboard protocol (`CSI > 1 u`, disambiguate). SwiftTerm's `kittyFunctionalKey(from:)` (`MacTerminalView.swift`) mapped keypad-Enter and the arrow/F keys but **not the main Return key (`kVK_Return`=36)**. So Shift+Enter fell through `keyDown`'s kitty branch into `interpretKeyEvents` → `doCommand(insertNewline:)` → `sendKittyFunctionalKey(.enter)` **with no modifiers** — the Shift bit was dropped, so Claude received a plain Enter (= submit).
- **Fix:** new idempotent SwiftTerm patch (`patch-swiftterm.sh`, sentinel `TERMY_PATCH return_key_enter`) maps `kVK_Return` → `.enter`, so Return is encoded through the kitty functional-key path **with real modifiers**: plain Enter → `CR` (unchanged), Shift+Enter → `ESC[13;2u` (exactly what Claude reads as newline), Ctrl/Alt+Enter likewise disambiguate. When kitty mode is off the whole branch is skipped → ordinary terminals unaffected.
- **Tests:** `KittyEnterTests` — drives a real SwiftTerm `TerminalView` with kitty mode enabled and synthesized `NSEvent`s, capturing the bytes sent to the PTY: Shift+Enter → `ESC[13;2u`, plain Enter → `CR`, Ctrl+Enter → `ESC[13;5u`.

### P0 — Cmd+K wiped scrollback AND silently broke Shift+Enter / paste under a live TUI
- **Cause:** `clearCurrent()` (`State/TerminalSessions.swift`) called `terminal.resetToInitialState()` — a hard RIS that re-runs terminal setup, resetting the kitty-keyboard / bracketed-paste / focus-reporting / application-cursor modes that claude sets *once* at startup and never re-emits. So after every Cmd+K, Shift+Enter stopped disambiguating (the bug we just fixed re-broke itself) and paste lost bracketing — plus scrollback was gone.
- **Fix:** feed a non-destructive `ESC[H ESC[2J ESC[3J` (home + erase display + erase scrollback) instead. RIS is reserved for an explicit "Reset Terminal".
- **Tests:** `ClearPreservesModesTests` — after the new clear, Shift+Enter still encodes `ESC[13;2u`; a companion test documents that RIS *would* have broken it.

### P0 — A lone `clear` could silently trim real scrollback after a TUI burst
- **Cause:** `handleFullScreenClear()` (`Views/TerminalSurface.swift`) set `tuiModeActive` sticky for 30s once a repaint burst was detected, then fired `ESC[3J` (erase scrollback) on *every* subsequent `ESC[2J` while sticky — so a single `clear` run a few seconds after claude exited wiped the history the user had just built.
- **Fix:** require the burst to still be *live* (≥2 clears in the rolling window) at fire time, via pure `TUIClearPolicy.shouldEraseScrollback`.
- **Tests:** `TUIClearPolicyTests` — live burst erases, isolated clear preserves, non-TUI never erases.

### P0/P1 — Scroll-lock mislatched during claude's synchronized-output frames (scrolled input + caret off-screen)
- **Cause:** `recomputeScrollLock()` (`Views/TerminalSurface.swift`) decided "at tail" from SwiftTerm's `scrollPosition`, which reads `terminal.displayBuffer`. During a DECSET 2026 synchronized-output block — which claude wraps **every repaint** in — `displayBuffer` returns a *frozen snapshot*, so `scrollPosition` could report "not at tail" while the live tail was at the bottom. That spuriously engaged the lock, pinned `yDisp`, and the per-chunk `scrollTo(row:)` scrolled claude's live input (and the caret with it) off-screen — which reads to users as "the caret doesn't render."
- **Fix:** decide tail-state from the **live** buffer (`yDisp` vs `yBase`), which is never frozen. Extracted to a pure `ScrollLockLogic.lockTarget`. Exposed `Buffer.yBase`'s getter via a new SwiftTerm patch (`TERMY_PATCH public_ybase`; `yDisp` was already public). Removed the now-unused float epsilon.
- **Tests:** `ScrollLockLogicTests` — at-tail releases, scrolled-up locks to current row, can't-scroll never locks, deep-scrollback live tail never locks.

### P1 — Split-pane divider resize accelerated / overshot
- **Cause:** `ResizableDivider` (`Views/PaneLayout.swift`) fed SwiftUI's *cumulative* `DragGesture` translation into `resize()` on every `.onChanged`, but `resize()` applied its argument as an *incremental* delta added to the already-updated fractions. N frames of a drag applied ~N²/2× the intended movement → the divider shot to the clamp instantly.
- **Fix:** divider now diffs against the last cumulative translation and passes the per-frame delta (reset on `.onEnded`). Extracted the geometry into a pure, tested `PaneMath` enum; `resized()` clamps to the 10% floor *partially* (tracks the cursor to the boundary instead of dropping the whole gesture), and `absoluteSizes()` folds the rounding remainder into the last pane so panes+dividers fill the parent with zero drift.
- **Tests:** `PaneMathTests` — `incrementalDeltasComposeLinearly` (5×0.02 == one 0.10 move), exact-fill/no-drift, clamp-not-refuse, out-of-range rejection.
