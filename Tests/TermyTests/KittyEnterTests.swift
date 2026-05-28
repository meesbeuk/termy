import Testing
import AppKit
import Carbon.HIToolbox
import SwiftTerm
@testable import Termy

/// Captures bytes the terminal view would send to the PTY, so we can assert
/// exactly what a keystroke encodes to without a real shell.
private final class CapturingDelegate: TerminalViewDelegate {
    var sent: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
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

/// Regression tests for the Shift+Enter bug. Claude Code (and neovim, fish,
/// etc.) enable the kitty keyboard protocol via `CSI > 1 u`. Before the fix,
/// SwiftTerm never mapped the main Return key to the kitty `.enter` functional
/// key, so Shift+Enter lost its modifier and was indistinguishable from Enter
/// — claude submitted instead of inserting a newline.
///
/// With the patch, keyDown handles Return through the kitty functional-key path
/// (no `interpretKeyEvents`, so no window is needed) and encodes WITH modifiers.
@MainActor
struct KittyEnterTests {
    private func makeView() -> (TerminalView, CapturingDelegate) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        // Enable the kitty keyboard protocol, disambiguate flag (what claude pushes).
        view.feed(text: "\u{1b}[>1u")
        delegate.sent.removeAll()  // drop any query/response noise from the feed
        return (view, delegate)
    }

    private func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags, chars: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func shiftEnterEncodesCsiU() {
        let (view, delegate) = makeView()
        view.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), flags: [.shift], chars: "\r"))
        // ESC [ 1 3 ; 2 u  — keycode 13 (Enter), modifier 2 (shift). This is the
        // exact sequence Claude Code reads as "insert newline".
        #expect(delegate.sent == [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75],
                "Shift+Enter under kitty mode must encode ESC[13;2u, got \(delegate.sent)")
    }

    @Test func plainEnterStillSendsCarriageReturn() {
        let (view, delegate) = makeView()
        view.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), flags: [], chars: "\r"))
        // No regression: unmodified Enter is still a bare CR, so shells/REPLs
        // submit exactly as before.
        #expect(delegate.sent == [0x0d],
                "plain Enter must still send CR (0x0d), got \(delegate.sent)")
    }

    @Test func ctrlEnterEncodesCsiUWithCtrlModifier() {
        let (view, delegate) = makeView()
        view.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), flags: [.control], chars: "\r"))
        // ESC [ 1 3 ; 5 u — modifier 5 = ctrl (4) + 1. Bonus: the same fix makes
        // Ctrl+Enter / Alt+Enter disambiguate too.
        #expect(delegate.sent == [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x35, 0x75],
                "Ctrl+Enter under kitty mode must encode ESC[13;5u, got \(delegate.sent)")
    }
}
