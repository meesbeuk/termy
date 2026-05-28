# Termy v0.15.0 — New Features Build: Final Report

Branch: `feat/layouts-mission-control` → merged to `main`. 18 logical commits, each
with a focused message. Test suite grew **49 → 107** (Swift Testing, all green).
Every feature was verified by build + automated tests; per the user's request,
no computer-use/visual testing was performed.

---

## 1. Committed scope — all shipped

### Layouts / Quad Claude
- **Grid layout mode** (`TerminalTab.gridColumns`, `PaneMath` grid geometry,
  `PaneLayout` grid renderer). Additive: `gridColumns == nil` is the original
  flat single-orientation behaviour, untouched. Panes are positioned by absolute
  rect in one id-keyed `ForEach`, so a grid reflow never re-parents (restarts) a
  pane's shell.
- **Layout model + store** (`TermyLayout`, `LayoutStore`): named layouts, grid
  columns, per-pane cwd + startup command. Persisted to UserDefaults (Profile
  pattern). Built-ins: **Quad Claude** (2×2, 4× `claude`), **Dual Claude**,
  **Claude + Shell**. User-definable + editable + "save current tab as layout".
- **Reliable launch path**: `TermyLayout.plan(baseCwd:)` resolves a layout
  (empty cwd → inherit current; empty command → plain shell) and
  `TerminalSessions.spawnLayout` delivers each command via `pendingInitialCommand`
  — the same path Termy uses to run a dropped script (real Enter once the shell
  is up). No blind timed keystrokes.
- **Visual layout picker** (`LayoutPicker.swift`): cards with accurate
  thumbnails, ★ quick-layout, editor (name / columns / per-pane command + cwd),
  duplicate built-ins, delete.

### Mission control
- **Agent Dashboard** (`AgentDashboard.swift`): every pane across all tabs,
  tagged working / idle / waiting, live counts (1 s tick) with stable order;
  click to focus.
- **Waiting-for-input detection** (`PaneActivityClassifier`): pure, conservative
  cue detector (y/n, numbered choice, "proceed?", arrow-select). Loud in-pane
  pulsing badge + accent ring. Built on the existing activity/idle transition.
- **Targeted send-to-pane** (`SendToPane.swift`, `TerminalSessions.send(text:
  toPaneId:)`): pick a pane, send a line with a real Enter.
- **Pane zoom** (`TerminalTab.zoomedPaneId`, `toggleZoomActivePane`): maximise
  the focused pane; siblings stay mounted off-screen (no shell restart);
  auto-clears on close / collapse to one pane.

