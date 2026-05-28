import Foundation
import Carbon.HIToolbox

/// Secure Keyboard Entry — when on, macOS stops other processes from reading
/// keystrokes typed into Termy (the same protection Terminal.app / iTerm2 /
/// Ghostty offer for password + auth flows). Opt-in (default off), so the
/// shipped default behaviour is unchanged.
///
/// macOS requires Enable/DisableSecureEventInput to be balanced and tied to
/// the app being active — leaving it enabled after the app deactivates can
/// block input elsewhere. `enabledByUs` guarantees we only ever toggle the
/// global state from off→on or on→off, never double-call.
enum SecureInput {
    static let defaultsKey = "termy.secureKeyboardEntry"
    private static var enabledByUs = false

    static var isPreferenceOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setPreference(_ on: Bool, appActive: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
        refresh(appActive: appActive)
    }

    /// Reconcile the real secure-input state with (preference AND app active).
    static func refresh(appActive: Bool) {
        let shouldBeOn = isPreferenceOn && appActive
        if shouldBeOn && !enabledByUs {
            EnableSecureEventInput()
            enabledByUs = true
        } else if !shouldBeOn && enabledByUs {
            DisableSecureEventInput()
            enabledByUs = false
        }
    }

    /// Unconditionally release secure input (app terminating / resigning).
    static func disable() {
        if enabledByUs {
            DisableSecureEventInput()
            enabledByUs = false
        }
    }
}
