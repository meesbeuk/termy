import SwiftUI

/// Termy settings — uses DSModal so it stays visually identical to every other
/// panel (AI launcher, recent dirs, future ones).
struct TerminalSettingsSheet: View {
    @EnvironmentObject var settings: TerminalSettings
    let onClose: () -> Void

    var body: some View {
        DSModal(
            title: "Termy Settings",
            titleIcon: "gearshape.fill",
            titleIconColor: DS.Colors.secondary,
            onClose: onClose
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    generalSection
                    vibecoderSection
                    themeSection
                    fontSection
                    cursorSection
                    densitySection
                    chromeSection
                    opacitySection
                }
            }
            .frame(maxHeight: 520)
        }
    }

    private var generalSection: some View {
        DSSection("General") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
            Toggle("Hide from Dock (menu-bar only style)", isOn: $settings.hideFromDock)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
            Toggle("Confirm before quitting", isOn: $settings.confirmOnQuit)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
            Toggle("Copy text on selection", isOn: $settings.copyOnSelect)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
        }
    }

    private var vibecoderSection: some View {
        DSSection("Vibecoder") {
            Toggle(isOn: $settings.vibecoderMode) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.aiAccent)
                    Text("Vibecoder Mode")
                        .font(DS.Typo.body.weight(.medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text("Quick-launch row for Claude / Codex / Cursor in the title strip. ⌘L opens the full launcher anytime.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var themeSection: some View {
        DSSection("Theme") {
            Picker("Theme", selection: $settings.themeID) {
                ForEach(ThemeCategory.allCases, id: \.self) { cat in
                    Section(header: Text(cat.rawValue)) {
                        ForEach(TerminalTheme.all.filter { $0.category == cat }) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var fontSection: some View {
        DSSection("Font") {
            Picker("Font Family", selection: $settings.fontFamily) {
                ForEach(availableInstalledFonts(), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack {
                Text("Size")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                Slider(value: $settings.fontSize, in: 8...28, step: 1)
                    .controlSize(.small)
                Text("\(Int(settings.fontSize))pt")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            Text("⌘+ / ⌘- / ⌘0 also work as shortcuts.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
        }
    }

    private var cursorSection: some View {
        DSSection("Cursor") {
            HStack(spacing: DS.Spacing.m) {
                Picker("Cursor Style", selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Toggle("Blink", isOn: $settings.cursorBlink)
                    .toggleStyle(.checkbox)
                    .font(DS.Typo.caption)
            }
        }
    }

    private var densitySection: some View {
        DSSection("Density") {
            Picker("Padding", selection: $settings.paddingPreset) {
                ForEach(PaddingPreset.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var chromeSection: some View {
        DSSection("Chrome") {
            Toggle("Show tab bar", isOn: $settings.showTabBar)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
            Toggle("Show status bar (cwd, git, clock)", isOn: $settings.showStatusBar)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
        }
    }

    private var opacitySection: some View {
        DSSection("Background") {
            HStack {
                Text("Opacity")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                Spacer()
                Text("\(Int(settings.effectiveOpacity * 100))%")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Toggle("Adapt to wallpaper brightness", isOn: $settings.autoOpacity)
                .toggleStyle(.checkbox)
                .font(DS.Typo.caption)
            Slider(value: $settings.opacity, in: 0...1.0)
                .controlSize(.small)
                .disabled(settings.autoOpacity)
                .opacity(settings.autoOpacity ? 0.4 : 1.0)
            Text(settings.autoOpacity
                 ? "Light wallpapers → more opaque, dark → more glass."
                 : "Manual opacity — drag to taste.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
        }
    }

    private func availableInstalledFonts() -> [String] {
        TerminalSettings.availableFontFamilies.filter { name in
            NSFont(name: name, size: 12) != nil
        }
    }
}
