import SwiftUI

/// Settings sheet — two-column layout (macOS System Settings style).
/// Left: list of categories. Right: controls + visual preview for whichever
/// category is selected.
struct TerminalSettingsSheet: View {
    @EnvironmentObject var settings: TerminalSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var profiles: ProfileStore
    let onClose: () -> Void

    @State private var selectedCategory: SettingsCategory = .appearance

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
                case .appearance: AppearancePane()
                case .profiles: ProfilesPane()
                case .quake: QuakePane()
                case .about: AboutPane()
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environmentObject(settings)
        .environmentObject(updater)
        .environmentObject(profiles)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    // Consolidated from 11 → 5 sections in v0.9.11. Vibecoder + bell +
    // updates folded into General; theme + font + density + background +
    // chrome consolidated into Appearance with subheaders. Profiles +
    // Quake + About stay as their own sections.
    case general, appearance, profiles, quake, about
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .profiles: return "Profiles"
        case .quake: return "Quake"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .profiles: return "person.crop.rectangle.stack"
        case .quake: return "chevron.down.square"
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
    @EnvironmentObject var updater: Updater

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            DSSection("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle("Hide from Dock (menu-bar only)", isOn: $settings.hideFromDock)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle("Confirm before quitting", isOn: $settings.confirmOnQuit)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
            }

            DSSection("Chrome") {
                Toggle("Show tab bar", isOn: $settings.showTabBar)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle("Show status bar (cwd, git, clock)", isOn: $settings.showStatusBar)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle(isOn: $settings.vibecoderMode) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(DS.Colors.aiAccent)
                        Text("Vibecoder Mode")
                            .font(DS.Typo.caption.weight(.medium))
                    }
                }
                .toggleStyle(.checkbox)
                Text("Surfaces Claude Code + Codex quick-launch icons in the title strip.")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DSSection("Notifications") {
                Toggle("Notify when a command finishes (auto)", isOn: $settings.notifyOnIdle)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Text("Detects when a pane goes from actively producing output to quiet — works for Claude Code, Codex, `npm test`, `cargo build`, anything. No shell setup required.")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Quiet threshold")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colors.secondary)
                    Slider(value: $settings.idleThresholdSeconds, in: 2...30, step: 1)
                        .controlSize(.small)
                        .disabled(!settings.notifyOnIdle)
                        .opacity(settings.notifyOnIdle ? 1.0 : 0.5)
                    Text("\(Int(settings.idleThresholdSeconds))s")
                        .font(DS.Typo.monoCaption)
                        .foregroundStyle(DS.Colors.secondary)
                        .frame(width: 30, alignment: .trailing)
                }

                Toggle("Notify when an unfocused window beeps", isOn: $settings.notifyOnBell)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Text("Hooks the terminal BEL. Pair with `precmd() { print -n \"\\a\" }` in zsh to ring after every command — useful as a manual alternative to the auto-quiet detector above.")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.2)

                Toggle("Only when the window isn't focused", isOn: $settings.notifyOnlyBackground)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle("Show last line as preview", isOn: $settings.notifyShowPreview)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Toggle("Play sound", isOn: $settings.notifySound)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
            }

            DSSection("Session recording") {
                Toggle("Record every pane's output to a log file", isOn: $settings.recordSessions)
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                Text("Each pane writes a `.log` file under `~/Library/Application Support/Termy/sessions/`. Useful for going back to a past `claude` conversation, or auditing what a command actually printed. Off by default — the log files include everything in scrollback verbatim.")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal log folder in Finder") {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    let dir = support?.appendingPathComponent("Termy/sessions", isDirectory: true)
                    if let dir {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                .controlSize(.small)
            }

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
                Toggle("Automatically download + install in background",
                       isOn: Binding(get: { updater.autoDownload },
                                     set: { updater.autoDownload = $0 }))
                    .toggleStyle(.checkbox).font(DS.Typo.caption)
                    .disabled(!updater.autoCheck)
                    .opacity(updater.autoCheck ? 1.0 : 0.5)
            }
        }
    }
}

/// Merged Theme + Font + Density + Background. Was four separate sections
/// in v0.9.10 — every one is "how the terminal looks", so they belong
/// together under one Appearance umbrella.
private struct AppearancePane: View {
    @EnvironmentObject var settings: TerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            ThemePicker()
            FontControls()
            DensityControls()
            BackgroundControls()
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
            Text("⌘+ / ⌘- / ⌘0 also adjust size.")
                .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
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

private struct QuakePane: View {
    @EnvironmentObject var settings: TerminalSettings
    var body: some View {
        DSSection("Quake drop-down") {
            Toggle("Hide on focus loss", isOn: $settings.quakeHideOnFocusLoss)
                .toggleStyle(.checkbox).font(DS.Typo.caption)
            Text("Classic Quake behaviour — clicking outside the panel slides it back up. Turn off to keep it pinned while you reference it from another window.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Height")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                Slider(value: $settings.quakeHeightFraction, in: 0.20...0.95)
                    .controlSize(.small)
                Text("\(Int(settings.quakeHeightFraction * 100))%")
                    .font(DS.Typo.monoCaption)
                    .foregroundStyle(DS.Colors.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            Text("Vertical fraction of the active display the panel takes when toggled. Applies next time you press ⌃`.")
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
                    if let url = URL(string: "https://github.com/meesbeuk/termy") {
                        Link("github.com/meesbeuk/termy", destination: url)
                            .font(DS.Typo.caption)
                    }
                }
                Spacer()
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
            Text("Saved shell configurations — open a new tab with a profile to use its shell, args, cwd, theme, and tag color. Pick one as default to apply on every new tab.")
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
        // Single-profile guard: never let the user delete the last profile.
        // The seed code expects ProfileStore.profiles non-empty.
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
                // Use DSIconButton for proper 22×22 hit areas — the previous
                // raw Image+Button gave a ~10×10pt target that was nearly
                // impossible to click without zooming.
                DSIconButton(icon: isEditing ? "chevron.up" : "pencil", action: onEdit)
                DSIconButton(icon: "trash", action: confirmAndDelete, color: DS.Colors.tertiary)
            }

            if isEditing {
                ProfileEditor(draft: $draft)
                HStack {
                    Spacer()
                    Button("Save") {
                        // Don't save blank-named profiles — they render as an
                        // empty row that's impossible to identify in the list.
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
        // Re-sync the draft whenever the editor is reopened OR the parent
        // profile changes externally — without this, editing the same profile
        // twice would show stale data from the previous session.
        .onChange(of: isEditing) { _, editing in
            if editing { draft = profile }
        }
        .onChange(of: profile) { _, new in
            if !isEditing { draft = new }
        }
        // Destructive-action confirmation. Prevents an accidental click on the
        // trash icon from nuking a profile (especially the default one) with
        // no recourse — UserDefaults state survives launches.
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
            field("Shell", text: $draft.shellPath, placeholder: "/bin/zsh (or leave blank to use $SHELL)")
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
        }
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

