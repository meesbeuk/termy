import Testing
import SwiftTerm
@testable import Termy

/// The rolling preview buffer that feeds the "command finished" notification
/// tail line + QuickSelect scan is capped at ~2048 chars, but trackIdleBytes
/// used to UTF-8-decode the entire (up to 128KB) PTY slice for every chunk on
/// the main thread. previewTail decodes only the tail.
struct PreviewTailTests {
    @Test func decodesOnlyTheTailOfALargeSlice() {
        // 100KB of 'a' then a distinctive suffix.
        var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: 100_000)
        bytes.append(contentsOf: Array("THE-END".utf8))
        let s = TermyTerminalView.previewTail(of: bytes[...], maxBytes: 8192)
        #expect(s.utf8.count <= 8192, "must not decode more than maxBytes")
        #expect(s.hasSuffix("THE-END"), "must keep the most-recent bytes")
    }

    @Test func smallSliceDecodedWhole() {
        let s = TermyTerminalView.previewTail(of: Array("hello".utf8)[...], maxBytes: 8192)
        #expect(s == "hello")
    }

    @Test func neverCrashesOnSplitMultibyte() {
        // A 4-byte emoji split so the tail begins mid-sequence; lenient decode
        // must not crash and must still surface the trailing ASCII.
        var bytes = Array("😀".utf8)            // F0 9F 98 80
        bytes.append(contentsOf: Array("Z".utf8))
        let s = TermyTerminalView.previewTail(of: bytes[...], maxBytes: 3)  // forces a split
        #expect(s.hasSuffix("Z"))
    }
}
