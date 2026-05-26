import SwiftUI

/// Settings sheet — two-column layout with searchable sidebar.
///
/// Five panes, each focused on one mental model:
///   - Appearance — how Termy looks (theme/font/density/transparency/cursor)
///   - Behavior — how Termy acts (notifications, links, shell defaults)
///   - Profiles — saved shell configurations
///   - Quake — drop-down terminal settings
///   - Advanced — power-user features + diagnostics + reset + about
///
/// Search filters DSSection titles across all panes; jumping to a hit
/// switches panes automatically. Every section follows a consistent
/// caption + control + (optional) one-line hint rhythm.
struct TerminalSettingsSheet: View {
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var profiles: ProfileStore
    let onClose: () -> Void

    @State private var selectedCategory: SettingsCategory = .appearance
    @State private var searchQuery: String = ""
    /// Section the user just clicked in the sidebar — fires a scroll-to.
    /// Nil means "no jump pending."
    @State private var jumpToSection: String? = nil

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
        .frame(width: 700, height: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onReceive(NotificationCenter.default.publisher(for: .terminalSettingsSelectPane)) { note in
            if let payload = note.object as? [String: String] {
                if let raw = payload["pane"], let cat = SettingsCategory(rawValue: raw) {
                    selectedCategory = cat
                }
                if let filter = payload["filter"] {
                    searchQuery = filter
                }
            } else if let raw = note.object as? String,
                      let cat = SettingsCategory(rawValue: raw) {
                // Back-compat with the old payload shape.
                selectedCategory = cat
            }
        }
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
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            // Search field — when typed into, scrolls the detail pane to
            // the first matching section and switches pane if needed.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.tertiary)
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.caption)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Colors.chipBg)
            )
            .onChange(of: searchQuery) { _, q in
                if let target = SettingsCategory.matching(query: q) {
                    selectedCategory = target
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsCategory.allCases) { cat in
                    SidebarRow(
                        title: cat.displayName,
                        icon: cat.icon,
                        isSelected: cat == selectedCategory,
                        onTap: { selectedCategory = cat }
                    )
                    // When this pane is selected, render its sections as
                    // indented chevrons so the user can jump straight to
                    // a section without scrolling. Sections come from the
                    // SettingsCategory.sections registry (kept in lockstep
                    // with the pane content).
                    if cat == selectedCategory {
                        ForEach(cat.sections, id: \.self) { section in
                            SidebarSubRow(title: section) {
                                jumpToSection = section
                            }
                            .transition(.opacity)
                        }
                    }
                }
                Spacer()
            }
            .animation(.easeOut(duration: 0.12), value: selectedCategory)
        }
        .padding(.vertical, DS.Spacing.m)
        .padding(.horizontal, DS.Spacing.s)
        .frame(width: 200)
        .background(.thickMaterial.opacity(0.3))
    }

    @ViewBuilder
    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    switch selectedCategory {
                    case .appearance: AppearancePane(searchQuery: searchQuery)
                    case .behavior:   BehaviorPane(searchQuery: searchQuery)
                    case .profiles:   ProfilesPane()
                    case .quake:      QuakePane()
                    case .advanced:   AdvancedPane(searchQuery: searchQuery)
                    }
                }
                .padding(DS.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: jumpToSection) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.20)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                // Clear after the scroll fires so re-tapping the same
                // subheader triggers a fresh scroll instead of no-oping.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToSection = nil
                }
            }
            .onChange(of: selectedCategory) { _, _ in
                // Switching panes resets scroll offset to top.
                proxy.scrollTo("__top", anchor: .top)
            }
        }
        .environmentObject(settings)
        .environmentObject(updater)
        .environmentObject(profiles)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, behavior, profiles, quake, advanced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appearance: return "Appearance"
        case .behavior:   return "Behavior"
        case .profiles:   return "Profiles"
        case .quake:      return "Quake"
        case .advanced:   return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .behavior:   return "bell.badge"
        case .profiles:   return "person.crop.rectangle.stack"
        case .quake:      return "chevron.down.square"
        case .advanced:   return "slider.horizontal.3"
        }
    }
    /// Sections rendered inside this pane, in display order. The sidebar
    /// uses this list to surface jumpable subheaders so the user doesn't
    /// have to scroll an entire pane to find one section. Keep in lockstep
    /// with the pane View's section ordering, AND with the .id() anchors
    /// tagged on each DSSection.
    var sections: [String] {
        switch self {
        case .appearance:
            return ["Theme", "Font", "Cursor", "Density", "Background", "Chrome"]
        case .behavior:
            return ["System", "Notifications", "Links & editor", "Shell", "Updates"]
        case .profiles:
            return []
        case .quake:
            return []
        case .advanced:
            return ["Triggers", "Session recording", "Diagnostics", "About", "Reset"]
        }
    }

    /// Maps a search query to the best-matching pane.
    /// Used to switch panes when the user types in the sidebar search.
    static func matching(query: String) -> SettingsCategory? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        // Keyword index — extend as new sections land.
        let map: [SettingsCategory: [String]] = [
            .appearance: ["theme", "font", "size", "spacing", "color",
                          "thickness", "contrast", "opacity", "glass",
                          "background", "density", "padding", "cursor",
                          "caret", "wallpaper"],
            .behavior:   ["notify", "notification", "bell", "idle", "alert",
                          "link", "editor", "vscode", "cursor editor", "shell",
                          "scrollback", "preview", "background", "sound"],
            .profiles:   ["profile", "default profile", "shell args", "tag",
                          "env", "environment"],
            .quake:      ["quake", "drop-down", "dropdown", "quick",
                          "height", "focus loss"],
            .advanced:   ["trigger", "regex", "session", "record", "log",
                          "diagnostics", "reset", "version", "update",
                          "about", "sparkle"],
        ]
        for cat in SettingsCategory.allCases {
            if (map[cat] ?? []).contains(where: { $0.contains(q) || q.contains($0) }) {
                return cat
            }
        }
        return nil
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

