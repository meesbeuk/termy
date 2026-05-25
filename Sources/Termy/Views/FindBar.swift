import SwiftUI
import AppKit
import SwiftTerm

/// Inline find bar that overlays the top-right of the active pane on ⌘F.
/// Drives SwiftTerm's `findNext` / `findPrevious` directly — replaces the
/// 2007-era NSFindPanel `performFindPanelAction` route used through v0.9.6.
struct FindBar: View {
    let view: LocalProcessTerminalView?
    /// Initial query to prefill (used by ⌘E "Use Selection for Find").
    /// nil → empty field, user types from scratch.
    let initialQuery: String?
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var caseSensitive: Bool = false
    @State private var regex: Bool = false
    @State private var lastSearchHadHit: Bool = true
    /// Total match count for the current query, computed by scanning the
    /// terminal's recent text buffer when the query stabilises. nil means
    /// "haven't counted yet" — UI just shows the no-hit dot if applicable.
    @State private var totalMatches: Int? = nil
    @State private var countDebounceTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.tertiary)
                .frame(width: 14)

            EscAwareTextField(
                text: $query,
                placeholder: "Find",
                onCancel: dismiss,
                onSubmit: { performFind(forward: !NSEvent.modifierFlags.contains(.shift)) }
            )
            .frame(width: 180, height: 18)
            .onChange(of: query) { _, new in
                if new.isEmpty {
                    view?.clearSearch()
                    lastSearchHadHit = true
                    totalMatches = nil
                    countDebounceTask?.cancel()
                } else {
                    // Search-as-you-type lands on the first match; ⏎ / ⇧⏎
                    // cycles from there.
                    lastSearchHadHit = view?.findNext(new, options: options) ?? false
                    scheduleCount(for: new)
                }
            }

            // No-hit indicator — small dot keeps the bar compact. When we
            // do have matches and a count is available, show the count
            // instead for the "3 matches" affordance every modern editor's
            // find bar has.
            if !query.isEmpty {
                if !lastSearchHadHit {
                    Circle()
                        .fill(DS.Colors.danger.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .help("No match")
                } else if let count = totalMatches, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Colors.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(DS.Colors.chipBg)
                        )
                        .help("\(count) match\(count == 1 ? "" : "es") in recent scrollback")
                }
            }

            ToggleChip(label: "Aa", isOn: caseSensitive, help: "Case sensitive") {
                caseSensitive.toggle()
                if !query.isEmpty {
                    lastSearchHadHit = view?.findNext(query, options: options) ?? false
                }
            }
            ToggleChip(label: ".*", isOn: regex, help: "Regular expression") {
                regex.toggle()
                if !query.isEmpty {
                    lastSearchHadHit = view?.findNext(query, options: options) ?? false
                }
            }

            DSIconButton(icon: "chevron.up", action: { performFind(forward: false) })
                .help("Previous match (⇧⏎ / ⌘⇧G)")
            DSIconButton(icon: "chevron.down", action: { performFind(forward: true) })
                .help("Next match (⏎ / ⌘G)")
            DSIconButton(icon: "xmark", action: dismiss)
                .help("Close (⌘F or click outside)")
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.xs)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // Hidden ⌘G / ⌘⇧G shortcuts so cycling matches doesn't require
        // taking focus back to the find bar.
        .background(
            Group {
                Button("") { performFind(forward: true) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { performFind(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: false)
    }

    private func performFind(forward: Bool) {
        guard !query.isEmpty, let view else { return }
        lastSearchHadHit = forward
            ? view.findNext(query, options: options)
            : view.findPrevious(query, options: options)
    }

    private func dismiss() {
        view?.clearSearch()
        countDebounceTask?.cancel()
        onClose()
    }

    /// Asynchronously count occurrences of `q` in the active pane's
    /// recent text buffer. Debounced so we don't run a regex per keystroke
    /// while the user is still typing. The count is bounded by
    /// `recentVisibleText()` which caps at ~4KB — not the whole scrollback,
    /// but enough for the "is this rare or common?" gut check the user
    /// actually wants from a match count.
    private func scheduleCount(for q: String) {
        countDebounceTask?.cancel()
        countDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            guard let termyView = view as? TermyTerminalView else {
                totalMatches = nil
                return
            }
            let text = termyView.recentVisibleText()
            let count: Int
            if regex {
                let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                if let re = try? NSRegularExpression(pattern: q, options: opts) {
                    count = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                } else {
                    count = 0
                }
            } else {
                let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                var c = 0
                var searchRange = text.startIndex..<text.endIndex
                while let r = text.range(of: q, options: opts, range: searchRange) {
                    c += 1
                    searchRange = r.upperBound..<text.endIndex
                }
                count = c
            }
            totalMatches = count
        }
    }
}

private struct ToggleChip: View {
    let label: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? DS.Colors.primary : DS.Colors.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? DS.Colors.chipBgActive : (hovering ? DS.Colors.chipBgHover : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DS.Colors.primary.opacity(isOn ? 0.18 : 0.06), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
        .help(help)
    }
}

/// SwiftUI's TextField swallows Esc / .onExitCommand / .onKeyPress / hidden
/// keyboardShortcut buttons / NSEvent local monitors when it owns first
/// responder. Subclassing NSTextField and overriding cancelOperation /
/// insertNewline directly is the only path that catches them reliably —
/// AppKit translates the keystrokes to those selectors before any delegate
/// or local monitor can interpose.
private struct EscAwareTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> CancelableTextField {
        let field = CancelableTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.onCancel = { context.coordinator.parent.onCancel() }
        field.onSubmit = { context.coordinator.parent.onSubmit() }
        DispatchQueue.main.async { [weak field] in
            field?.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: CancelableTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
        // Refresh callbacks so they always see the current parent's closures.
        field.onCancel = { context.coordinator.parent.onCancel() }
        field.onSubmit = { context.coordinator.parent.onSubmit() }
    }

    final class Coord: NSObject, NSTextFieldDelegate, NSControlTextEditingDelegate {
        var parent: EscAwareTextField
        init(_ p: EscAwareTextField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        // While an NSTextField is editing, the SHARED FIELD EDITOR (NSTextView)
        // is the actual first responder — keystrokes go to it, not the field.
        // The field editor routes commands like Esc and ⏎ through this
        // delegate method BEFORE applying its default behavior. Returning
        // true consumes the keystroke so the field editor doesn't also try
        // to revert / submit / etc.
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            let name = NSStringFromSelector(selector)
            if name == "cancelOperation:" || name == "cancel:" {
                parent.onCancel()
                return true
            }
            if name == "insertNewline:" || name == "insertLineBreak:" {
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    /// Keeps the cancelOperation override as belt-and-braces for the rare
    /// case when AppKit dispatches directly to the field (e.g. when the
    /// field has selection but isn't actively editing).
    final class CancelableTextField: NSTextField {
        var onCancel: (() -> Void)?
        var onSubmit: (() -> Void)?
        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }
}
