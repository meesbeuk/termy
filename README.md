# Termy

A fast, native macOS terminal **built for vibecoders** — Apple Liquid Glass aesthetic, one-click access to Claude / Codex / Cursor / Gemini CLI / GitHub Copilot from the title strip, and a profile-aware session model so every shell session matches your setup.

Built in SwiftUI + AppKit on top of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the actual terminal emulation, wrapped in a polished window that uses the `.hudWindow` material so text stays readable on any backdrop (white app, dark photo, anything).

## Why Termy

iTerm2 is powerful but dated. Warp is great but cloud-tied. Apple's Terminal.app is bare. Termy is for people who want **a clean fast native macOS terminal that knows you live in AI tools** — Claude, Codex, Cursor — without forcing you into a specific workflow.

## Features

### Vibecoder workflow
- **Vibecoder Mode** (default on) — quick-launch row in the title strip for Claude Code, OpenAI Codex, Cursor, Gemini CLI, GitHub Copilot, Aider. One click runs the CLI with Enter, not just types it.
- **Real brand icons** — bundled SVGs from [LobeHub](https://lobehub.com/icons), rendered template-mode so they tint with the active theme.
- **Hover label** — pill next to the icon shows the tool name; no SF Symbol guessing game.

### Sessions
- **Tabs + splits** in one window — `⌘T` new tab, `⌘D` horizontal split, `⌘⇧D` vertical split, `⌘⌥]/[` cycle focus.
- **Multi-window** — `⌘N` opens a new independent window with its own tab list.
- **Quake-style drop-down terminal** — `⌃`` (Control-backtick) slides a persistent panel down from the top of the active display. Same panel toggles in and out; its shell stays alive between toggles so it's instant. Hides on focus loss.
- **Duplicate tab** — `⌘⇧T`.
- **Recent directories** picker — `⌘⌥/` to jump back into any cwd from any tab.
- **Broadcast input** — mirror keystrokes to every pane in a tab (right-click the tab to toggle).
- **Drag-drop** file paths from Finder straight into the active pane (auto-quoted).
- **Inline find** — `⌘F` opens a search-as-you-type bar with case + regex toggles; `⌘G` / `⌘⇧G` cycles matches.

### Profiles
- Saved shell configurations: name, shell path, args, initial cwd, environment overrides, tag color.
- **Per-profile avatar** — local deterministic gradient + initial circle keyed off a stable seed so you can pick your profile out at a glance. Re-roll button generates a fresh seed.
- Set a default profile and every new tab uses its shell / env / cwd.
- Right-click Termy in the Dock → **New Tab with Profile** submenu.
- Delete confirmation + last-profile guard so you can't end up with zero profiles.

### Look
- **NSVisualEffectView `.hudWindow` material** for the window backdrop — dark glassy surface that stays readable on a white app behind it, not just on dark wallpapers.
- **Adaptive tint** layered on top — small extra darken on light wallpapers, full glass on dark.
- **17 themes** in three categories: Modern Dark (Tokyo Night, Catppuccin Mocha, Dracula, Nord, One Dark, Ayu Dark, Monokai Pro, Material Dark, Night Owl, Palenight, Synthwave '84), Classic Dark (Default, Solarized, Gruvbox), Light (Solarized Light, Gruvbox Light, GitHub Light).
- **Live theme switching** — no restart.
- **Density presets** — Compact / Cozy / Spacious, with a real mini-terminal preview showing the actual padding each produces.
- **Font family + size** with live preview; `⌘+ / ⌘- / ⌘0` for size.
- **Tab tag colors** — 9 options, set per tab via right-click or per profile.

### Quality of life
- **Command Palette** — `⌘⇧P`, fuzzy jump to tab / theme / action / SSH host. Sidebar layout matches the Settings sheet.
- **Visible chrome icons** — every keyboard shortcut also has a clickable icon in the title strip (search, palette, recent dirs, splits, Quake drop-down, settings) so features are discoverable without reading docs.
- **SSH profile manager** — reads `~/.ssh/config` plus any `Include` directives (e.g. `~/.ssh/config.d/*`) and surfaces hosts in the Command Palette.
- **Status bar** — cwd (with `~` folding), git branch (worktree + submodule safe), clock.
- **Process-done notifications** — toggle in General settings; add `precmd() { print -n "\a" }` to `.zshrc` to get a system notification when a long command finishes in a background window.
- **Sparkle auto-updater** — Settings → Updates → "Automatically check" + "Automatically download + install in background". No reinstalls.
- **Persistent across launches** — tabs, panes, cwds, theme, font, profiles all restore.

### Standard app
- Launch at login (via `SMAppService`).
- Hide from Dock (menu-bar-only style).
- Confirm before quitting.
- Right-click Termy in the Dock → New Window / New Tab / Quick Terminal / per-profile submenu.

## Install

### Download the latest release

Grab `Termy.dmg` from the [Releases page](../../releases/latest), drag `Termy.app` into `/Applications`, and run.

The first launch will be blocked by Gatekeeper because the build isn't notarized. Right-click `Termy.app` → **Open** → confirm. (You only need to do this once.)

Subsequent versions auto-update via Sparkle — no manual reinstall.

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
| Duplicate tab | `⌘⇧T` |
| Close pane (cascades to tab / window) | `⌘W` |
| Close window | `⌘⇧W` |
| Next / previous tab | `⌘⇧]` / `⌘⇧[` |
| New window | `⌘N` |
| Quick Terminal | `⌃`` |
| Split horizontally | `⌘D` |
| Split vertically | `⌘⇧D` |
| Focus next / previous pane | `⌘⌥]` / `⌘⌥[` |
| Recent directories | `⌘⌥/` |
| Command Palette | `⌘⇧P` |
| Find in scrollback | `⌘F` |
| Next / previous find match | `⌘G` / `⌘⇧G` |
| Clear | `⌘K` |
| Increase / decrease font | `⌘=` / `⌘-` |
| Reset font | `⌘0` |

## Settings

Open via the ⚙ icon in the title bar.

- **General** — launch at login, hide from Dock, confirm-on-quit, bell notifications.
- **Profiles** — saved shell configurations with memoji avatars.
- **Vibecoder** — toggle the AI launcher row.
- **Theme** — 17 bundled themes with previews.
- **Font** — family + size picker with live preview.
- **Density** — Compact / Cozy / Spacious padding.
- **Chrome** — show / hide tab bar and status bar.
- **Background** — opacity slider, auto-adapt-to-wallpaper toggle.
- **Updates** — current version, last-checked timestamp, auto-check + auto-install toggles.
- **About** — version, build, repo link.

## Known limitations

Honest list, so you know what you're getting:

- **Multi-window tab restore is lossy.** Every window writes to the same UserDefaults key — the last one to save wins on relaunch. Fine if you mostly use one window. Multi-window people will lose state across launches.
- **No OSC 133 shell-integration markers** yet, which means: no Warp-style command blocks, no perfectly-accurate "command finished" notifications (we use a bell-based heuristic instead), no regex triggers on command output.
- **No sixel / kitty / iTerm image protocols** — image rendering in the terminal isn't supported.
- **No inline AI chat panel** — Termy launches AI CLIs; it doesn't embed a chat surface.
- **Cursor style / blink isn't configurable** — SwiftTerm doesn't expose a public hook for it on macOS.
- **`copyOnSelect` isn't supported** for the same reason.

These are either deferred features (open to PRs) or SwiftTerm-protocol-blocked.

## Roadmap

Open to PRs on the deferred items above. The big-ticket additions worth building next:

- OSC 133 shell integration → command blocks, accurate process notifications, regex triggers
- Per-pane profile persistence (so split restore remembers which profile each pane used)
- Per-window UserDefaults namespacing so multi-window tab restore stops trampling

## Built with

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation core
- [Sparkle](https://sparkle-project.org/) — auto-updater
- [LobeHub icons](https://lobehub.com/icons) — brand SVGs for the AI launcher row
- SwiftUI + AppKit + NSVisualEffectView

## License

MIT — see [LICENSE](LICENSE).
