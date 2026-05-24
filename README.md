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
- **Real Quake-style drop-down.** ⌃` slides a persistent panel down from the top of the active display. Stays alive between toggles so it's instant.
- **Inline scrollback search.** ⌘F opens a search-as-you-type bar with regex, case toggle, and prev/next navigation. No NSFindPanel popup from 2007.
- **Liquid-glass window** that stays readable on any wallpaper — adaptive opacity samples the desktop and ramps tint only when it has to.
- **Live preview Settings** for every visual choice — pick a theme by clicking a real mini-terminal, not by guessing from a name.

## Install

```sh
# Latest release
open https://github.com/meesbeuk/termy/releases/latest
# Drag Termy.app to /Applications and right-click → Open the first time.
```

Subsequent versions auto-update via Sparkle. EdDSA-signed since v0.9.4.

**Build from source:**
```sh
git clone https://github.com/meesbeuk/termy.git
cd termy && ./build.sh
```

Requires macOS 15+ and the Xcode Command Line Tools.

## Features

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
- **Command Palette** (⌘⇧P): fuzzy jump to any tab, theme, action, or SSH host.
- **Keyboard cheatsheet** (`?` icon in title strip): one modal listing every shortcut. Discoverable, not docs-only.
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
- **Smart command-finished notifications** — heuristic idle detector for any shell, or **OSC 133 shell integration** for pixel-accurate "Claude finished responding" pings. One-time zsh setup:
  ```sh
  # ~/.zshrc — Termy OSC 133 shell integration
  precmd()  { print -n "\e]133;D;$?\a\e]133;A\a" }
  preexec() { print -n "\e]133;C\a" }
  ```
  After this, Termy notifications fire the instant `claude`, `codex`, `npm test` etc. return, with the last output line as the body. No prompt-line guessing.
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

- **v0.9.11** — Settings consolidated to 5 sections, README rewrite, tab right-click menu (Close Others, Reveal in Finder), ⌘1-⌘9 tab switching.
- **v0.9.10** — Tight launcher row (Claude + Codex), unified title-strip styling.
- **v0.9.9** — Multi-window state survives launches, per-pane profile persistence, Quake settings (hide-on-focus-loss + height slider).
- **v0.9.8** — Live git branch in status bar, Quake opens on the active monitor, keyboard cheatsheet.
- **v0.9.7** — Real Quake drop-down, inline find bar, visible icon affordances.

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
