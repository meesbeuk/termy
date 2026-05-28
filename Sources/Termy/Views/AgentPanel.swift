import SwiftUI
import AppKit

/// Agent Panel — reads Claude Code's local JSONL transcripts under
/// `~/.claude/projects/` and surfaces a sidebar of recent sessions
/// with last user message, last assistant message, project path,
/// and a quick action to `cd` into the session's working dir in a
/// new Termy tab.
///
/// This is Bucket A #8 from the competitor research — the "Agent
/// Panel that's actually useful (vs Warp's)" angle: we read local
/// files that Claude Code already writes, no first-party API needed.
struct AgentPanel: View {
    @EnvironmentObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var sessionsList: [ClaudeSession] = []
    @State private var selected: ClaudeSession?
    @State private var query: String = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.3)
                detail
            }
        }
        .frame(maxWidth: 760, maxHeight: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear { loadSessions() }
        .background(
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.aiAccent)
                Text("Agent Sessions")
                    .font(DS.Typo.title)
            }
            Spacer()
            Button("Refresh") { loadSessions() }
                .controlSize(.small)
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    private var sidebar: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Filter sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.caption)
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )

            ScrollView {
                VStack(spacing: 1) {
                    if loading {
                        ProgressView().padding(DS.Spacing.l)
                    } else if filtered.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 20))
                                .foregroundStyle(DS.Colors.tertiary)
                            Text(sessionsList.isEmpty
                                 ? "No Claude Code sessions found."
                                 : "No matches.")
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.Colors.tertiary)
                                .multilineTextAlignment(.center)
                            if sessionsList.isEmpty {
                                Text("Run `claude` in a Termy tab to start one — its transcripts will appear here.")
                                    .font(DS.Typo.tiny)
                                    .foregroundStyle(DS.Colors.tertiary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, DS.Spacing.s)
                            }
                        }
                        .padding(.vertical, DS.Spacing.l)
                    } else {
                        ForEach(filtered) { sess in
                            AgentRow(
                                session: sess,
                                isSelected: selected?.id == sess.id,
                                onSelect: { selected = sess }
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.s)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 280)
        .background(.thickMaterial.opacity(0.3))
    }

    @ViewBuilder
    private var detail: some View {
        if let sess = selected {
            AgentDetail(session: sess, onOpenInTab: { openInTab(sess) }, onResume: { resume(sess) })
        } else {
            VStack {
                Spacer()
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(DS.Colors.tertiary)
                Text("Select a session")
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Colors.tertiary)
                    .padding(.top, DS.Spacing.s)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filtered: [ClaudeSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessionsList }
        return sessionsList.filter {
            $0.projectPath.lowercased().contains(q)
                || $0.lastUserMessage.lowercased().contains(q)
                || $0.lastAssistantSnippet.lowercased().contains(q)
        }
    }

    private func loadSessions() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let loaded = await ClaudeSessionReader.scanAll()
            await MainActor.run {
                sessionsList = loaded
                selected = loaded.first
                loading = false
            }
        }
    }

    private func openInTab(_ sess: ClaudeSession) {
        // Open a new tab in the session's project directory.
        sessions.openTabIn(cwd: sess.projectPath)
        onDismiss()
    }

    private func resume(_ sess: ClaudeSession) {
        // Relaunch the past Claude session in a fresh pane in its project dir.
        sessions.openTabRunning(cwd: sess.projectPath,
                                command: ClaudeResume.command(sessionId: sess.sessionId))
        onDismiss()
    }
}

// MARK: - Session model + reader

struct ClaudeSession: Identifiable, Equatable {
    let id: String          // JSONL file path
    let sessionId: String
    let projectPath: String // decoded from the project-dir name
    let projectDisplayName: String
    let modified: Date
    let lastUserMessage: String
    let lastAssistantSnippet: String
}