/// Indented sub-section row shown beneath the active sidebar pane. Tapping
/// scrolls the detail ScrollView to the matching DSSection. Visually
/// lighter than the parent row so the hierarchy is unambiguous.
private struct SidebarSubRow: View {
    let title: String
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.Colors.tertiary)
                Text(title)
                    .font(DS.Typo.caption)
                    .foregroundStyle(hovering ? DS.Colors.primary : DS.Colors.secondary)
                Spacer()
            }
            .padding(.leading, 26)
            .padding(.trailing, DS.Spacing.s)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? DS.Colors.chipBgHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.08)) { hovering = v }
        }
    }
}

// MARK: - Search filtering helper
//
// Sections check this before rendering so a non-empty search query hides
// non-matching sections in the same pane. Empty query → render everything.
private func sectionVisible(_ title: String, query: String) -> Bool {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return true }
    return title.lowercased().contains(q)
}

// MARK: - Appearance pane

private struct AppearancePane: View {
    let searchQuery: String
    @EnvironmentObject var settings: TerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            // Empty top anchor so onChange(selectedCategory) can scroll
            // to top when the user switches panes.
            Color.clear.frame(height: 0).id("__top")
            if sectionVisible("Theme", query: searchQuery) {
                ThemePicker().id("Theme")
            }
            if sectionVisible("Font", query: searchQuery) {
                FontControls().id("Font")
            }
            if sectionVisible("Cursor", query: searchQuery) {
                CursorControls().id("Cursor")
            }
            if sectionVisible("Density", query: searchQuery) {
                DensityControls().id("Density")
            }
            if sectionVisible("Background", query: searchQuery) {
                BackgroundControls().id("Background")
            }
            if sectionVisible("Chrome", query: searchQuery) {
                ChromeControls().id("Chrome")
            }
        }
    }
}

private struct ThemePicker: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
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

private struct FontControls: View {
    @EnvironmentObject var settings: TerminalSettings
    @State private var showAdvanced: Bool = false

