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

    /// Fire a notification when a pane goes from "actively producing
    /// output" to "quiet for N seconds" — the heuristic for "your AI tool
    /// (or build, or test run, or whatever) just finished". No OSC 133
    /// required; works with `claude`, `codex`, `npm test`, `cargo build`,
    /// anything.
    @Published var notifyOnIdle: Bool {
        didSet { UserDefaults.standard.set(notifyOnIdle, forKey: Self.notifyOnIdleKey) }
    }

    /// Seconds of zero output that count as "settled". Lower = more
    /// notifications (every short pause). Higher = catches only longer
    /// commands. Default 4s = matches Claude/Codex response cadence.
    @Published var idleThresholdSeconds: Double {
        didSet {
            let clamped = max(2.0, min(60.0, idleThresholdSeconds))
            if clamped != idleThresholdSeconds { idleThresholdSeconds = clamped; return }
            UserDefaults.standard.set(idleThresholdSeconds, forKey: Self.idleThresholdKey)
        }
    }

    /// Limit notifications (bell + idle) to windows that aren't currently
    /// focused. Default on — matches the user's intent of "I want to know
    /// when something happens in the background." Turn off to get every
    /// trigger, regardless of focus.
    @Published var notifyOnlyBackground: Bool {
        didSet { UserDefaults.standard.set(notifyOnlyBackground, forKey: Self.notifyOnlyBackgroundKey) }
    }

    /// Play the default sound with each notification. Off by default so
    /// terminals next to the user don't audibly ding every time a command
    /// settles.
    @Published var notifySound: Bool {
        didSet { UserDefaults.standard.set(notifySound, forKey: Self.notifySoundKey) }
    }

    /// Show the last terminal line as the notification body so the user
    /// sees the actual result without switching windows. On by default —
    /// the marginal context is worth the slight body length.
    @Published var notifyShowPreview: Bool {
        didSet { UserDefaults.standard.set(notifyShowPreview, forKey: Self.notifyShowPreviewKey) }
    }

    /// Record each pane's raw output to a file under
    /// `~/Library/Application Support/Termy/sessions/`. Off by default —
    /// disk write + privacy implications mean it must be explicitly opted
    /// into. One file per session, named with the start timestamp and a
    /// short pane id; rotates implicitly because each new pane gets a
    /// fresh file.
    @Published var recordSessions: Bool {
        didSet { UserDefaults.standard.set(recordSessions, forKey: Self.recordSessionsKey) }
    }

    /// Paces incoming PTY output to a fixed characters-per-second rate so
    /// streaming output looks "typewriter-smooth" instead of arriving in
    /// frame-coalesced bursts. Off by default — purpose-built for users
    /// recording Termy demos / screencasts where chunky output looks bad
    /// on camera. Tracking (OSC 133, idle detection, recording) still
    /// happens at real-time arrival; only the visible display is paced.
    @Published var cinemaMode: Bool {
        didSet { UserDefaults.standard.set(cinemaMode, forKey: Self.cinemaModeKey) }
    }

    /// Characters per second when cinema mode is on. ~80 cps matches a
    /// fast human typist; ~150 is comfortable for technical content;
    /// 300+ approaches "fast streaming" and starts to look like normal
    /// output. Capped because too-slow values make a 500-char burst
    /// take an annoying 25s to display.
    @Published var cinemaCps: Double {
        didSet {
            let clamped = max(30.0, min(500.0, cinemaCps))
            if clamped != cinemaCps { cinemaCps = clamped; return }
            UserDefaults.standard.set(cinemaCps, forKey: Self.cinemaCpsKey)
        }
    }

    /// Preferred editor URL scheme for OSC 8 / Cmd-click on `path:line`
    /// references. Empty string = auto-detect (cursor → vscode → zed).
    /// Common values: "cursor", "vscode", "zed", "subl", "mate".
    @Published var editorScheme: String {
        didSet { UserDefaults.standard.set(editorScheme, forKey: Self.editorSchemeKey) }
    }

    // MARK: - Quake (drop-down terminal) settings

    /// Auto-hide the Quake drop-down when it loses focus. Standard Quake
    /// behavior; turn off if you want it to stay visible while you reference
    /// it from another window.
    @Published var quakeHideOnFocusLoss: Bool {
        didSet { UserDefaults.standard.set(quakeHideOnFocusLoss, forKey: Self.quakeHideOnFocusLossKey) }
    }

    /// Vertical fraction of the active screen the Quake panel occupies.
    /// 0.30 → tight, 0.45 → default, 0.80 → almost full screen.
    @Published var quakeHeightFraction: Double {
        didSet {
            let clamped = max(0.20, min(0.95, quakeHeightFraction))
            if clamped != quakeHeightFraction { quakeHeightFraction = clamped; return }
            UserDefaults.standard.set(quakeHeightFraction, forKey: Self.quakeHeightKey)
        }
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
    private static let notifyOnIdleKey = "termy.notifyOnIdle"
    private static let idleThresholdKey = "termy.idleThresholdSeconds"
    private static let notifyOnlyBackgroundKey = "termy.notifyOnlyBackground"
    private static let notifySoundKey = "termy.notifySound"
    private static let notifyShowPreviewKey = "termy.notifyShowPreview"
    private static let recordSessionsKey = "termy.recordSessions"
    private static let cinemaModeKey = "termy.cinemaMode"
    private static let cinemaCpsKey = "termy.cinemaCps"
    private static let editorSchemeKey = "termy.editorScheme"
    private static let quakeHideOnFocusLossKey = "termy.quakeHideOnFocusLoss"
    private static let quakeHeightKey = "termy.quakeHeightFraction"

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
        self.notifyOnIdle = UserDefaults.standard.bool(forKey: Self.notifyOnIdleKey)
        let savedThreshold = UserDefaults.standard.double(forKey: Self.idleThresholdKey)
        self.idleThresholdSeconds = savedThreshold > 0 ? savedThreshold : 4.0
        if UserDefaults.standard.object(forKey: Self.notifyOnlyBackgroundKey) == nil {
            self.notifyOnlyBackground = true
        } else {
            self.notifyOnlyBackground = UserDefaults.standard.bool(forKey: Self.notifyOnlyBackgroundKey)
        }
        self.notifySound = UserDefaults.standard.bool(forKey: Self.notifySoundKey)
        if UserDefaults.standard.object(forKey: Self.notifyShowPreviewKey) == nil {
            self.notifyShowPreview = true
        } else {
            self.notifyShowPreview = UserDefaults.standard.bool(forKey: Self.notifyShowPreviewKey)
        }
        self.recordSessions = UserDefaults.standard.bool(forKey: Self.recordSessionsKey)
        self.cinemaMode = UserDefaults.standard.bool(forKey: Self.cinemaModeKey)
        let savedCps = UserDefaults.standard.double(forKey: Self.cinemaCpsKey)
        self.cinemaCps = savedCps > 0 ? savedCps : 80
        self.editorScheme = UserDefaults.standard.string(forKey: Self.editorSchemeKey) ?? ""
        if UserDefaults.standard.object(forKey: Self.quakeHideOnFocusLossKey) == nil {
            self.quakeHideOnFocusLoss = true
        } else {
            self.quakeHideOnFocusLoss = UserDefaults.standard.bool(forKey: Self.quakeHideOnFocusLossKey)
        }
        let savedHeight = UserDefaults.standard.double(forKey: Self.quakeHeightKey)
        self.quakeHeightFraction = savedHeight > 0 ? savedHeight : 0.45
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
