import Foundation

/// Parses ~/.ssh/config for `Host` entries so we can offer them as one-click
/// targets. Minimal parser — handles `Host` blocks, comments, `Include`
/// directives (recursive glob expansion, common in modern multi-account
/// setups), and basic `User`/`HostName`/`Port` overrides without full RFC
/// compliance.
struct SSHHost: Identifiable, Hashable {
    let id: String          // alias from the config
    let alias: String
    let hostname: String?   // resolved real host
    let user: String?
    let port: Int?

    /// The command Termy types into the pane to connect.
    var sshCommand: String {
        var cmd = "ssh"
        if let port { cmd += " -p \(port)" }
        if let user, let hostname { cmd += " \(user)@\(hostname)" }
        else if let user { cmd += " \(user)@\(alias)" }
        else { cmd += " \(alias)" }
        return cmd
    }
}

enum SSHHostsReader {
    /// Read ~/.ssh/config (and any files it Includes) and return non-wildcard
    /// hosts, alphabetized.
    static func read() -> [SSHHost] {
        let base = NSHomeDirectory() + "/.ssh/config"
        let lines = readWithIncludes(path: base, depth: 0, seen: Set())
        return parse(lines.joined(separator: "\n"))
    }

    /// Reads a config file, recursively inlining any `Include` directives.
    /// Depth-limited and seen-tracked so a circular Include can't loop. The
    /// glob expansion is intentionally minimal (`*`, `?`, ranges) — matches
    /// FileManager's globbing surface and covers the realistic shapes:
    /// `Include ~/.ssh/config.d/*`, `Include work/*.conf`.
    static func readWithIncludes(path: String, depth: Int, seen: Set<String>) -> [String] {
        guard depth < 8 else { return [] }
        let resolved = expandTilde(path)
        guard !seen.contains(resolved),
              let raw = try? String(contentsOfFile: resolved, encoding: .utf8)
        else { return [] }
        var seen = seen
        seen.insert(resolved)

        var out: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("include ") || line.lowercased().hasPrefix("include\t") {
                let pattern = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                let base = (resolved as NSString).deletingLastPathComponent
                for match in expandGlob(pattern, relativeTo: base) {
                    out.append(contentsOf: readWithIncludes(path: match, depth: depth + 1, seen: seen))
                }
            } else {
                out.append(String(rawLine))
            }
        }
        return out
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst(1))
    }

    /// Minimal glob expansion via FileManager.enumerator + NSString matching.
    /// ssh_config-style globs support `*` and `?`; we translate to a regex
    /// rather than shelling out so this stays in-process and unprivileged.
    private static func expandGlob(_ pattern: String, relativeTo base: String) -> [String] {
        let expanded = expandTilde(pattern)
        let absolute = expanded.hasPrefix("/") ? expanded : (base + "/" + expanded)
        // Fast path: no wildcards → single file.
        if !absolute.contains("*") && !absolute.contains("?") && !absolute.contains("[") {
            return FileManager.default.fileExists(atPath: absolute) ? [absolute] : []
        }
        // Walk only the literal-prefix directory; match the tail with regex.
        let url = URL(fileURLWithPath: absolute)
        let parent = url.deletingLastPathComponent().path
        let tail = url.lastPathComponent
        let regex = globToRegex(tail)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return names
            .filter { regex.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
            .map { parent + "/" + $0 }
            .sorted()
    }

    private static func globToRegex(_ glob: String) -> NSRegularExpression {
        var pattern = "^"
        for ch in glob {
            switch ch {
            case "*": pattern += "[^/]*"
            case "?": pattern += "."
            case ".", "+", "(", ")", "{", "}", "^", "$", "|", "\\":
                pattern += "\\\(ch)"
            default: pattern.append(ch)
            }
        }
        pattern += "$"
        return (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }

    static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var currentAlias: String?
        var currentHostname: String?
        var currentUser: String?
        var currentPort: Int?

        func flush() {
            guard let alias = currentAlias,
                  !alias.contains("*"),     // skip wildcard groups
                  !alias.isEmpty
            else {
                currentAlias = nil
                currentHostname = nil
                currentUser = nil
                currentPort = nil
                return
            }
            hosts.append(SSHHost(
                id: alias,
                alias: alias,
                hostname: currentHostname,
                user: currentUser,
                port: currentPort
            ))
            currentAlias = nil
            currentHostname = nil
            currentUser = nil
            currentPort = nil
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Tokenize on any whitespace (space or tab) — ssh_config permits
            // tabs as separators, and `Host\talias` is common when generated
            // by scripts. Earlier code split only on " " and missed every
            // tab-separated entry.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.dropFirst().joined(separator: " ")
            if key == "host" {
                flush()
                currentAlias = value
            } else if key == "hostname" {
                currentHostname = value
            } else if key == "user" {
                currentUser = value
            } else if key == "port" {
                currentPort = Int(value)
            }
        }
        flush()
        // Dedup by alias (Include files sometimes redefine), keep first occurrence.
        var seen = Set<String>()
        let unique = hosts.filter { seen.insert($0.alias).inserted }
        return unique.sorted { $0.alias < $1.alias }
    }
}
