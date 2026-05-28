import Foundation

/// Reads token usage from Claude Code's own local transcripts
/// (`~/.claude/projects/**/*.jsonl`) — the same source ccusage uses, parsed
/// natively in Swift so there's no Node dependency and it works offline.
/// Call `scan()` off the main thread; it's pure I/O + parsing.
enum ClaudeUsageReader {
    static func projectsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFractional.date(from: s)
    }

    /// Scan every transcript and return one entry per assistant turn that
    /// carries usage. Resilient: a malformed line is skipped, not fatal.
    static func scan() -> [ClaudeUsageEntry] {
        let root = projectsDirectory()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return [] }
        var entries: [ClaudeUsageEntry] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lineNo = 0
            text.enumerateLines { line, _ in
                lineNo += 1
                if let e = parseLine(line, file: url.lastPathComponent, lineNo: lineNo) {
                    entries.append(e)
                }
            }
        }
        return entries
    }

    static func parseLine(_ line: String, file: String, lineNo: Int) -> ClaudeUsageEntry? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = (message["model"] as? String) ?? ""
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        // Nothing billable on this line → skip.
        if input == 0 && output == 0 && cacheWrite == 0 && cacheRead == 0 { return nil }

        let ts = (obj["timestamp"] as? String).flatMap(parseDate) ?? Date(timeIntervalSince1970: 0)
        let msgId = (message["id"] as? String) ?? ""
        let reqId = (obj["requestId"] as? String) ?? ""
        // Stable dedupe key when ids exist; otherwise a per-line key so two
        // genuinely distinct id-less turns are never collapsed together.
        let key = (msgId.isEmpty && reqId.isEmpty) ? "\(file)#\(lineNo)" : "\(msgId):\(reqId)"

        return ClaudeUsageEntry(timestamp: ts, model: model, input: input, output: output,
                                cacheWrite: cacheWrite, cacheRead: cacheRead, dedupeKey: key)
    }
}
