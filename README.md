<h1 align="center">Termy</h1>

<p align="center">
  <strong>A native macOS terminal built for AI workflows.</strong><br/>
  Liquid glass aesthetic, one-key launchers for Claude Code and Codex, a real Quake drop-down, and inline scrollback search — all in a single app that opens in &lt;0.5s.
</p>

<p align="center">
  <a href="https://github.com/meesbeuk/termy/releases/latest">
    <img alt="Download" src="https://img.shields.io/github/v/release/meesbeuk/termy?style=for-the-badge&label=Download&color=000000">
  </a>
  <a href="https://github.com/meesbeuk/termy/blob/main/LICENSE">
    <img alt="MIT License" src="https://img.shields.io/github/license/meesbeuk/termy?style=for-the-badge&color=000000">
  </a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-000000?style=for-the-badge">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-✓-000000?style=for-the-badge">
</p>

---

## Why Termy

iTerm2 is dated. Warp is cloud-locked. Apple's Terminal.app is barebones. **Termy is what a 2026 macOS terminal should be** — fast, native, beautiful, and aware that your shell sessions are mostly running AI coding tools.

- **One click launches your AI tool of choice.** Claude Code and OpenAI Codex sit in the title strip as proper icon buttons — `claude` or `codex` runs in the active pane with the right enter key, not just types it.
- **Activity stripe** — a thin animated bar pulses at the top of any pane that's busy, so a glance tells you whether claude is still thinking. Works for builds, watchers, anything that prints — no shell integration required.
- **Real Quake-style drop-down.** ⌃` slides a persistent panel down from the top of the active display. Stays alive between toggles so it's instant.
- **Inline scrollback search.** ⌘F opens a search-as-you-type bar with regex, case toggle, and prev/next navigation. No NSFindPanel popup from 2007.
- **Liquid-glass window** that stays readable on any wallpaper — adaptive opacity samples the desktop and ramps tint only when it has to.
- **Live preview Settings** for every visual choice — pick a theme by clicking a real mini-terminal, not by guessing from a name.

## Install

1. Download the latest `Termy.app.zip` from [releases](https://github.com/meesbeuk/termy/releases/latest)
2. Unzip and drag `Termy.app` into `/Applications`
3. The first launch will hit Apple's Gatekeeper ("Apple could not verify Termy is free of malware"). One of:
   - **Easiest:** open Terminal and run `xattr -dr com.apple.quarantine /Applications/Termy.app`, then double-click Termy normally.
   - **GUI route:** click **Done** on the warning, then System Settings → Privacy & Security → scroll to "Termy.app was blocked" → **Open Anyway**.

Subsequent versions auto-update via Sparkle. EdDSA-signed since v0.9.4. (Gatekeeper requires an Apple Developer ID + notarization to bypass on first install; until then the `xattr` one-liner above is the fix.)

**Build from source:**
```sh
git clone https://github.com/meesbeuk/termy.git
cd termy && ./build.sh
```

Requires macOS 15+ and the Xcode Command Line Tools.

## Features

### Run a whole agent fleet (v0.15)
- **Quad Claude** — `⌘⌥N` (or the grid toolbar button) spawns a 2×2 grid with a Claude Code session ready in each pane, in your current project. Define your own named layouts (grid + per-pane cwd + startup command) in the visual layout picker.
- **Agent Dashboard** (`⌘⌥A`) — every pane across every tab at a glance: working / idle / **waiting-for-input**. A pane blocked on a y/n or "proceed?" prompt gets a loud pulsing badge so it never goes unnoticed. Click to focus.
- **Send to one pane** (`⌘⇧S`) and **broadcast** to all — drive one agent or every agent.
- **Pane zoom** (`⌘⇧↩`), and **real drag-to-resize** between any panes (including grids).
- **Resume a past Claude session** into a new pane from the Agent Sessions panel.
- **Claude Usage** (`⌘⌥U`) — tokens + estimated cost (today / 7 days / all-time, by model), read natively from your local logs — no Node, no `ccusage` install.
- **Command Blocks** (`⌘⇧B`) and **inline images** (iTerm2 / kitty / Sixel, plus a native Show Image…).

Every action is reachable without a keybind — menu bar, command palette, right-click, and toolbar buttons — with shortcuts shown inline. Layouts persist as JSON under `termy.layouts.v1`; see `FEATURES_v0.15_REPORT.md` for the config schema, full keybind table, and UI locations.

### Built for AI workflows
- **Vibecoder Mode** — Claude Code + OpenAI Codex quick-launch icons in the title strip. One click, command runs.
- Add other AI CLIs as **Workflows** in the Command Palette (⌘⇧P).
- **SSH host picker** reads `~/.ssh/config` + any `Include` directives, drops every host into the palette.

### Sessions
- **Tabs** (⌘T), **splits** (⌘D / ⌘⇧D), **multi-window** (⌘N) — every window's tabs persist independently and restore on next launch.
- **Quake drop-down** (⌃`) — sticky panel that lives on the active monitor, configurable height + hide-on-focus-loss.
- **⌘1–⌘9** jumps to tab N (⌘9 = last, browser convention).
- **Broadcast input** — mirror keystrokes to every pane in a tab.
- **Drag-drop** files from Finder, **paths auto-quoted** so `/tmp/$(whoami)/file` doesn't get shell-substituted.
- **Recent directories** (⌘⌥/) — jump back to any cwd from any tab.