    var body: some View {
        DSSection("Font") {
            // Always-visible primary controls: family + size + preview.
            Picker("Font Family", selection: $settings.fontFamily) {
                ForEach(installedFonts(), id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()

            sliderRow(label: "Size",
                      value: $settings.fontSize, range: 11...28, step: 1,
                      unit: "pt")
            sliderRow(label: "Line spacing",
                      value: Binding(
                          get: { Double(settings.lineSpacing) },
                          set: { settings.lineSpacing = CGFloat($0) }),
                      range: 0...12, step: 1,
                      unit: "px")

            // "Advanced typography" — thickness + contrast floor — folded
            // behind a disclosure. Most users don't touch these once the
            // defaults are good, but they're available when needed.
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow(label: "Thickness",
                              value: Binding(
                                  get: { Double(settings.fontThicken) },
                                  set: { settings.fontThicken = CGFloat($0) }),
                              range: 0...1.5, step: 0.05,
                              formatter: { String(format: "%.2f", $0) })
                    sliderRow(label: "Contrast floor",
                              value: $settings.minimumContrast,
                              range: 0...7, step: 0.5,
                              formatter: { $0 > 0 ? String(format: "%.1f:1", $0) : "off" })
                    Text("Stroke width on glyphs · WCAG min ratio (foreground vs theme bg). Both have safety floors — you can't drag this to illegible.")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced typography")
                    .font(DS.Typo.caption.weight(.medium))
                    .foregroundStyle(DS.Colors.secondary)
            }

            FontPreview(
                family: settings.fontFamily,
                size: settings.fontSize,
                foreground: themeForeground
            )
        }
    }

    // Stamp out a labeled slider — every appearance section uses the same
    // shape, so keep one builder and call it everywhere.
    @ViewBuilder
    private func sliderRow<V: BinaryFloatingPoint>(
        label: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        step: V.Stride,
        unit: String = "",
        formatter: ((Double) -> String)? = nil
    ) -> some View where V.Stride: BinaryFloatingPoint {
        HStack {
            Text(label).font(DS.Typo.caption).foregroundStyle(DS.Colors.secondary)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: range, step: step).controlSize(.small)
            Text(formatter?(Double(value.wrappedValue)) ?? "\(Int(value.wrappedValue))\(unit)")
                .font(DS.Typo.monoCaption)
                .foregroundStyle(DS.Colors.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var themeForeground: Color {
        let (r, g, b) = settings.theme.foreground
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    private func installedFonts() -> [String] {
        let recommended = TerminalSettings.availableFontFamilies
            .filter { NSFont(name: $0, size: 12) != nil }
        let descriptor = NSFontDescriptor().withSymbolicTraits(.monoSpace)
        let matches = descriptor.matchingFontDescriptors(withMandatoryKeys: nil)
        let all = matches
            .compactMap { $0.object(forKey: .name) as? String }
            .sorted()
        var seen = Set(recommended)
        let extras = all.filter { name in
            !name.hasPrefix(".")
                && !name.lowercased().contains("italic")
                && !name.lowercased().contains("oblique")
                && seen.insert(name).inserted
        }
        return recommended + extras
    }
}

private struct CursorControls: View {
    @EnvironmentObject var settings: TerminalSettings
    private let options: [(String, String, String)] = [
        ("steadyBlock", "Block",     "block.fill"),
        ("blinkBlock",  "Block (blink)", "block"),
        ("steadyBar",   "Bar",       "rectangle.portrait.fill"),
        ("blinkBar",    "Bar (blink)",   "rectangle.portrait"),
        ("steadyUnderline", "Underline",     "minus"),
        ("blinkUnderline",  "Underline (blink)", "minus.square"),
    ]

    var body: some View {
        DSSection("Cursor") {
            // 3x2 grid of cursor-style chips — clicking picks one.
            LazyVGrid(columns: [GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())],
                      spacing: DS.Spacing.s) {
                ForEach(options, id: \.0) { (id, label, _) in
                    CursorChip(
                        label: label,
                        kind: id,
                        isSelected: settings.cursorStyle == id,
                        onTap: { settings.cursorStyle = id }
                    )
                }
            }
        }
    }
}

private struct CursorChip: View {
    let label: String
    let kind: String
    let isSelected: Bool
    let onTap: () -> Void
    @EnvironmentObject var settings: TerminalSettings
    @State private var hovering = false

    /// Cursor preview uses the live theme's cursor color so picking
    /// "Block" in Sunset shows an amber block, in Aurora a mint block, etc.
    /// — exactly what the pane will render. The text glyph behind the
    /// cursor uses the theme's foreground.
    private var cursorColor: Color { settings.theme.cursorColor }
    private var glyphColor: Color { settings.theme.foregroundColor.opacity(0.85) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                cursorPreview
                    .frame(width: 36, height: 22)
                Text(label)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isSelected ? DS.Colors.chipBgActive : (hovering ? DS.Colors.chipBgHover : DS.Colors.chipBg))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .stroke(isSelected ? settings.theme.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }

    @ViewBuilder
    private var cursorPreview: some View {
        ZStack {
            Text("a")
                .font(.custom(settings.fontFamily, size: 14))
                .foregroundStyle(glyphColor)
            switch kind {
            case "steadyBlock", "blinkBlock":
                Rectangle()
                    .fill(cursorColor.opacity(0.6))
                    .frame(width: 10, height: 14)
                    .offset(x: 8)
            case "steadyBar", "blinkBar":
                Rectangle()
                    .fill(cursorColor)
                    .frame(width: 2, height: 14)
                    .offset(x: 8)
            default:
                Rectangle()
                    .fill(cursorColor)
                    .frame(width: 10, height: 2)
                    .offset(x: 8, y: 7)
            }
        }
    }
}

private struct DensityControls: View {
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

private struct BackgroundControls: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Background") {
            Toggle("Adapt to wallpaper brightness", isOn: $settings.autoOpacity)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            HStack {
                Text("Opacity").font(DS.Typo.caption).foregroundStyle(DS.Colors.secondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $settings.opacity, in: 0...1.0)
                    .controlSize(.small)
                    .disabled(settings.autoOpacity)
                    .opacity(settings.autoOpacity ? 0.4 : 1.0)
                Text("\(Int(settings.effectiveOpacity * 100))%")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            OpacityPreview(opacity: settings.effectiveOpacity)
        }
    }
}

/// Chrome lives under Appearance now (it's a visual setting): tab bar,
/// status bar, vibecoder strip. Removed from Behavior — they were
/// orphans in that pane.
private struct ChromeControls: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Chrome") {
            Toggle("Show tab bar", isOn: $settings.showTabBar)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Show status bar", isOn: $settings.showStatusBar)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle(isOn: $settings.vibecoderMode) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(DS.Colors.aiAccent)
                    Text("Vibecoder mode")
                        .font(DS.Typo.caption.weight(.medium))
                }
            }
            .toggleStyle(.checkbox)
            Text("Adds Claude Code + Codex quick-launch icons to the title strip.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
        }
    }
}

