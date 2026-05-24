import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's `SPUStandardUpdaterController` and exposes a SwiftUI-friendly
/// `checkForUpdates()` method. Auto-check on launch is enabled — users still
/// get the "what's new" prompt and can defer.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Backed by Sparkle's persistent prefs — Sparkle writes these to the
    /// app's UserDefaults under SU* keys, so the toggle survives launches.
    @Published var autoCheck: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = autoCheck }
    }
    @Published var autoDownload: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = autoDownload }
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.autoCheck = controller.updater.automaticallyChecksForUpdates
        self.autoDownload = controller.updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Human-readable date of the most recent successful update check, or nil
    /// if Sparkle hasn't checked yet.
    var lastCheckedDescription: String? {
        guard let date = controller.updater.lastUpdateCheckDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
