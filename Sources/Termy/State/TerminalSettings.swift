import Foundation
import SwiftUI
import Combine
import AppKit

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
        refreshEffectiveOpacity(screen: NSScreen.main)
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
