import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement

/// User-facing terminal preferences, persisted to UserDefaults.
@MainActor
final class TerminalSettings: ObservableObject {
    @Published var fontSize: CGFloat {
        didSet {
            let clamped = max(8, min(36, fontSize))
            if clamped != fontSize { fontSize = clamped; return }
            UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
        }
    }

    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Self.fontFamilyKey) }
    }

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Self.themeKey) }
    }

    /// Manual background opacity, 0.0–1.0. Ignored when `autoOpacity == true`.
    @Published var opacity: Double {
        didSet {
            UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
            if !autoOpacity { effectiveOpacity = opacity }
        }
    }

    /// When true, override `opacity` with a value derived from the desktop
    /// wallpaper's brightness.
    @Published var autoOpacity: Bool {
        didSet {
            UserDefaults.standard.set(autoOpacity, forKey: Self.autoOpacityKey)
            refreshEffectiveOpacity(screen: NSScreen.main)
        }
    }

    /// The opacity actually applied — auto when enabled, manual otherwise.
    @Published var effectiveOpacity: Double = 0.70

    /// Vibecoder mode: surfaces an AI launcher row in the title strip so quick-
    /// launching Claude / Codex / Cursor is one click. Doesn't hide any features.
    @Published var vibecoderMode: Bool {
        didSet { UserDefaults.standard.set(vibecoderMode, forKey: Self.vibecoderKey) }
    }

    // cursorStyle + cursorBlink removed in v0.8.3 — SwiftTerm has no public
    // hook to set them and the DECSCUSR path corrupted the buffer.

    @Published var paddingPreset: PaddingPreset {
        didSet { UserDefaults.standard.set(paddingPreset.rawValue, forKey: Self.paddingKey) }
    }

    @Published var showStatusBar: Bool {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: Self.showStatusBarKey) }
    }

    @Published var showTabBar: Bool {
        didSet { UserDefaults.standard.set(showTabBar, forKey: Self.showTabBarKey) }
    }

    // MARK: - Standard app preferences

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginKey)
            applyLaunchAtLogin()
        }
    }

    @Published var hideFromDock: Bool {
        didSet {
            UserDefaults.standard.set(hideFromDock, forKey: Self.hideFromDockKey)
            applyDockVisibility()
        }
    }

    @Published var confirmOnQuit: Bool {
        didSet { UserDefaults.standard.set(confirmOnQuit, forKey: Self.confirmOnQuitKey) }
    }

    /// Show a system notification when a terminal pane emits BEL while its
    /// window isn't focused. Pair with a shell `precmd` that rings the bell
    /// to get "command finished" alerts for long-running work.
    @Published var notifyOnBell: Bool {
        didSet { UserDefaults.standard.set(notifyOnBell, forKey: Self.notifyOnBellKey) }
    }

    var theme: TerminalTheme { TerminalTheme.find(id: themeID) }

    static let `default`: CGFloat = 13
    static let defaultFontFamily = "SFMono-Regular"
    static let availableFontFamilies = [
        "SFMono-Regular", "Menlo", "Monaco", "JetBrainsMono-Regular",
        "FiraCode-Regular", "Hack-Regular", "Inconsolata-Regular",
    ]

    private static let fontSizeKey = "termy.fontSize"
    private static let fontFamilyKey = "termy.fontFamily"
    private static let themeKey = "termy.themeID"
    private static let opacityKey = "termy.opacity"
    private static let autoOpacityKey = "termy.autoOpacity"
    private static let vibecoderKey = "termy.vibecoderMode"
    private static let paddingKey = "termy.padding"
    private static let showStatusBarKey = "termy.showStatusBar"
    private static let showTabBarKey = "termy.showTabBar"
    private static let launchAtLoginKey = "termy.launchAtLogin"
    private static let hideFromDockKey = "termy.hideFromDock"
    private static let confirmOnQuitKey = "termy.confirmOnQuit"
    private static let notifyOnBellKey = "termy.notifyOnBell"

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? CGFloat(saved) : Self.default
        self.fontFamily = UserDefaults.standard.string(forKey: Self.fontFamilyKey) ?? Self.defaultFontFamily
        self.themeID = UserDefaults.standard.string(forKey: Self.themeKey) ?? TerminalTheme.tokyoNight.id
        let savedOpacity = UserDefaults.standard.double(forKey: Self.opacityKey)
        // Default 0.15 — strongly glass-favored. The terminal should look like
        // a translucent window, not a tinted block.
        self.opacity = savedOpacity > 0 ? savedOpacity : 0.15
        // Default on — most users want adaptive behavior.
        if UserDefaults.standard.object(forKey: Self.autoOpacityKey) == nil {
            self.autoOpacity = true
        } else {
            self.autoOpacity = UserDefaults.standard.bool(forKey: Self.autoOpacityKey)
        }
        // Vibecoder mode default-on — Termy's primary audience.
        if UserDefaults.standard.object(forKey: Self.vibecoderKey) == nil {
            self.vibecoderMode = true
        } else {
            self.vibecoderMode = UserDefaults.standard.bool(forKey: Self.vibecoderKey)
        }
        let padRaw = UserDefaults.standard.string(forKey: Self.paddingKey) ?? PaddingPreset.cozy.rawValue
        self.paddingPreset = PaddingPreset(rawValue: padRaw) ?? .cozy
        if UserDefaults.standard.object(forKey: Self.showStatusBarKey) == nil {
            self.showStatusBar = true
        } else {
            self.showStatusBar = UserDefaults.standard.bool(forKey: Self.showStatusBarKey)
        }
        if UserDefaults.standard.object(forKey: Self.showTabBarKey) == nil {
            self.showTabBar = true
        } else {
            self.showTabBar = UserDefaults.standard.bool(forKey: Self.showTabBarKey)
        }
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Self.launchAtLoginKey)
        self.hideFromDock = UserDefaults.standard.bool(forKey: Self.hideFromDockKey)
        if UserDefaults.standard.object(forKey: Self.confirmOnQuitKey) == nil {
            self.confirmOnQuit = false
        } else {
            self.confirmOnQuit = UserDefaults.standard.bool(forKey: Self.confirmOnQuitKey)
        }
        // Default-off so we don't pop a notification-permission dialog at
        // first launch with no user context.
        self.notifyOnBell = UserDefaults.standard.bool(forKey: Self.notifyOnBellKey)
        refreshEffectiveOpacity(screen: NSScreen.main)
        applyDockVisibility()
        installBrightnessObservers()
    }

    /// Re-sample the wallpaper whenever the user is likely to notice a
    /// changed backdrop: app becomes active, the display config changes
    /// (monitor connect/disconnect, wallpaper rotation), Space switches.
    /// Without this, effectiveOpacity is frozen at first launch — switch
    /// from a dark wallpaper to a light one and Termy stays too transparent.
    private func installBrightnessObservers() {
        let center = NotificationCenter.default
        let wsCenter = NSWorkspace.shared.notificationCenter
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.refreshEffectiveOpacity(
                    screen: NSApp.keyWindow?.screen ?? NSScreen.main
                )
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main, using: refresh)
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main, using: refresh)
        wsCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                             object: nil, queue: .main, using: refresh)
    }

    /// Register/unregister Termy as a login item via ServiceManagement.
    private func applyLaunchAtLogin() {
        let enable = launchAtLogin
        Task.detached {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Silently ignore — user can retry from settings.
            }
        }
    }

    /// Hide / show the Dock icon. Apple's `setActivationPolicy` is the public API.
    /// Switching to .accessory removes the Dock icon; .regular brings it back.
    private func applyDockVisibility() {
        NSApp.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }

    /// Recompute the effective opacity from current settings + screen.
    func refreshEffectiveOpacity(screen: NSScreen?) {
        if autoOpacity, let lum = WallpaperBrightness.detect(for: screen) {
            effectiveOpacity = WallpaperBrightness.opacity(forBrightness: lum)
        } else {
            effectiveOpacity = opacity
        }
    }

    func bumpFontSize() { fontSize += 1 }
    func reduceFontSize() { fontSize -= 1 }
    func resetFontSize() { fontSize = Self.default }
}

enum PaddingPreset: String, CaseIterable, Identifiable {
    case compact, cozy, spacious
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .cozy: return "Cozy"
        case .spacious: return "Spacious"
        }
    }
    var horizontal: CGFloat {
        switch self {
        case .compact: return 4
        case .cozy: return 10
        case .spacious: return 18
        }
    }
    var vertical: CGFloat {
        switch self {
        case .compact: return 4
        case .cozy: return 8
        case .spacious: return 14
        }
    }
}
