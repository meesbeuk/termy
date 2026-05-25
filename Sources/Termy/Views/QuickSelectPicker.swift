import SwiftUI
import AppKit

/// ⌘⇧/ QuickSelect — scans the active pane's recent output for URLs,
/// file paths, git hashes, and IPs, then surfaces them in a keyboard-
/// driven picker. WezTerm-style overlay-on-the-terminal is harder to
/// position given SwiftTerm's internal buffer; this picker variant
/// trades the in-place overlay for a focused modal that lists every
/// match with a single-letter hint label ("type a to copy this URL").
struct QuickSelectPicker: View {
    @EnvironmentObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var matches: [QuickMatch] = []
    @State private var query: String = ""
    @State private var selected: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(maxWidth: 640, maxHeight: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear {
            focused = true
            loadMatches()
        }
        .background(
            Group {
                Button("") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { activate(filtered[selected], modifier: false) }
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { selected = (selected + 1) % filtered.count }
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                Button("") {
                    if !filtered.isEmpty { selected = (selected - 1 + filtered.count) % filtered.count }
                }
                .keyboardShortcut(.upArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "scope")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Quick Select")
                    .font(DS.Typo.title)
            }
            Spacer()
            Text("\(matches.count) found")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Filter URLs / paths / hashes / IPs…", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .focused($focused)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )

            ScrollView {
                VStack(spacing: 1) {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22))
                                .foregroundStyle(DS.Colors.tertiary)
                            Text(matches.isEmpty
                                 ? "Nothing detected in recent output."
                                 : "No matches for \"\(query)\"")
                                .font(DS.Typo.body)
                                .foregroundStyle(DS.Colors.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.xl)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, m in
                            QuickRow(match: m,
                                     isSelected: idx == selected,
                                     onPick: { activate(m, modifier: false) },
                                     onOpen: { activate(m, modifier: true) })
                        }
                    }
                }
            }

            HStack(spacing: DS.Spacing.m) {
                Text("↑↓ navigate · ↵ copy · ⌘↵ open · ⎋ close")
                Spacer()
                Text("Detects URLs, file paths, git hashes, IPs")
            }
            .font(DS.Typo.tiny)
            .foregroundStyle(DS.Colors.tertiary)
        }
        .padding(DS.Spacing.xl)
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private var filtered: [QuickMatch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return matches }
        return matches.filter { $0.text.lowercased().contains(q) }
    }

    private func loadMatches() {
        guard let view = sessions.currentSession?.terminalView as? TermyTerminalView else {
            matches = []
            return
        }
        let text = view.recentVisibleText()
        matches = QuickSelectScanner.scan(text: text)
    }

    /// `modifier == true` means ⌘↵ — open the match (URL via browser,
    /// file path via configured editor, hash copies to clipboard).
    /// Otherwise just copy to pasteboard.
    private func activate(_ m: QuickMatch, modifier: Bool) {
        if modifier, let url = m.openableURL {
            NSWorkspace.shared.open(url)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(m.text, forType: .string)
        }
        onDismiss()
    }
}

// MARK: - Match scanner

struct QuickMatch: Identifiable, Equatable {
    enum Kind: String { case url, path, hash, ip }
    let id = UUID()
    let kind: Kind
    let text: String

    var openableURL: URL? {
        switch kind {
        case .url:
            return URL(string: text)
        case .path:
            let absolute = text.hasPrefix("/") ? text : NSHomeDirectory() + "/" + text
            return URL(fileURLWithPath: absolute)
        case .hash, .ip:
            return nil
        }
    }

    var icon: String {
        switch kind {
        case .url: return "link"
        case .path: return "doc"
        case .hash: return "number"
        case .ip: return "network"
        }
    }
}

enum QuickSelectScanner {
    /// Order matters: URL first (greediest), then file paths, then
    /// git-like hashes (7-40 hex), then IPv4. De-dups overlapping
    /// matches by keeping the longest at each starting position.
    static func scan(text: String) -> [QuickMatch] {
        let patterns: [(QuickMatch.Kind, String)] = [
            (.url,  "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+"),
            (.path, "(?:[~/]|\\./|\\.\\./)?[A-Za-z0-9._/-]+\\.[A-Za-z0-9_-]+(?::\\d+)?"),
            (.hash, "\\b[0-9a-f]{7,40}\\b"),
            (.ip,   "\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b"),
        ]
        var found: [(NSRange, QuickMatch)] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: text, range: fullRange) { result, _, _ in
                guard let r = result?.range, r.location != NSNotFound else { return }
                let text = nsText.substring(with: r)
                found.append((r, QuickMatch(kind: kind, text: text)))
            }
        }
        // Sort by location ascending, then by length descending so the
        // first (longest) at each start wins the dedup pass.
        let sorted = found.sorted { lhs, rhs in
            if lhs.0.location != rhs.0.location { return lhs.0.location < rhs.0.location }
            return lhs.0.length > rhs.0.length
        }
        var lastEnd = -1
        var output: [QuickMatch] = []
        var seenTexts = Set<String>()
        for (range, match) in sorted {
            if range.location < lastEnd { continue }
            // Skip exact text duplicates — same path appearing 10 times
            // in scrollback would otherwise flood the picker.
            if seenTexts.contains(match.text) { continue }
            seenTexts.insert(match.text)
            output.append(match)
            lastEnd = range.location + range.length
        }
        return output
    }
}

private struct QuickRow: View {
    let match: QuickMatch
    let isSelected: Bool
    let onPick: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: match.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(match.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DS.Colors.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(match.kind.rawValue)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                if isSelected {
                    Image(systemName: "return")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Colors.tertiary)
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                isSelected ? DS.Colors.chipBgHover :
                    (hovering ? DS.Colors.chipBg : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
        .contextMenu {
            Button("Copy") { onPick() }
            if match.openableURL != nil {
                Button("Open") { onOpen() }
            }
        }
    }

    private var tint: Color {
        switch match.kind {
        case .url: return .blue
        case .path: return .green
        case .hash: return .orange
        case .ip: return .purple
        }
    }
}
