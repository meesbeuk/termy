import Foundation

/// Parses ~/.ssh/config for `Host` entries so we can offer them as one-click
/// targets. Minimal parser — handles `Host` blocks, comments, and basic
/// `User`/`HostName`/`Port` overrides without full RFC compliance.
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
    /// Read ~/.ssh/config and return non-wildcard hosts.
    static func read() -> [SSHHost] {
        let path = NSHomeDirectory() + "/.ssh/config"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(raw)
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
            // Tokenize on whitespace; key value form.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
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
        return hosts.sorted { $0.alias < $1.alias }
    }
}
