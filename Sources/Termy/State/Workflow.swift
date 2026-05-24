import Foundation

/// A saved command snippet the user can recall via the command palette and
/// invoke into the active pane. Warp-style: short name, the actual command
/// text, optional shortcut, optional description.
struct Workflow: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var description: String

    init(id: UUID = UUID(), name: String, command: String, description: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.description = description
    }
}

@MainActor
final class WorkflowStore: ObservableObject {
    @Published var workflows: [Workflow] = []

    private static let key = "termy.workflows.v1"

    init() {
        load()
        if workflows.isEmpty {
            // Seed a few useful workflows so the feature has visible value
            // immediately. Users will swap these out / add their own.
            workflows = [
                Workflow(name: "git status", command: "git status",
                         description: "Show working-tree status"),
                Workflow(name: "git log graph", command: "git log --oneline --graph --decorate -20",
                         description: "Pretty branch graph, last 20 commits"),
                Workflow(name: "Find large files",
                         command: "du -sh */ | sort -h | tail -10",
                         description: "Top 10 biggest folders in the current dir"),
                Workflow(name: "Kill port 3000",
                         command: "lsof -ti:3000 | xargs kill -9",
                         description: "Free up port 3000 (change number as needed)"),
                Workflow(name: "Reload zsh", command: "source ~/.zshrc",
                         description: "Re-source your zsh config"),
            ]
            save()
        }
    }

    func add(_ workflow: Workflow) {
        workflows.append(workflow)
        save()
    }

    func update(_ workflow: Workflow) {
        guard let i = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[i] = workflow
        save()
    }

    func remove(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(workflows) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Workflow].self, from: data) {
            workflows = decoded
        }
    }
}
