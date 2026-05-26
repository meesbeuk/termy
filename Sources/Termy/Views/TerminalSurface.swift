import SwiftUI
import AppKit
import ObjectiveC.runtime
import SwiftTerm

/// SwiftTerm's CursorStyle enum doesn't expose a string parser by default.
/// We store the rawValue string in UserDefaults so the on-disk format is
/// stable across binary rebuilds; this maps it back to the enum.
extension SwiftTerm.CursorStyle {
    static func from(string: String) -> SwiftTerm.CursorStyle? {
        switch string {
        case "blinkBlock": return .blinkBlock
        case "steadyBlock": return .steadyBlock
        case "blinkUnderline": return .blinkUnderline
        case "steadyUnderline": return .steadyUnderline
        case "blinkBar": return .blinkBar
        case "steadyBar": return .steadyBar
        default: return nil
        }
    }
}

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView`.
/// Each instance owns a separate shell process — its lifecycle is tied to the
/// `TerminalSession` model, not to the view tree, so tab switches don't fork
/// new shells.
/// Subclass that hooks the bell so we can fire a notification when an
/// unfocused window beeps. Overriding the view-level `bell(source: Terminal)`
/// is safe — it doesn't touch the terminalDelegate (replacing that would
/// disconnect keyboard input, as v0.8.0–0.8.2 painfully proved).
final class TermyTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    /// Fires when this pane goes from "actively producing output" to
    /// "settled for the configured idle threshold". The `preview`
    /// parameter carries the most recent chunk of received text so the
    /// notification can show *what* finished, not just *that* something
    /// finished. Wired up in TerminalSurface to call TermyNotifications.
    var onCommandSettled: ((_ preview: String?, _ viaOSC133: Bool) -> Void)?

    /// Fires when this pane transitions between "actively producing
    /// output" and "settled". Drives the activity stripe rendered above
    /// the pane — same heuristic that powers `onCommandSettled`, just
    /// reported as a leading edge instead of only the trailing edge.
    var onActivityChanged: ((_ active: Bool) -> Void)?

    /// Re-applies theme + caret colors. Set by TerminalSurface so we can
    /// re-run it both when the view first lands in a window AND on first
    /// non-zero layout. SwiftTerm's caret is positioned by updateDisplay,
    /// and updateDisplay reads frame.height — so an applyAppearance fired
    /// while frame is .zero positions the caret off-screen and it never
    /// paints. Theme switches accidentally fix this because updateNSView
    /// re-fires applyAppearance once the view has a real frame.
    var onNeedsAppearanceRefresh: (() -> Void)?

    /// Tracks whether we've ever laid out at a non-zero size. Used to fire
    /// `onNeedsAppearanceRefresh` exactly once after the first real layout
    /// so the caret renders without requiring a theme switch.
    private var hasLaidOutAtRealSize = false

    // MARK: - Command-finished tracking
    //
    // TWO mechanisms, in priority order:
    //
    //   1. **OSC 133 shell integration** — if the user's shell emits
    //      FinalTerm-style markers (`\e]133;D` for command-done), we
    //      catch them and fire onCommandSettled immediately and
    //      accurately. Setup is a one-line addition to .zshrc/.bashrc
    //      (documented in README).
    //
    //   2. **Idle heuristic** — fallback for shells without OSC 133.
    //      Watches for "active output → quiet for N seconds" transitions.
    //      Works for any long-running command (claude, codex, npm test,
    //      cargo build, etc.).
    //
    // Both feed the same onCommandSettled callback. When OSC 133 fires
    // during a burst, we suppress the upcoming idle fire so the user
    // doesn't get two notifications for one command.
    private var lastDataAt: Date = .distantPast
    private var bytesSinceBurstStart: Int = 0
    private var isCurrentlyActive = false
    private var idleTimer: Timer?
    private var lastPreviewBuffer: String = ""
    private var osc133JustFired = false

    /// Tracks the rolling state of an in-progress OSC 133 sequence so we
    /// can match `\e]133;D` (with optional `;<exit>`) regardless of byte
    /// chunk boundaries. SwiftTerm hands us partial reads constantly.
    private var oscBuffer: [UInt8] = []
    private var inOSC = false

    /// Per-pane line accumulator for trigger evaluation. Triggers fire
    /// per complete line (newline-terminated), not per byte chunk, so
    /// we hold partial input until a `\n` arrives. Capped at 4KB to
    /// bound memory for streams without newlines.
    private var triggerLineBuffer: String = ""
    /// Active trigger set, refreshed on every dataReceived (cheap —
    /// reads from a singleton, copies a small array). nil means triggers
    /// haven't been wired up yet (no TriggerRegistry callback set).
    var triggerProvider: (() -> [Trigger])?
    var onTriggerFired: ((Trigger, String) -> Void)?

    /// Returns the recent text buffer (with ANSI stripped) for use by
    /// QuickSelect to scan visible-ish output for URLs / paths / hashes.
    /// Bounded by lastPreviewBuffer's cap so a 1GB transcript doesn't
    /// scan forever.
    func recentVisibleText() -> String {
        let range = NSRange(lastPreviewBuffer.startIndex..., in: lastPreviewBuffer)
        return Self.ansiCSIRegex.stringByReplacingMatches(
            in: lastPreviewBuffer, range: range, withTemplate: ""
        )
    }

    /// Compiled once per app lifecycle. Previously this regex was built
    /// fresh inside both `recentVisibleText()` and `stripAnsiCSI()` —
    /// the latter runs per LINE in `scanForTriggers`, so a streaming
    /// command produced one `NSRegularExpression` alloc per output
    /// line. Caching cuts that to zero. Pattern matches CSI sequences:
    /// `ESC [`, optional params (`0-?`), optional intermediates (` -/`),
    /// final byte (`@-~`).
    static let ansiCSIRegex: NSRegularExpression = {
        // try! is safe — this literal compiles or the binary doesn't
        // ship. The pattern was previously `try?`-checked at every
        // call site as a paranoid guard; lift that to startup.
        try! NSRegularExpression(pattern: "\\x1B\\[[0-?]*[ -/]*[@-~]")
    }()

    /// Absolute row positions (in the scrollback line buffer) where
    /// the shell emitted an OSC 133;A (prompt start). Lets `⌘↑/⌘↓`
    /// jump prompt-to-prompt without the user scrolling. Capped at
    /// 1000 to bound memory for marathon sessions; oldest dropped.
    var promptMarks: [Int] = []

    // MARK: - Cinema mode (typewriter pacer)
    //
    // Optional feature for users recording Termy demos / screencasts.
    // When on, incoming PTY bytes are queued and drained at a fixed
    // characters-per-second rate so streaming output looks "smooth
    // typewriter" instead of frame-coalesced bursts on camera.
    //
    // Critically: pace command OUTPUT only, never the echo-back of
    // typed characters. The PTY doesn't tag bytes as "echo" vs
    // "output" — the shell echoes back typed chars through the same
    // stdout stream as command output. Heuristic: bytes arriving
    // within `cinemaInputEchoWindow` of the last keystroke are
    // treated as echo and bypass the pacer. Bytes arriving after a
    // quiet keyboard period are command output and get queued.
    // Without this gate, typing into the prompt feels laggy because
    // each echoed character renders one timer-tick later instead of
    // instantly.
    private var typewriterQueue: [UInt8] = []
    private var typewriterTimer: Timer?
    private var lastKeyDownAt: Date = .distantPast
    /// Bytes arriving within this window of the last keystroke are
    /// treated as terminal echo of the user's input, not as command
    /// output, and bypass the cinema pacer entirely. ~200ms covers
    /// even slow PTY roundtrips on local shells and pasted input
    /// where multiple keystrokes fire in rapid succession.
    private let cinemaInputEchoWindow: TimeInterval = 0.2
    /// Local NSEvent monitor used to stamp `lastKeyDownAt` when the
    /// user types into THIS view. Installed once per view in
    /// viewDidMoveToWindow; nil'd in deinit. Can't override
    /// `keyDown(with:)` directly because SwiftTerm's
    /// LocalProcessTerminalView declares it as a non-open Swift
    /// method, so subclass overrides are rejected at compile time.
    private var cinemaKeyMonitor: Any?

    // MARK: - Session recording (optional, off by default)
    //
    // When the user opts in via Settings → General → Notifications →
    // "Record session output", every pane streams its decoded text to a
    // per-session log file under ~/Library/Application Support/Termy/
    // sessions/. SessionRecorder strips ANSI/OSC/DCS so the file opens
    // cleanly in any text editor. One file per pane lifecycle; closed in
    // deinit.
    private var recorder: SessionRecorder?
    private var recordingChecked = false
    /// Cached values used to seed the recorder header on first byte —
    /// SwiftTerm doesn't surface cwd/shell directly to the view, so
    /// TerminalSurface passes them in via configureRecording().
    var recordingCwd: String?
    var recordingShell: String?

    /// Bytes accumulated within a single burst before the pane is
    /// considered "active". One-byte rerenders (just a prompt refresh)
    /// shouldn't count. 64B is enough to filter prompt redraws but small
    /// enough to catch short-running commands.
    private let activeByteThreshold = 64

    // MARK: - Inactive-pane caret reinforcement
    //
    // SwiftTerm draws a 3pt hollow stroke caret when its view isn't
    // first responder (Apple/CaretView.swift). On bright glass / busy
    // wallpapers the stroke blends with the foreground theme color and
    // is effectively invisible — users can't tell where the cursor is
    // in inactive split panes. Overlay a higher-contrast filled rect
    // with a brighter border on top, only when this pane is NOT first
    // responder and its parent window IS key.
    private var inactiveCaretLayer: CALayer?

    // MARK: - Drag-and-drop state
    //
    // While a Finder drag hovers, paint a 2pt accent border on the
    // pane to confirm the drop target. Removed on exit/end.
    private var dragHighlightLayer: CALayer?

    // MARK: - User-scroll lock (anti-stick-to-bottom)
    //
    // SwiftTerm auto-snaps the viewport to the live tail every time new
    // output arrives, unless its internal `userScrolling` flag is set.
    // That flag is set ONLY during scrollbar drag — not during
    // mouse/trackpad scrollWheel — so if the user scrolls up to read
    // claude's earlier paragraph while claude is still streaming, the
    // next token chunk yanks them right back to the bottom. Track
    // user scroll-away ourselves via scrollWheel and freeze yDisp on
    // each dataReceived until the user explicitly returns to bottom.
    private var userScrolledAway: Bool = false
    /// The absolute scrollback row the user is locked to while
    /// scrolled away. Captured ONCE when the user first scrolls
    /// away (or on the first dataReceived that observes them
    /// scrolled), and held until they explicitly return to the
    /// tail. Using a stored row instead of re-snapshotting per
    /// chunk means async restores don't race against incoming
    /// output — the lock target stays put even as multiple data
    /// chunks fire while a restore is in flight.
    private var lockedRow: Int? = nil
    /// Tolerance for "at bottom" check — scrollPosition is a Double
    /// 0..1 ratio; floating-point rounding can leave a fully-scrolled
    /// view at 0.9998 instead of 1.0.
    private let scrollPositionTailEpsilon: Double = 0.005

    /// Re-evaluate the lock state from current yDisp/scrollPosition.
    /// Called synchronously inside `dataReceived` (per chunk) so the
    /// lock is always in sync with the latest user scroll — no async
    /// dispatch, no stale `lockedRow`, no race between scroll wheel
    /// events and chunk arrivals.
    private func recomputeScrollLock() {
        guard canScroll else {
            releaseScrollLock()
            return
        }
        let atTail = scrollPosition >= (1.0 - scrollPositionTailEpsilon)
        if atTail {
            releaseScrollLock()
        } else {
            userScrolledAway = true
            // ALWAYS update to current yDisp — if the user scrolled
            // since the last chunk, follow them. Without this, the
            // sync restore would yank them back to the original
            // locked row instead of the row they just scrolled to,
            // which is the "scrolling feels glitchy" symptom.
            lockedRow = getTerminal().buffer.yDisp
        }
    }

    /// Public release entry point — called by explicit user actions
    /// that should bring them back to the live tail (⌘⇧↓ scroll to
    /// bottom, PageDown to bottom, etc.). Safe to call even when no
    /// lock is active; it just no-ops in that case.
    func releaseScrollLock() {
        userScrolledAway = false
        lockedRow = nil
    }

    /// NSEvent local monitor for scroll wheel + flags-changed events.
    /// SwiftTerm's `scrollWheel(with:)` is declared non-open so we
    /// can't override it; instead intercept the same event at the
    /// app event loop. We only sample the state AFTER SwiftTerm has
    /// processed the wheel event (the monitor's closure runs after
    /// the normal responder chain), so `scrollPosition` reflects
    /// the post-scroll value.
    private var scrollMonitor: Any?

    private func installScrollMonitor() {
        if scrollMonitor != nil { return }
        // Lightweight monitor — kept solely to recompute the lock when
        // the user scrolls back to the tail while no chunks are
        // streaming. If we relied only on per-chunk recomputation in
        // dataReceived, scrolling-to-bottom in a quiet pane wouldn't
        // release the lock until the next chunk arrived. The actual
        // lock TARGET (`lockedRow`) is updated inside dataReceived
        // synchronously from the current yDisp, not from this monitor,
        // so there's no race with chunks anymore.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            if let win = self.window, event.window === win {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Just check the at-tail predicate and release if so.
                    // Setting the lock is the job of dataReceived's
                    // synchronous path.
                    if self.canScroll,
                       self.scrollPosition >= (1.0 - self.scrollPositionTailEpsilon) {
                        self.releaseScrollLock()
                    }
                }
            }
            return event
        }
    }

    // MARK: - Cached UserDefaults values
    //
    // dataReceived runs on the hot path — once per PTY chunk. Reading
    // from UserDefaults is fast but not free (each read goes through
    // CFPreferences). Cache the values we touch per-byte and refresh
    // them only when UserDefaults actually changes. Saves a measurable
    // chunk of CPU on output-heavy sessions (claude streaming, `cat
    // bigfile`, build logs).
    private var cachedCinemaMode = false
    private var cachedCinemaCps: Double = 80
    private var cachedRecordSessions = false
    private var cachedIdleThreshold: TimeInterval = 4
    private var defaultsObserver: NSObjectProtocol?

    private func refreshCachedDefaults() {
        let d = UserDefaults.standard
        cachedCinemaMode = d.bool(forKey: "termy.cinemaMode")
        let cps = d.double(forKey: "termy.cinemaCps")
        cachedCinemaCps = cps > 0 ? cps : 80
        cachedRecordSessions = d.bool(forKey: "termy.recordSessions")
        let th = d.double(forKey: "termy.idleThresholdSeconds")
        cachedIdleThreshold = th > 0 ? th : 4
    }

    private func installDefaultsObserver() {
        if defaultsObserver != nil { return }
        refreshCachedDefaults()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCachedDefaults()
        }
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    /// Native AppKit context menu installed in makeNSView via `view.menu = ...`.
    /// Built once, shared across the view's lifetime. SwiftUI's `.contextMenu`
    /// modifier was previously providing this — but `.contextMenu` installs
    /// an NSGestureRecognizer that, combined with the NSViewRepresentable
    /// wrapper, broke SwiftTerm's mouseDown→mouseDragged path for
    /// drag-to-select. Using AppKit's built-in `view.menu` mechanism means
    /// right-click is handled at the NSView layer (no gesture recognizers
    /// in the way) and left-click drag is fully uninterrupted.
    ///
    /// `target: nil` on standard items (Copy/Paste/Select All) routes the
    /// action up the responder chain so AppKit finds SwiftTerm's own
    /// implementations and auto-validates them (Copy disabled when no
    /// selection, Paste disabled when clipboard is empty, etc.).
    static func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true

        let copy = NSMenuItem(title: "Copy",
                              action: #selector(NSText.copy(_:)),
                              keyEquivalent: "")
        menu.addItem(copy)

        let paste = NSMenuItem(title: "Paste",
                               action: #selector(NSText.paste(_:)),
                               keyEquivalent: "")
        menu.addItem(paste)

        let selectAll = NSMenuItem(title: "Select All",
                                   action: #selector(NSResponder.selectAll(_:)),
                                   keyEquivalent: "")
        menu.addItem(selectAll)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(notificationItem(title: "Find in Scrollback",
                                      notification: .terminalToggleFind))
        menu.addItem(notificationItem(title: "Clear",
                                      notification: .terminalClear))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(notificationItem(title: "New Tab",
                                      notification: .terminalNewTab))
        menu.addItem(notificationItem(title: "Split Horizontally",
                                      notification: .terminalSplitHorizontal))
        menu.addItem(notificationItem(title: "Split Vertically",
                                      notification: .terminalSplitVertical))

        return menu
    }

    /// Build a menu item that posts an app notification when triggered.
    /// Target is the shared dispatcher (which holds the @objc action) so
    /// the responder chain doesn't need to know about it. Strong reference
    /// to the dispatcher is held by the menu via target retention.
    private static func notificationItem(title: String,
                                         notification: Notification.Name) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(NotificationDispatcher.fire(_:)),
                              keyEquivalent: "")
        item.target = NotificationDispatcher.shared
        item.representedObject = notification.rawValue
        return item
    }

    /// Intercept link clicks (OSC 8 hyperlinks + implicit URL detection)
    /// to route file paths through the user's preferred editor when
    /// possible. `link` may be:
    ///   - `http(s)://...` — open in default browser (NSWorkspace default)
    ///   - `file:///...` — open the file (Finder-default-app or our editor)
    ///   - `file:///path#line=N` (iTerm/Kitty convention) — open at line N
    ///   - plain path `src/foo.ts:42` — opening picker resolves cwd
    ///
    /// The "Open in Editor" path uses a small registry of common editor
    /// schemes (vscode://, cursor://, zed://) and falls back to
    /// NSWorkspace.shared.open for anything else.
    func requestOpenLink (source: TerminalView, link: String, params: [String:String]) {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed) {
            // file:// links — try the user's editor first if it has a
            // line= param, otherwise fall back to NSWorkspace.
            if url.isFileURL, let line = params["line"] ?? params["lineNumber"], let lineNum = Int(line) {
                openInEditor(filePath: url.path, line: lineNum)
                return
            }
            NSWorkspace.shared.open(url)
            return
        }
        // Plain `path:line:col` style — try to resolve relative to the
        // session's current working directory and open in editor.
        let parts = trimmed.split(separator: ":", maxSplits: 2)
        if parts.count >= 2, let line = Int(parts[1]) {
            openInEditor(filePath: String(parts[0]), line: line)
        }
    }

    /// Tiny editor opener — prefers the user's configured editor
    /// (UserDefaults `termy.editorScheme`) if set; otherwise tries each
    /// known editor in order (cursor → vscode → zed) and falls back to
    /// the system default for the file type.
    private func openInEditor(filePath: String, line: Int) {
        let scheme = UserDefaults.standard.string(forKey: "termy.editorScheme")
        let editors: [String] = scheme.map { [$0] } ?? ["cursor", "vscode", "zed"]
        let absolute = filePath.hasPrefix("/") ? filePath : NSHomeDirectory() + "/" + filePath
        for editor in editors {
            let urlString = "\(editor)://file/\(absolute):\(line)"
            if let url = URL(string: urlString),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return
            }
        }
        // Last resort — open the file in the default app for its type.
        NSWorkspace.shared.open(URL(fileURLWithPath: absolute))
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Snapshot the user's scroll position BEFORE SwiftTerm's
        // parser runs — once it's appended the new output it'll
        // (internally) reset yDisp to yBase, snapping us back to
        // the live tail. We restore the original yDisp at the end
        // of this method if the user had scrolled away. The
        // `lockedScrollRow` is the absolute row in scrollback the
        // user is looking at; that row's content doesn't move as
        // the buffer grows below it, so the same yDisp value
        // continues to point at it after SwiftTerm processes the
        // chunk.
        //
        // Read scrollPosition directly (no need for an event
        // monitor): a value < 1.0 - epsilon means the user is
        // looking at scrollback, not the live tail. This catches
        // every scroll mechanism — wheel, trackpad, PageUp/PageDn,
        // ⌘↑/⌘↓, scrollbar drag, Cmd+Home — without listing them.
        // Lock row sources, in priority order:
        //
        //   (a) `userScrolledAway` flag — set explicitly by the
        //       scrollWheel monitor when the user mouse/trackpad-
        //       scrolls away from the tail. Persistent across
        //       chunks. Cleared only by the monitor seeing the user
        //       return to the tail.
        //
        //   (b) Live `scrollPosition < 1 - epsilon` check — catches
        //       keyboard-driven scrolls (PageUp, ⌘⇧↑, scrollbar
        //       drag) that don't fire scroll-wheel events. Read
        //       BEFORE super.dataReceived snaps yDisp back to yBase.
        //
        // If either says "scrolled away", we capture preYDisp and
        // restore async (so the restore lands AFTER SwiftTerm's
        // internal `ensureCaretIsVisible` snap).
        // ONLY set the lock here — never release. The release
        // path is exclusively user-driven (scrollWheel monitor,
        // ⌘⇧↓ in sessions, etc.). Releasing here based on the
        // current scrollPosition would clear the lock during the
        // transient snap-to-tail that happens between each chunk
        // arriving and the async restore landing, breaking the
        // lock after a single chunk.
        // Synchronously re-evaluate the lock state from current yDisp.
        // This is the single source of truth — no scrollWheel-monitor
        // race, no stale `lockedRow`. If the user scrolled since the
        // last chunk, lockedRow is updated to follow them. If they
        // returned to the tail, the lock is released. Gate is inside
        // `recomputeScrollLock` (canScroll + at-tail).
        recomputeScrollLock()
        let lockedScrollRow = lockedRow

        recordIfEnabled(slice)
        scanForOSC133(slice)
        scanForTriggers(slice)
        scanForTUIRedraw(slice)
        trackIdleBytes(slice)

        // Display path: paced or immediate.
        let cinema = cachedCinemaMode
        // Two reasons to bypass the pacer:
        //   1) Very small slices that arrive AT a keystroke are the
        //      shell echoing the typed character. We can't pace
        //      those without making typing feel laggy. Three-byte
        //      window catches \r\n on Enter and most modifier+key
        //      echoes too.
        //   2) The queue would overflow — `cat large_file`
        //      shouldn't take 10 minutes even with cinema on.
        //      Drain the existing queue first so on-screen order
        //      stays correct, then flush the burst immediately.
        let isTinyEchoBurst = slice.count <= 3 && Date().timeIntervalSince(lastKeyDownAt) < cinemaInputEchoWindow
        let queueWouldOverflow = typewriterQueue.count + slice.count > 8192
        if cinema && !isTinyEchoBurst && !queueWouldOverflow {
            typewriterQueue.append(contentsOf: slice)
            ensureTypewriterTimer()
        } else {
            if !typewriterQueue.isEmpty {
                let pending = ArraySlice(typewriterQueue)
                typewriterQueue.removeAll()
                typewriterTimer?.invalidate()
                typewriterTimer = nil
                super.dataReceived(slice: pending)
            }
            super.dataReceived(slice: slice)
        }
        // Reposition the inactive-caret overlay (if any) so it tracks
        // the cursor as the shell moves it. Cheap: early-returns if
        // there's no overlay attached.
        updateInactiveCaret()
        // Single synchronous restore. SwiftTerm's snap-to-bottom
        // happens inside `terminal.scroll()` during super.dataReceived
        // (Terminal.swift L5291: `if !userScrolling { buffer.yDisp =
        // buffer.yBase }`), all in this runloop turn. The view's
        // drawRect hasn't fired yet, so pulling yDisp back here means
        // the snap NEVER renders — no flash, no jitter, no double-paint.
        //
        // No async fallback needed: ensureCaretIsVisible (the only
        // SwiftTerm path that snaps yDisp post-dataReceived) fires
        // from `send(data:)` — keyboard input — and that path SHOULD
        // release the lock (typing brings you back to live). For
        // every output-arrival path, this sync restore is sufficient.
        if let row = lockedScrollRow, getTerminal().buffer.yDisp != row {
            scrollTo(row: row, notifyAccessibility: false)
        }
        return
    }

    private func ensureTypewriterTimer() {
        if typewriterTimer != nil { return }
        // Fixed 60Hz tick rate for smooth visual pacing. Per-tick byte
        // count is computed from the user's `cps` setting so the
        // ACTUAL throughput matches what they asked for. Previously
        // the drain divided the queue size by 8 every tick (an
        // "auto-catch-up" heuristic), which made a 200-char paragraph
        // render in <1s no matter what cps was set to — completely
        // defeating the cps slider.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.drainTypewriter()
        }
        RunLoop.main.add(t, forMode: .common)
        typewriterTimer = t
    }

    private func drainTypewriter() {
        guard !typewriterQueue.isEmpty else {
            typewriterTimer?.invalidate()
            typewriterTimer = nil
            return
        }
        // Drain bytes at the user-configured chars-per-second rate.
        // 1 byte per tick at 60Hz = 60 cps; 2 bytes/tick = 120 cps;
        // etc. Cap the per-tick chunk so a queue surge can't blast
        // through in one frame and ruin the typewriter effect.
        let perTick = max(1, Int((cachedCinemaCps / 60.0).rounded(.up)))
        let take = min(perTick, typewriterQueue.count)
        let chunk = ArraySlice(typewriterQueue.prefix(take))
        typewriterQueue.removeFirst(take)
        super.dataReceived(slice: chunk)
    }

    /// Buffers incoming bytes as lines and runs each completed line
    /// through the active trigger set. Skipped entirely when triggers
    /// aren't wired up (e.g., on first render before MainTerminalView
    /// installed the provider). Strips ANSI CSI sequences before
    /// matching so triggers don't trip on color codes.
    private func scanForTriggers(_ slice: ArraySlice<UInt8>) {
        guard let provider = triggerProvider else { return }
        let triggers = provider()
        guard !triggers.isEmpty else { return }
        guard let s = String(bytes: slice, encoding: .utf8) else { return }
        triggerLineBuffer += s
        if triggerLineBuffer.count > 4096 {
            triggerLineBuffer = String(triggerLineBuffer.suffix(2048))
        }
        guard triggerLineBuffer.contains("\n") else { return }
        let parts = triggerLineBuffer.components(separatedBy: "\n")
        let complete = parts.dropLast()
        triggerLineBuffer = parts.last ?? ""
        for line in complete {
            let stripped = stripAnsiCSI(line)
            guard !stripped.isEmpty else { continue }
            let range = NSRange(stripped.startIndex..., in: stripped)
            for trigger in triggers {
                if trigger.pattern.firstMatch(in: stripped, range: range) != nil {
                    onTriggerFired?(trigger, stripped)
                    break  // one notification per line is plenty
                }
            }
        }
    }

    // MARK: - TUI-redraw detection (anti-cascading-banner)
    //
    // Apps that use the alt-screen properly (vim, less, htop) keep
    // their UI out of scrollback. Apps that don't (claude in
    // particular) just emit `\e[2J\e[H` and redraw their whole UI
    // every time, leaving every previous render permanently
    // accumulated in scrollback. After a few splits/resizes the user
    // ends up with the welcome banner stacked 4-5 times.
    //
    // Heuristic: count `\e[2J` (full-screen erase) events in a rolling
    // 5-second window. ONE in 5s is a normal `clear` command — leave
    // scrollback alone, the user might want it back. THREE+ in 5s is
    // a TUI repainting itself — start suppressing the next renders
    // by sending `\e[3J` (erase scrollback) right after each `\e[2J`,
    // so the TUI's last render is what stays visible without
    // history accumulation.
    //
    // The detection is sticky for `tuiModeStickWindow` seconds after
    // the last `\e[2J` so we keep suppressing through the TUI's
    // entire session, then unsticks so a later shell `clear`
    // preserves scrollback again.
    private var clearTimes: [Date] = []
    private var lastClearAt: Date = .distantPast
    private var tuiModeActive: Bool = false
    private let tuiModeWindow: TimeInterval = 5
    private let tuiModeStickWindow: TimeInterval = 30
    private let tuiModeThreshold: Int = 3
    // CSI parser state for the `\e[2J` matcher.
    private var tuiScanState: Int = 0
    private var tuiScanParam: UInt8 = 0

    private func scanForTUIRedraw(_ slice: ArraySlice<UInt8>) {
        if !slice.contains(0x1B) && tuiScanState == 0 { return }
        for byte in slice {
            switch tuiScanState {
            case 0:
                if byte == 0x1B { tuiScanState = 1; tuiScanParam = 0 }
            case 1:
                if byte == 0x5B { tuiScanState = 2; tuiScanParam = 0 }
                else if byte != 0x1B { tuiScanState = 0 }
            case 2:
                if byte == 0x4A {  // 'J'
                    if tuiScanParam == 0x32 { handleFullScreenClear() }
                    tuiScanState = 0
                } else if (byte >= 0x30 && byte <= 0x39) {  // digit
                    tuiScanParam = byte
                } else if byte == 0x3B || byte == 0x3F {
                    // multi-param or DEC private; not a 2J even if a 2 appears
                    tuiScanParam = 0
                } else if (byte >= 0x40 && byte <= 0x7E) {
                    // CSI final byte, not J
                    tuiScanState = 0
                }
            default:
                tuiScanState = 0
            }
        }
    }

    private func handleFullScreenClear() {
        let now = Date()
        clearTimes.append(now)
        clearTimes.removeAll { now.timeIntervalSince($0) > tuiModeWindow }
        // Sticky: once we identified TUI mode, keep it for the stick
        // window so claude's slower redraw pace doesn't fall out of
        // the 5s detection window and prematurely re-enable history.
        if clearTimes.count >= tuiModeThreshold {
            tuiModeActive = true
            lastClearAt = now
        } else if tuiModeActive && now.timeIntervalSince(lastClearAt) > tuiModeStickWindow {
            tuiModeActive = false
        }
        guard tuiModeActive else { return }
        // Send \e[3J asynchronously so it lands after SwiftTerm has
        // processed the \e[2J it follows. Without the async hop the
        // parser would interleave the two and not all of the cleared
        // content makes it into scrollback for us to wipe.
        DispatchQueue.main.async { [weak self] in
            self?.feed(text: "\u{001B}[3J")
        }
        lastClearAt = now
    }

    private func stripAnsiCSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return Self.ansiCSIRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// Refactored out of the inline body so cinema mode can call the
    /// same tracking path at real time without double-counting.
    private func trackIdleBytes(_ slice: ArraySlice<UInt8>) {
        let now = Date()
        // Treat a >2s gap as a fresh burst — anything within 2s is one
        // continuous output stream (Claude/Codex stream tokens, builds
        // log throughout, etc.).
        if now.timeIntervalSince(lastDataAt) > 2.0 {
            bytesSinceBurstStart = 0
            lastPreviewBuffer = ""
        }
        bytesSinceBurstStart += slice.count
        lastDataAt = now
        // Capture a sliding window of the most recent bytes (UTF-8
        // decoded best-effort) so we can put a meaningful tail line in
        // the eventual notification.
        if let s = String(bytes: slice, encoding: .utf8) {
            lastPreviewBuffer += s
            if lastPreviewBuffer.count > 4096 {
                lastPreviewBuffer = String(lastPreviewBuffer.suffix(2048))
            }
        }
        if !isCurrentlyActive && bytesSinceBurstStart >= activeByteThreshold {
            isCurrentlyActive = true
            onActivityChanged?(true)
            ensureIdleTimer()
        }
    }

    /// Minimal FinalTerm / iTerm2 OSC 133 parser. Doesn't actually need
    /// full XParse — only flags the sequence `ESC ] 133 ; X ... BEL` or
    /// `... ESC \`. We accumulate while `inOSC == true` and dispatch on
    /// the terminator. Sub-codes we care about:
    ///
    ///   - `A` — prompt start: a new prompt is being drawn, so any
    ///     "active" state from the previous command is implicitly done.
    ///   - `B` — prompt end / command start (we treat the two
    ///     interchangeably for notification purposes).
    ///   - `C` — command output start.
    ///   - `D[;exit]` — command finished. Fire the notification
    ///     immediately and suppress the idle fallback for the next tick.
    private func scanForOSC133(_ slice: ArraySlice<UInt8>) {
        // Fast path: most output chunks (plain text from a shell
        // command's stdout) contain no ESC bytes at all. Skip the
        // per-byte loop entirely. Saves a meaningful amount of CPU
        // on output-heavy sessions (build logs, `cat large_file`,
        // ls of huge directories).
        if !inOSC && !slice.contains(0x1B) { return }
        for byte in slice {
            if !inOSC {
                if byte == 0x1B {                  // ESC
                    oscBuffer = [byte]
                    inOSC = true
                }
                continue
            }
            oscBuffer.append(byte)
            // Cap the buffer so a malformed never-terminating OSC
            // doesn't grow unbounded. 256B is huge for shell-integration
            // sequences; if we hit it, drop and re-arm on the next ESC.
            if oscBuffer.count > 256 {
                inOSC = false
                oscBuffer.removeAll()
                continue
            }
            // Terminator: BEL (0x07) or ESC \\ (0x1B 0x5C)
            let last = oscBuffer.last
            let secondLast = oscBuffer.count >= 2 ? oscBuffer[oscBuffer.count - 2] : 0
            let bel = last == 0x07
            let stTerm = secondLast == 0x1B && last == 0x5C
            guard bel || stTerm else { continue }
            handleOSC(oscBuffer)
            inOSC = false
            oscBuffer.removeAll()
        }
    }

    /// Inspect a complete OSC payload and dispatch on 133;X. Other OSC
    /// codes (133;P / 133;L for properties, OSC 7 for cwd, OSC 8 for
    /// hyperlinks) are handled by SwiftTerm itself — we don't intercept.
    private func handleOSC(_ buffer: [UInt8]) {
        // Strip ESC ] prefix (2 bytes) and trailing terminator (BEL or
        // ESC \\). If the prefix isn't ESC ] it's not an OSC we care
        // about — abort silently.
        guard buffer.count >= 4,
              buffer[0] == 0x1B,
              buffer[1] == 0x5D                    // ']'
        else { return }
        let endTrim = buffer.last == 0x07 ? 1 : 2
        let payload = buffer.dropFirst(2).dropLast(endTrim)
        guard let str = String(bytes: payload, encoding: .utf8),
              str.hasPrefix("133;")
        else { return }
        let afterPrefix = str.dropFirst("133;".count)
        guard let code = afterPrefix.first else { return }
        switch code {
        case "A", "B":
            // Prompt boundary — if we were tracking an active burst,
            // the previous command has settled by now. Fire a settle
            // event only if we hadn't already (e.g. via 133;D).
            if isCurrentlyActive && !osc133JustFired {
                isCurrentlyActive = false
                onActivityChanged?(false)
                let preview = tailLine(from: lastPreviewBuffer)
                onCommandSettled?(preview, true)
            }
            osc133JustFired = false
            // Record this prompt's absolute row so ⌘↑/⌘↓ can jump back.
            // yDisp (public) is the top of the viewport in scrollback;
            // y (public) is the cursor's row within the viewport. Sum
            // gives the scrollback-absolute row where the prompt just
            // landed. De-dupe consecutive identical rows (paste echoes).
            let buffer = getTerminal().buffer
            let absRow = buffer.yDisp + buffer.y
            if promptMarks.last != absRow {
                promptMarks.append(absRow)
                if promptMarks.count > 1000 {
                    promptMarks.removeFirst(promptMarks.count - 1000)
                }
            }
        case "C":
            // Command output starts — reset preview so it captures only
            // this command's output, not the prompt prefix.
            lastPreviewBuffer = ""
            bytesSinceBurstStart = 0
        case "D":
            // Command done with explicit shell signal. Fire immediately
            // and suppress the idle fallback so the user doesn't get
            // two notifications for one command.
            let preview = tailLine(from: lastPreviewBuffer)
            isCurrentlyActive = false
            osc133JustFired = true
            onActivityChanged?(false)
            onCommandSettled?(preview, true)
        default:
            break
        }
    }

    private func tailLine(from buffer: String) -> String? {
        buffer
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)
    }

    /// Scroll to the previous prompt mark before the current viewport.
    /// Falls back to half-page-up when no marks are recorded (shell
    /// without OSC 133 setup). Returns true if we moved.
    @discardableResult
    func jumpToPreviousPrompt() -> Bool {
        let buffer = getTerminal().buffer
        let viewportTop = buffer.yDisp
        let candidate = promptMarks.last(where: { $0 < viewportTop })
        if let target = candidate {
            scrollTo(row: max(0, target - 1))
            return true
        }
        // Fallback: scroll half a screen up.
        let half = max(1, getTerminal().rows / 2)
        scrollTo(row: max(0, viewportTop - half))
        return false
    }

    @discardableResult
    func jumpToNextPrompt() -> Bool {
        let buffer = getTerminal().buffer
        let viewportTop = buffer.yDisp
        let candidate = promptMarks.first(where: { $0 > viewportTop })
        if let target = candidate {
            scrollTo(row: max(0, target - 1))
            return true
        }
        // Fallback: scroll half a screen down. Use the highest known
        // mark as a stand-in upper bound when we can't read total
        // line count (internal in SwiftTerm).
        let upperBound = max(promptMarks.last ?? viewportTop, viewportTop)
        let half = max(1, getTerminal().rows / 2)
        scrollTo(row: min(upperBound, viewportTop + half))
        return false
    }

    /// Lazy-install the per-view idle-check timer. Tears down with the
    /// view (timers are invalidated in deinit) so we don't leak.
    /// 1.0s interval is plenty: the user-visible idle threshold is
    /// ≥ 4s (cachedIdleThreshold default), so checking twice as often
    /// just burned runloop wakeups. With N active panes we now do
    /// N wakes/sec instead of 2N — meaningful on the heavy multi-pane
    /// claude-streaming workflows.
    private func ensureIdleTimer() {
        if idleTimer != nil { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickIdle()
        }
        // Run on the common runloop mode so the timer keeps firing during
        // modal sheets / live-resizes / scroll gestures.
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func tickIdle() {
        // Tear down the timer once the pane settles. Previously the
        // 0.5Hz idle timer kept ticking forever after the first burst
        // of output, returning early on every fire — N panes ×
        // 2 wake-ups/second forever. Reconstructed on the next active
        // burst via ensureIdleTimer.
        guard isCurrentlyActive else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        if osc133JustFired {
            osc133JustFired = false
            return
        }
        if Date().timeIntervalSince(lastDataAt) >= cachedIdleThreshold {
            isCurrentlyActive = false
            onActivityChanged?(false)
            // viaOSC133=false — this is the heuristic path, which is
            // suppressed by default in TermyNotifications because it's
            // way too noisy for TUI sessions (claude pauses between
            // generation cycles trigger it constantly).
            onCommandSettled?(tailLine(from: lastPreviewBuffer), false)
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    deinit {
        idleTimer?.invalidate()
        typewriterTimer?.invalidate()
        recorder?.close()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = focusChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = cinemaKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// If the user has the "Record session output" preference on, hand the
    /// slice to the session recorder. The recorder lazy-opens its file on
    /// first byte and silently degrades on any IO failure — recording is
    /// best-effort, never load-bearing.
    private func recordIfEnabled(_ slice: ArraySlice<UInt8>) {
        let enabled = cachedRecordSessions
        guard enabled else {
            if recorder != nil {
                recorder?.close()
                recorder = nil
                recordingChecked = false
            }
            return
        }
        if recorder == nil {
            if recordingChecked { return }  // failed once → don't keep trying
            recordingChecked = true
            recorder = SessionRecorder(
                cwd: recordingCwd ?? NSHomeDirectory(),
                shell: recordingShell ?? "/bin/zsh"
            )
        }
        recorder?.append(slice)
    }

    /// Tell the recorder the working directory just changed (OSC 7). Lets
    /// the on-disk log mark `[cwd → ~/foo]` so the user can see in the
    /// log file where each command sequence ran. No-op when not recording.
    func recorderDidChangeCwd(_ cwd: String) {
        recorder?.notifyCwdChanged(cwd)
    }

    /// Observer for windowDidBecomeKey — claiming focus only in
    /// viewDidMoveToWindow can race the window becoming key on cold launch.
    /// Re-attempts the claim whenever the window flips to key.
    private var keyWindowObserver: NSObjectProtocol?
    /// Observer for windowDidResignKey — hides the inactive-caret
    /// reinforcement layer when the whole window backgrounds (every
    /// caret should dim to match macOS terminal convention).
    private var resignKeyObserver: NSObjectProtocol?
    /// Observer for the Termy-internal focus-changed notification.
    /// Each pane fires this when it claims focus; every pane listens
    /// and re-evaluates whether it should be showing its inactive
    /// caret overlay.
    private var focusChangedObserver: NSObjectProtocol?

    /// Posted by every focus-mutating site (PaneCellView tap, attempt-
    /// FocusClaim, command palette pane switches, the app-wide left-
    /// mouse-down monitor). Drives the inactive-caret overlay update.
    /// SwiftTerm's `becomeFirstResponder`/`resignFirstResponder` are
    /// declared non-open so we can't observe focus changes by override.
    static let focusChangedNotification = Notification.Name("TermyTerminalFocusChanged")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        if let observer = focusChangedObserver {
            NotificationCenter.default.removeObserver(observer)
            focusChangedObserver = nil
        }
        // Install the cinema-mode keystroke timestamp monitor exactly
        // once per view. The monitor fires for ALL window key events,
        // but we only stamp when the firstResponder is THIS view —
        // so a keystroke aimed at a sibling pane or the find bar
        // doesn't suppress pacing on this pane's command output.
        if cinemaKeyMonitor == nil {
            cinemaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, let w = self.window, w.firstResponder === self {
                    self.lastKeyDownAt = Date()
                }
                return event
            }
        }
        guard let window else { return }
        installDefaultsObserver()
        installScrollMonitor()
        onNeedsAppearanceRefresh?()
        // Re-attached to a window (either first mount or after a
        // tab-switch re-parent). Mark every visible row dirty and
        // request a redraw so the scrollback paints onto the new
        // surface. Without this, switching back to a tab whose pane
        // was previously unmounted shows a blank terminal even
        // though the buffer is intact.
        let term = getTerminal()
        term.refresh(startRow: 0, endRow: max(0, term.rows - 1))
        needsDisplay = true
        // Claim focus on initial attach AND any time the window becomes
        // key. On a cold-launch boot the window isn't always key yet at
        // viewDidMoveToWindow time, so a single attempt would leave the
        // caret hollow. NotificationCenter retries cover that race and
        // the "user switched apps and came back" case for free.
        attemptFocusClaim()
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attemptFocusClaim()
            self?.updateInactiveCaret()
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateInactiveCaret()
        }
        focusChangedObserver = NotificationCenter.default.addObserver(
            forName: TermyTerminalView.focusChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateInactiveCaret()
        }
        updateInactiveCaret()
    }

    private func attemptFocusClaim() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if Self.shouldClaimFocus(over: window.firstResponder) {
                window.makeFirstResponder(self)
                NotificationCenter.default.post(
                    name: TermyTerminalView.focusChangedNotification,
                    object: self
                )
            }
            // Force one appearance refresh even if we didn't claim — on
            // cold launch SwiftTerm's becomeFirstResponder may have
            // fired while our frame was `.zero`, positioning the caret
            // off-screen. Re-applying installColors retriggers
            // updateDisplay → updateCursorPosition with the real frame
            // so the caret paints. (Fixes single-pane caret-at-launch.)
            self.onNeedsAppearanceRefresh?()
        }
    }

    /// Walk subviews to find SwiftTerm's `CaretView`. The class is
    /// internal to SwiftTerm so we match by name — fragile if SwiftTerm
    /// renames it, but recovery is graceful (overlay just doesn't appear).
    private func findSwiftTermCaretView() -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == "CaretView" {
                return subview
            }
        }
        return nil
    }

    /// Show or hide the bright filled overlay that reinforces the
    /// SwiftTerm hollow caret. Reads first-responder + window-key state
    /// live so it doesn't depend on observing notifications correctly.
    func updateInactiveCaret() {
        guard let caretView = findSwiftTermCaretView() else {
            inactiveCaretLayer?.removeFromSuperlayer()
            inactiveCaretLayer = nil
            return
        }
        let windowIsKey = window?.isKeyWindow ?? false
        let isFirstResponder = window?.firstResponder === self
        // Only reinforce when window is active AND a sibling pane has
        // focus. When the window is backgrounded, mirror macOS terminal
        // convention: every caret dims.
        let shouldShow = windowIsKey && !isFirstResponder && !caretView.isHidden

        if !shouldShow {
            inactiveCaretLayer?.removeFromSuperlayer()
            inactiveCaretLayer = nil
            return
        }
        wantsLayer = true
        let overlay = inactiveCaretLayer ?? makeInactiveCaretLayer()
        if inactiveCaretLayer == nil {
            self.layer?.addSublayer(overlay)
            inactiveCaretLayer = overlay
        }
        // Match SwiftTerm's caretView frame. Disable implicit animations
        // so cursor movement doesn't slide.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = caretView.frame
        let fg = nativeForegroundColor
        overlay.backgroundColor = fg.withAlphaComponent(0.55).cgColor
        overlay.borderColor = fg.withAlphaComponent(0.95).cgColor
        CATransaction.commit()
    }

    private func makeInactiveCaretLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 1.5
        layer.cornerRadius = 1
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        return layer
    }

    // MARK: - Drag-and-drop (Finder file paths)
    //
    // The view already calls `registerForDraggedTypes([.fileURL])` in
    // makeNSView; without the protocol methods below, drops were
    // silently rejected. On drop, shell-quote the path(s) and send to
    // the PTY. Multi-select drops produce space-separated paths.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else {
            return []
        }
        showDragHighlight()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDragHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDragHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDragHighlight()
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        // Focus this pane before sending — dropping on a sibling pane
        // should both focus it AND insert. Without makeFirstResponder
        // here, the dropped path would go to whichever pane was
        // previously first responder.
        window?.makeFirstResponder(self)
        NotificationCenter.default.post(
            name: TermyTerminalView.focusChangedNotification, object: self
        )
        let quoted = urls.map { TermyTerminalView.shellQuote($0.path) }.joined(separator: " ")
        send(txt: quoted)
        return true
    }

    /// POSIX-safe shell quoting. Bare-word for paths containing only
    /// portable filename characters; single-quoted with `'\''` escapes
    /// for everything else. Avoids `\` escapes (zsh/bash agree on
    /// single-quote semantics; backslash rules differ).
    static func shellQuote(_ path: String) -> String {
        if path.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func showDragHighlight() {
        wantsLayer = true
        if dragHighlightLayer == nil {
            let l = CALayer()
            l.frame = bounds
            l.borderWidth = 2
            l.borderColor = NSColor.controlAccentColor.cgColor
            l.cornerRadius = 6
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(l)
            dragHighlightLayer = l
        }
    }

    private func hideDragHighlight() {
        dragHighlightLayer?.removeFromSuperlayer()
        dragHighlightLayer = nil
    }

    static func shouldClaimFocus(over responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        if responder is TermyTerminalView { return false }
        if responder is NSText || responder is NSTextField { return false }
        // NSWindow itself counts as "nothing meaningfully focused" — safe
        // to take focus.
        if responder is NSWindow { return true }
        // Default: anything else (SwiftUI hosting view, generic NSView,
        // unknown) is fair game. Terminal is the primary input target.
        return true
    }

    // MARK: - Scrollbar top inset (room for pane close button)
    //
    // SwiftTerm pins its NSScroller subview to the pane's top edge via
    // Auto Layout (`scroller.topAnchor.constraint(equalTo: topAnchor)`).
    // The per-pane close X lands on top of the scroll-up arrow,
    // making it hard to distinguish AND non-clickable when the thumb
    // is at the very top. Override by deactivating SwiftTerm's top
    // constraint and installing our own with a constant offset.
    // Frame-based overrides in `layout()` don't work — Auto Layout
    // re-applies its computed frame on every pass and undoes the change.
    private static let paneCloseTopInset: CGFloat = 26
    private var scrollerTopInsetConstraint: NSLayoutConstraint?

    private func installScrollerTopInset() {
        guard scrollerTopInsetConstraint == nil, let scroller = findScrollerSubview() else {
            return
        }
        // Deactivate the existing top constraint on the scroller (the
        // one SwiftTerm added with constant=0). Iterate parent + scroller
        // constraints because Auto Layout chooses the common ancestor
        // for constraint storage, which is `self` here.
        for c in constraints {
            let matchesFirst = (c.firstItem as? NSScroller) === scroller && c.firstAttribute == .top
            let matchesSecond = (c.secondItem as? NSScroller) === scroller && c.secondAttribute == .top
            if matchesFirst || matchesSecond {
                c.isActive = false
            }
        }
        let inset = scroller.topAnchor.constraint(equalTo: topAnchor, constant: Self.paneCloseTopInset)
        inset.priority = .required
        inset.isActive = true
        scrollerTopInsetConstraint = inset
    }

    private func findScrollerSubview() -> NSScroller? {
        for subview in subviews {
            if let scroller = subview as? NSScroller { return scroller }
        }
        return nil
    }

    override func layout() {
        super.layout()
        // Lazy install once the scroller subview exists (SwiftTerm
        // adds it during its own setup, which may post-date our
        // viewDidMoveToWindow).
        installScrollerTopInset()
    }

    // MARK: - Live-resize coalescing
    //
    // SwiftTerm's setFrameSize calls `processSizeChange` → `terminal.resize` →
    // `reflowWider`/`reflowNarrower` on every AppKit setFrameSize tick. During
    // a window-corner drag AppKit fires that hundreds of times per second with
    // intermediate widths. We coalesce: skip per-tick processSizeChange via the
    // NSView-direct setFrameSize, then fire ONE real resize on
    // viewDidEndLiveResize so SwiftTerm's reflow runs exactly once.
    //
    // Earlier builds used `withReflowDisabled` to skip SwiftTerm's reflow path
    // on the settling resize. That call wraps `changeScrollback(nil)`, which
    // internally calls `lines.trimStart(amountToTrim)` — permanently dropping
    // every scrollback line above the visible viewport. End result: any window
    // resize that crossed a cell boundary wiped the user's command history.
    // SwiftTerm 1.13 reflows correctly; trust it and keep scrollback intact.

    /// Captured at viewWillStartLiveResize so we can detect a
    /// significant width change across the entire drag (not just
    /// per-tick) and clear scrollback once when the user lets go.
    private var preLiveResizeCols: Int = 0
    private var preLiveResizeRows: Int = 0

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        preLiveResizeCols = getTerminal().cols
        preLiveResizeRows = getTerminal().rows
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        let final = frame.size
        if wouldChangeCellGrid(newSize: final) {
            super.setFrameSize(NSSize(width: final.width + 0.5, height: final.height))
            super.setFrameSize(final)
        }
        // Scrollback is intentionally NOT cleared here. See
        // nudgeAndRefreshAfterResize() for the long explanation —
        // preserving user history is more important than the
        // cosmetic mess that some TUIs leave when they redraw on
        // SIGWINCH.
        let term = getTerminal()
        term.refresh(startRow: 0, endRow: term.rows - 1)
        needsDisplay = true
    }

    /// Snapshot of the cell grid before each setFrameSize call.
    /// Used to detect "significant" resizes (>~30% in either axis)
    /// so we can clear scrollback to remove the accumulated mess
    /// from TUI apps that don't use alt-screen (claude in particular
    /// redraws its banner on every SIGWINCH, leaving stacked copies
    /// in scrollback after every split/close).
    private var preResizeCols: Int = 0
    private var preResizeRows: Int = 0

    override func setFrameSize(_ newSize: NSSize) {
        let wasZeroSized = frame.size.width <= 0 || frame.size.height <= 0
        // Capture pre-resize grid for the post-resize predicate below.
        preResizeCols = getTerminal().cols
        preResizeRows = getTerminal().rows
        // Always go through SwiftTerm's setFrameSize → processSizeChange
        // path so the terminal's cols/rows stay in lockstep with the
        // visible cell grid, including during live drag-resize.
        //
        // We used to coalesce live-resize ticks (call NSView's
        // setFrameSize directly to skip SwiftTerm's per-tick reflow,
        // then fire one settling resize on viewDidEndLiveResize). That
        // saved a few cycles per frame on a drag, but it meant
        // SIGWINCH wasn't sent until the user let go — so any TUI
        // running in the pane (claude, fzf, vim) rendered its output
        // at the OLD width while the window had already grown wider,
        // producing exactly the "wrap doesn't match window" artifact
        // users were reporting. SwiftTerm 1.13's reflow is fast enough
        // per-tick that the drag still feels smooth.
        let gridWillChange = wouldChangeCellGrid(newSize: newSize)
        super.setFrameSize(newSize)
        // First time we land at a real size, ask the host to re-apply
        // appearance. updateDisplay (and therefore caret positioning)
        // reads frame.height — an applyAppearance fired while frame was
        // zero left the caret positioned off-screen.
        if wasZeroSized && newSize.width > 0 && newSize.height > 0 && !hasLaidOutAtRealSize {
            hasLaidOutAtRealSize = true
            DispatchQueue.main.async { [weak self] in
                self?.onNeedsAppearanceRefresh?()
            }
        }
        // Non-live resize that crossed a cell boundary (split close,
        // window snap-resize, programmatic set-size). Re-poke SwiftTerm
        // with a half-point nudge so its processSizeChange re-runs
        // against the settled frame, then pin the viewport to the
        // tail and force a full redisplay. Without this, the viewport
        // renders blank after a split-close until the next keystroke.
        // Live-resize ticks don't need the async nudge because the
        // per-tick super.setFrameSize above already runs the reflow.
        if gridWillChange && !inLiveResize {
            DispatchQueue.main.async { [weak self] in
                self?.nudgeAndRefreshAfterResize()
            }
        }
    }

    /// Sibling to viewDidEndLiveResize, called from the async path
    /// after a non-live grid change. Can't use `super` inside an
    /// `[weak self]` closure (Swift 6 restriction), so the actual
    /// re-poke lives here as an instance method where `super` is
    /// directly callable.
    private func nudgeAndRefreshAfterResize() {
        let current = frame.size
        // Half-point nudge re-runs SwiftTerm's processSizeChange
        // (which early-returns when size matches the cached size).
        super.setFrameSize(NSSize(width: current.width + 0.5, height: current.height))
        super.setFrameSize(current)
        let term = getTerminal()
        // NO scrollback clears here. v0.11.0 used to fire \e[3J on
        // significant grid change to clean up cascading TUI redraws,
        // but it also nuked legitimate history any time the user
        // closed a split or aggressively resized — making it
        // impossible to scroll back to earlier content in the
        // surviving pane. The cascading-banner artifact is the
        // lesser evil; users can ⌘K to clear scrollback manually
        // when a TUI leaves a mess.
        term.refresh(startRow: 0, endRow: max(0, term.rows - 1))
        needsDisplay = true
        displayIfNeeded()
        setNeedsDisplay(bounds)
    }

    /// Estimates whether super.setFrameSize(newSize) would change SwiftTerm's
    /// (cols × rows). We mirror SwiftTerm's own computeFontDimensions + the
    /// scroller-width subtraction in getEffectiveWidth so the prediction
    /// matches what processSizeChange would compute. Internal API access
    /// isn't possible from this module, so we replicate the math.
    private func wouldChangeCellGrid(newSize: NSSize) -> Bool {
        let cell = cachedCellDimension()
        guard cell.width > 0, cell.height > 0 else { return true }
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let effectiveWidth = max(0, newSize.width - scrollerWidth)
        let newCols = Int(effectiveWidth / cell.width)
        let newRows = Int(newSize.height / cell.height)
        let term = getTerminal()
        return newCols != term.cols || newRows != term.rows
    }

    /// Cached (font, scale) → cell dimension. Recomputed when either changes.
    private var cellDimensionCache: (font: NSFont, scale: CGFloat, dimension: CGSize)?

    private func cachedCellDimension() -> CGSize {
        let f = self.font
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let cached = cellDimensionCache,
           cached.font === f,
           abs(cached.scale - scale) < 0.001 {
            return cached.dimension
        }
        let glyph = f.glyph(withName: "W")
        let advance = f.advancement(forGlyph: glyph).width
        let ctFont = f as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let height = ceil(ascent + descent + leading)
        let snappedW = ceil(advance * scale) / scale
        let snappedH = ceil(height * scale) / scale
        let dim = CGSize(width: max(1, snappedW), height: max(1, min(snappedH, 8192)))
        cellDimensionCache = (f, scale, dim)
        return dim
    }

    private func callNSViewSetFrameSize(_ newSize: NSSize) {
        typealias Fn = @convention(c) (NSView, Selector, NSSize) -> Void
        let sel = #selector(NSView.setFrameSize(_:))
        guard let impl = class_getMethodImplementation(NSView.self, sel) else {
            // Shouldn't happen — NSView always responds to setFrameSize.
            // Fall back to super so we at least don't crash on resize.
            super.setFrameSize(newSize)
            return
        }
        unsafeBitCast(impl, to: Fn.self)(self, sel, newSize)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let existing = session.terminalView {
            // Cached path — the user switched away from this session
            // and back. The cached NSView was unmounted from its prior
            // SwiftUI hosting and is being re-parented into this one.
            //
            // 1) Re-wire processDelegate to the NEW coordinator. The
            //    old coordinator was deallocated when its representable
            //    tore down. Without this re-wire, title and cwd
            //    updates stop flowing when the view is re-mounted —
            //    AND the auto-close-when-shell-exits hook breaks
            //    because processTerminated is dispatched through the
            //    coordinator.
            // 2) Force a full SwiftTerm redraw on the next runloop
            //    tick. SwiftTerm's display state is tied to the view
            //    being mounted in a window; after a re-parent, the
            //    on-screen text is blank even though the scrollback
            //    buffer is intact. Marking every row dirty +
            //    needsDisplay re-renders the scrollback into the new
            //    surface. Dispatched async so AppKit has finished the
            //    layout pass that gives the view its real frame
            //    before we ask SwiftTerm to repaint into it.
            existing.processDelegate = context.coordinator
            applyAppearance(existing, coordinator: context.coordinator)
            DispatchQueue.main.async { [weak existing] in
                guard let existing else { return }
                let term = existing.getTerminal()
                term.refresh(startRow: 0, endRow: max(0, term.rows - 1))
                existing.needsDisplay = true
            }
            return existing
        }

        let view = TermyTerminalView(frame: .zero)
        // CRITICAL FOR SELECTION. SwiftTerm defaults `allowMouseReporting`
        // to TRUE, which routes mouse events to the running PTY app whenever
        // it has set mouseMode != .off. Many common setups (tmux, vim with
        // mouse, fzf, claude/codex, anything using terminfo XM/Xm) do that —
        // and SwiftTerm's `mouseDragged` bails out the moment ANY mouse mode
        // is set, even if the app didn't request motion events. Net effect:
        // drag-to-select silently dies as soon as the prompt's pre-exec hooks
        // touch mouseMode. For a daily-driver terminal where selecting text
        // is the more fundamental affordance, turn mouse reporting off so
        // selection always wins. (A per-profile "Pass mouse events to apps"
        // toggle can re-enable it later for users who specifically want vim
        // / htop mouse support, but the default must favor "I can select".)
        view.allowMouseReporting = false
        // Default SwiftTerm requires Cmd-hover to discover and Cmd-click to
        // open links — terrible discoverability. `.hover` underlines any
        // URL / OSC 8 hyperlink the cursor is over, and a plain click on a
        // highlighted link opens it. Selection still works via drag.
        view.linkHighlightMode = .hover
        view.linkReporting = .implicit
        // Force full-rect redraws. SwiftTerm's default Big-Sur-era
        // partial-redraw optimization keeps stale glyphs visible when the
        // backing layer has an alpha-blended (clear) background — every
        // dirty rect composites *over* the previous pixels instead of
        // replacing them, which is the "text duplicates / ghosts" symptom
        // on Termy's glass window. Trading a small perf hit for clean
        // text is the right call for a glass terminal.
        view.disableFullRedrawOnAnyChanges = false
        view.onBell = { [weak session] in
            guard let session else { return }
            TermyNotifications.shared.bell(
                window: session.terminalView?.window,
                cwd: session.cwd
            )
        }
        view.onActivityChanged = { [weak session] active in
            DispatchQueue.main.async {
                guard let session, session.isActive != active else { return }
                session.isActive = active
            }
        }
        view.onCommandSettled = { [weak session] preview, viaOSC133 in
            guard let session else { return }
            TermyNotifications.shared.commandSettled(
                window: session.terminalView?.window,
                cwd: session.cwd,
                preview: preview,
                viaOSC133: viaOSC133
            )
        }
        // Wire the trigger pipeline. Triggers come from a shared
        // TriggerRegistry singleton so toggling a pack in Settings
        // immediately affects every live pane.
        view.triggerProvider = { TriggerRegistry.shared.activeTriggers }
        view.onTriggerFired = { [weak session] trigger, line in
            guard let session else { return }
            TermyNotifications.shared.triggerFired(
                trigger: trigger,
                matched: line,
                window: session.terminalView?.window,
                cwd: session.cwd
            )
        }
        // Re-apply on window-attach and on first real layout — fixes the
        // missing-caret-at-launch case. The first applyAppearance below
        // runs while the view's frame is .zero, so SwiftTerm positions the
        // caret off-screen and it never paints. Both hooks re-run
        // applyAppearance once the view is in the hierarchy with a real
        // size, which retriggers installColors → updateDisplay →
        // updateCursorPosition with a frame the caret can actually live in.
        // Bump the coordinator's appearance stamp on each apply so the next
        // updateNSView (fired by an unrelated parent re-render) doesn't
        // redundantly re-apply the same theme/font.
        view.onNeedsAppearanceRefresh = { [weak view, weak coord = context.coordinator] in
            guard let view, let coord else { return }
            self.applyAppearance(view, coordinator: coord)
        }
        applyAppearance(view, coordinator: context.coordinator)
        // CRITICAL: autoresizing makes AppKit propagate every superview size
        // change down to this view, which fires SwiftTerm's setFrameSize →
        // grid relayout → clean redraw. Without this, the SwiftUI hosting
        // layer absorbs size changes and SwiftTerm never sees them, leaving
        // stale rendered text behind on every window drag.
        view.autoresizingMask = [.width, .height]
        view.registerForDraggedTypes([.fileURL])
        // Native right-click menu (replaces the SwiftUI .contextMenu that
        // used to wrap PaneCellView). See `TermyTerminalView.makeContextMenu`
        // for why this was moved off the SwiftUI side.
        view.menu = TermyTerminalView.makeContextMenu()

        // Bridge process state back to the session model — title/cwd updates,
        // termination, etc. Coordinator pattern keeps the delegate alive.
        view.processDelegate = context.coordinator
        // NOTE: do NOT overwrite view.terminalDelegate. LocalProcessTerminalView
        // is its own TerminalViewDelegate (see SwiftTerm's MacLocalTerminalView
        // init) and routes `send(source:data:)` to the PTY's stdin. Replacing
        // it with our own delegate would silently disconnect keyboard input.
        // SwiftTerm's macOS default already opens URLs via NSWorkspace.

        // Seed the recorder with cwd/shell so the log header carries the
        // right metadata even if the user toggled recording on between
        // sessions. SessionRecorder lazy-opens on first byte.
        view.recordingCwd = session.initialCwd
        view.recordingShell = session.shellPath

        view.startProcess(
            executable: session.shellPath,
            args: session.shellArgs,
            environment: session.processEnvironment,
            execName: nil,
            currentDirectory: session.initialCwd
        )

        // Scrollback from settings (default 10000). User-controlled so
        // marathon Claude sessions can crank to 50000, and minimal
        // terminals to 1000.
        view.getTerminal().changeScrollback(settings.scrollbackLines)

        session.terminalView = view

        // If the session was opened to run a file the OS handed us, type the
        // command into the shell once it's had a moment to print its prompt.
        // ~0.4s is enough for zsh --login to source rc files; sending too
        // early causes the command to appear before the prompt.
        if let cmd = session.pendingInitialCommand {
            session.pendingInitialCommand = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
                view?.send(txt: cmd + "\r")
            }
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Skip the full re-apply when nothing the view cares about has
        // changed. Avoids reallocating 16 NSColors per parent re-render
        // (hover-state changes in the title strip trigger updateNSView).
        if context.coordinator.lastAppearanceStamp != currentAppearanceStamp {
            applyAppearance(nsView, coordinator: context.coordinator)
        }
    }

    /// Single source of truth for what counts as a meaningful appearance
    /// change. Bump this string's input set if you add a new visual setting
    /// — both the gate in `updateNSView` and the stamp written by
    /// `applyAppearance` read this so they can never disagree.
    private var currentAppearanceStamp: String {
        "\(settings.themeID)|\(Int(settings.fontSize))|\(settings.fontFamily)|"
        + "\(Int(settings.lineSpacing * 10))|\(Int(settings.fontThicken * 100))|"
        + "\(Int(settings.minimumContrast * 100))|"
        + "\(settings.cursorStyle)|\(settings.scrollbackLines)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, sessions: sessions)
    }

    /// Visual tuning to match the rest of the suite — dark glass background,
    /// SF Mono, generous line spacing, transparent fill so the window's glass
    /// shows through the terminal area. The coordinator param lets every
    /// apply site update the appearance stamp in one place, so the
    /// updateNSView gate never re-applies what we just applied.
    private func applyAppearance(_ view: LocalProcessTerminalView, coordinator: Coordinator? = nil) {
        let size = settings.fontSize
        let font = NSFont(name: settings.fontFamily, size: size)
            ?? NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // CRITICAL: SwiftTerm's `font` setter unconditionally calls
        // `selectNone()` (MacTerminalView.swift line ~209), which means
        // any spurious applyAppearance — e.g. one triggered after the
        // user just clicked, when the appearance hasn't really changed —
        // wipes the selection mid-drag. Guard the assignment so we only
        // poke the setter when the font ACTUALLY differs from what
        // SwiftTerm is already using.
        if view.font != font {
            view.font = font
        }

        // Apply host-controlled typography knobs (added to SwiftTerm via
        // release_helpers/patch-swiftterm.sh). lineSpacing widens the cell
        // grid vertically; fontThicken bolden strokes glyphs in their fg
        // color. Both are clamped at the settings layer so the user can't
        // ship something illegible.
        view.lineSpacing = settings.lineSpacing
        view.fontThicken = settings.fontThicken
        // Cursor style — one of SwiftTerm's six. Use `setCursorStyle` (not
        // direct `options.cursorStyle = …`) so SwiftTerm's terminal-delegate
        // fires `cursorStyleChanged`, which is what propagates the new
        // style to the live CaretView. Setting the option alone updates
        // the model but leaves the caret rendering its old shape.
        if let style = SwiftTerm.CursorStyle.from(string: settings.cursorStyle) {
            view.getTerminal().setCursorStyle(style)
        }
        // Scrollback line count. SwiftTerm's `changeScrollback` reflows the
        // ring buffer to the new capacity — works on live panes, not only
        // on creation. Skipping it here meant the slider only affected
        // future panes.
        view.getTerminal().changeScrollback(settings.scrollbackLines)

        // Fully transparent — the window's adaptive backdrop is the single
        // source of opacity for the entire app. No per-element backgrounds.
        view.nativeBackgroundColor = NSColor.clear
        let (fr, fg, fb) = settings.theme.foreground
        var foreground = NSColor(
            red: CGFloat(fr) / 255, green: CGFloat(fg) / 255, blue: CGFloat(fb) / 255, alpha: 1.0
        )
        let (br, bg, bb) = settings.theme.ansi[0]
        let themeBackground = NSColor(
            red: CGFloat(br) / 255, green: CGFloat(bg) / 255, blue: CGFloat(bb) / 255, alpha: 1.0
        )
        // Enforce the WCAG contrast floor — themes whose foreground sits
        // close to their declared background (Palenight, Solarized at
        // certain values) are nudged toward white/black until they cross
        // the user's minimumContrast threshold. Themes that are already
        // above the floor pass through untouched.
        if settings.minimumContrast > 1 {
            foreground = ContrastEnforcer.enforce(
                foreground: foreground,
                background: themeBackground,
                minRatio: settings.minimumContrast
            )
        }
        view.nativeForegroundColor = foreground
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        // Caret + selection — theme-driven. caretColor defaults to the
        // theme's explicit cursor color (falls back to foreground via
        // resolvedCursor); selection background uses the theme's selection
        // pick (or ANSI 8 fallback). Both keep good contrast against the
        // glass backdrop and the theme's intended chrome.
        view.caretColor = settings.theme.nsCursorColor
        view.caretTextColor = themeBackground
        view.selectedTextBackgroundColor = settings.theme.nsSelectionColor

        view.installColors(settings.theme.swiftTermColors)

        coordinator?.lastAppearanceStamp = currentAppearanceStamp
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        let sessions: TerminalSessions
        /// Last appearance signature (theme|font|cursor) we applied — used to
        /// skip redundant `applyAppearance` calls when nothing visual changed.
        var lastAppearanceStamp: String = ""
        /// Debounce timer for persisting cwd changes. Heavy `cd` workflows
        /// otherwise produce hundreds of UserDefaults writes per second.
        private var persistTimer: Timer?

        init(session: TerminalSession, sessions: TerminalSessions) {
            self.session = session
            self.sessions = sessions
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm handles PTY resize internally; nothing extra to do.
            // We force the redraw from setFrameSize → nudgeAndRefreshAfterResize.
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            DispatchQueue.main.async {
                if !title.isEmpty { self.session.title = title }
            }
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            DispatchQueue.main.async {
                if let dir = directory, !dir.isEmpty {
                    self.session.cwd = dir
                    if let view = source as? TermyTerminalView {
                        view.recordingCwd = dir
                        view.recorderDidChangeCwd(dir)
                    }
                    // Debounce persist — `cd`-heavy workflows hit this on every
                    // hop, and UserDefaults writes are not free. 1.0s
                    // catches the end of any reasonable cd-burst (z,
                    // autoenv, scripted `find -exec cd`) without saving
                    // a stale intermediate cwd as the "current" one.
                    self.persistTimer?.invalidate()
                    self.persistTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async { self?.sessions.persist() }
                    }
                }
            }
        }

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            // Auto-close just THIS pane (closePane handles tab/window cascade).
            // closeTab(session.id) was wrong — session.id is a pane id, not a tab id.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessions.closePane(self.session.id)
            }
        }

    }
}

/// Tiny @objc helper that turns NSMenuItem clicks into NotificationCenter
/// posts. Used by the native context menu installed on every
/// TermyTerminalView (see makeContextMenu). Kept as a singleton so each
/// menu item's `target` references the same instance — saves allocating
/// a fresh dispatcher per menu.
final class NotificationDispatcher: NSObject {
    static let shared = NotificationDispatcher()
    @objc func fire(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(raw), object: nil)
    }
}