enum ClaudeSessionReader {
    /// Scans `~/.claude/projects/<encoded-dir>/<sessionId>.jsonl`,
    /// reads tail of each file for last user + assistant message
    /// previews, sorts newest-first. Limits to 60 most recent to
    /// keep the panel responsive.
    static func scanAll() async -> [ClaudeSession] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var sessions: [ClaudeSession] = []
        for dir in projectDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                if let sess = parse(url: url, projectDir: dir.lastPathComponent) {
                    sessions.append(sess)
                }
            }
        }
        return sessions.sorted { $0.modified > $1.modified }.prefix(60).map { $0 }
    }

    /// Encoded project directory names like `-Users-meesdebeukelaar-Code-Termy`
    /// back to `/Users/meesdebeukelaar/Code/Termy`. Best-effort; if the
    /// path doesn't resolve to a real directory we still display it for
    /// reference.
    private static func decodeProjectPath(_ encoded: String) -> String {
        // Claude Code encodes / as -; safe naive decode (collisions are
        // possible if the real path contains dashes, but matches its own
        // encoding scheme).
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    private static func parse(url: URL, projectDir: String) -> ClaudeSession? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Read backwards through the lines to find the most recent
        // user + assistant messages without parsing every line. JSONL
        // is huge for long sessions; limit to last 200 lines.
        let lines = text.split(separator: "\n").suffix(200)
        var lastUser: String = ""
        var lastAssistant: String = ""
        var sessionId: String = ""
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if sessionId.isEmpty, let id = obj["sessionId"] as? String {
                sessionId = id
            }
            let type = obj["type"] as? String
            if type == "user" && lastUser.isEmpty {
                lastUser = extractTextPreview(from: obj)
            } else if type == "assistant" && lastAssistant.isEmpty {
                lastAssistant = extractTextPreview(from: obj)
            }
            if !lastUser.isEmpty && !lastAssistant.isEmpty && !sessionId.isEmpty { break }
        }
        let decoded = decodeProjectPath(projectDir)
        let displayName = (decoded as NSString).lastPathComponent.isEmpty ? decoded : (decoded as NSString).lastPathComponent
        return ClaudeSession(
            id: url.path,
            sessionId: sessionId.isEmpty ? url.deletingPathExtension().lastPathComponent : sessionId,
            projectPath: decoded,
            projectDisplayName: displayName,
            modified: modified,
            lastUserMessage: lastUser.isEmpty ? "(no user messages yet)" : lastUser,
            lastAssistantSnippet: lastAssistant.isEmpty ? "(no assistant reply yet)" : lastAssistant
        )
    }

    /// Pull a readable text preview out of a Claude message record.
    /// Records have a `.message.content` that may be a string or an
    /// array of `{type, text}` blocks; we keep only the text blocks.
    private static func extractTextPreview(from obj: [String: Any]) -> String {
        let message = (obj["message"] as? [String: Any]) ?? obj
        if let s = message["content"] as? String { return trim(s) }
        if let arr = message["content"] as? [[String: Any]] {
            for block in arr {
                if let text = block["text"] as? String, !text.isEmpty {
                    return trim(text)
                }
            }
        }
        return ""
    }

    private static func trim(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 200 ? String(collapsed.prefix(199)) + "…" : collapsed
    }
}

// MARK: - Row + detail

private struct AgentRow: View {
    let session: ClaudeSession
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? DS.Colors.aiAccent : DS.Colors.tertiary)
                        .frame(width: 14)
                    Text(session.projectDisplayName)
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                Text(session.lastUserMessage)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isSelected ? DS.Colors.chipBgActive
                          : (hovering ? DS.Colors.chipBgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

private struct AgentDetail: View {
    let session: ClaudeSession
    let onOpenInTab: () -> Void
    let onResume: () -> Void

    private var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.modified)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.projectDisplayName)
                        .font(DS.Typo.title)
                    Text(session.projectPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Colors.tertiary)
                    Text("Last update \(dateString) · session \(session.sessionId.prefix(8))")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }

                HStack(spacing: DS.Spacing.s) {
                    Button(action: onResume) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Resume session")
                        }
                        .font(DS.Typo.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Relaunch this session in a new pane (claude --resume)")

                    Button(action: onOpenInTab) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.square")
                            Text("Open new tab here")
                        }
                        .font(DS.Typo.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                section(title: "Last user message") {
                    Text(session.lastUserMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.Colors.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.s)
                                .fill(DS.Colors.chipBg)
                        )
                }
                section(title: "Last assistant reply") {
                    Text(session.lastAssistantSnippet)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.Colors.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.s)
                                .fill(DS.Colors.chipBg)
                        )
                }
            }
            .padding(DS.Spacing.l)
        }
    }

    @ViewBuilder
    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .textCase(.uppercase)
                .opacity(0.7)
            content()
        }
    }
}
