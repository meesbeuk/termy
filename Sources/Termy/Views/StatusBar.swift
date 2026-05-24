import SwiftUI
import Foundation

/// Slim bar pinned to the bottom of the window. Shows the active pane's cwd
/// (with `~` folding) + git branch (when the cwd is inside a repo) + clock.
/// Updates on cwd change; git lookup is cached per-cwd so it doesn't fork shells
/// on every render.
struct StatusBar: View {
    @EnvironmentObject var sessions: TerminalSessions

    @State private var gitBranch: String?
    @State private var now: Date = Date()
    @State private var lastResolvedCwd: String = ""
    private let clockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var cwd: String { sessions.currentSession?.cwd ?? "" }

    private var displayCwd: String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(displayCwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let branch = gitBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(clockString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onAppear { resolveGit() }
        .onChange(of: cwd) { _, _ in resolveGit() }
        .onReceive(clockTimer) { now = $0 }
    }

    private var clockString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: now)
    }

    /// Walk up from cwd looking for a .git directory; if found, read HEAD.
    /// Pure filesystem — no shell fork, no git binary required.
    private func resolveGit() {
        guard !cwd.isEmpty, cwd != lastResolvedCwd else { return }
        lastResolvedCwd = cwd
        DispatchQueue.global(qos: .utility).async {
            let branch = Self.findBranch(startingAt: cwd)
            DispatchQueue.main.async { self.gitBranch = branch }
        }
    }

    /// Walks up the tree looking for `.git`. Handles three layouts:
    ///   - normal repo:   `.git/` directory with `HEAD` inside
    ///   - submodule:     `.git` file pointing at `gitdir: <path>`
    ///   - worktree:      same `gitdir:` indirection — must follow to find HEAD
    /// Without the indirection step we'd render "gitdir:" as the branch name.
    private static func findBranch(startingAt path: String) -> String? {
        var current = URL(fileURLWithPath: path)
        let fm = FileManager.default
        for _ in 0..<25 {
            let gitURL = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                let headURL: URL = isDir.boolValue
                    ? gitURL.appendingPathComponent("HEAD")
                    : Self.resolveGitDirFile(at: gitURL).appendingPathComponent("HEAD")
                if let data = try? Data(contentsOf: headURL),
                   let s = String(data: data, encoding: .utf8) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("ref: refs/heads/") {
                        return String(trimmed.dropFirst("ref: refs/heads/".count))
                    }
                    return String(trimmed.prefix(7))
                }
                return nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// Parses a `.git` file (submodule / worktree) of the form
    /// `gitdir: <relative-or-absolute-path>` and returns the resolved URL.
    private static func resolveGitDirFile(at fileURL: URL) -> URL {
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return fileURL }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else { return fileURL }
        let raw = String(trimmed.dropFirst("gitdir: ".count))
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return fileURL.deletingLastPathComponent().appendingPathComponent(raw)
    }
}