// MARK: - Behavior pane

private struct BehaviorPane: View {
    let searchQuery: String
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Color.clear.frame(height: 0).id("__top")
            if sectionVisible("System", query: searchQuery) {
                SystemControls().id("System")
            }
            if sectionVisible("Notifications", query: searchQuery) {
                NotificationControls().id("Notifications")
            }
            if sectionVisible("Links", query: searchQuery)
                || sectionVisible("editor", query: searchQuery)
                || sectionVisible("Links & editor", query: searchQuery) {
                LinksControls().id("Links & editor")
            }
            if sectionVisible("Shell", query: searchQuery) {
                ShellDefaults().id("Shell")
            }
            if sectionVisible("Updates", query: searchQuery) {
                UpdatesControls().id("Updates")
            }
        }
    }
}

private struct SystemControls: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("System") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Hide from Dock", isOn: $settings.hideFromDock)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Confirm before quitting", isOn: $settings.confirmOnQuit)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
        }
    }
}

private struct NotificationControls: View {
    @EnvironmentObject var settings: TerminalSettings
    @State private var advanced = false

    var body: some View {
        DSSection("Notifications") {
            Toggle("When a command finishes", isOn: $settings.notifyOnIdle)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            if settings.notifyOnIdle {
                HStack {
                    Text("Quiet threshold")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $settings.idleThresholdSeconds, in: 2...30, step: 1)
                        .controlSize(.small)
                    Text("\(Int(settings.idleThresholdSeconds))s")
                        .font(DS.Typo.monoCaption)
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            Toggle("When an unfocused window beeps", isOn: $settings.notifyOnBell)
                .toggleStyle(.checkbox).font(DS.Typo.caption)

            DisclosureGroup(isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Only when window isn't focused", isOn: $settings.notifyOnlyBackground)
                        .toggleStyle(.checkbox).font(DS.Typo.caption)
                    Toggle("Include last line as preview", isOn: $settings.notifyShowPreview)
                        .toggleStyle(.checkbox).font(DS.Typo.caption)
                    Toggle("Play sound", isOn: $settings.notifySound)
                        .toggleStyle(.checkbox).font(DS.Typo.caption)
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced")
                    .font(DS.Typo.caption.weight(.medium))
                    .foregroundStyle(DS.Colors.secondary)
            }
        }
    }
}

private struct LinksControls: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Links & editor") {
            Picker("Editor", selection: $settings.editorScheme) {
                Text("Auto-detect (Cursor → VSCode → Zed)").tag("")
                Text("Cursor").tag("cursor")
                Text("VSCode").tag("vscode")
                Text("Zed").tag("zed")
                Text("Sublime Text").tag("subl")
                Text("TextMate").tag("mate")
            }
            .pickerStyle(.menu).labelsHidden()
            Text("Clicking a `path:line` reference in scrollback opens it here.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
        }
    }
}

