import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's `SPUStandardUpdaterController` and exposes a SwiftUI-friendly
/// `checkForUpdates()` method. Auto-check on launch is enabled — users still
/// get the "what's new" prompt and can defer.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → check at launch with default schedule.
        // updaterDelegate / userDriverDelegate are nil → use Sparkle's standard UI.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }
}
