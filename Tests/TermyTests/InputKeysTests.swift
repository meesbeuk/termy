import Testing
import AppKit
import Carbon.HIToolbox
import SwiftTerm
@testable import Termy

private final class KeyCaptureDelegate: TerminalViewDelegate {
    var sent: [UInt8] = []
    func drain() -> [UInt8] { defer { sent.removeAll() }; return sent }
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

/// Modified Backspace/Escape under the kitty keyboard protocol — these used to
/// drop their modifiers (routed through doCommand with no NSEvent flags).
@MainActor
struct ModifiedSpecialKeyTests {
    private func makeKitty() -> (TerminalView, KeyCaptureDelegate) {
        let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let d = KeyCaptureDelegate()
        v.terminalDelegate = d
        v.feed(text: "\u{1b}[>1u")  // kitty disambiguate
        d.drain()
        return (v, d)
    }
    private func key(_ v: TerminalView, _ code: Int, _ flags: NSEvent.ModifierFlags, _ chars: String) {
        v.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!)
    }

    @Test func ctrlBackspaceDisambiguates() {
        let (v, d) = makeKitty()
        key(v, kVK_Delete, [.control], "\u{7f}")
        #expect(d.drain() == [0x1b, 0x5b, 0x31, 0x32, 0x37, 0x3b, 0x35, 0x75], "Ctrl+Backspace => ESC[127;5u")
    }

    @Test func plainBackspaceStillDel() {
        let (v, d) = makeKitty()
        key(v, kVK_Delete, [], "\u{7f}")
        #expect(d.drain() == [0x7f], "plain Backspace still DEL (0x7f) — no regression")
    }

    @Test func shiftEscapeDisambiguates() {
        let (v, d) = makeKitty()
        key(v, kVK_Escape, [.shift], "\u{1b}")
        #expect(d.drain() == [0x1b, 0x5b, 0x32, 0x37, 0x3b, 0x32, 0x75], "Shift+Escape => ESC[27;2u")
    }

    @Test func plainEscapeIsCsiUUnderKitty() {
        let (v, d) = makeKitty()
        key(v, kVK_Escape, [], "\u{1b}")
        // Disambiguate mode reports plain Escape as ESC[27u (so it's
        // distinguishable from the start of an escape sequence).
        #expect(d.drain() == [0x1b, 0x5b, 0x32, 0x37, 0x75], "plain Escape under kitty => ESC[27u")
    }
}

/// Broadcast-input forwarding: routing the key EVENT through a sibling view's
/// keyDown encodes special keys correctly, whereas the old `event.characters`
/// path mirrored macOS private-use codepoints. We assert the underlying truth:
/// (a) the arrow key's `.characters` is the private-use scalar the old code
/// would have sent, and (b) keyDown produces the real CSI sequence.
@MainActor
struct BroadcastEncodingTests {
    @Test func arrowCharactersAreUselessPrivateUse() {
        // U+F700 (NSUpArrowFunctionKey) — what the old broadcast forwarded.
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow))!
        let bytes = Array((e.characters ?? "").utf8)
        #expect(bytes == [0xEF, 0x9C, 0x80], "Up arrow .characters is U+F700 (private use) — wrong to send to a PTY")
    }

    @Test func keyDownEncodesUpArrowAsCSI() {
        let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let d = KeyCaptureDelegate(); v.terminalDelegate = d; _ = d
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow))!
        v.keyDown(with: e)
        // Normal (non-application) cursor mode: ESC [ A.
        #expect(d.sent == [0x1b, 0x5b, 0x41],
                "routing keyDown encodes Up as ESC[A, got \(d.sent)")
    }
}

/// Cocoa line-editing selectors that used to be dropped by doCommand's default.
@MainActor
struct CocoaEditingKeyTests {
    private func make() -> (TerminalView, KeyCaptureDelegate) {
        let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let d = KeyCaptureDelegate()
        v.terminalDelegate = d
        return (v, d)
    }

    @Test func deleteToBeginningOfLineSendsCtrlU() {
        let (v, d) = make()
        v.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
        #expect(d.drain() == [0x15], "Cmd+Delete => Ctrl+U")
    }
    @Test func deleteToEndOfLineSendsCtrlK() {
        let (v, d) = make()
        v.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToEndOfLine(_:)))
        #expect(d.drain() == [0x0b], "Fn+Delete / Ctrl+K => Ctrl+K")
    }
    @Test func deleteWordBackwardSendsCtrlW() {
        let (v, d) = make()
        v.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteWordBackward(_:)))
        #expect(d.drain() == [0x17], "Option+Delete => Ctrl+W")
    }
    @Test func deleteForwardSendsCsi3Tilde() {
        let (v, d) = make()
        v.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteForward(_:)))
        #expect(d.drain() == [0x1b, 0x5b, 0x33, 0x7e], "forward delete => ESC[3~")
    }
}