### Flashier
- **Inline images**: SwiftTerm already renders iTerm2 (OSC 1337) / kitty / Sixel
  from program output (`imgcat`, `viu`, `chafa`, kitty icat). Added a native
  **Show Image…** that renders a user-picked image via `createImage` (injected
  into the terminal stream, not the shell's stdin), gated by `InlineImagePolicy`.
- **Command Blocks** (`CommandBlock`, `CommandBlocksPanel.swift`): captured at
  OSC 133 C/D — command line + output preview — in a collapsible panel with
  copy-output and jump-to. SwiftTerm renders the grid itself, so inline
  scrollback folding isn't possible without engine changes; this is the honest
  companion-panel delivery built on the marks we already track.

### Also
- **Resume agent session** (`ClaudeResume`, `openTabRunning`): "Resume session"
  button in the Agent Sessions panel relaunches `claude --resume <id>` (or
  `--continue`) in a new pane in the session's project dir. The id is sanitised
  so a filename-derived value can't inject into the shell line.

---

## 2. Own additions (beyond committed scope)

- **Native Claude Usage panel** (`ClaudeUsage*`): reads `~/.claude/projects/**/*.jsonl`
  natively (the data ccusage parses — no Node dependency), dedupes by
  message+request id, shows tokens + estimated cost for today / 7 days / all time
  and a per-model breakdown. Cost is clearly labelled estimated. *(User asked
  whether to integrate ccusage; built native instead of bundling the CLI.)*
- **Theme audit** — added 7 modern palettes (Rosé Pine, Kanagawa, Everforest,
  Catppuccin Latte, Rosé Pine Dawn, Solarized Light, Gruvbox Light); 17 → 24, with
  a real light selection. *(User request.)*
- **Secure Keyboard Entry** — opt-in (default off), balanced to app-active state.
  *(Ghostty parity.)*
- **Resize hitbox fix** — the pre-existing divider's content shape was
  zero-height, so panes couldn't be resized at all; rewritten with a real grab
  zone + visible handle. *(User report.)*
- **Discoverability pass** — closed audit-found gaps in existing features (Close
  Pane + Focus Pane on right-click, pane-focus in the palette, fixed a stale
  cheatsheet entry, keybinds shown inline on context-menu items).

---

## 3. Config format (layouts)

Layouts persist to `UserDefaults` key `termy.layouts.v1` as JSON (built-ins are
code-defined and always present). Schema per user layout:

```json
{
  "id": "<uuid>",
  "name": "My Layout",
  "symbol": "square.grid.2x2",
  "columns": 2,
  "isBuiltIn": false,
  "panes": [
    { "id": "<uuid>", "cwd": "", "command": "claude", "profileID": null }
  ]
}
```

- `columns` — panes tile row-major into this many columns. 1 row → horizontal
  split; 1 column → vertical split; otherwise grid mode.
- `cwd` empty → inherits the cwd active when the layout is spawned.
- `command` empty → a plain shell.
- The quick-layout (spawned by ⌘⌥N) id is stored at `termy.layouts.quickID`.

Edit via the visual picker (Layouts button / palette / Terminal ▸ New Layout ▸
Layout Picker…). Grid sizes + zoom + layout persist across relaunch via the
window restore payload.

---

## 4. Keybinds + where every action lives

| Action | Keybind | Menu | Palette | Right-click | Toolbar | Cheatsheet |
|---|---|---|---|---|---|---|
| New layout (quick / Quad Claude) | ⌘⌥N | Terminal ▸ New Layout | ✓ (per layout) | — | grid button | ✓ |
| Layout picker | — | Terminal ▸ New Layout ▸ Picker | ✓ | — | grid button | ✓ |
| Agent dashboard | ⌘⌥A | Terminal | ✓ | — | group button | ✓ |
| Send text to pane | ⌘⇧S | Terminal | ✓ | ✓ | — | ✓ |
| Zoom / restore pane | ⌘⇧↩ | Terminal | ✓ | ✓ | toggle button | ✓ |
| Command blocks | ⌘⇧B | Terminal | ✓ | — | — | ✓ |
| Show image | — | Terminal | ✓ | — | — | ✓ |
| Claude usage | ⌘⌥U | Termy | ✓ | — | — | ✓ |
| Resume agent session | — | — | — | — | Agent Sessions panel | ✓ |
| Secure keyboard entry | — | Termy (toggle) | — | — | — | ✓ |
| Focus next/prev pane | ⌘⌥] / ⌘⌥[ | Terminal | ✓ | ✓ (next) | — | ✓ |
| Resize panes | — drag divider | — | — | — | divider handle | ✓ |

---

## 5. Subsystem changes (isolated, reviewable)

- **Grid layout mode** — extension to the pane model, fully guarded by
  `gridColumns == nil` so existing tabs/splits are byte-for-byte unchanged. One
  commit (`feat(panes): optional grid layout mode`).
- **ResizableDivider rewrite** — divider grab zone + affordance; widened
  `PaneMath.dividerWidth` 4 → 8 (symbolic in tests, no breakage). One commit.
- No working subsystem was rewritten wholesale; everything else is additive.

---

## 6. Ghostty parity (cross-reference)

Researched ghostty.org/docs and matched against Termy. **Termy is already ahead**
on AI-workflow features Ghostty has no equivalent for: Quad Claude / grid
layouts, the agent dashboard + waiting-for-input detection, Vibecoder launchers,
triggers/trigger-packs, the activity stripe, adaptive wallpaper-aware opacity,
Sparkle auto-update, and now native Claude usage. At parity on: tabs/splits/quake,
OSC 133 + jump-to-prompt, kitty keyboard protocol, command palette, find,
notifications, background opacity/blur, minimum-contrast, hyperlinks.

**Closed this release:** inline image affordance, secure keyboard entry, real
pane resize, a fuller theme set.

**Residual gaps (documented, not shipped):**
- **Ligatures / font-feature shaping** — genuine engine-level gap; SwiftTerm has
  no ligature API. Large; needs upstream work or a custom glyph-run shaper. P1
  for a future release.
- **Terminal-content VoiceOver** — SwiftTerm ships `MacAccessibilityService` +
  `screenReaderMode`; Termy doesn't enable it yet. P1, medium effort; deferred
  because it couldn't be verified without VoiceOver testing this session.
- **OSC 52 clipboard read/write permission gating** — security nicety. P2.
- **User-rebindable keybindings, native scrollbars, GPU/Metal renderer + custom
  shaders, background images** — P2 polish; the Metal renderer (and thus shaders)
  is a large effort and not aligned with the AI-workflow thesis.
- Not worth copying: config-file-as-primary-interface, proxy icon (conflicts with
  the hidden-titlebar glass look).

---

## 7. Residual risk / verification notes

- **Inline image pixel rendering** relies on SwiftTerm's `createImage`; the engine
  ships the decoders and Termy advertises the protocols, but on-screen rendering
  was **not** visually verified this session (no computer-use, per request). If a
  rendering issue surfaces, the Ghostty research notes likely culprits (the
  forced full-redraw or overlay interference) — start in `TerminalSurface`.
- **Waiting-for-input** fires on the idle transition (~4 s after output stops for
  shells without OSC 133), and the classifier is deliberately conservative
  (favours idle over a stuck false badge). Cue list may need tuning as agent
  prompt wording changes.
- **Command blocks** populate only for shells with OSC 133 integration; output is
  the rolling ~2 KB preview (tail), not the full transcript — labelled as such.
- **Claude usage cost** is an estimate from a built-in price table; token totals
  are exact, prices drift.
- **Secure keyboard entry** is opt-in (default off) so the default experience is
  unchanged; enable/disable is balanced to app-active state.
