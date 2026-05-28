import Testing
import AppKit
import Carbon.HIToolbox
import SwiftTerm
@testable import Termy

/// Pure-logic guard for the TUI-redraw scrollback-erase decision.
struct TUIClearPolicyTests {
    @Test func liveBurstErasesScrollback() {
        // 3 clears in the window, TUI mode active -> suppress accumulation.
        #expect(TUIClearPolicy.shouldEraseScrollback(recentClearCount: 3, tuiModeActive: true))
        #expect(TUIClearPolicy.shouldEraseScrollback(recentClearCount: 2, tuiModeActive: true))
    }

    @Test func isolatedClearPreservesScrollback() {
        // A lone `clear` (count 1) within the 30s stick window must NOT fire
        // ESC[3J, even though tuiModeActive is still true — that was wiping
        // real history.
        #expect(!TUIClearPolicy.shouldEraseScrollback(recentClearCount: 1, tuiModeActive: true))
    }

    @Test func notTuiNeverErases() {
        #expect(!TUIClearPolicy.shouldEraseScrollback(recentClearCount: 5, tuiModeActive: false))
    }
}

/// Behavioral guard for the Cmd+K fix: the non-destructive clear sequence must
/// preserve the kitty keyboard mode (and other DECSET modes) that a live TUI
/// set once at startup. We assert via the user-visible consequence — Shift+Enter
/// must still encode ESC[13;2u after the clear — which is exactly what broke
/// when Cmd+K called resetToInitialState().
@MainActor
struct ClearPreservesModesTests {
    private func makeView() -> (TerminalView, CapturingClearDelegate) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let delegate = CapturingClearDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[>1u")  // claude's kitty push (disambiguate)
        return (view, delegate)
    }

    private func shiftEnter(_ view: TerminalView, _ delegate: CapturingClearDelegate) -> [UInt8] {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                 timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                                 charactersIgnoringModifiers: "\r", isARepeat: false,
                                 keyCode: UInt16(kVK_Return))!
        view.keyDown(with: e)
        return delegate.drain()
    }

    @Test func nonDestructiveClearKeepsKittyMode() {
        let (view, delegate) = makeView()  // retain delegate (terminalDelegate is weak)
        // The exact sequence clearCurrent() now feeds.
        view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        #expect(shiftEnter(view, delegate) == [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75],
                "Shift+Enter must still encode ESC[13;2u after a non-destructive clear")
    }

    @Test func risWouldHaveBrokenKittyMode() {
        // Documents the old bug: resetToInitialState() resets kitty mode, so
        // Shift+Enter no longer disambiguates. This is what Cmd+K used to do.
        let (view, delegate) = makeView()
        view.getTerminal().resetToInitialState()
        let bytes = shiftEnter(view, delegate)
        #expect(bytes != [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75],
                "after RIS, kitty mode is gone so Shift+Enter no longer encodes ESC[13;2u (the bug)")
    }
}

private final class CapturingClearDelegate: TerminalViewDelegate {
    private var sent: [UInt8] = []
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