private struct ShellDefaults: View {
    @EnvironmentObject var settings: TerminalSettings

    var body: some View {
        DSSection("Shell") {
            HStack {
                Text("Scrollback")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(settings.scrollbackLines) },
                    set: { settings.scrollbackLines = Int($0) }
                ), in: 1000...50000, step: 1000).controlSize(.small)
                Text("\(settings.scrollbackLines / 1000)k")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Text("Lines retained per pane. Bigger = more history, slightly more memory.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UpdatesControls: View {
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
                    if let last = updater.lastCheckedDescription {
                        Text("Last checked \(last)")
                            .font(DS.Typo.tiny)
                            .foregroundStyle(DS.Colors.tertiary)
                    } else {
                        Text("Never checked yet.")
                            .font(DS.Typo.tiny)
                            .foregroundStyle(DS.Colors.tertiary)
                    }
                }
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                    .controlSize(.small)
            }
            Toggle("Automatically check for updates",
                   isOn: Binding(get: { updater.autoCheck },
                                 set: { updater.autoCheck = $0 }))
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Toggle("Download and install in background",
                   isOn: Binding(get: { updater.autoDownload },
                                 set: { updater.autoDownload = $0 }))
                .toggleStyle(.checkbox).font(DS.Typo.caption)
                .disabled(!updater.autoCheck)
                .opacity(updater.autoCheck ? 1.0 : 0.5)
        }
    }
}

// MARK: - Quake pane

private struct QuakePane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Quake drop-down") {
            Toggle("Hide on focus loss", isOn: $settings.quakeHideOnFocusLoss)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            HStack {
                Text("Height")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $settings.quakeHeightFraction, in: 0.20...0.95)
                    .controlSize(.small)
                Text("\(Int(settings.quakeHeightFraction * 100))%")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Text("Vertical fraction the panel takes on ⌃`.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
        }
    }
}

// MARK: - Advanced pane (consolidated: triggers, session recording, dev, about, reset)

