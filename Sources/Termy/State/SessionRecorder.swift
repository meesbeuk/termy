import Foundation
import AppKit

/// Writes a single terminal pane's stream to a readable transcript under
/// `~/Library/Application Support/Termy/sessions/`.
///
/// **Output style** — the log reads like a book of scenes, not a memory
/// dump:
///
/// ```
/// ╭──────────────────────────────────────────────────────────╮
/// │ Termy session log                                        │
/// │ 2026-05-25 09:33  ·  meesdebeukelaar@Meess-Mac-mini      │
/// │ /bin/zsh  ·  ~/projects/termy                            │
/// ╰──────────────────────────────────────────────────────────╯
///
/// ▸ 09:33:14  in ~/projects/termy
///   ❯ ls -la
///
///   total 24
///   drwxr-xr-x  ...
///   -rw-r--r--  ...
///
/// ▸ 09:33:22  in ~/projects/termy
///   ❯ claude
///
///   [interactive program — 4m 12s]
///
/// ▸ 09:37:34  in ~/projects/termy
///   ❯ git status
///   ...
/// ```
///
/// **How it gets there:**
///
///   1. Strip ANSI / OSC / DCS bytes (chunk-boundary-safe state machine).
///   2. Detect alternate-screen entry/exit (CSI `?1049h` / `?47h`). Output
///      inside an alt-screen run is unreadable as plain text — it's just
///      cursor-positioning redraws. We swallow it and emit a single
///      `[interactive program — XXs]` block on exit.
///   3. Use OSC 133 prompt markers when present, otherwise heuristically
///      split on newlines following an idle pause to find prompt
///      boundaries. Each becomes a scene header.
///   4. Indent body text two spaces under each scene so it's visually
///      under its header.
///
/// Best-effort: any IO failure stops further recording for this pane.
final class SessionRecorder {
    private let url: URL
    private var handle: FileHandle?

    /// Carry-over bytes for an escape sequence split across slices.
    private var pending: [UInt8] = []

    /// Cell-by-cell current-line buffer. Models a single line of the
    /// terminal as a Character grid with a write cursor. CR moves the
    /// cursor to 0 (it does NOT clear), BS moves it back, CSI K
    /// truncates at the cursor, characters overwrite at the cursor.
    /// Only when `\n` arrives is the resolved line shipped to the file.
    /// This is what collapses zsh's "print prompt + autosuggestion +
    /// CR + reprint" cycle to the final visible line.
    private var currentCells: [Character] = []
    private var currentCursor: Int = 0
    /// Bytes from the previous append() that started a multi-byte UTF-8
    /// codepoint we couldn't finish yet. Prepended to the next slice.
    private var pendingUtf8: [UInt8] = []
    /// Buffer of pre-flush completed lines, in case a future scene-break
    /// heuristic wants to peek at them. Currently unused but cheap.
    private var lineBuffer: String = ""

    /// Are we currently inside the alternate screen buffer (claude/codex/
    /// vim/less etc.)? Driven by CSI `?1049h` / `?1047h` / `?47h` set/reset.
    private var inAlternateScreen = false
    private var alternateScreenStart: Date?

    /// Most recent observed cwd — written into the scene header so the
    /// reader knows where the command ran.
    private var currentCwd: String

    /// Wall-clock time of the last byte we wrote. Used to decide whether
    /// a new prompt warrants a scene break (a freshly-resumed pane after
    /// a long pause = new scene; rapid back-to-back commands = same scene).
    private var lastWriteAt: Date = .distantPast

    /// True the first time we open the file — used to skip a leading
    /// blank line before the very first scene.
    private var firstScene = true

    init?(cwd: String, shell: String) {
        let dir = Self.sessionsDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(f.string(from: Date()))_\(UUID().uuidString.prefix(6)).log"
        self.url = dir.appendingPathComponent(name)
        self.currentCwd = cwd
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        writeHeader(cwd: cwd, shell: shell)
    }

    deinit { close() }

