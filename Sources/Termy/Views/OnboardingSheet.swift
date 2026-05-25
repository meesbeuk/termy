import SwiftUI
import AppKit

/// One-time welcome sheet shown on Termy's very first launch. Walks the
/// user through the three things that make Termy feel "set up" rather
/// than "just installed":
///
///   1. Why Termy exists (1-line pitch + the AI-launcher angle).
///   2. The shell-integration snippet — copy-button, no fuss. Without
///      OSC 133 the idle heuristic still works, so this is presented as
///      a "more accurate" option rather than required setup.
///   3. The fastest 5 shortcuts to memorise (with a pointer to ⌘/ for
///      the rest).
///
/// Dismissal sets `termy.onboarding.v1.completed = true` so it never
/// appears again. Existing users (with persisted windowKeys at launch)
/// are auto-marked completed in `TerminalAppDelegate.applicationDidFinishLaunching`
/// so an upgrade doesn't surprise them with a "welcome" sheet.
struct OnboardingSheet: View {
    let onDismiss: () -> Void

    /// The exact zsh snippet from the README. Centralised here so we can
    /// surface it with a copy button in onboarding AND in Diagnostics
    /// without two copies diverging.
    static let shellIntegrationSnippet = """
    # ~/.zshrc — Termy OSC 133 shell integration + dynamic tab title
    precmd()  { print -n "\\e]133;D;$?\\a\\e]133;A\\a" ; print -Pn "\\e]0;%~\\a" }
    preexec() { print -n "\\e]133;C\\a" ; print -Pn "\\e]0;$1\\a" }
    """

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    welcome
                    shellIntegrationSection
                    shortcutsSection
                    nextStepsSection
                }
                .padding(DS.Spacing.xl)
            }
            Divider().opacity(0.3)
            footer
        }
        // maxWidth/maxHeight instead of fixed dimensions so the sheet
        // shrinks to fit small windows. Combined with the .padding() on
        // the parent overlay (in MainTerminalView), the sheet never clips
        // off the top — the header stays visible and the body's existing
        // ScrollView absorbs vertical overflow.
        .frame(maxWidth: 620, maxHeight: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .background(
            Button("") { complete() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(DS.Colors.aiAccent)
            Text("Welcome to Termy")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            DSIconButton(icon: "xmark", action: complete)
        }
        .padding(DS.Spacing.l)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("The macOS terminal built for Claude Code, Codex, and however you ship.")
                .font(DS.Typo.body)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You're already set up — the title strip has one-click launchers for your AI of choice, tabs and splits work via standard shortcuts, and the find bar (⌘F) searches scrollback as you type. Three things worth knowing on day one:")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellIntegrationSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionHeader("Optional: pixel-accurate \"command finished\" pings", icon: "bell.badge")
            Text("Termy auto-detects when a command finishes (Claude/Codex/builds — any shell). For the most precise pings, drop this in your `~/.zshrc`:")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topTrailing) {
                Text(Self.shellIntegrationSnippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.primary)
                    .textSelection(.enabled)
                    .padding(DS.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s)
                            .fill(DS.Colors.chipBg)
                    )
                Button(action: copySnippet) {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(DS.Typo.tiny)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(8)
            }
            Text("Skip it if you want — heuristic detection works fine. Adding it unlocks per-prompt jump (⌘↑/⌘↓), tab titles showing the running command, and exact OSC 133 boundaries.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionHeader("The 5 shortcuts to muscle-memory", icon: "keyboard")
            VStack(alignment: .leading, spacing: 4) {
                shortcut("Find in scrollback (as-you-type, regex toggle)", key: "⌘F")
                shortcut("Command Palette — fuzzy jump to anything", key: "⌘⇧P")
                shortcut("Quake drop-down terminal — global", key: "⌃`")
                shortcut("Split pane", key: "⌘D  /  ⌘⇧D")
                shortcut("All shortcuts (this dialog forever)", key: "⌘/")
            }
        }
    }

    private var nextStepsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionHeader("Make it yours", icon: "paintpalette")
            Text("Settings (⌘,) → Appearance for theme + font + density, → Profiles to save per-project shells with env vars, → General for notifications and recording. 17 themes are bundled — click a preview to apply.")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.accent)
            Text(title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .textCase(.uppercase)
                .opacity(0.8)
        }
    }

    @ViewBuilder
    private func shortcut(_ label: String, key: String) -> some View {
        HStack {
            Text(label)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Colors.primary)
            Spacer()
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS.Colors.chipBg)
                )
        }
    }

    private var footer: some View {
        HStack {
            Text("You can revisit any of this from Settings (⌘,) and the Help menu.")
                .font(DS.Typo.tiny)
                .foregroundStyle(DS.Colors.tertiary)
            Spacer()
            Button("Get started") { complete() }
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.m)
    }

    private func copySnippet() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.shellIntegrationSnippet, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        onDismiss()
    }
}

/// Single source of truth for the "have we shown onboarding?" UserDefaults
/// key. Lives outside the sheet so `TerminalAppDelegate` can stamp it true
/// for existing users on first launch after the upgrade.
enum OnboardingState {
    static let completedKey = "termy.onboarding.v1.completed"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}
