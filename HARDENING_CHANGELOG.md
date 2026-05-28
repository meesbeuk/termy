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

### P1 — Split-pane divider resize accelerated / overshot
- **Cause:** `ResizableDivider` (`Views/PaneLayout.swift`) fed SwiftUI's *cumulative* `DragGesture` translation into `resize()` on every `.onChanged`, but `resize()` applied its argument as an *incremental* delta added to the already-updated fractions. N frames of a drag applied ~N²/2× the intended movement → the divider shot to the clamp instantly.
- **Fix:** divider now diffs against the last cumulative translation and passes the per-frame delta (reset on `.onEnded`). Extracted the geometry into a pure, tested `PaneMath` enum; `resized()` clamps to the 10% floor *partially* (tracks the cursor to the boundary instead of dropping the whole gesture), and `absoluteSizes()` folds the rounding remainder into the last pane so panes+dividers fill the parent with zero drift.
- **Tests:** `PaneMathTests` — `incrementalDeltasComposeLinearly` (5×0.02 == one 0.10 move), exact-fill/no-drift, clamp-not-refuse, out-of-range rejection.
