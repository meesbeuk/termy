import SwiftUI

// MARK: - Theme preview card

/// Mini Termy renderer used as the theme picker preview.
///
/// Honesty rule: every element here corresponds to something real Termy
/// actually applies when this theme is selected — nothing fabricated.
/// Specifically:
///
///   - Background: neutral dark gradient + darken layer, simulating the
///     glass backdrop Termy renders over. Held constant across themes
///     because the theme doesn't control wallpaper.
///   - Active-pane stroke: theme.accentColor at 0.55 alpha — the exact
///     overlay PaneLayout draws around the focused pane.
///   - Terminal text: theme.foreground at the real terminal font.
///   - ANSI samples: prompt char in ansi[2], "main" in ansi[4] — the
///     same indices SwiftTerm's color table reads.
///   - Selection: theme.selectionColor — what SwiftTerm sets as
///     `selectedTextBackgroundColor` on the live pane.
///   - Cursor: theme.cursorColor, shaped to match the user's chosen
///     cursor style (block/bar/underline). The SAME caretColor +
///     CursorStyle the live pane uses.
///   - Bottom strip: the full 16-color ANSI palette.
///
/// No fake tab strip, no fake URL chrome, no element that doesn't trace
/// back to a real apply site in TerminalSurface / PaneLayout.
struct ThemePreviewCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject var settings: TerminalSettings
    @State private var hovering = false

    private func swiftColor(_ rgb: (Int, Int, Int)) -> Color {
        Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    /// Constant backdrop shared by every theme card. Termy itself doesn't
    /// own the wallpaper — that's whatever the user has set on their Mac
    /// — so the preview shouldn't change wallpaper per theme either.
    /// Varying it would lie about what the theme actually controls.
    /// Tuned to approximate a neutral dark desktop, since that's the
    /// most common case; light-theme cards still read OK on it.
    private static let sharedBackdrop: LinearGradient = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.18, blue: 0.22),
            Color(red: 0.24, green: 0.22, blue: 0.28),
            Color(red: 0.15, green: 0.15, blue: 0.20),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Constant glass alpha on top of the backdrop — mimics Termy's
    /// .hudWindow material darkening at its default ~45% opacity floor.
    /// Held constant across themes for the same honesty reason: a theme
    /// doesn't drive window opacity in real Termy.
    private static let backdropDarken: Double = 0.55

    private var fg: Color { theme.foregroundColor }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 4) {
                    // Accent dot — same color the app's chrome will adopt
                    // (active-pane stroke, activity stripe, tinted controls).
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 7, height: 7)
                    Text(theme.name)
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(DS.Colors.primary)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

                // Full 16-color ANSI strip — honest "here's the cell palette".
                HStack(spacing: 1) {
                    ForEach(0..<16, id: \.self) { i in
                        swiftColor(theme.ansi[i])
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg.opacity(hovering ? 1.4 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .strokeBorder(isSelected ? theme.accentColor : Color.white.opacity(0.06),
                                  lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            // Shared neutral backdrop — see Self.sharedBackdrop docs.
            // Identical across every card so the differences between
            // themes (text color, ANSI palette, selection, cursor,
            // accent stroke) are the only thing that varies.
            Self.sharedBackdrop
            Color.black.opacity(Self.backdropDarken)

            terminalLines
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            // Active-pane stroke — matches PaneLayout's
            // .strokeBorder(Color.accentColor.opacity(0.55)) which
            // tints to theme.accentColor via the .tint() cascade.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.accentColor.opacity(0.55), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var terminalLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("$")
                    .foregroundStyle(swiftColor(theme.ansi[2]))
                Text("git status")
                    .foregroundStyle(fg)
            }
            HStack(spacing: 3) {
                Text("On branch")
                    .foregroundStyle(fg.opacity(0.6))
                Text("main")
                    .foregroundStyle(swiftColor(theme.ansi[4]))
                    .padding(.horizontal, 1)
                    // Selection highlight — what SwiftTerm renders when
                    // text is drag-selected (selectedTextBackgroundColor).
                    .background(theme.selectionColor.opacity(0.55))
            }
            HStack(spacing: 3) {
                Text("$")
                    .foregroundStyle(swiftColor(theme.ansi[2]))
                // Cursor — shape follows the user's cursorStyle setting,
                // color is theme.cursorColor (the exact NSColor SwiftTerm
                // uses for caretColor on the live pane).
                themeCursor
            }
        }
        // Use the user's chosen font family (SF Mono / Menlo / JetBrains /
        // etc.) so picking a font in Settings → Font is reflected across
        // every theme card too — the preview shows the SAME glyphs the
        // live pane will draw, just smaller.
        .font(.custom(settings.fontFamily, size: 8))
    }

    /// Cursor rendered in the same SHAPE the user has picked under
    /// Settings → Appearance → Cursor. We deliberately render the steady
    /// form (no blink animation) — a grid of 17 blinking cursors would
    /// be noise, and "color + shape" is what theme selection affects.
    @ViewBuilder
    private var themeCursor: some View {
        let color = theme.cursorColor
        let style = settings.cursorStyle
        if style.hasSuffix("Block") {
            Rectangle()
                .fill(color)
                .frame(width: 5, height: 8)
        } else if style.hasSuffix("Bar") {
            Rectangle()
                .fill(color)
                .frame(width: 1.5, height: 8)
        } else {
            // underline — sits along the baseline like SwiftTerm's
            // .steadyUnderline / .blinkUnderline caret.
            Rectangle()
                .fill(color)
                .frame(width: 5, height: 1.5)
                .padding(.top, 6)
        }
    }
}

