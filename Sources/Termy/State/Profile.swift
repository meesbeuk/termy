import Foundation

/// A saved terminal configuration. Used when opening a new tab/window via
/// the "New Tab With Profile" menu — overrides shell / args / cwd / theme
/// for that specific session.
struct Profile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var shellPath: String        // empty = use $SHELL default
    var shellArgs: [String]
    var initialCwd: String       // empty = inherit / use HOME
    var themeID: String          // empty = use global theme
    var environmentExtras: [String: String]  // additional env vars to inject
    var tagColor: TabTagColor
    /// Stable seed for the locally-rendered avatar gradient. Random on
    /// creation so each profile reads as visually distinct. Kept across
    /// versions for backward compatibility with persisted profiles.
    var avatarSeed: String
    /// Legacy field (was Tapback color index 0…17). Retained so persisted
    /// JSON round-trips; new code derives color from avatarSeed only.
    var avatarColor: Int

    init(
        id: UUID = UUID(),
        name: String,
        shellPath: String = "",
        shellArgs: [String] = ["--login"],
        initialCwd: String = "",
        themeID: String = "",
        environmentExtras: [String: String] = [:],
        tagColor: TabTagColor = .none,
        avatarSeed: String = Profile.randomSeed(),
        avatarColor: Int = 0
    ) {
        self.id = id
        self.name = name
        self.shellPath = shellPath
        self.shellArgs = shellArgs
        self.initialCwd = initialCwd
        self.themeID = themeID
        self.environmentExtras = environmentExtras
        self.tagColor = tagColor
        self.avatarSeed = avatarSeed
        self.avatarColor = avatarColor
    }

    /// Random 10-char alphanumeric seed. Stable per profile across launches.
    static func randomSeed() -> String {
        let chars: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in chars.randomElement() ?? "a" })
    }

    /// Resolve the effective shell path (honoring $SHELL if empty).
    var effectiveShellPath: String {
        if !shellPath.isEmpty { return shellPath }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Resolve the effective cwd (HOME if empty).
    var effectiveCwd: String {
        initialCwd.isEmpty ? NSHomeDirectory() : initialCwd
    }
}

/// In-process store for the user's saved profiles. Persists to UserDefaults
/// as JSON so it survives launches.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var defaultProfileID: UUID?

    private static let profilesKey = "termy.profiles.v1"
    private static let defaultIDKey = "termy.profiles.defaultID"

    init() {
        load()
        if profiles.isEmpty {
            // Seed with a Default profile so the user has something to start from.
            let defaultProfile = Profile(name: "Default")
            profiles = [defaultProfile]
            defaultProfileID = defaultProfile.id
            save()
        }
    }

    var defaultProfile: Profile {
        profiles.first(where: { $0.id == defaultProfileID }) ?? profiles.first ?? Profile(name: "Default")
    }

    func add(_ profile: Profile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
    }

    func remove(_ id: UUID) {
        // Guard: never leave the store empty. Without this, defaultProfile
        // falls back to a fresh Profile(name: "Default") every call — looks
        // OK at first but the synthesized profile has a brand-new UUID each
        // time, breaking any code that compares IDs.
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id { defaultProfileID = profiles.first?.id }
        save()
    }

    func setDefault(_ id: UUID) {
        defaultProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.defaultIDKey)
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        UserDefaults.standard.set(defaultProfileID?.uuidString, forKey: Self.defaultIDKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: Self.defaultIDKey) {
            defaultProfileID = UUID(uuidString: idStr)
        }
    }
}
