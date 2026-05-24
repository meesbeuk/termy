import SwiftUI

// MARK: - Theme preview card

/// Visual swatch for a single theme. Shows a sample terminal line in the
/// theme's foreground color over its dominant background, plus the full ANSI
/// palette as a thin strip across the bottom.
struct ThemePreviewCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private func swiftColor(_ rgb: (Int, Int, Int)) -> Color {
        Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    /// Background = first ANSI color (the theme's "black"); foreground from theme.
    private var bgColor: Color { swiftColor(theme.ansi[0]) }
    private var fgColor: Color { swiftColor(theme.foreground) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Sample code preview using a handful of the theme's ANSI colors.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(bgColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("$")
                                .foregroundStyle(swiftColor(theme.ansi[2]))     // green
                            Text("git status")
                                .foregroundStyle(fgColor)
                        }
                        HStack(spacing: 4) {
                            Text("On branch")
                                .foregroundStyle(fgColor.opacity(0.7))
                            Text("main")
                                .foregroundStyle(swiftColor(theme.ansi[4]))     // blue
                        }
                        Text("nothing to commit")
                            .foregroundStyle(swiftColor(theme.ansi[3]))         // yellow
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack {
                    Text(theme.name)
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(DS.Colors.primary)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

                // Full 16-color ANSI strip — the most honest "what colors will I see?"
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
                    .strokeBorder(isSelected ? DS.Colors.accent : Color.white.opacity(0.06),
                                  lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

// MARK: - Cursor style preview

struct CursorPreview: View {
    let style: CursorStyle
    let blink: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var blinkOn = true

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.35))
                    HStack(spacing: 1) {
                        Text("git ")
                            .foregroundStyle(.white)
                        cursorShape
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                }
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(style.displayName)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? DS.Colors.accent : Color.clear, lineWidth: 1.5)
                    .padding(.bottom, 14)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard blink else { blinkOn = true; return }
            // Subtle blink so the preview shows what the cursor actually does.
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                blinkOn.toggle()
            }
        }
    }

    @ViewBuilder
    private var cursorShape: some View {
        let on = blink ? blinkOn : true
        switch style {
        case .block:
            Rectangle()
                .fill(Color.white.opacity(on ? 1.0 : 0.2))
                .frame(width: 7, height: 14)
        case .bar:
            Rectangle()
                .fill(Color.white.opacity(on ? 1.0 : 0.2))
                .frame(width: 2, height: 14)
        case .underline:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(on ? 1.0 : 0.2))
                    .frame(width: 7, height: 2)
            }
            .frame(width: 7, height: 14)
        }
    }
}

// MARK: - Density / padding preview

struct DensityPreview: View {
    let preset: PaddingPreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.35))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule()
                                .fill(Color.white.opacity(0.55))
                                .frame(height: 2)
                        }
                    }
                    .padding(.horizontal, preset.horizontal / 2)
                    .padding(.vertical, preset.vertical / 2)
                }
                .frame(height: 42)
                Text(preset.displayName)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? DS.Colors.accent : Color.clear, lineWidth: 1.5)
                    .padding(.bottom, 14)
            )
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

struct OpacityPreview: View {
    let opacity: Double

    var body: some View {
        ZStack {
            // Fake "wallpaper" gradient to demonstrate what shows through.
            LinearGradient(
                colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.5), Color.pink.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(opacity)
            Text("Sample terminal text")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