    func close() {
        if inAlternateScreen { closeAlternateScreen() }
        if !currentCells.isEmpty { commitLine() }
        writeRaw("\n")
        try? handle?.close()
        handle = nil
    }

    /// Feed a raw PTY byte slice. The recorder buffers, strips, and
    /// segments the input into transcript sections.
    func append(_ slice: ArraySlice<UInt8>) {
        guard handle != nil else { return }
        var buf = pending
        buf.append(contentsOf: slice)
        pending.removeAll(keepingCapacity: true)

        var i = 0
        while i < buf.count {
            let b = buf[i]
            if b == 0x1B {  // ESC: classify the sequence
                guard i + 1 < buf.count else {
                    pending = Array(buf[i...])
                    break
                }
                let kind = buf[i + 1]
                switch kind {
                case 0x5B:  // CSI: [
                    if let end = Self.scanCSIEnd(buf, from: i + 2) {
                        handleCSI(buf, csiStart: i + 2, csiEnd: end)
                        i = end + 1
                    } else {
                        pending = Array(buf[i...])
                        return
                    }
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ], P, X, ^, _ → string-terminator sequences
                    if let end = Self.scanStringTerminator(buf, from: i + 2) {
                        handleStringSeq(buf, sigil: kind, payloadStart: i + 2, payloadEnd: end)
                        i = end + 1
                    } else {
                        pending = Array(buf[i...])
                        return
                    }
                case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F:  // charset selects: ESC ( + 1 byte
                    if i + 2 < buf.count {
                        i += 3
                    } else {
                        pending = Array(buf[i...])
                        return
                    }
                default:
                    i += 2  // single-byte ESC (cursor save, RIS, etc.)
                }
                continue
            }
            // While in alternate screen mode, drop everything — the
            // output is cursor moves and full redraws, not text the user
            // could possibly want to re-read.
            if inAlternateScreen {
                i += 1
                continue
            }
            // C0 controls: keep tab + newline, drop the rest.
            if b < 0x20 {
                switch b {
                case 0x09: writeCell(" ")                 // TAB → space
                case 0x0A: commitLine()                   // LF → flush current line
                case 0x0D: currentCursor = 0              // CR → cursor to column 0 (don't erase)
                case 0x08: currentCursor = max(0, currentCursor - 1)  // BS
                default:   break                          // BEL, etc.
                }
                i += 1
                continue
            }
            if b == 0x7F {  // DEL
                i += 1
                continue
            }
            // Append UTF-8 codepoint. Multi-byte sequences may span
            // chunk boundaries — appendUtf8Byte handles partial reads.
            let consumed = appendUtf8Byte(b, from: buf, at: i)
            i += consumed
        }
        lastWriteAt = Date()
    }

    /// Notify the recorder the working directory just changed. Used as a
    /// hint for the next scene header.
    func notifyCwdChanged(_ cwd: String) {
        guard handle != nil else { return }
        currentCwd = cwd
    }

    // MARK: - CSI / OSC handlers

    private func handleCSI(_ buf: [UInt8], csiStart: Int, csiEnd: Int) {
        guard csiEnd >= csiStart else { return }
        let final = buf[csiEnd]

        // Parse leading parameters (digits, semicolons) into a sequence
        // of integers. Pn=0 is the typical default for missing params.
        let isDecPrivate = csiStart < csiEnd && buf[csiStart] == 0x3F
        let paramStart = isDecPrivate ? csiStart + 1 : csiStart
        let paramBytes = paramStart <= csiEnd ? Array(buf[paramStart..<csiEnd]) : []
        let paramStr = String(decoding: paramBytes, as: UTF8.self)
        let params = paramStr
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        switch final {
        case 0x4B where !isDecPrivate:  // CSI Pn K — erase in line
            let mode = params.first ?? 0
            switch mode {
            case 0: truncateAtCursor()      // cursor → end
            case 1: blankBeforeCursor()     // start → cursor
            case 2: clearCurrentLine()      // whole line
            default: break
            }
            return
        case 0x68, 0x6C:  // DEC private mode set/reset (only when ?-prefixed)
            guard isDecPrivate else { return }
            let altModes: Set<Int> = [47, 1047, 1049]
            for m in params where altModes.contains(m) {
                if final == 0x68 { enterAlternateScreen() }
                else { exitAlternateScreen() }
                return
            }
        default:
            break
        }
    }

    // MARK: - Cell-buffer ops

    /// Place `c` at the cursor (overwriting any existing cell) and
    /// advance. Extends the buffer with spaces when the cursor has
    /// somehow moved past the end (defensive — most terminals don't do
    /// this but `\rxxxx` past the original line length will).
    private func writeCell(_ c: Character) {
        while currentCells.count < currentCursor {
            currentCells.append(" ")
        }
        if currentCursor < currentCells.count {
            currentCells[currentCursor] = c
        } else {
            currentCells.append(c)
        }
        currentCursor += 1
    }

    /// Newline arrived — finalise the current line, indent it, write it,
    /// and reset cell state for the next line.
    private func commitLine() {
        let line = String(currentCells)
        currentCells.removeAll(keepingCapacity: true)
        currentCursor = 0
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            writeRaw("\n")
        } else {
            writeRaw("  ")
            writeRaw(trimmed)
            writeRaw("\n")
        }
    }

    /// CSI 0K — drop everything from the cursor to the end of the line.
    private func truncateAtCursor() {
        if currentCursor < currentCells.count {
            currentCells.removeSubrange(currentCursor...)
        }
    }

    /// CSI 1K — blank cells from start of line up to (and including) the
    /// cursor. We just replace them with spaces so later writes can
    /// still land at their positions.
    private func blankBeforeCursor() {
        let upTo = min(currentCells.count, currentCursor + 1)
        for i in 0..<upTo { currentCells[i] = " " }
    }

    /// CSI 2K — clear the whole line. Cursor stays put.
    private func clearCurrentLine() {
        currentCells.removeAll(keepingCapacity: true)
    }

    private func handleStringSeq(_ buf: [UInt8], sigil: UInt8, payloadStart: Int, payloadEnd: Int) {
        // Only OSC (sigil = `]`) carries data we care about. Look for:
        //   OSC 7 ; file://host/cwd → cwd advertisement
        //   OSC 133 ; A → prompt start (begin a new scene)
        guard sigil == 0x5D else { return }
        // payload bytes are buf[payloadStart..<terminatorStart]
        // terminator is BEL (1 byte) or ESC \ (2 bytes); strip it
        let endTrim = buf[payloadEnd] == 0x07 ? 0 : 1
        let payloadBytes = Array(buf[payloadStart..<(payloadEnd - endTrim)])
        let payload = String(decoding: payloadBytes, as: UTF8.self)
        if payload.hasPrefix("7;") {
            let url = String(payload.dropFirst(2))
            if let parsed = URL(string: url), parsed.isFileURL {
                currentCwd = parsed.path
            }
            return
        }
        if payload.hasPrefix("133;A") {
            beginScene()
        }
    }

    // MARK: - Alternate screen detection

    private func enterAlternateScreen() {
        if inAlternateScreen { return }
        // Finalise any in-progress line before the screen goes silent.
        if !currentCells.isEmpty { commitLine() }
        inAlternateScreen = true
        alternateScreenStart = Date()
    }

    private func closeAlternateScreen() {
        guard inAlternateScreen else { return }
        let start = alternateScreenStart ?? Date()
        let elapsed = Date().timeIntervalSince(start)
        inAlternateScreen = false
        alternateScreenStart = nil
        let stamp = Self.formatDuration(elapsed)
        writeRaw("\n  [interactive program — \(stamp)]\n\n")
    }

    private func exitAlternateScreen() {
        closeAlternateScreen()
    }

    // MARK: - Scene boundaries

    /// Start a new transcript scene — fires on OSC 133;A (prompt mark)
    /// or, lacking that, on the heuristic prompt-detection inside
    /// flushLineBuffer. Writes a `▸ HH:mm:ss  in <cwd>` header followed
    /// by two spaces of indent for the next prompt+output block.
    private func beginScene() {
        if firstScene {
            firstScene = false
        } else {
            writeRaw("\n")
        }
        let stamp = Self.headerTimeFormatter.string(from: Date())
        writeRaw("▸ \(stamp)  in \(foldHome(currentCwd))\n")
    }

    private func writeRaw(_ s: String) {
        guard let handle, let data = s.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    // MARK: - UTF-8 byte → Character assembly
    //
    // Naive single-byte decoding would mangle every cyrillic / Chinese /
    // emoji character (2-4 bytes each). Assemble the full codepoint
    // before writing it as a cell.

    /// Append a UTF-8 codepoint that starts at `buf[index]` (with lead
    /// byte `b`) to the current cell buffer. Returns how many bytes of
    /// `buf` we consumed (1 for ASCII, 2-4 for multi-byte, or whatever
    /// trailing bytes we stashed into `pending` for the next slice).
    private func appendUtf8Byte(_ b: UInt8, from buf: [UInt8], at index: Int) -> Int {
        if b < 0x80 {
            writeCell(Character(UnicodeScalar(b)))
            return 1
        }
        // Continuation byte without a lead — skip.
        if (b & 0xC0) == 0x80 { return 1 }
        let need: Int
        if (b & 0xE0) == 0xC0 { need = 2 }
        else if (b & 0xF0) == 0xE0 { need = 3 }
        else if (b & 0xF8) == 0xF0 { need = 4 }
        else { return 1 }
        if index + need <= buf.count {
            let bytes = Array(buf[index..<index + need])
            if let s = String(bytes: bytes, encoding: .utf8), let c = s.first {
                writeCell(c)
            }
            return need
        }
        // Trailing partial codepoint — stash and continue on next slice.
        pending.append(contentsOf: buf[index..<buf.count])
        return buf.count - index
    }

    // MARK: - Helpers

    private func writeHeader(cwd: String, shell: String) {
        let host = ProcessInfo.processInfo.hostName
        let user = NSUserName()
        let stamp = Self.headerStampFormatter.string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let foldedCwd = foldHome(cwd)
        let header = """
        ╭──────────────────────────────────────────────────────────╮
        │ Termy session log
        │ \(stamp)  ·  \(user)@\(host)
        │ \(shell)  ·  \(foldedCwd)
        │ Termy \(version)
        ╰──────────────────────────────────────────────────────────╯


        """
        writeRaw(header)
    }

    private static let headerStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f
    }()

    private static let headerTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func sessionsDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Termy/sessions", isDirectory: true)
    }

    private func foldHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let hours = s / 3600
        let mins = (s % 3600) / 60
        return "\(hours)h \(mins)m"
    }

    // MARK: - Escape-sequence scanning

    /// CSI parameter byte range is 0x30-0x3F, intermediate 0x20-0x2F,
    /// final byte 0x40-0x7E. Returns the index of the final byte, or nil
    /// if the sequence isn't yet complete.
    private static func scanCSIEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var j = start
        while j < bytes.count {
            let b = bytes[j]
            if (0x40...0x7E).contains(b) { return j }
            if !((0x20...0x3F).contains(b)) { return j }  // malformed → break here
            j += 1
        }
        return nil
    }

    /// OSC/DCS/SOS/PM/APC string terminator: BEL (0x07) or ESC \ (0x1B 0x5C).
    /// Returns the index of the LAST byte of the terminator.
    private static func scanStringTerminator(_ bytes: [UInt8], from start: Int) -> Int? {
        var j = start
        while j < bytes.count {
            let b = bytes[j]
            if b == 0x07 { return j }
            if b == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return j + 1 }
            if j - start > 8192 { return j }
            j += 1
        }
        return nil
    }
}
