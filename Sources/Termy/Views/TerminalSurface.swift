import SwiftUI
import AppKit
import ObjectiveC.runtime
import SwiftTerm

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
    var onCommandSettled: ((_ preview: String?) -> Void)?

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
    // Important: ONLY the visible display is paced. Tracking (OSC 133
    // command-finished, idle heuristic, session recording) still runs
    // at real-time arrival so notifications fire when commands actually
    // finish, not when the paced display catches up. Large bursts
    // (paste, file dumps > 200B) bypass the queue and render
    // immediately — pacing a `cat large_file` would just be annoying.
    private var typewriterQueue: [UInt8] = []
    private var typewriterTimer: Timer?

    // MARK: - Session recording (optional, off by default)
    //
    // When the user opts in via Settings → General → Notifications →
    // "Record session output", every pane writes its received bytes to a
    // per-session log file under ~/Library/Application Support/Termy/
    // sessions/. One file per pane lifecycle, named with start
    // timestamp + short pane id. FileHandle stays open for the pane's
    // lifetime; closed in deinit.
    private var recordingHandle: FileHandle?
    private var recordingChecked = false

    /// Bytes accumulated within a single burst before the pane is
    /// considered "active". One-byte rerenders (just a prompt refresh)
    /// shouldn't count. 64B is enough to filter prompt redraws but small
    /// enough to catch short-running commands.
    private let activeByteThreshold = 64

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
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
        // Tracking always runs at real-time arrival, regardless of
        // cinema-mode pacing. Notifications / OSC 133 / recording all
        // depend on the actual byte timing, not the paced display.
        recordIfEnabled(slice)
        scanForOSC133(slice)
        scanForTriggers(slice)
        trackIdleBytes(slice)

        // Display path: paced or immediate.
        let cinema = UserDefaults.standard.bool(forKey: "termy.cinemaMode")
        if cinema && slice.count <= 200 {
            typewriterQueue.append(contentsOf: slice)
            ensureTypewriterTimer()
        } else {
            super.dataReceived(slice: slice)
        }
        return
    }

    private func ensureTypewriterTimer() {
        if typewriterTimer != nil { return }
        let cps = UserDefaults.standard.double(forKey: "termy.cinemaCps")
        let effective = cps > 0 ? cps : 80.0
        let interval = 1.0 / max(30.0, min(500.0, effective))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
        // Drain a few bytes per tick, with auto-catch-up if the queue
        // grew large — keeps the apparent rate close to the target cps
        // without compounding latency on bursty streams.
        let chunkSize = max(1, typewriterQueue.count / 8)
        let take = min(chunkSize, typewriterQueue.count)
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

    private func stripAnsiCSI(_ s: String) -> String {
        let pattern = "\\x1B\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
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
                let preview = tailLine(from: lastPreviewBuffer)
                onCommandSettled?(preview)
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
            onCommandSettled?(preview)
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
    private func ensureIdleTimer() {
        if idleTimer != nil { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickIdle()
        }
        // Run on the common runloop mode so the timer keeps firing during
        // modal sheets / live-resizes / scroll gestures.
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func tickIdle() {
        guard isCurrentlyActive else { return }
        // If OSC 133 already fired for this burst, the heuristic is just
        // chasing a settled state — suppress it so the user doesn't get
        // two notifications.
        if osc133JustFired {
            osc133JustFired = false
            return
        }
        let threshold = UserDefaults.standard.double(forKey: "termy.idleThresholdSeconds")
        let effective = threshold > 0 ? threshold : 4.0
        if Date().timeIntervalSince(lastDataAt) >= effective {
            isCurrentlyActive = false
            onCommandSettled?(tailLine(from: lastPreviewBuffer))
        }
    }

    deinit {
        idleTimer?.invalidate()
        typewriterTimer?.invalidate()
        try? recordingHandle?.close()
    }

    /// If the user has the "Record session output" preference on, append
    /// the raw byte slice to this pane's log file. First call per pane
    /// lazily opens the file. Failures are swallowed — recording is a
    /// best-effort QoL feature, not load-bearing.
    private func recordIfEnabled(_ slice: ArraySlice<UInt8>) {
        let enabled = UserDefaults.standard.bool(forKey: "termy.recordSessions")
        guard enabled else {
            if recordingHandle != nil { try? recordingHandle?.close(); recordingHandle = nil }
            return
        }
        if recordingHandle == nil {
            if recordingChecked { return }  // failed once → don't keep trying
            recordingChecked = true
            recordingHandle = Self.openSessionLog()
        }
        guard let handle = recordingHandle else { return }
        try? handle.write(contentsOf: Data(slice))
    }

    private static func openSessionLog() -> FileHandle? {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("Termy/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(f.string(from: Date()))_\(UUID().uuidString.prefix(6)).log"
        let fileURL = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        return try? FileHandle(forWritingTo: fileURL)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onNeedsAppearanceRefresh?()
    }

    // MARK: - Live-resize coalescing
    //
    // SwiftTerm's setFrameSize calls `processSizeChange` → `terminal.resize` →
    // `reflowWider` on every AppKit setFrameSize tick. During a window-corner
    // drag AppKit fires that hundreds of times per second with intermediate
    // widths, and SwiftTerm's reflowWider has a buggy "remove wrapped
    // continuation lines" path that drops content without merging into the
    // surviving line. The net effect: scrollback gains duplicated/ghosted rows
    // and scrolling back up looks corrupt.
    //
    // Two defenses, stacked:
    //   1. Coalesce — during a live drag, skip SwiftTerm's per-tick
    //      processSizeChange so the cell grid mutates exactly once. We
    //      hand-dispatch to NSView's setFrameSize via the objc runtime to
    //      bypass SwiftTerm's override.
    //   2. Skip the reflow entirely — when the drag ends and we run the one
    //      final resize, temporarily flip the terminal's scrollback off
    //      (`isReflowEnabled = hasScrollback`, so nil disables it). The
    //      resize still rebuilds the visible grid; the buggy reflow path is
    //      simply never taken. Scrollback past the visible viewport is lost,
    //      but the alternative (corrupted, unreadable scrollback) is worse.

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Settle the grid at the final size with reflow disabled, so the
        // single resize that crosses cols/rows doesn't run reflowWider.
        // Nudge by half a point first to force processSizeChange (which
        // early-returns when the size matches the current frame). Only do
        // this when the grid would actually change — a sub-cell drag (user
        // wiggled the corner by < 1 column) doesn't need a reflow flush,
        // and going through withReflowDisabled there would needlessly trim
        // scrollback above the viewport.
        let final = frame.size
        if wouldChangeCellGrid(newSize: final) {
            withReflowDisabled {
                super.setFrameSize(NSSize(width: final.width + 0.5, height: final.height))
                super.setFrameSize(final)
            }
        }
        // Full refresh from the buffer so any stale draw region clears.
        getTerminal().refresh(startRow: 0, endRow: getTerminal().rows - 1)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasZeroSized = frame.size.width <= 0 || frame.size.height <= 0
        guard inLiveResize else {
            // Reflow only mutates the buffer when (cols × rows) would change.
            // For sub-cell layout adjustments (SwiftUI hover state, fractional
            // pixel snaps, etc.) the grid is identical before and after — so
            // we can skip the reflow-off wrapper. Wrapping every layout pass
            // in withReflowDisabled was the v0.9.3 cure-worse-than-disease:
            // every call trimmed and re-installed the scrollback buffer,
            // permanently losing history. Now we only pay that cost when an
            // actual cell-grid change is about to happen.
            if wouldChangeCellGrid(newSize: newSize) {
                withReflowDisabled { super.setFrameSize(newSize) }
            } else {
                super.setFrameSize(newSize)
            }
            // First time we land at a real size, ask the host to re-apply
            // appearance. updateDisplay (and therefore caret positioning)
            // reads frame.height — an applyAppearance fired while frame was
            // zero left the caret positioned off-screen. Dispatch async so
            // the dispatch runs after AppKit has finished this layout pass.
            if wasZeroSized && newSize.width > 0 && newSize.height > 0 && !hasLaidOutAtRealSize {
                hasLaidOutAtRealSize = true
                DispatchQueue.main.async { [weak self] in
                    self?.onNeedsAppearanceRefresh?()
                }
            }
            return
        }
        // In a live resize: update NSView's frame directly, skipping
        // SwiftTerm's per-tick terminal.resize. The cell grid stays at its
        // previous (cols × rows) for the duration of the drag — the rendered
        // text shifts slightly in the window while the user is dragging, but
        // the scrollback buffer is not mutated.
        callNSViewSetFrameSize(newSize)
        needsDisplay = true
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

    /// Runs `body` with the terminal's scrollback temporarily set to nil so
    /// `Buffer.resize` skips its reflow path. Restores the prior scrollback
    /// size afterward. Visible viewport content is preserved across the
    /// toggle (changeHistorySize trims from the START of the line buffer and
    /// adjusts yBase/yDisp so the visible window stays anchored).
    private func withReflowDisabled(_ body: () -> Void) {
        let terminal = getTerminal()
        let priorScrollback = terminal.options.scrollback
        terminal.changeScrollback(nil)
        body()
        terminal.changeScrollback(priorScrollback > 0 ? priorScrollback : nil)
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
            applyAppearance(existing)
            return existing
        }

        let view = TermyTerminalView(frame: .zero)
        view.onBell = { [weak session] in
            guard let session else { return }
            TermyNotifications.shared.bell(
                window: session.terminalView?.window,
                cwd: session.cwd
            )
        }
        view.onCommandSettled = { [weak session] preview in
            guard let session else { return }
            TermyNotifications.shared.commandSettled(
                window: session.terminalView?.window,
                cwd: session.cwd,
                preview: preview
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

        // Bridge process state back to the session model — title/cwd updates,
        // termination, etc. Coordinator pattern keeps the delegate alive.
        view.processDelegate = context.coordinator
        // NOTE: do NOT overwrite view.terminalDelegate. LocalProcessTerminalView
        // is its own TerminalViewDelegate (see SwiftTerm's MacLocalTerminalView
        // init) and routes `send(source:data:)` to the PTY's stdin. Replacing
        // it with our own delegate would silently disconnect keyboard input.
        // SwiftTerm's macOS default already opens URLs via NSWorkspace.

        view.startProcess(
            executable: session.shellPath,
            args: session.shellArgs,
            environment: session.processEnvironment,
            execName: nil,
            currentDirectory: session.initialCwd
        )

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
        "\(settings.themeID)|\(Int(settings.fontSize))|\(settings.fontFamily)"
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
        view.font = font

        // Fully transparent — the window's adaptive backdrop is the single
        // source of opacity for the entire app. No per-element backgrounds.
        view.nativeBackgroundColor = NSColor.clear
        let (fr, fg, fb) = settings.theme.foreground
        let foreground = NSColor(
            red: CGFloat(fr) / 255, green: CGFloat(fg) / 255, blue: CGFloat(fb) / 255, alpha: 1.0
        )
        view.nativeForegroundColor = foreground
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        // Caret defaults to NSColor.selectedControlColor (system accent), which
        // disappears on dark wallpapers/themes since the window's bg is clear
        // glass. Pin it to the theme's foreground so the cursor is always
        // visible, and use ansi[0] (the theme's intended bg) as the inverse
        // text color so a character under the caret stays legible.
        view.caretColor = foreground
        let (br, bg, bb) = settings.theme.ansi[0]
        view.caretTextColor = NSColor(
            red: CGFloat(br) / 255, green: CGFloat(bg) / 255, blue: CGFloat(bb) / 255, alpha: 1.0
        )

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
                    // Debounce persist — `cd`-heavy workflows hit this on every
                    // hop, and UserDefaults writes are not free.
                    self.persistTimer?.invalidate()
                    self.persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
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