private struct AdvancedPane: View {
    let searchQuery: String
    @State private var showingDiagnostics = false
    @State private var showingResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Color.clear.frame(height: 0).id("__top")
            if sectionVisible("Triggers", query: searchQuery) {
                TriggersSection().id("Triggers")
            }
            if sectionVisible("Session recording", query: searchQuery) {
                SessionRecordingSection().id("Session recording")
            }
            if sectionVisible("Diagnostics", query: searchQuery) {
                DSSection("Diagnostics") {
                    Button(action: { showingDiagnostics = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stethoscope")
                            Text("Run Diagnostics…")
                        }
                        .font(DS.Typo.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Colors.accent)
                    Text("Shows what Termy advertises to capability probes. Useful for bug reports.")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                .id("Diagnostics")
            }
            if sectionVisible("About", query: searchQuery) {
                AboutSection().id("About")
            }
            if sectionVisible("Reset", query: searchQuery) {
                DSSection("Reset") {
                    Button(role: .destructive, action: { showingResetConfirm = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset all Termy settings…")
                        }
                        .font(DS.Typo.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Colors.danger.opacity(0.85))
                    Text("Wipes every Termy preference. Termy quits; relaunch for a clean slate. Files on disk are untouched.")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                .id("Reset")
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet(onDismiss: { showingDiagnostics = false })
        }
        .alert("Reset all Termy settings?", isPresented: $showingResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { resetAndQuit() }
        } message: {
            Text("Removes every Termy preference. Termy quits afterwards.")
        }
    }

    private func resetAndQuit() {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix("termy.") || key.hasPrefix("mees.terminal.") {
            defaults.removeObject(forKey: key)
        }
        if let windowKeys = defaults.stringArray(forKey: "mees.terminal.windowKeys.v1") {
            for k in windowKeys { defaults.removeObject(forKey: k) }
        }
        defaults.removeObject(forKey: "mees.terminal.windowKeys.v1")
        defaults.removeObject(forKey: "mees.terminal.restoreTabs.v2")
        defaults.synchronize()
        NSApp.terminate(nil)
    }
}

private struct TriggersSection: View {
    var body: some View {
        DSSection("Triggers") {
            Text("Regex packs that notify you when your output matches. Toggle a pack to enable its rules.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            TriggerPacksControl()
        }
    }
}

private struct SessionRecordingSection: View {
    @EnvironmentObject var settings: TerminalSettings
    @State private var showingDeleteConfirm = false
    /// Cached file count for the confirmation dialog and button enablement.
    /// Recomputed on appear and after a successful delete.
    @State private var logCount: Int = 0
    @State private var logBytes: Int64 = 0

    var body: some View {
        DSSection("Session recording") {
            Toggle("Record every pane's output to disk", isOn: $settings.recordSessions)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Text("Plain-text transcript per pane (`.txt`) under `~/Library/Application Support/Termy/sessions/`. Off by default.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.s) {
                Button("Reveal log folder") {
                    let dir = SessionRecorder.sessionsDir()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .controlSize(.small)

                Button(role: .destructive, action: { showingDeleteConfirm = true }) {
                    Text(logCount == 0 ? "No logs to delete" : "Delete all logs…")
                }
                .controlSize(.small)
                .disabled(logCount == 0)

                Spacer()
                if logCount > 0 {
                    Text("\(logCount) file\(logCount == 1 ? "" : "s") · \(humanBytes(logBytes))")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
            }
        }
        .onAppear(perform: refreshStats)
        .alert("Delete all session logs?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(logCount) file\(logCount == 1 ? "" : "s")", role: .destructive) {
                deleteAll()
            }
        } message: {
            Text("Permanently removes every transcript under `~/Library/Application Support/Termy/sessions/`. Active recordings keep running into fresh files.")
        }
    }

    /// Scan the sessions directory and update the file count + total size.
    /// Cheap (only stats files, doesn't read them).
    private func refreshStats() {
        let dir = SessionRecorder.sessionsDir()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            logCount = 0; logBytes = 0; return
        }
        var count = 0
        var bytes: Int64 = 0
        for name in names where name.hasSuffix(".txt") || name.hasSuffix(".log") {
            let url = dir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                count += 1
                bytes += size.int64Value
            }
        }
        logCount = count
        logBytes = bytes
    }

    /// Delete every transcript. Open recorders for currently-active panes
    /// keep their file handles open — POSIX semantics mean their next
    /// write continues into the unlinked file (a tiny orphan), which the
    /// next launch reaps cleanly. No need to coordinate with live panes.
    private func deleteAll() {
        let dir = SessionRecorder.sessionsDir()
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasSuffix(".txt") || name.hasSuffix(".log") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        refreshStats()
    }

    private func humanBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}

private struct AboutSection: View {
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
                        .frame(width: 56, height: 56)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Text("T").font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Termy")
                        .font(DS.Typo.title)
                    Text("Version \(version) (build \(build))")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.secondary)
                    if let url = URL(string: "https://github.com/meesbeuk/termy") {
                        Link("github.com/meesbeuk/termy", destination: url)
                            .font(DS.Typo.caption)
                    }
                    if let releaseURL = URL(string: "https://github.com/meesbeuk/termy/releases/tag/v\(version)") {
                        Link("What's new in v\(version) →", destination: releaseURL)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
                Spacer()
            }
        }
    }
}

