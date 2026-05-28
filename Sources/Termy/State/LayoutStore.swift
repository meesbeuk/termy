import Foundation

/// One pane in a saved layout: where it opens and what it runs on boot.
/// `cwd` empty = inherit the cwd active when the layout is spawned (so
/// "Quad Claude" opens four Claudes in *your current project*). `command`
/// empty = a plain shell. The command is delivered through the same
/// pending-initial-command path the app already uses to run dropped scripts,
/// so it submits with a real Enter once the shell is up — no blind timers.
struct LayoutPaneSpec: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var cwd: String = ""
    var command: String = ""
    var profileID: UUID?

    init(id: UUID = UUID(), cwd: String = "", command: String = "", profileID: UUID? = nil) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.profileID = profileID
    }
}

/// A named multi-pane layout. Panes are laid out row-major into `columns`
/// columns. The renderer picks the cheapest correct path:
///   • 1 pane            → a normal single-pane tab
///   • 1 row  (rows==1)  → a horizontal split (existing H divider)
///   • 1 col  (cols==1)  → a vertical split (existing V divider)
///   • otherwise         → grid mode (TerminalTab.gridColumns)
/// so the well-worn split path handles the common cases and grid mode only
/// kicks in for true 2-D tilings like Quad Claude's 2×2.
///
/// Named `TermyLayout` rather than `Layout` to avoid colliding with SwiftUI's
/// `Layout` protocol in view files.
struct TermyLayout: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var symbol: String            // SF Symbol shown on the picker card
    var columns: Int              // >= 1
    var panes: [LayoutPaneSpec]
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, symbol: String = "square.grid.2x2",
         columns: Int, panes: [LayoutPaneSpec], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.columns = max(1, columns)
        self.panes = panes
        self.isBuiltIn = isBuiltIn
    }

    var paneCount: Int { panes.count }
    var rows: Int { PaneMath.gridRows(count: panes.count, columns: max(1, columns)) }

    /// Human-readable grid shape, e.g. "2×2" or "1×3".
    var shapeLabel: String { "\(rows)×\(max(1, columns))" }
}

/// In-process store for layouts. Built-ins are code-defined and always
/// present (with stable UUIDs so a persisted "quick layout" choice survives
/// launches); user layouts persist to UserDefaults as JSON, exactly like
/// ProfileStore. `all` = built-ins followed by user layouts.
@MainActor
final class LayoutStore: ObservableObject {
    @Published var userLayouts: [TermyLayout] = []
    /// The layout spawned by the one-press keybind / title-strip button.
    /// Defaults to Quad Claude.
    @Published var quickLayoutID: UUID

    private static let userKey = "termy.layouts.v1"
    private static let quickIDKey = "termy.layouts.quickID"

    // Stable built-in IDs — hardcoded so persisted references (quickLayoutID)
    // resolve across launches and app updates.
    static let quadClaudeID = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    static let dualClaudeID = UUID(uuidString: "11111111-0000-4000-8000-000000000002")!
    static let claudeShellID = UUID(uuidString: "11111111-0000-4000-8000-000000000003")!

    init() {
        // Seed quick layout to Quad Claude before load() can override it.
        self.quickLayoutID = Self.quadClaudeID
        load()
    }

    /// Code-defined presets. Quad Claude is the headline: a 2×2 grid that
    /// boots four Claude Code sessions in the current project.
    static let builtIns: [TermyLayout] = [
        TermyLayout(id: quadClaudeID, name: "Quad Claude", symbol: "square.grid.2x2",
                    columns: 2,
                    panes: (0..<4).map { _ in LayoutPaneSpec(command: "claude") },
                    isBuiltIn: true),
        TermyLayout(id: dualClaudeID, name: "Dual Claude", symbol: "rectangle.split.2x1",
                    columns: 2,
                    panes: [LayoutPaneSpec(command: "claude"), LayoutPaneSpec(command: "claude")],
                    isBuiltIn: true),
        TermyLayout(id: claudeShellID, name: "Claude + Shell", symbol: "rectangle.split.2x1.fill",
                    columns: 2,
                    panes: [LayoutPaneSpec(command: "claude"), LayoutPaneSpec()],
                    isBuiltIn: true),
    ]

    var all: [TermyLayout] { Self.builtIns + userLayouts }

    func layout(id: UUID) -> TermyLayout? { all.first(where: { $0.id == id }) }

    var quickLayout: TermyLayout {
        layout(id: quickLayoutID) ?? Self.builtIns[0]
    }

    func add(_ layout: TermyLayout) {
        var l = layout
        l.isBuiltIn = false
        userLayouts.append(l)
        save()
    }

    func update(_ layout: TermyLayout) {
        guard let i = userLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        userLayouts[i] = layout
        save()
    }

    func remove(_ id: UUID) {
        userLayouts.removeAll { $0.id == id }
        if quickLayoutID == id { quickLayoutID = Self.quadClaudeID }
        save()
    }

    func setQuick(_ id: UUID) {
        guard layout(id: id) != nil else { return }
        quickLayoutID = id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(userLayouts) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
        UserDefaults.standard.set(quickLayoutID.uuidString, forKey: Self.quickIDKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.userKey),
           let decoded = try? JSONDecoder().decode([TermyLayout].self, from: data) {
            userLayouts = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: Self.quickIDKey),
           let id = UUID(uuidString: idStr) {
            quickLayoutID = id
        }
    }
}
