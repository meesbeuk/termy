import Foundation

/// Per-line pattern matchers that fire actions on terminal output. The
/// initial pack is hardcoded and tuned for vibecoder workflows (Claude
/// Code + Codex + common build errors). Future iteration adds a
/// Settings UI for custom triggers and trigger packs.
///
/// Termy's design choice vs iTerm2: triggers are not free-form rows
/// that the user wires up; they're toggleable PACKS (like ad-blocker
/// filter lists) so the common cases are one-tap.
struct Trigger {
    let id: String
    let pattern: NSRegularExpression
    let action: TriggerAction
    let pack: TriggerPack
    var enabled: Bool

    init?(id: String, pattern: String, action: TriggerAction, pack: TriggerPack, enabled: Bool = true) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return nil }
        self.id = id
        self.pattern = regex
        self.action = action
        self.pack = pack
        self.enabled = enabled
    }
}

enum TriggerAction {
    case notify(title: String, urgent: Bool)
}

enum TriggerPack: String, CaseIterable, Identifiable {
    case claude, codex, errors
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "OpenAI Codex"
        case .errors: return "Build / test errors"
        }
    }
    var description: String {
        switch self {
        case .claude: return "Notify when Claude is waiting for approval, summarizing, or compacting context."
        case .codex: return "Notify when Codex is waiting for input or finished generating."
        case .errors: return "Notify on common error markers from build / test output."
        }
    }
}

@MainActor
final class TriggerRegistry: ObservableObject {
    /// Shared singleton so TerminalSurface (NSViewRepresentable) can
    /// query active triggers without threading a Binding through every
    /// session — and so toggling a pack in Settings immediately affects
    /// every live pane.
    static let shared = TriggerRegistry()

    @Published var triggers: [Trigger] = []
    @Published var enabledPacks: Set<TriggerPack> = []

    private static let enabledPacksKey = "termy.triggers.enabledPacks"

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.enabledPacksKey) ?? []
        self.enabledPacks = Set(raw.compactMap(TriggerPack.init(rawValue:)))
        self.triggers = Self.buildAll()
    }

    func setPack(_ pack: TriggerPack, enabled: Bool) {
        if enabled { enabledPacks.insert(pack) } else { enabledPacks.remove(pack) }
        UserDefaults.standard.set(enabledPacks.map { $0.rawValue }, forKey: Self.enabledPacksKey)
        triggers = Self.buildAll()
    }

    /// Returns only triggers whose pack is enabled. Hot-path checker
    /// reads `activeTriggers` rather than `triggers` so a per-byte cost
    /// isn't paid for disabled rules.
    var activeTriggers: [Trigger] {
        triggers.filter { enabledPacks.contains($0.pack) }
    }

    private static func buildAll() -> [Trigger] {
        var out: [Trigger] = []
        // Claude pack
        out += [
            Trigger(id: "claude.approval",
                    pattern: "(do you want me to|may i|should i|continue\\?|proceed\\?)",
                    action: .notify(title: "Claude needs approval", urgent: true),
                    pack: .claude),
            Trigger(id: "claude.compact",
                    pattern: "compacting (context|conversation)",
                    action: .notify(title: "Claude compacting context", urgent: false),
                    pack: .claude),
            Trigger(id: "claude.done",
                    pattern: "(✓ done|all done|completed)",
                    action: .notify(title: "Claude finished", urgent: false),
                    pack: .claude),
        ].compactMap { $0 }
        // Codex pack
        out += [
            Trigger(id: "codex.approval",
                    pattern: "(approve|y/n|press enter to (run|continue))",
                    action: .notify(title: "Codex needs approval", urgent: true),
                    pack: .codex),
        ].compactMap { $0 }
        // Errors pack
        out += [
            Trigger(id: "errors.generic",
                    pattern: "(?:^|\\s)(error|fatal|panic|fail(ed|ure)?|exception)[:\\s]",
                    action: .notify(title: "Error in terminal", urgent: false),
                    pack: .errors),
            Trigger(id: "errors.test",
                    pattern: "(test(s)? failed|assertion failed)",
                    action: .notify(title: "Tests failed", urgent: false),
                    pack: .errors),
        ].compactMap { $0 }
        return out
    }
}
