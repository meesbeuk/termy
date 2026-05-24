import SwiftUI

/// Sheet for terminal preferences — theme, font family, font size.
/// Settings persist via TerminalSettings and re-apply to all open tabs.
struct TerminalSettingsSheet: View {
    @EnvironmentObject var settings: TerminalSettings
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Terminal Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Theme", selection: $settings.themeID) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Font Family")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(availableInstalledFonts(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Only fonts you have installed are shown.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.fontSize))pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontSize, in: 8...28, step: 1)
                    .controlSize(.small)
                Text("⌘+ / ⌘- / ⌘0 also work as shortcuts.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Background Opacity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.effectiveOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Toggle("Adapt to wallpaper brightness", isOn: $settings.autoOpacity)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Slider(value: $settings.opacity, in: 0.20...1.00)
                    .controlSize(.small)
                    .disabled(settings.autoOpacity)
                    .opacity(settings.autoOpacity ? 0.4 : 1.0)
                Text(settings.autoOpacity
                     ? "Light wallpapers → more opaque, dark → more glass."
                     : "Manual opacity — drag to taste.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial)
    }

    /// Filter the candidate font list to only fonts actually installed on this Mac.
    private func availableInstalledFonts() -> [String] {
        TerminalSettings.availableFontFamilies.filter { name in
            NSFont(name: name, size: 12) != nil
        }
    }
}
