import Testing
import Foundation
@testable import Termy

/// The command-block model + bounded log behind the Command Blocks panel.
struct CommandBlockTests {
    private func block(_ cmd: String, _ out: String = "") -> CommandBlock {
        CommandBlock(command: cmd, output: out, row: 0, at: .distantPast)
    }

    @Test func trimsCommandAndLabelsEmpty() {
        let b = block("   git status  \n")
        #expect(b.command == "git status")
        #expect(block("").label == "(command)")
        #expect(block("ls").label == "ls")
    }

    @Test func appendGrowsTheLog() {
        var log: [CommandBlock] = []
        log = CommandBlockLog.appended(log, block("a"))
        log = CommandBlockLog.appended(log, block("b"))
        #expect(log.count == 2)
        #expect(log.last?.command == "b")
    }

    @Test func appendEnforcesCapDroppingOldest() {
        var log: [CommandBlock] = []
        for i in 0..<10 { log = CommandBlockLog.appended(log, block("cmd\(i)"), cap: 5) }
        #expect(log.count == 5)
        // Oldest dropped: the surviving window is cmd5…cmd9.
        #expect(log.first?.command == "cmd5")
        #expect(log.last?.command == "cmd9")
    }

    @Test func capBoundaryKeepsExactlyCap() {
        var log: [CommandBlock] = []
        for i in 0..<5 { log = CommandBlockLog.appended(log, block("c\(i)"), cap: 5) }
        #expect(log.count == 5)
        #expect(log.first?.command == "c0")
    }
}
