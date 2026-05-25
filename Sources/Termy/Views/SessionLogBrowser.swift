import SwiftUI
import AppKit

/// Browser for past terminal session recordings. Matches the canonical
/// Settings + Command Palette + Cheatsheet shell (640×480, sidebar +
/// detail). Sidebar lists every saved log file sorted newest-first;
/// detail shows head + tail of the selected log so the user can spot
/// the conversation / build / test run they're looking for without
/// opening anything externally.
///
/// Source: `~/Library/Application Support/Termy/sessions/*.log` — the
/// files TermyTerminalView writes when `recordSessions` is on.
struct SessionLogBrowser: View {
    let onDismiss: () -> Void

    @State private var logs: [SessionLog] = []
    @State private var selectedLog: SessionLog?
    @State private var query: String = ""
    @State private var showingClearConfirm = false
    /// Per-log content-match counts populated when the query is non-empty
    /// — lets us show "12 matches" next to each filtered file and rank
    /// results. Empty when query is empty (filename filter only).
    @State private var contentMatchCounts: [String: Int] = [:]
    @State private var searchTask: Task<Void, Never>?

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
        .frame(width: 720, height: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear(perform: loadLogs)
        .background(
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Session Logs")
                    .font(DS.Typo.title)
            }
            Spacer()
            Button("Reveal folder") {
                let dir = Self.sessionsDir()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
            .controlSize(.small)
            Button("Clear all…", role: .destructive) {
                showingClearConfirm = true
            }
            .controlSize(.small)
            .disabled(logs.isEmpty)
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
        .confirmationDialog(
            "Delete all session logs?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(logs.count) log\(logs.count == 1 ? "" : "s")", role: .destructive) {
                clearAllLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every file in ~/Library/Application Support/Termy/sessions/. New recordings will start fresh.")
        }
    }

    /// Remove every file from the sessions directory. Open recorders
    /// (for currently-active panes) will simply lose their handle's
    /// underlying file — that's harmless; their next write attempt fails
    /// silently and recording continues into a fresh file on next pane
    /// launch.
    private func clearAllLogs() {
        let dir = Self.sessionsDir()
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names {
                let url = dir.appendingPathComponent(name)
                try? fm.removeItem(at: url)
            }
        }
        logs = []
        selectedLog = nil
        contentMatchCounts = [:]
    }

    private var sidebar: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Search across all logs…", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.caption)
                    .onChange(of: query) { _, _ in scheduleContentSearch() }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )

            ScrollView {
                VStack(spacing: 1) {
                    if filteredLogs.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.system(size: 18))
                                .foregroundStyle(DS.Colors.tertiary)
                            Text(logs.isEmpty ? "No sessions recorded yet" : "No matches")
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.Colors.tertiary)
                                .multilineTextAlignment(.center)
                            if logs.isEmpty {
                                Text("Enable Settings → General → Session recording to start logging.")
                                    .font(DS.Typo.tiny)
                                    .foregroundStyle(DS.Colors.tertiary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, DS.Spacing.l)
                        .padding(.horizontal, DS.Spacing.s)
                    } else {
                        ForEach(filteredLogs) { log in
                            SessionLogRow(
                                log: log,
                                isSelected: selectedLog?.id == log.id,
                                matchCount: contentMatchCounts[log.id] ?? 0,
                                onSelect: { selectedLog = log }
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.s)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 260)
        .background(.thickMaterial.opacity(0.3))
    }

    @ViewBuilder
    private var detail: some View {
        if let log = selectedLog {
            SessionLogDetail(log: log, highlight: query.trimmingCharacters(in: .whitespaces))
        } else {
            VStack {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(DS.Colors.tertiary)
                Text(logs.isEmpty
                     ? "Recording is off"
                     : "Select a session to preview")
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Colors.tertiary)
                    .padding(.top, DS.Spacing.s)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredLogs: [SessionLog] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return logs }
        return logs.filter { log in
            log.displayName.lowercased().contains(q)
                || (contentMatchCounts[log.id] ?? 0) > 0
        }.sorted { (contentMatchCounts[$0.id] ?? 0) > (contentMatchCounts[$1.id] ?? 0) || $0.modified > $1.modified }
    }

    /// Debounced grep across every log's contents. Runs off main thread,
    /// returns hit counts per log file. Cancelled + restarted on every
    /// keystroke. Skips files > 5 MB to stay snappy — those are
    /// pathological and previewed via the head/tail path anyway.
    private func scheduleContentSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            contentMatchCounts = [:]
            return
        }
        let snapshot = logs
        searchTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 150_000_000)  // debounce
            if Task.isCancelled { return }
            var counts: [String: Int] = [:]
            for log in snapshot {
                if Task.isCancelled { return }
                guard log.size <= 5 * 1024 * 1024 else { continue }
                if let text = try? String(contentsOf: log.url, encoding: .utf8) {
                    let lower = text.lowercased()
                    let count = lower.components(separatedBy: q).count - 1
                    if count > 0 { counts[log.id] = count }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { contentMatchCounts = counts }
        }
    }

    private func loadLogs() {
        let dir = Self.sessionsDir()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            logs = []
            return
        }
        let fm = FileManager.default
        var loaded: [SessionLog] = []
        for name in names where name.hasSuffix(".log") {
            let url = dir.appendingPathComponent(name)
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let date = attrs[.modificationDate] as? Date ?? Date.distantPast
            let size = attrs[.size] as? Int ?? 0
            loaded.append(SessionLog(id: name, url: url, modified: date, size: size))
        }
        logs = loaded.sorted { $0.modified > $1.modified }
        selectedLog = logs.first
    }

    static func sessionsDir() -> URL {
        SessionRecorder.sessionsDir()
    }
}

