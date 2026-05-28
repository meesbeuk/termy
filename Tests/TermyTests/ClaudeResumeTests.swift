import Testing
@testable import Termy

/// The resume-command builder behind the Agent panel's "Resume session" button.
struct ClaudeResumeTests {
    @Test func resumesSpecificSessionById() {
        #expect(ClaudeResume.command(sessionId: "abc123-DEF") == "claude --resume abc123-DEF")
    }

    @Test func fallsBackToContinueWithoutId() {
        #expect(ClaudeResume.command(sessionId: nil) == "claude --continue")
        #expect(ClaudeResume.command(sessionId: "") == "claude --continue")
    }

    @Test func sanitisesUnexpectedCharacters() {
        // A filename-derived id with shell-significant chars must be stripped,
        // never passed through — no spaces, semicolons, quotes, backticks.
        let dirty = "abc; rm -rf ~ `whoami`"
        let cmd = ClaudeResume.command(sessionId: dirty)
        #expect(!cmd.contains(";"))
        #expect(!cmd.contains("`"))
        #expect(!cmd.contains("rm -rf"))
        #expect(cmd.hasPrefix("claude --resume "))
    }

    @Test func keepsUuidStyleIds() {
        let uuid = "9f8e7d6c-1234-4abc-9def-0123456789ab"
        #expect(ClaudeResume.command(sessionId: uuid) == "claude --resume \(uuid)")
    }
}
