<h2>v0.15.0 — Agents, Layouts &amp; Mission Control</h2>
<p>The biggest feature release yet: Termy is now built around running <em>several</em> AI agents at once. 58 automated tests added (49 → 107).</p>
<ul>
  <li><b>Quad Claude.</b> One press of <kbd>&#8984;&#8997;N</kbd> (or the grid button in the toolbar) spawns a 2&times;2 grid with a Claude Code session ready in each pane, all in your current project. Built on a reliable launch path — no blind timed keystrokes.</li>
  <li><b>Layout system.</b> Named multi-pane layouts (grid + per-pane working dir &amp; startup command), with a visual picker (live thumbnails), an editor, "save current tab as layout", and a &#9733; quick-layout. Built-ins: Quad Claude, Dual Claude, Claude + Shell.</li>
  <li><b>Real pane resizing.</b> The divider had effectively no grab zone — fixed. It now has a proper hit area + a visible handle on hover; drag between any panes, including grid cells.</li>
  <li><b>Agent Dashboard</b> (<kbd>&#8984;&#8997;A</kbd>). Every pane across every tab at a glance — working / idle / <b>waiting-for-input</b>. Click a row to focus that pane.</li>
  <li><b>Waiting-for-input detection.</b> A pane sitting at a y/n or "proceed?" prompt (Claude permission prompts, npm/git confirmations) is flagged with a pulsing badge, so a blocked agent never goes unnoticed across a wall of panes.</li>
  <li><b>Send to one pane</b> (<kbd>&#8984;&#8679;S</kbd>) — targeted input to a single pane, the complement to broadcast.</li>
  <li><b>Pane zoom</b> (<kbd>&#8984;&#8679;&#9166;</kbd>) — maximise the focused pane and restore; siblings stay alive.</li>
  <li><b>Resume a past Claude session</b> straight into a new pane from the Agent Sessions panel.</li>
  <li><b>Claude Usage</b> (<kbd>&#8984;&#8997;U</kbd>) — tokens + estimated cost for today / 7 days / all time, by model, read natively from your local Claude logs (no Node dependency).</li>
  <li><b>Inline images</b> — render images inline via the iTerm2 / kitty / Sixel protocols, plus a native "Show Image…".</li>
  <li><b>Command Blocks</b> (<kbd>&#8984;&#8679;B</kbd>) — collapsible command + output history from OSC 133 shell-integration marks, with copy-output and jump-to.</li>
  <li><b>7 new themes</b> — Ros&eacute; Pine, Kanagawa, Everforest, Catppuccin Latte, Ros&eacute; Pine Dawn, Solarized Light, Gruvbox Light (24 total).</li>
  <li><b>Secure Keyboard Entry</b> — opt-in protection so other processes can't read keystrokes during password / auth flows.</li>
</ul>
<p><i>Every new action is reachable without a keyboard shortcut — macOS menu bar, command palette, right-click, and tasteful toolbar buttons — with shortcuts shown inline. See FEATURES_v0.15_REPORT.md in the repo for the full breakdown, the Ghostty parity matrix, and residual-risk notes.</i></p>