// MARK: - Density / padding preview

/// Mini-terminal preview that scales padding + line spacing to match what the
/// preset actually applies. Compact = tight, cozy = balanced, spacious = lots
/// of breathing room. Uses the live theme's colors + font family so the
/// preview matches what the user's actual pane will render — pick a
/// padding under Sunset and see Sunset-tinted text, not generic green/white.
struct DensityPreview: View {
    let preset: PaddingPreset
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject var settings: TerminalSettings

    /// Scaled-down line spacing per preset — visible difference in the preview.
    private var lineGap: CGFloat {
        switch preset {
        case .compact: return 1
        case .cozy: return 3
        case .spacious: return 6
        }
    }

    private func swiftColor(_ rgb: (Int, Int, Int)) -> Color {
        Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    var body: some View {
        let theme = settings.theme
        let fg = theme.foregroundColor
        let promptColor = swiftColor(theme.ansi[2])   // green channel — matches the ThemePreviewCard convention
        let dirColor = swiftColor(theme.ansi[4])      // blue channel
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.55))
                    VStack(alignment: .leading, spacing: lineGap) {
                        HStack(spacing: 3) {
                            Text("$").foregroundStyle(promptColor)
                            Text("ls").foregroundStyle(fg)
                        }
                        HStack(spacing: 5) {
                            Text("Sources").foregroundStyle(dirColor)
                            Text("Tests").foregroundStyle(dirColor)
                        }
                        HStack(spacing: 3) {
                            Text("$").foregroundStyle(promptColor)
                            Rectangle()
                                .fill(theme.cursorColor)
                                .frame(width: 4, height: 7)
                        }
                    }
                    .font(.custom(settings.fontFamily, size: 7))
                    .padding(.horizontal, preset.horizontal * 0.55)
                    .padding(.vertical, preset.vertical * 0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? theme.accentColor : Color.clear, lineWidth: 1.5)
                )
                Text(preset.displayName)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Font live preview

struct FontPreview: View {
    let family: String
    let size: CGFloat
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("$ echo \"the quick brown fox 0123456789\"")
                .font(.custom(family, size: size))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("// fn() -> { let x = 42; return x; }")
                .font(.custom(family, size: size))
                .foregroundStyle(foreground.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.35))
        )
    }
}

// MARK: - Opacity preview swatch

/// Shows how much of "the wallpaper" the configured opacity blocks out,
/// with sample text in the user's actual theme foreground + font so what
/// they see here matches what the pane will render. The simulated
/// wallpaper is a fixed gradient — real Termy renders over the user's
/// actual desktop and that's per-user, but the value the slider drives
/// (the dark overlay alpha) is the only thing the setting actually
/// controls, and that IS shown faithfully.
struct OpacityPreview: View {
    let opacity: Double
    @EnvironmentObject var settings: TerminalSettings

    var body: some View {
        ZStack {
            // Simulated wallpaper — neutral enough that text in any theme
            // foreground stays readable across the swatch.
            LinearGradient(
                colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.5), Color.pink.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(opacity)
            Text("Sample terminal text")
                .font(.custom(settings.fontFamily, size: 11))
                .foregroundStyle(settings.theme.foregroundColor)
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
