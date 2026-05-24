# Termy

A beautiful, fast, native macOS terminal with **Apple's Liquid Glass** aesthetic.

Built in pure SwiftUI + AppKit on top of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the actual terminal emulation, wrapped in a polished window that adapts to your wallpaper.

![Termy screenshot placeholder](docs/screenshot.png)

## Why Termy

iTerm2 is powerful but cluttered. Apple's Terminal.app is bare. Termy is for people who want **iTerm2 power with the look of macOS Tahoe** — and zero config to start.

- **Real liquid glass** — the actual `.glassEffect()` API on macOS 26 Tahoe, plus a `.ultraThinMaterial` fallback on macOS 15 Sequoia
- **Adaptive opacity** — the terminal background subtly increases over light wallpapers so text stays legible
- **Tabs + splits** in one window, multi-window via `⌘N`
- **Themes**: Tokyo Night, Default Dark, Solarized Dark, Gruvbox Dark — switchable from Settings
- **Persistent across launches** — tabs, panes, cwds, theme, font all restore
- **Real terminal**: full ANSI, xterm-256color, 24-bit truecolor, mouse, scrollback (vim/htop/fzf all work)

## Install

### Download the latest release

Grab `Termy.dmg` from the [Releases page](../../releases/latest), drag `Termy.app` into `/Applications`, and run.

The first launch will be blocked by Gatekeeper because the build isn't notarized. Right-click `Termy.app` → **Open** → confirm. (You only need to do this once.)

### Build from source

You need macOS 15+ and Xcode Command Line Tools.

```sh
git clone https://github.com/meesbeuk/termy.git
cd termy
./build.sh
open /Applications/Termy.app
```

## Shortcuts

| Action | Shortcut |
|---|---|
| New tab | `⌘T` |
| Close tab / pane | `⌘W` |
| Next / prev tab | `⌘⇧]` / `⌘⇧[` |
| New window | `⌘N` |
| Split horizontally | `⌘D` |
| Split vertically | `⌘⇧D` |
| Focus next / prev pane | `⌘⌥]` / `⌘⌥[` |
| Find | `⌘F` |
| Clear | `⌘K` |
| Increase / decrease font | `⌘=` / `⌘-` |
| Reset font | `⌘0` |

## Settings

Open via the ⚙ icon in the title bar.

- **Theme** — picker for the bundled color palettes
- **Font family** — picks from monospace fonts installed on this Mac
- **Font size** — slider, or use the shortcuts
- **Background opacity** — manual slider OR enable *Adapt to wallpaper* and Termy picks for you

## What's not in v0.2 yet

Honest list:

- No AI integration (Claude, etc.)
- No command palette (`⌘P`-style switcher)
- No hyperlink click support
- No shell integration markers (iTerm2 protocol)
- No custom keybindings
- No profiles

These are coming. PRs welcome.

## Built with

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation core
- SwiftUI + AppKit
- macOS 26 Tahoe Liquid Glass APIs

## License

MIT — see LICENSE.
