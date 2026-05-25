import SwiftUI

/// "Run Diagnostics" sheet — shows the user what Termy is currently
/// advertising to tools that probe terminal capabilities. Cuts down
/// "why isn't <tool> rendering an image / using my color theme /
/// detecting Claude Code finished?" support load by making the
/// detection state visible.
struct DiagnosticsSheet: View {
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    section(title: "Identification") {
                        row("Termy version", value: version)
                        row("Build", value: build)
                        row("macOS", value: osVersion)
                        row("Architecture", value: archString)
                    }
                    section(title: "Environment (what tools see)") {
                        row("TERM", value: env("TERM") ?? "—")
                        row("TERM_PROGRAM", value: env("TERM_PROGRAM") ?? "—",
                            note: env("TERM_PROGRAM") == "iTerm.app"
                                ? "iTerm.app impersonation — tools like imgcat opt-in"
                                : nil)
                        row("TERM_PROGRAM_VERSION", value: env("TERM_PROGRAM_VERSION") ?? "—")
                        row("LC_TERMINAL", value: env("LC_TERMINAL") ?? "—")
                        row("LC_TERMINAL_VERSION", value: env("LC_TERMINAL_VERSION") ?? "—")
                        row("TERM_FEATURES", value: env("TERM_FEATURES") ?? "—",
                            note: "title / sixel / kitty / iterm2 — features Termy claims to support")
                        row("TERMY", value: env("TERMY") ?? "—",
                            note: "Termy-only marker — use this in shell config to detect actual Termy")
                        row("COLORTERM", value: env("COLORTERM") ?? "—")
                    }
                    section(title: "Graphics protocols (via SwiftTerm)") {
                        row("OSC 1337 (iTerm2)", value: "parsed",
                            note: "Visible render pending view-layer investigation")
                        row("Sixel", value: "parsed")
                        row("Kitty graphics", value: "parsed")
                    }
                    section(title: "Shell integration") {
                        row("OSC 133 parser", value: "active",
                            note: "Add the README zsh snippet to enable accurate command-finished notifications")
                        row("OSC 0 title", value: "active",
                            note: "Add the README zsh snippet so tab titles show the running command")
                        row("OSC 8 hyperlinks", value: "clickable",
                            note: "Routes file://… and path:line:col to your chosen editor")
                    }
                    section(title: "Notifications") {
                        row("On-bell", value: UserDefaults.standard.bool(forKey: "termy.notifyOnBell") ? "on" : "off")
                        row("On-idle (heuristic)", value: UserDefaults.standard.bool(forKey: "termy.notifyOnIdle") ? "on" : "off")
                        row("Background scope", value: ((UserDefaults.standard.object(forKey: "termy.notifyOnlyBackground") as? Bool) ?? true) ? "on" : "off")
                    }
                    section(title: "Recording / Cinema") {
                        row("Session recording", value: UserDefaults.standard.bool(forKey: "termy.recordSessions") ? "on" : "off")
                        row("Cinema mode", value: UserDefaults.standard.bool(forKey: "termy.cinemaMode") ? "on" : "off")
                    }
                }
                .padding(DS.Spacing.xl)
            }
            Divider().opacity(0.3)
            HStack {
                Button(action: copyReport) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy report to clipboard")
                    }
                    .font(DS.Typo.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text("Paste this in a GitHub issue if something's not working.")
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.s)
        }
        .frame(maxWidth: 640, maxHeight: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .background(
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false).frame(width: 0, height: 0)
        )
    }

    // MARK: Layout helpers

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.accent)
                Text("Termy Diagnostics")
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onDismiss)
        }
        .padding(DS.Spacing.l)
    }

    @ViewBuilder
    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .textCase(.uppercase)
                .opacity(0.7)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colors.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DS.Colors.chipBg)
                    )
            }
            if let note {
                Text(note)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Data sources

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    private var archString: String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64 (Intel)"
        #else
        return "unknown"
        #endif
    }

    /// Reads from the env Termy injects into every pane's child shell.
    /// `ProcessInfo.processInfo.environment` would show Termy's OWN env
    /// (mostly unset for TERM_PROGRAM / LC_TERMINAL when Termy launches
    /// from Finder) — which is misleading because tools probing
    /// capabilities see the injected child env, not Termy's. Mirror
    /// TerminalSessions.processEnvironment here so the report reflects
    /// what tools actually observe.
    private func env(_ key: String) -> String? {
        Self.advertisedEnv[key]
    }

    private static let advertisedEnv: [String: String] = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "iTerm.app"
        env["TERM_PROGRAM_VERSION"] = version
        env["TERMY"] = version
        env["LC_TERMINAL"] = "iTerm2"
        env["LC_TERMINAL_VERSION"] = version
        env["TERM_FEATURES"] = "title,sixel,kitty,iterm2"
        return env
    }()

    private func copyReport() {
        let envKeys = ["TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
                       "LC_TERMINAL", "LC_TERMINAL_VERSION", "TERM_FEATURES",
                       "TERMY", "COLORTERM"]
        var lines: [String] = [
            "Termy \(version) (build \(build))",
            "macOS \(osVersion) — \(archString)",
            ""
        ]
        lines += envKeys.map { "\($0)=\(env($0) ?? "")" }
        lines += ["",
                  "Graphics: OSC 1337 / Sixel / Kitty parsed (visible render pending investigation)",
                  "OSC 133: parser active",
                  "OSC 8: clickable → user-configured editor",
                  ""]
        let report = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}
