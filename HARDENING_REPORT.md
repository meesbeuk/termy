# Termy hardening + parity pass — final report

Branch: `harden/parity-pass` (13 commits off `main`). Full suite: **49 tests / 14 suites green** via `./test.sh` (Swift Testing; CLT-compatible — no Xcode required).

## Method
1. Mapped the architecture (SwiftUI + AppKit hosting a locally-patched SwiftTerm 1.13) and captured exactly what `claude` emits to a PTY (kitty keyboard protocol flag 1, synchronized output 2026, cursor hide + reverse-video cursor, bracketed paste, focus reporting).
2. Fanned out a 6-agent parallel discovery workflow (caret / input / resize / scrollback / perf / ux) + synthesis → 22 triaged P0/P1/P2 issues with file:line, cause, fix and test.
3. Fixed in dependency order, one logical commit each, every fix backed by an automated regression test (or, for rendering, an end-to-end visual smoke test). Built + installed the dev bundle and verified the headline behaviours in a live `claude` session.

## The 5 known headline bugs — all resolved
| Bug | Root cause | Fix | Verified by |
|---|---|---|---|
| Caret missing in claude | claude hides the OS cursor and draws a **reverse-video** cursor; SwiftTerm fills reverse-of-default cells with `nativeBackgroundColor.inverseColor()`, which on Termy's transparent glass backdrop (`clear`, alpha 0) stays transparent → painted nothing | `TERMY_PATCH inverse_bg_opaque`: reversed default bg falls back to the opaque foreground when the backdrop is transparent. Also fixed two contributing issues: scroll-lock scrolling the input off-screen, and caret geometry read from the frozen 2026 snapshot | **Live screenshot** (cursor now a visible block) + `ReverseVideoColorTests`, `ScrollLockLogicTests`, `CaretOwnerTests` |
| Shift+Enter doesn't insert a newline | SwiftTerm's `kittyFunctionalKey` never mapped the main Return key, so under kitty mode Shift+Enter lost its modifier (encoded as plain Enter) | `TERMY_PATCH return_key_enter` maps `kVK_Return` → `.enter`; Shift+Enter → `ESC[13;2u` | `KittyEnterTests` (real view + synthesized NSEvent → captured bytes) |
| Split-pane resize broken | divider fed SwiftUI's *cumulative* drag translation into a function treating it as an *incremental* delta → quadratic overshoot | divider diffs to per-frame deltas; pure `PaneMath` for clamp/sizing | `PaneMathTests` |
| Scrollback rendering issues | scroll-lock decided "at tail" from `scrollPosition` (the frozen 2026 snapshot) → mislatched, pinned `yDisp` | decide from the live buffer (`yDisp`/`yBase`); TUI-clear no longer trims real scrollback | `ScrollLockLogicTests`, `TUIClearPolicyTests`; live resize showed clean reflow, no banner-stacking |
| Window-resize reflow breaks | `cachedCellDimension` omitted SwiftTerm's `lineSpacing` term → wrong predicted row count, over-firing reflow | `CellMetrics` mirrors SwiftTerm's formula exactly | `CellMetricsTests` + live maximize reflowed cleanly |

## Also fixed (found in the audit)
- **P0 data-loss:** Cmd+K did a full RIS (wiped scrollback + reset kitty/paste/focus modes — silently re-broke Shift+Enter); now a non-destructive `ESC[H ESC[2J ESC[3J`. A lone `clear` after a TUI burst could trim real scrollback; now gated on a still-live burst.
- **P1 input:** Ctrl/Alt+Backspace and Shift+Escape lost modifiers under kitty (now `ESC[127;5u` / `ESC[27;2u`); Cocoa line-editing keys (Cmd/Fn/Option+Delete) were dropped (now Ctrl-U/K/W, `ESC[3~`, `ESC d`); Broadcast Input mirrored `event.characters` (broke arrows/Fn/kitty) — now routes the key event; find-bar Esc was swallowed app-wide — now confined to its window.
- **P1 state/UX:** closing a pane via its X reset a custom split to equal (unified `removePane`); Quick Terminal leaked a restore key → phantom blank window each launch; tab rename/color/broadcast were lost on quit (now debounce-persisted); divider could shrink a pane below its min size and clip.
- **P1 perf:** `dataReceived` UTF-8-decoded the whole up-to-128KB PTY slice every chunk on the main thread → now decodes only the tail.

## Couldn't fully fix / deferred (residual risk + follow-ups)
- **IME pre-edit (P1, #11):** CJK / dead-key inline composition is invisible — SwiftTerm stubs `hasMarkedText()`/`markedRange()`. A real fix means implementing the NSTextInputClient marked-text protocol inside SwiftTerm (a non-trivial subsystem change). Deferred to avoid rewriting a working subsystem under time pressure. **Risk:** non-Latin input is degraded.
- **Scroll-lock 1-line drift on trim (P1, #15):** while scrolled up during heavy streaming, the locked viewport can drift one line per trimmed scrollback line, because the host can't set SwiftTerm's internal `userScrolling` to use its own trim-compensation. Fix needs another SwiftTerm patch exposing that flag. **Risk:** minor visual drift in an edge case; the lock itself works.
- **Idle "command finished" notification (P1, #7):** the heuristic path is gated off by default (`notifyOnlyOSC133`), so the toggle does nothing without the optional OSC 133 shell snippet. Flipping the default would spam notifications during `claude` (a TUI). **Recommended fix:** auto-fall back to the idle heuristic until an OSC 133 marker is seen, then prefer the accurate path. Left as a product decision.
- **P2 polish (#18–#22):** glyph ghosting concern on glass did **not** reproduce in the live smoke test (claude rendered + reflowed cleanly); promptMarks `⌘↑/⌘↓` drift after scrollback trim; SessionRecorder garbles inline-repainting TUIs; dead `Profile.themeID`; misc (opacity=0 sentinel, 24h clock, per-pane monitors). Low-impact; documented for a follow-up pass.

## Residual-risk notes on the fixes themselves
- The SwiftTerm fixes live in `release_helpers/patch-swiftterm.sh` (sentinel-guarded, idempotent, re-applied by build/stage/test/release). A `swift package update` that bumps SwiftTerm could move an anchor; the patch script fails loudly (`anchor missing`) rather than silently mis-patching.
- Caret sync-deferral and reverse-video rendering are verified by an end-to-end visual smoke test rather than a headless unit test (drawing/async-timing aren't cleanly unit-testable); the supporting color/predicate logic is unit-tested.
- These changes are on `harden/parity-pass` and built into **Termy Dev** (`com.mees.termy.dev`). The daily **Termy.app** is unchanged until a prod build/release.
