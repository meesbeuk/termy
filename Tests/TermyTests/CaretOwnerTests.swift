import Testing
import AppKit
import SwiftTerm
@testable import Termy

/// Guards the caret "single owner" fix: showCursor (the DECTCEM ESC[?25h
/// delegate callback) must re-attach the caret at the CURRENT cursor position
/// by routing through updateCursorPosition — not blindly re-add it at its stale
/// frame, which is what the bare `addSubview(caretView)` did and which raced the
/// async updateCursorPosition.
@MainActor
struct CaretOwnerTests {
    private final class NoopDelegate: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @Test func showCursorRepositionsToCurrentColumn() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let delegate = NoopDelegate()
        view.terminalDelegate = delegate
        _ = delegate  // retain (terminalDelegate is weak)

        view.feed(text: "\u{1b}[1;1H")     // cursor home (column 0)
        view.feed(text: "\u{1b}[?25l")     // hide cursor
        view.feed(text: "\u{1b}[1;21H")    // move to column 20 (1-based 21) while hidden
        view.feed(text: "\u{1b}[?25h")     // show cursor

        // With the fix, showCursor -> updateCursorPosition placed the caret at
        // column 20 (origin.x = cellWidth * 20, clearly > 0). The old bare
        // addSubview left it at the stale home origin (x == 0).
        #expect(view.caretFrame.origin.x > 1,
                "caret must sit at the current column 20 after show, not the stale home column (got x=\(view.caretFrame.origin.x))")
    }
}