/// Inline section listing each TriggerPack with a toggle bound to the
/// shared TriggerRegistry.
private struct TriggerPacksControl: View {
    @ObservedObject private var registry = TriggerRegistry.shared

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            ForEach(TriggerPack.allCases) { pack in
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.name)
                            .font(DS.Typo.caption.weight(.medium))
                            .foregroundStyle(DS.Colors.primary)
                        Text(pack.description)
                            .font(DS.Typo.tiny)
                            .foregroundStyle(DS.Colors.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { registry.enabledPacks.contains(pack) },
                        set: { registry.setPack(pack, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @EnvironmentObject var profiles: ProfileStore
    @State private var editingID: UUID?

    var body: some View {
        DSSection("Profiles") {
            Text("Saved shell configurations — open a new tab with a profile to use its shell, args, cwd, theme, and tag color.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Spacing.xs) {
                ForEach(profiles.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isDefault: profiles.defaultProfileID == profile.id,
                        isEditing: editingID == profile.id,
                        onSetDefault: { profiles.setDefault(profile.id) },
                        onEdit: { editingID = editingID == profile.id ? nil : profile.id },
                        onDelete: {
                            profiles.remove(profile.id)
                            if editingID == profile.id { editingID = nil }
                        },
                        onSave: { updated in
                            profiles.update(updated)
                            editingID = nil
                        }
                    )
                }
            }

            Button(action: {
                let new = Profile(name: "New Profile")
                profiles.add(new)
                editingID = new.id
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("Add Profile")
                }
                .font(DS.Typo.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.accent)
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isDefault: Bool
    let isEditing: Bool
    let onSetDefault: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSave: (Profile) -> Void

    @State private var draft: Profile
    @State private var showingDeleteConfirm = false

    init(profile: Profile, isDefault: Bool, isEditing: Bool,
         onSetDefault: @escaping () -> Void, onEdit: @escaping () -> Void,
         onDelete: @escaping () -> Void, onSave: @escaping (Profile) -> Void) {
        self.profile = profile
        self.isDefault = isDefault
        self.isEditing = isEditing
        self.onSetDefault = onSetDefault
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onSave = onSave
        _draft = State(initialValue: profile)
    }

    private func confirmAndDelete() {
        showingDeleteConfirm = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.s) {
                ProfileAvatar(profile: profile, size: 24)
                if let dot = profile.tagColor.swiftColor {
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                Text(profile.name)
                    .font(DS.Typo.body.weight(.medium))
                    .foregroundStyle(DS.Colors.primary)
                if isDefault {
                    Text("default")
                        .font(DS.Typo.micro.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Capsule().fill(DS.Colors.accent.opacity(0.15))
                        )
                }
                Spacer()
                if !isDefault {
                    Button("Make Default", action: onSetDefault)
                        .buttonStyle(.plain)
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                DSIconButton(icon: isEditing ? "chevron.up" : "pencil", action: onEdit)
                DSIconButton(icon: "trash", action: confirmAndDelete, color: DS.Colors.tertiary)
            }

            if isEditing {
                ProfileEditor(draft: $draft)
                HStack {
                    Spacer()
                    Button("Save") {
                        var safe = draft
                        let trimmed = safe.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { safe.name = "Untitled" }
                        onSave(safe)
                    }
                    .controlSize(.small)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && draft.shellPath.isEmpty && draft.initialCwd.isEmpty)
                }
            }
        }
        .padding(DS.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .fill(DS.Colors.chipBg)
        )
        .onChange(of: isEditing) { _, editing in
            if editing { draft = profile }
        }
        .onChange(of: profile) { _, new in
            if !isEditing { draft = new }
        }
        .alert("Delete profile \"\(profile.name)\"?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text(isDefault
                 ? "This is your default profile. Deleting it promotes another profile to default."
                 : "This action cannot be undone.")
        }
    }
}

private struct ProfileEditor: View {
    @Binding var draft: Profile
    @State private var newEnvKey: String = ""
    @State private var newEnvValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.s) {
                Text("Avatar").font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary).frame(width: 70, alignment: .leading)
                ProfileAvatar(profile: draft, size: 36)
                Button(action: {
                    draft.avatarSeed = Profile.randomSeed()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Re-roll")
                    }
                    .font(DS.Typo.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.accent)
                Spacer()
            }
            field("Name", text: $draft.name)
            field("Shell", text: $draft.shellPath, placeholder: "/bin/zsh (blank = $SHELL)")
            field("Initial cwd", text: $draft.initialCwd, placeholder: "~  (blank = HOME)")
            HStack(spacing: 6) {
                Text("Tag").font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary).frame(width: 70, alignment: .leading)
                Picker("", selection: $draft.tagColor) {
                    ForEach(TabTagColor.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
            }
            envEditor
        }
    }

    @ViewBuilder
    private var envEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text("Environment")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .frame(width: 70, alignment: .leading)
                Spacer()
                if !draft.environmentExtras.isEmpty {
                    Text("\(draft.environmentExtras.count) override\(draft.environmentExtras.count == 1 ? "" : "s")")
                        .font(DS.Typo.tiny)
                        .foregroundStyle(DS.Colors.tertiary)
                }
            }
            ForEach(draft.environmentExtras.keys.sorted(), id: \.self) { key in
                envRow(key: key, value: draft.environmentExtras[key] ?? "")
            }
            HStack(spacing: 4) {
                TextField("KEY", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(DS.Typo.monoCaption)
                    .frame(maxWidth: 110)
                Text("=").foregroundStyle(DS.Colors.tertiary).font(DS.Typo.caption)
                TextField("value", text: $newEnvValue)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(DS.Typo.monoCaption)
                Button(action: commitNewEnv) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAddEnv ? DS.Colors.accent : DS.Colors.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canAddEnv)
                .help("Add env var")
            }
            .padding(.leading, 76)
            Text("Injected into every shell launched with this profile.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .padding(.leading, 76)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func envRow(key: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(DS.Typo.monoCaption)
                .foregroundStyle(DS.Colors.primary)
                .frame(maxWidth: 110, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("=").foregroundStyle(DS.Colors.tertiary).font(DS.Typo.caption)
            TextField("", text: Binding(
                get: { draft.environmentExtras[key] ?? value },
                set: { newValue in draft.environmentExtras[key] = newValue }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(DS.Typo.monoCaption)
            Button(action: { draft.environmentExtras.removeValue(forKey: key) }) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(DS.Colors.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove \(key)")
        }
        .padding(.leading, 76)
    }

    private var canAddEnv: Bool {
        let trimmed = newEnvKey.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("=") && !trimmed.contains(" ")
    }

    private func commitNewEnv() {
        let key = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft.environmentExtras[key] = newEnvValue
        newEnvKey = ""
        newEnvValue = ""
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(DS.Typo.monoCaption)
        }
    }
}
