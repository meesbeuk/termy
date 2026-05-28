import Foundation

/// One shell command + its output, captured from OSC 133 shell-integration
/// marks (prompt-start A, output-start C, command-done D). SwiftTerm renders
/// the grid itself, so Termy can't fold scrollback lines inline; instead these
/// blocks power a collapsible Command Blocks panel (jump-to, copy-output) — the
/// same block UX, in a companion view, built on the marks we already track.
///
/// `output` is the rolling preview (capped ~2KB), so it's the tail of long
/// output, not the full transcript — labelled as a preview in the UI.
struct CommandBlock: Identifiable, Equatable {
    let id: UUID
    let command: String      // the command line as it appeared (may include the prompt prefix)
    let output: String       // captured output preview (tail)
    let row: Int             // scrollback row of the prompt, for jump-to
    let at: Date

    init(id: UUID = UUID(), command: String, output: String, row: Int, at: Date) {
        self.id = id
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.output = output
        self.row = row
        self.at = at
    }

    /// A non-empty one-line label for the block list.
    var label: String { command.isEmpty ? "(command)" : command }
}

/// Append-with-cap so a marathon session's block list stays bounded. Pure +
/// testable; the capture site just swaps its array for the result.
enum CommandBlockLog {
    static let cap = 200
    static func appended(_ blocks: [CommandBlock], _ block: CommandBlock, cap: Int = cap) -> [CommandBlock] {
        var out = blocks
        out.append(block)
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }
}
