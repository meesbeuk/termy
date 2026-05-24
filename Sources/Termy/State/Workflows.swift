import Foundation

/// A reusable command snippet with `{{name}}` argument placeholders.
/// Loaded from `~/.termy/workflows/*.yaml` and `<cwd>/.termy/workflows/*.yaml`
/// (project-local takes precedence on a name collision). Surfaced through
/// the Command Palette so vibecoders can dispatch `claude --resume`,
/// `git worktree add`, deploy incantations, etc. without retyping.
///
/// YAML schema (minimal — not the full Warp surface):
///
/// ```yaml
/// name: Resume Claude
/// description: Re-attach to the most recent Claude Code session
/// command: claude --resume {{session}}
/// arguments:
///   - name: session
///     default_value: latest
/// tags: [claude, ai]
/// ```
struct Workflow: Identifiable, Equatable {
    let id: String       // unique id derived from source path
    var name: String
    var description: String
    var command: String
    var arguments: [WorkflowArgument]
    var tags: [String]
    var source: URL      // where the YAML lives (for "Reveal in Finder")
}

struct WorkflowArgument: Equatable {
    var name: String
    var defaultValue: String
}

/// Scans the two workflow directories and parses every `.yaml` file
/// into a Workflow. The parser is intentionally minimal — handles the
/// flat-key shape above plus the `arguments:` and `tags:` lists. Falls
/// back to skipping files it can't parse rather than crashing.
@MainActor
final class WorkflowStore: ObservableObject {
    @Published var workflows: [Workflow] = []

    private var loadTask: Task<Void, Never>?

    init() {
        reload()
    }

    /// Triggers an async scan + parse of the workflow directories.
    /// Debounced so a flurry of file events doesn't thrash.
    func reload() {
        loadTask?.cancel()
        loadTask = Task.detached(priority: .utility) {
            let loaded = await Self.scanAndParse()
            await MainActor.run { self.workflows = loaded }
        }
    }

    /// Project-local + global workflow directories. Project-local files
    /// override global files with the same workflow name.
    static func searchPaths(cwd: String? = nil) -> [URL] {
        var paths: [URL] = []
        let home = NSHomeDirectory()
        paths.append(URL(fileURLWithPath: home + "/.termy/workflows", isDirectory: true))
        if let cwd {
            paths.append(URL(fileURLWithPath: cwd + "/.termy/workflows", isDirectory: true))
        }
        return paths
    }

    private static func scanAndParse() async -> [Workflow] {
        let fm = FileManager.default
        var loaded: [String: Workflow] = [:]  // keyed by workflow name (later wins)
        for dir in searchPaths() {
            guard fm.fileExists(atPath: dir.path),
                  let entries = try? fm.contentsOfDirectory(atPath: dir.path)
            else { continue }
            for name in entries where name.hasSuffix(".yaml") || name.hasSuffix(".yml") {
                let url = dir.appendingPathComponent(name)
                if let wf = try? parse(at: url) {
                    loaded[wf.name] = wf
                }
            }
        }
        return loaded.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Minimal YAML parser tuned to the Workflow schema. Handles top-
    /// level scalars, the `arguments:` list of `{name, default_value}`
    /// dicts, and the `tags:` flow-style or block-style array. Avoids a
    /// full YAML dependency since the schema is fixed.
    private static func parse(at url: URL) throws -> Workflow {
        let text = try String(contentsOf: url, encoding: .utf8)
        var name = url.deletingPathExtension().lastPathComponent
        var description = ""
        var command = ""
        var arguments: [WorkflowArgument] = []
        var tags: [String] = []
        var currentArg: WorkflowArgument?

        enum Section { case top, arguments, tags }
        var section: Section = .top

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let leading = line.prefix(while: { $0 == " " }).count
            let isIndented = leading > 0

            // Detect section headers
            if !isIndented {
                if trimmed.hasPrefix("arguments:") {
                    if let arg = currentArg { arguments.append(arg); currentArg = nil }
                    section = .arguments
                    let rest = trimmed.dropFirst("arguments:".count).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("[") { /* flow-style; punt */ }
                    continue
                }
                if trimmed.hasPrefix("tags:") {
                    if let arg = currentArg { arguments.append(arg); currentArg = nil }
                    section = .tags
                    let rest = trimmed.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("[") && rest.hasSuffix("]") {
                        let inner = rest.dropFirst().dropLast()
                        tags = inner.split(separator: ",")
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    }
                    continue
                }
                section = .top
            }

            switch section {
            case .top:
                if let (k, v) = splitYamlKeyValue(trimmed) {
                    switch k {
                    case "name": name = v
                    case "description": description = v
                    case "command": command = v
                    default: break
                    }
                }
            case .arguments:
                if trimmed.hasPrefix("- ") {
                    // Start of a new argument record
                    if let arg = currentArg { arguments.append(arg) }
                    currentArg = WorkflowArgument(name: "", defaultValue: "")
                    let rest = String(trimmed.dropFirst(2))
                    if let (k, v) = splitYamlKeyValue(rest) {
                        if k == "name" { currentArg?.name = v }
                        else if k == "default_value" { currentArg?.defaultValue = v }
                    }
                } else if let (k, v) = splitYamlKeyValue(trimmed) {
                    if k == "name" { currentArg?.name = v }
                    else if k == "default_value" { currentArg?.defaultValue = v }
                }
            case .tags:
                if trimmed.hasPrefix("- ") {
                    let val = trimmed.dropFirst(2)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !val.isEmpty { tags.append(val) }
                }
            }
        }
        if let arg = currentArg { arguments.append(arg) }
        guard !command.isEmpty else { throw NSError(domain: "Workflow", code: 1) }
        let id = url.path
        return Workflow(id: id, name: name, description: description,
                        command: command, arguments: arguments, tags: tags, source: url)
    }

    /// Splits `key: value` honoring trimmed whitespace + stripping
    /// matching outer quotes from the value.
    private static func splitYamlKeyValue(_ s: String) -> (String, String)? {
        guard let colonIdx = s.firstIndex(of: ":") else { return nil }
        let k = s[s.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces)
        var v = s[s.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return (k, String(v))
    }

    /// Substitute `{{arg.name}}` placeholders in the command with the
    /// supplied values, falling back to defaults for any missing key.
    static func resolve(_ wf: Workflow, values: [String: String]) -> String {
        var out = wf.command
        for arg in wf.arguments {
            let placeholder = "{{\(arg.name)}}"
            let value = values[arg.name] ?? arg.defaultValue
            out = out.replacingOccurrences(of: placeholder, with: value)
        }
        return out
    }
}
