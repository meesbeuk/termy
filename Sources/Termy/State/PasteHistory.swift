import Foundation
import AppKit

/// Captures the last N strings copied to the system pasteboard so the
/// user can paste a recent one via ⌘⇧V picker — like 1Password / Paste /
/// Raycast clipboard history but scoped to Termy and bounded by the
/// user's privacy preference (off by default, capped at 20 entries,
/// never persists to disk).
@MainActor
final class PasteHistoryStore: ObservableObject {
    @Published var entries: [PasteEntry] = []

    private var pollTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let maxEntries = 20
    /// Items shorter than this are kept verbatim; longer items are
    /// captured with a trimmed preview while the full string lives in
    /// `entry.text` for paste. UI displays the preview.
    private let previewLength = 80

    init() {
        // Pasteboard doesn't post notifications — poll the changeCount
        // every 500ms while at least one window is active. Cheap; ints
        // only compared, no string copying unless something changed.
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Wipes all captured entries — exposed in Settings for a "Clear
    /// paste history" action.
    func clear() {
        entries = []
    }

    private func tick() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard let str = pb.string(forType: .string), !str.isEmpty else { return }
        // De-dup: if the top entry is identical, refresh its timestamp
        // instead of inserting a duplicate.
        if let first = entries.first, first.text == str {
            entries[0].lastSeen = Date()
            return
        }
        let preview = makePreview(str)
        let entry = PasteEntry(
            id: UUID(),
            text: str,
            preview: preview,
            lastSeen: Date(),
            byteSize: str.utf8.count
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    private func makePreview(_ s: String) -> String {
        // Strip newlines for the row label; the full text still pastes.
        let oneLine = s
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count > previewLength {
            return String(oneLine.prefix(previewLength - 1)) + "…"
        }
        return oneLine
    }
}

struct PasteEntry: Identifiable, Equatable {
    let id: UUID
    let text: String
    let preview: String
    var lastSeen: Date
    let byteSize: Int

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteSize))
    }
}
