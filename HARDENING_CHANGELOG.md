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

### P1 — Closing a pane via its X button reset a custom split to equal
- **Cause:** `TerminalSessions.closePane` (close-button + shell-`exit` path) removed the pane but never updated `paneFractions`, so `PaneLayout` saw the length mismatch and overwrote the user's split with equal fractions. The keyboard/menu path (`closeActivePane`) did it correctly — two divergent implementations.
- **Fix:** factor a single `TerminalTab.removePane(id:)` (donates the closed pane's share to the focus-inheriting neighbour, fixes up `activePaneId`); both paths call it.
- **Tests:** `PaneRemovalTests` — middle-pane close keeps `[0.6, 0.4]` (not `0.5/0.5`), active-vs-by-id agree, last-pane signals tab close.

### P1 (perf) — Per-chunk full UTF-8 decode of up-to-128KB PTY slices on the main thread
- **Cause:** `trackIdleBytes` decoded the entire PTY slice to a `String` every chunk (for a preview buffer that's truncated to ~2048 chars), so `cat bigfile` / `yes` / build logs paid a full decode + alloc per chunk on the main thread.
- **Fix:** `previewTail` decodes only the last 8KB of each slice (lenient UTF-8). `scanForTriggers`'s decode was already gated on active triggers.
- **Tests:** `PreviewTailTests` — large slice decodes ≤ maxBytes and keeps the suffix; small slice whole; split multibyte never crashes.

### P1 — Broadcast Input mangled special keys; find-bar Esc was app-wide
- **Broadcast (`MainTerminalView.installKeyMonitor`):** mirrored `event.characters` to sibling panes, so arrows/Fn/nav keys sent macOS private-use codepoints (Up = `U+F700` → bytes `EF 9C 80`) and ignored each pane's encoding mode (app-cursor, kitty, optionAsMeta, bracketed paste). Now forwards the key **event** via each sibling's `keyDown`, so every pane encodes per its own mode — matching iTerm2.
- **EscMonitor (`MainTerminalView`):** the Esc/Cmd-period local monitor had no `event.window` guard, so an open find bar in one window swallowed Esc for **every** window (Esc never reached claude/vim elsewhere). Now resolves the hosting window from the backing view and confines swallowing to it.
- **Tests:** `BroadcastEncodingTests` (Up arrow `.characters` is the useless private-use scalar; `keyDown` encodes `ESC[A`). EscMonitor windowing is an AppKit multi-window monitor — verified by reasoning + the end-to-end smoke test (see residual risk).

### P1 — Modified special keys + Cocoa editing keys dropped/mis-encoded
- **Modified Backspace/Escape under kitty** (`TERMY_PATCH special_keys_kitty`): these fell through `keyDown`'s kitty branch into `doCommand`, which called `sendKittyFunctionalKey(.backspace/.escape)` with **no** modifiers — so Ctrl+Backspace, Alt+Backspace, Shift+Escape emitted plain DEL/ESC. Mapped `kVK_Delete/kVK_Escape/kVK_ForwardDelete` in `kittyFunctionalKey`, routing them through the modifier-carrying path (Ctrl+Backspace → `ESC[127;5u`, Shift+Escape → `ESC[27;2u`). Unmodified keys still encode to legacy bytes.
- **Cocoa line-editing keys** (`TERMY_PATCH editing_keys`): Cmd+Delete / Fn+Delete / Option+Delete and word-deletes hit `doCommand`'s `default:` and were dropped with a stray `print()`. Now send the conventional readline bytes (Ctrl+U/K/W, `ESC[3~`, `ESC d`), matching iTerm2.
- **Tests:** `ModifiedSpecialKeyTests` (Ctrl+Backspace, Shift+Escape, plain Escape→`ESC[27u`, plain Backspace→DEL), `CocoaEditingKeyTests` (per-selector byte assertions).

### P0 (headline) — Caret in claude / synchronized-output rendering
- **Finding (verified empirically):** claude turns the OS cursor *off* (`ESC[?25l`, never re-shown) and draws its own reverse-video cursor — so the removed `CaretView` is *correct*. The user-visible "caret doesn't render" was the **scroll-lock** scrolling claude's input off-screen (fixed above). Two real SwiftTerm caret-correctness bugs were fixed alongside:
- **Frozen-snapshot inconsistency** (`TERMY_PATCH caret_sync_consistency`): `updateCursorPosition()` took all geometry from `terminal.displayBuffer` (frozen during a 2026 sync frame) while reading `terminal.cursorHidden` live — mis-positioning/removing the caret mid-frame. Now it defers all caret mutation while `synchronizedOutputActive`; the post-sync `queuePendingDisplay` re-runs it off the live buffer. (`synchronizedOutputActive` widened to module-internal via `TERMY_PATCH sync_active_internal`.)
- **Dual-owner race** (`TERMY_PATCH caret_single_owner`): `showCursor`/`hideCursor` (DECTCEM callbacks) poked `caretView.superview` directly with no viewport check and no reposition, so `showCursor` re-attached the caret at its *stale* frame and raced the async `updateCursorPosition`. Both now route through `updateCursorPosition` (the single owner).
- **Tests:** `CaretOwnerTests` — after hide → move-to-column-20 → show, the caret sits at column 20, not the stale home column. (Sync-deferral is exercised here + verified in the end-to-end smoke test; a deterministic headless test of the async mid-sync redraw isn't practical — see residual risk.)

### P1 (headline) — Window-resize reflow over-fired (wrong predicted row count)
- **Cause:** `cachedCellDimension()` computed cell height as `ceil(ascent+descent+leading)`, omitting the `lineSpacing` term that SwiftTerm's patched `computeFontDimensions` folds in. So `wouldChangeCellGrid` mispredicted the row count whenever vertical spacing > 0, and resizes over-fired reflow work. `lineSpacing` was also missing from the cache key.
- **Fix:** extracted `CellMetrics` mirroring SwiftTerm's exact formula (incl. `lineSpacing`); `cachedCellDimension` now uses it and keys the cache on `lineSpacing`.
- **Tests:** `CellMetricsTests` — lineSpacing increases height, matches SwiftTerm's formula, width pixel-snaps, height never zero.

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
