import Testing
@testable import Termy

/// The waiting-for-input detector. These patterns are the contract for the
/// pane "Waiting for input" badge + the agent dashboard, so realistic Claude /
/// shell snippets are pinned both ways: real prompts must flag, ordinary
/// output + idle shell prompts must NOT (a stuck false-positive badge is worse
/// than a missed one).
struct PaneActivityClassifierTests {

    // MARK: - Should flag waiting

    @Test func claudePermissionPromptIsWaiting() {
        let screen = """
        ● I'll edit the file now.

        Do you want to proceed?
        ❯ 1. Yes
          2. No, tell Claude what to do differently
        """
        #expect(PaneActivityClassifier.isWaitingPrompt(screen))
    }

    @Test func plainYesNoIsWaiting() {
        #expect(PaneActivityClassifier.isWaitingPrompt("Overwrite existing file? (y/n)"))
        #expect(PaneActivityClassifier.isWaitingPrompt("Continue? [Y/n]"))
        #expect(PaneActivityClassifier.isWaitingPrompt("Are you sure you want to remove all packages?"))
    }

    @Test func npmAndGitStyleConfirmations() {
        #expect(PaneActivityClassifier.isWaitingPrompt("Ok to proceed? (y)"))
        #expect(PaneActivityClassifier.isWaitingPrompt("This will overwrite changes. Proceed?"))
    }

    @Test func arrowSelectMenuIsWaiting() {
        let menu = """
        Select an option (use arrow keys)
        ❯ 1) Keep
          2) Discard
        """
        #expect(PaneActivityClassifier.isWaitingPrompt(menu))
    }

    // MARK: - Should NOT flag waiting

    @Test func idleShellPromptIsNotWaiting() {
        #expect(!PaneActivityClassifier.isWaitingPrompt("mees@mac ~/projects/termy % "))
        #expect(!PaneActivityClassifier.isWaitingPrompt("➜  termy git:(main) ✗ "))
        #expect(!PaneActivityClassifier.isWaitingPrompt("$ "))
    }

    @Test func ordinaryOutputIsNotWaiting() {
        let build = """
        Compiling Termy PaneLayout.swift
        Build complete! (3.0s)
        56 tests passed.
        """
        #expect(!PaneActivityClassifier.isWaitingPrompt(build))
    }

    @Test func emptyIsNotWaiting() {
        #expect(!PaneActivityClassifier.isWaitingPrompt(""))
        #expect(!PaneActivityClassifier.isWaitingPrompt("   \n  \n"))
    }

    @Test func staleEarlyPromptDoesNotMatchAfterMoreOutput() {
        // A "proceed?" far up the buffer followed by 12+ later lines must not
        // keep the pane flagged as waiting — only the recent tail counts.
        var lines = ["Do you want to proceed? (y/n)"]
        lines += (1...20).map { "line \($0) of streaming output" }
        #expect(!PaneActivityClassifier.isWaitingPrompt(lines.joined(separator: "\n")))
    }

    // MARK: - classify()

    @Test func classifyPrefersWorkingWhenProducing() {
        // Even if the recent text looks prompt-like, active output = working.
        #expect(PaneActivityClassifier.classify(isActivelyProducing: true,
                                                recentText: "Continue? (y/n)") == .working)
    }

    @Test func classifyIdleVsWaiting() {
        #expect(PaneActivityClassifier.classify(isActivelyProducing: false,
                                                recentText: "Continue? (y/n)") == .waiting)
        #expect(PaneActivityClassifier.classify(isActivelyProducing: false,
                                                recentText: "$ ") == .idle)
    }
}
