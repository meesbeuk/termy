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
        let pattern = "\\x1B\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return lastPreviewBuffer
        }
        let range = NSRange(lastPreviewBuffer.startIndex..., in: lastPreviewBuffer)
        return regex.stringByReplacingMatches(in: lastPreviewBuffer, range: range, withTemplate: "")
    }

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
        if let monitor = cinemaKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
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
        }
    }

    private func attemptFocusClaim() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if Self.shouldClaimFocus(over: window.firstResponder) {
                window.makeFirstResponder(self)
            }
        }
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
        // Capture pre-resize grid for the significant-change check
        // below. Reading these properties is cheap.
        preResizeCols = getTerminal().cols
        preResizeRows = getTerminal().rows
        guard inLiveResize else {
            // After SwiftTerm reflows yDisp can point at a row that no
            // longer makes sense for the new grid (e.g. right pane
            // closes → left pane goes full-width → reflow shrinks
            // total physical line count → old yDisp is past EOF and
            // viewport renders blank). After a non-live grid change,
            // always pin to the tail. Yanking a scrolled-back user to
            // the live tail on resize is mildly annoying, but better
            // than rendering an empty pane they have to click into to
            // recover. Don't try to use SwiftTerm's
            // `isCursorInViewPort` as a "were we at the tail"
            // detector — its formula (`yBase + 2*yDisp`) overflows
            // and crashes the app with deep scrollback.
            let gridWillChange = wouldChangeCellGrid(newSize: newSize)
            super.setFrameSize(newSize)
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
            // Non-live resize that changed the grid (split close,
            // window snap-resize, programmatic set-size). Re-poke
            // SwiftTerm with a tiny size nudge so its processSizeChange
            // re-runs against the settled frame (it early-returns when
            // size matches), then pin the viewport to the live tail
            // and force a full redisplay. Without this nudge, the
            // viewport renders blank after a split-close until the
            // next keystroke kicks SwiftTerm into drawing.
            if gridWillChange {
                DispatchQueue.main.async { [weak self] in
                    self?.nudgeAndRefreshAfterResize()
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
        // Default SwiftTerm requires Cmd-hover to discover and Cmd-click to
        // open links — terrible discoverability. `.hover` underlines any
        // URL / OSC 8 hyperlink the cursor is over, and a plain click on a
        // highlighted link opens it. Selection still works via drag.
        view.linkHighlightMode = .hover
        view.linkReporting = .implicit
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

        // Bump scrollback from SwiftTerm's 500-line default to 10000.
        // 500 is laughably small for AI workflows: a single claude
        // response easily fills 100+ lines, and the moment you split
        // a pane (halving its width) all those lines wrap and the
        // physical row count doubles or triples — blowing past 500
        // and dropping the oldest history permanently. 10000 covers
        // hours of work even with aggressive wrapping. The memory
        // cost is modest (~few MB per pane) and bounded.
        view.getTerminal().changeScrollback(10000)

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