### Find + navigate
- **Inline find bar** (⌘F): search-as-you-type, case + regex toggles, ⌘G / ⌘⇧G cycles matches. Driven by SwiftTerm's native find API.
- **⌘E "Use Selection for Find"** — standard macOS pattern: select text in a pane, ⌘E opens the find bar prefilled with it.
- **Command Palette** (⌘⇧P): fuzzy jump to any tab, theme, action, or SSH host.
- **Session Logs browser** (⌘⇧L): browse + grep across every past recorded session. Find that one Claude conversation about WebSockets.
- **Keyboard cheatsheet** (⌘/ or `?` icon in title strip): one modal listing every shortcut. Discoverable, not docs-only.
- **Right-click anywhere in a pane** — native menu: Copy, Paste, Select All, Find in Scrollback, Clear, New Tab, Split.
- **Reveal in Finder** from the status-bar cwd or the tab right-click menu.

### Look
- **17 bundled themes** in three families: Modern Dark (Tokyo Night, Catppuccin Mocha, Dracula, Nord, One Dark, Ayu Dark, Monokai Pro, Material Dark, Night Owl, Palenight, Synthwave '84), Classic Dark (Default, Solarized, Gruvbox), Light (Solarized Light, Gruvbox Light, GitHub Light).
- **`.hudWindow` material** for the backdrop — stays dark-glassy whether the wallpaper is white, dark, or anything else.
- **Adaptive opacity** that samples wallpaper brightness and shifts the tint to keep terminal text legible.
- **Every monospaced font** the system has installed — Nerd Fonts, Berkeley Mono, JetBrains Mono, you name it.
- **Density presets** (Compact / Cozy / Spacious) with a real mini-terminal preview at each padding level.

### Profiles
- Saved shell configurations: name, shell path, args, initial cwd, env overrides, tag color, avatar.
- **Local gradient avatars** per profile (no third-party HTTP fetch) — re-roll if you don't like the one you got.
- **Right-click Dock icon → New Tab with Profile** submenu.

### Quality of life
- **Status bar** — cwd (with `~` folding), git branch (refreshes every 4s so `git checkout` reflects without `cd`), clock. Handles worktrees + submodules.
- **Activity stripe** — thin animated bar at the top of any pane producing output. Tells you at a glance whether claude / codex / your build is still working. TimelineView-driven so it can't desync; toggle in Settings.
- **Hover-to-discover links** — URLs and OSC 8 hyperlinks underline on hover, open on a single click. No Cmd modifier needed; works equally in plain shell or inside Claude / Codex.
- **Transcript-style session logs** — opt-in pane recording produces files you can actually read in a text editor. Each prompt + command is one line, output indented under it; alternate-screen runs (claude / vim / less) are summarised as `[interactive program — Xm Ys]`. Browse + grep them via ⌘⇧L; **Clear all** wipes the folder in one click.
- **Smart command-finished notifications** — heuristic idle detector for any shell, or **OSC 133 shell integration** for pixel-accurate "Claude finished responding" pings. One-time zsh setup:
  ```sh
  # ~/.zshrc — Termy OSC 133 shell integration + dynamic tab title
  precmd()  { print -n "\e]133;D;$?\a\e]133;A\a" ; print -Pn "\e]0;%~\a" }
  preexec() { print -n "\e]133;C\a" ; print -Pn "\e]0;$1\a" }
  ```
  After this:
  - Termy notifications fire the instant `claude`, `codex`, `npm test` etc. return, with the last output line as the body.
  - Tab titles show the **currently-running command** (`npm start`, `claude`, etc.) while it runs, and fall back to the cwd at the prompt — no more every-tab-named-`zsh`.
- **Auto-update** via Sparkle, configurable background install.
- **Confirm before quit**, **launch at login**, **hide from Dock** — standard macOS app conveniences, off by default.

## Shortcuts

Press `?` in the title strip for the in-app cheatsheet. Quick reference:

```
⌘T   new tab            ⌘D   split horizontal    ⌘F   find in scrollback
⌘⇧T  duplicate tab      ⌘⇧D  split vertical      ⌘G   next match
⌘W   close pane         ⌘⌥]  focus next pane     ⌘⇧G  prev match
⌘⇧W  close window       ⌘⌥[  focus prev pane     ⌘K   clear screen
⌘N   new window         ⌘⇧]  next tab            ⌘⌥/  recent dirs
⌃`   Quake drop-down    ⌘⇧[  prev tab            ⌘⇧P  command palette
⌘1-9 jump to tab N      ⌘=/-/0 font size
```

## Project status

Termy is shipping rapidly. Recent releases:

- **v0.11.2** — Scroll lock + tab rename sensitivity. Scrolling up no longer gets cancelled by streaming output — Termy now tracks scroll-away state itself (SwiftTerm only lights `userScrolling` on scrollbar drag, not wheel/trackpad) and restores yDisp after SwiftTerm's internal caret-visibility snap. ⌘⇧↓ or scrolling back to the live tail releases the lock so future output auto-snaps as before. Tab title rename is now right-click only — the double-tap gesture was adding a 250 ms delay to every tab switch AND tripping into rename mode on accidental quick double-clicks.
- **v0.11.1** — Scrollback stays put + smarter notifications + perf cache. The unconditional `\e[3J` of v0.11.0 was nuking legitimate scrollback whenever a split closed; now Termy detects TUI redraw cascades adaptively (≥3 full-screen-clears in 5s → suppress, single `clear` → keep history). Notifications redesigned: cwd basename as title, ✓/🔔/⚠ glyphs, 30s dedupe, OSC-133-only by default. Perf: per-byte UserDefaults reads cached via change observer; OSC 133 scanner early-exits on chunks with no ESC; idle timer tears down when pane settles.
- **v0.11.0** — Multi-pane reliability + scrollback fixes. New tab no longer shares the previous tab's NSView (was silently cloning). Split-close no longer leaves a blank pane (was caused by `scrollTo(Int.max/2)` poisoning yDisp). Focus actually moves to the new pane after ⌘T / ⌘D (previously stranded keystrokes on the OLD pane). Scrollback bumped 500 → 10 000 lines so splits don't permanently drop history. TUI welcome banners (claude) no longer stack 4× in scrollback after a resize — Termy clears scrollback on >30% pane size change. Cinema mode actually honours the cps slider now (was clamped to 30 + defeated by a "catch-up" heuristic). Crash fixed in SwiftTerm's `isCursorInViewPort`. Idle timer tears down when panes settle.
- **v0.10.1** — Polish pass: cheatsheet now lists every shortcut (Agent Sessions / Session Logs / Paste History / Quick Select / Use Selection for Find / jump-to-prompt / scroll-to-edge — was missing from the in-app help), Diagnostics report actually shows the env Termy advertises to tools (TERM_PROGRAM, LC_TERMINAL, TERM_FEATURES — were showing as "—"), Command Palette can no longer crash when switching filter category, modal overlays shrink to fit small windows, `termy://palette` / `termy://welcome` / `termy://diagnostics` now reliably show on URL invocation.
- **v0.10.0** — Resize/scrollback bug fixed (history no longer wiped on font/split resize), caret auto-focuses on launch + tab switch, activity stripe, hover-to-open links, transcript-style session logs, **Clear all logs**, notification redesign (no more prompt-soup body lines).
- **v0.9.33** — QuickSelect (⌘⇧/) — Bucket A complete (URLs / file paths / git hashes / IPs from scrollback, click to open).
- **v0.9.32** — Agent Sessions panel (⌘⇧A) — browse every recent Claude Code session, jump back into its directory.
- **v0.9.31** — Paste history (⌘⇧V).
- **v0.9.30** — Jump-to-prompt (⌘↑ / ⌘↓), trigger packs, YAML workflows.

[Full changelog →](https://github.com/meesbeuk/termy/releases)

## Built with

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation core
- [Sparkle](https://sparkle-project.org/) — auto-updater
- [LobeHub icons](https://lobehub.com/icons) — brand SVGs for the AI launcher row
- SwiftUI + AppKit + NSVisualEffectView

## License

MIT — see [LICENSE](LICENSE).

---

<sub><em>Keywords: macOS terminal, modern terminal, iTerm2 alternative, Warp alternative, Claude Code terminal, AI terminal, OpenAI Codex terminal, native macOS app, SwiftUI terminal, vibecoder, liquid glass, Tokyo Night, Catppuccin, Dracula, terminal emulator, Quake terminal, scrollback search, tmux alternative</em></sub>
