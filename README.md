# Termy

A beautiful, fast, native macOS terminal **built for vibecoders** — with **Apple's Liquid Glass** aesthetic and one-click access to Claude / Codex / Cursor / VS Code / Aider straight from the title bar.

Built in pure SwiftUI + AppKit on top of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the actual terminal emulation, wrapped in a polished window that adapts to your wallpaper.

![Termy screenshot placeholder](docs/screenshot.png)

## Why Termy

iTerm2 is powerful but dated. Warp is great but cloud-tied. Apple's Terminal.app is bare. Termy is for people who want **a clean fast native macOS terminal that knows you live in AI tools** — Claude, Codex, Cursor — without forcing you into a specific workflow.

- **Vibecoder Mode** (default on) — quick-launch row in the title strip for Claude / Codex / Cursor / VS Code / Aider. `⌘L` for the full launcher.
- **Real liquid glass** — the actual `.glassEffect()` API on macOS 26 Tahoe, plus a `.ultraThinMaterial` fallback on macOS 15 Sequoia
- **Adaptive opacity** — the terminal background subtly increases over light wallpapers so text stays legible
- **Tabs + splits** in one window, multi-window via `⌘N`, duplicate tab via `⌘⇧T`
- **Recent directories** picker (`⌘⌥/`) — jump back into any cwd from any tab
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
| **Launch AI tool** | `⌘L` |
| **Recent directories** | `⌘⌥/` |
| New tab | `⌘T` |
| Duplicate tab | `⌘⇧T` |
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

## Roadmap

Big features on deck (cross-referenced from Warp / WezTerm / iTerm2 / Ghostty / Hyper / Tabby):

- **Profiles** — named configurations (shell + env + theme + cwd) per profile
- **Quick terminal hotkey window** — slide-down terminal anywhere on screen
- **Hyperlink + file path click** (`⌘+click`)
- **Drag-drop file paths** from Finder
- **Process-done notifications** for long-running commands
- **Command palette** (`⌘⇧P`) — fuzzy jump to tab / theme / action
- **Workflows / saved commands** with parameter slots
- **Broadcast input** to all panes in a tab
- **Shell integration markers** (OSC 133) → jump-to-prompt + Warp-style command blocks
- **Inline image rendering** (sixel / kitty / iTerm protocols)
- **SSH host manager** reading `~/.ssh/config`
- **Inline AI chat panel** with current-pane context
- **Tab color tagging**
- **Triggers** (regex → action)
- **Auto-updater** via Sparkle

PRs welcome.

## Built with

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation core
- SwiftUI + AppKit
- macOS 26 Tahoe Liquid Glass APIs

## License

MIT — see LICENSE.
