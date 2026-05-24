import SwiftUI

/// Settings sheet — two-column layout (macOS System Settings style).
/// Left: list of categories. Right: controls + visual preview for whichever
/// category is selected.
struct TerminalSettingsSheet: View {
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var updater: Updater
    let onClose: () -> Void

    @State private var selectedCategory: SettingsCategory = .theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.3)
                detail
            }
        }
        .frame(width: 640, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.secondary)
                Text("Termy Settings")
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onClose)
        }
        .padding(DS.Spacing.l)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsCategory.allCases) { cat in
                SidebarRow(
                    title: cat.displayName,
                    icon: cat.icon,
                    isSelected: cat == selectedCategory,
                    onTap: { selectedCategory = cat }
                )
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.m)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 170)
        .background(.thickMaterial.opacity(0.3))
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                switch selectedCategory {
                case .general: GeneralPane()
                case .vibecoder: VibecoderPane()
                case .theme: ThemePane()
                case .font: FontPane()
                case .cursor: CursorPane()
                case .density: DensityPane()
                case .chrome: ChromePane()
                case .background: BackgroundPane()
                case .updates: UpdatesPane()
                case .about: AboutPane()
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environmentObject(settings)
        .environmentObject(updater)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, vibecoder, theme, font, cursor, density, chrome, background, updates, about
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .general: return "General"
        case .vibecoder: return "Vibecoder"
        case .theme: return "Theme"
        case .font: return "Font"
        case .cursor: return "Cursor"
        case .density: return "Density"
        case .chrome: return "Chrome"
        case .background: return "Background"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .vibecoder: return "sparkles"
        case .theme: return "paintpalette"
        case .font: return "textformat"
        case .cursor: return "cursorarrow"
        case .density: return "rectangle.compress.vertical"
        case .chrome: return "rectangle.topthird.inset.filled"
        case .background: return "circle.lefthalf.filled"
        case .updates: return "arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typo.body)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isSelected ? DS.Colors.chipBgActive : (hovering ? DS.Colors.chipBgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }
}

// MARK: - Detail panes

private struct GeneralPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("General") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Hide from Dock (menu-bar only style)", isOn: $settings.hideFromDock)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Confirm before quitting", isOn: $settings.confirmOnQuit)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Copy text on selection", isOn: $settings.copyOnSelect)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
        }
    }
}

private struct VibecoderPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Vibecoder") {
            Toggle(isOn: $settings.vibecoderMode) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(DS.Colors.aiAccent)
                    Text("Vibecoder Mode")
                        .font(DS.Typo.body.weight(.medium))
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            Text("Quick-launch row for Claude / Codex / Cursor / VS Code / Aider in the title strip. Icon-only circular buttons; hover for the tool name.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ThemePane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            DSSection("Theme") {
                ForEach(ThemeCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue)
                        .font(DS.Typo.tiny.weight(.semibold))
                        .foregroundStyle(DS.Colors.tertiary)
                        .textCase(.uppercase)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: DS.Spacing.s) {
                        ForEach(TerminalTheme.all.filter { $0.category == cat }) { theme in
                            ThemePreviewCard(
                                theme: theme,
                                isSelected: settings.themeID == theme.id,
                                onSelect: { settings.themeID = theme.id }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct FontPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Font") {
            Picker("Font Family", selection: $settings.fontFamily) {
                ForEach(installedFonts(), id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()

            HStack {
                Text("Size").font(DS.Typo.caption).foregroundStyle(DS.Colors.secondary)
                Slider(value: $settings.fontSize, in: 8...28, step: 1).controlSize(.small)
                Text("\(Int(settings.fontSize))pt")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            FontPreview(
                family: settings.fontFamily,
                size: settings.fontSize,
                foreground: themeForeground
            )

            Text("⌘+ / ⌘- / ⌘0 also work as shortcuts.")
                .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
        }
    }

    private var themeForeground: Color {
        let (r, g, b) = settings.theme.foreground
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    private func installedFonts() -> [String] {
        TerminalSettings.availableFontFamilies.filter { NSFont(name: $0, size: 12) != nil }
    }
}

private struct CursorPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Cursor") {
            HStack(spacing: DS.Spacing.s) {
                ForEach(CursorStyle.allCases) { style in
                    CursorPreview(
                        style: style,
                        blink: settings.cursorBlink,
                        isSelected: settings.cursorStyle == style,
                        onSelect: { settings.cursorStyle = style }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            Toggle("Blink", isOn: $settings.cursorBlink)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
        }
    }
}

private struct DensityPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Density") {
            HStack(spacing: DS.Spacing.s) {
                ForEach(PaddingPreset.allCases) { p in
                    DensityPreview(
                        preset: p,
                        isSelected: settings.paddingPreset == p,
                        onSelect: { settings.paddingPreset = p }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ChromePane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Chrome") {
            Toggle("Show tab bar", isOn: $settings.showTabBar)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Show status bar (cwd, git, clock)", isOn: $settings.showStatusBar)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
        }
    }
}

private struct UpdatesPane: View {
    @EnvironmentObject var updater: Updater

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        DSSection("Updates") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Termy \(currentVersion)")
                        .font(DS.Typo.body.weight(.semibold))
                    Text("Auto-checks for new versions on launch via Sparkle.")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                    .controlSize(.small)
            }
            Text("Updates pull from the GitHub Releases feed. You'll be prompted before downloading.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        DSSection("About") {
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable().interpolation(.medium)
                        .frame(width: 64, height: 64)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Text("T").font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Termy")
                        .font(DS.Typo.title)
                    Text("Version \(version) (build \(build))")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.secondary)
                    Text("A native macOS terminal for vibecoders.")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.tertiary)
                    Link("github.com/meesbeuk/termy",
                         destination: URL(string: "https://github.com/meesbeuk/termy")!)
                        .font(DS.Typo.caption)
                }
                Spacer()
            }
        }
    }
}

private struct BackgroundPane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Background") {
            HStack {
                Text("Opacity").font(DS.Typo.caption).foregroundStyle(DS.Colors.secondary)
                Spacer()
                Text("\(Int(settings.effectiveOpacity * 100))%")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
            }
            Toggle("Adapt to wallpaper brightness", isOn: $settings.autoOpacity)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Slider(value: $settings.opacity, in: 0...1.0)
                .controlSize(.small)
                .disabled(settings.autoOpacity)
                .opacity(settings.autoOpacity ? 0.4 : 1.0)
            OpacityPreview(opacity: settings.effectiveOpacity)
            Text(settings.autoOpacity
                 ? "Light wallpapers → more opaque, dark → more glass."
                 : "Manual opacity — drag to taste.")
                .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
        }
    }
}