struct SessionLog: Identifiable, Equatable {
    let id: String
    let url: URL
    let modified: Date
    let size: Int

    var displayName: String {
        // Filenames look like "2026-05-25_001233_abc123.log" — convert
        // to a friendlier date string. Falls back to the raw name on
        // parse failure.
        let bare = id.replacingOccurrences(of: ".log", with: "")
        let parts = bare.split(separator: "_")
        guard parts.count >= 2 else { return bare }
        let date = parts[0]
        let time = parts[1]
        let formatted = "\(date) \(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.dropFirst(4).prefix(2))"
        return formatted
    }

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

private struct SessionLogRow: View {
    let log: SessionLog
    let isSelected: Bool
    let matchCount: Int
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(log.displayName)
                        .font(DS.Typo.caption)
                        .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
                        .lineLimit(1)
                    Text(log.sizeString)
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                if matchCount > 0 {
                    Text("\(matchCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DS.Colors.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(DS.Colors.accent.opacity(0.15))
                        )
                        .help("\(matchCount) match\(matchCount == 1 ? "" : "es") in this log")
                }
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
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([log.url])
            }
            Button("Open in default app") {
                NSWorkspace.shared.open(log.url)
            }
        }
    }
}

private struct SessionLogDetail: View {
    let log: SessionLog
    let highlight: String
    @State private var preview: String = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.displayName)
                        .font(DS.Typo.body.weight(.semibold))
                    Text(log.sizeString)
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.url])
                }
                .controlSize(.small)
                Button("Open") {
                    NSWorkspace.shared.open(log.url)
                }
                .controlSize(.small)
            }

            ScrollView {
                if loading {
                    ProgressView()
                        .padding(DS.Spacing.l)
                } else {
                    highlightedText
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Colors.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.s)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )
        }
        .padding(DS.Spacing.l)
        .onAppear { loadPreview() }
        .onChange(of: log.id) { _, _ in loadPreview() }
    }

    /// Renders the preview with matches highlighted via AttributedString
    /// when a search query is active. Falls back to plain text otherwise.
    private var highlightedText: Text {
        guard !highlight.isEmpty else { return Text(preview) }
        var attributed = AttributedString(preview)
        let q = highlight.lowercased()
        let lowerStr = preview.lowercased()
        var searchStart = lowerStr.startIndex
        while let range = lowerStr.range(of: q, range: searchStart..<lowerStr.endIndex) {
            // Map String index range to AttributedString index range.
            if let attribRange = Range<AttributedString.Index>(range, in: attributed) {
                attributed[attribRange].backgroundColor = .accentColor.opacity(0.35)
            }
            searchStart = range.upperBound
        }
        return Text(attributed)
    }

    /// Loads head + tail of the log file so previews stay snappy on
    /// very large recordings (a 100 MB `claude` transcript shouldn't
    /// freeze the modal). On-disk files are already ANSI-stripped by
    /// SessionRecorder, but we still run the legacy stripper as a safety
    /// net for files saved by older Termy builds.
    private func loadPreview() {
        loading = true
        let url = log.url
        DispatchQueue.global(qos: .userInitiated).async {
            let maxBytes = 64 * 1024
            let raw = readHeadAndTail(url: url, maxBytes: maxBytes)
            let stripped = stripAnsi(raw)
            DispatchQueue.main.async {
                preview = stripped
                loading = false
            }
        }
    }

    private func readHeadAndTail(url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        if size <= UInt64(maxBytes) {
            let data = (try? handle.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8) ?? "(binary)"
        }
        let half = UInt64(maxBytes / 2)
        let headData = (try? handle.read(upToCount: Int(half))) ?? Data()
        try? handle.seek(toOffset: size - half)
        let tailData = (try? handle.readToEnd()) ?? Data()
        let head = String(data: headData, encoding: .utf8) ?? ""
        let tail = String(data: tailData, encoding: .utf8) ?? ""
        let skippedBytes = size - 2 * half
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        let skippedString = formatter.string(fromByteCount: Int64(skippedBytes))
        return head + "\n\n… [\(skippedString) elided] …\n\n" + tail
    }

    /// Best-effort ANSI escape stripper — covers CSI sequences (the
    /// vast majority of color / cursor / clear codes). Keeps OSC text
    /// titles since those are user-meaningful.
    private func stripAnsi(_ s: String) -> String {
        // CSI: ESC [ params letter
        let pattern = "\\x1B\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
