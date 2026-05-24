import SwiftUI

/// Quick-launch panel for AI/coding tools. ⌘L opens it. Pick one → types the
/// CLI into the active pane + runs.
struct AILauncherPanel: View {
    let onDismiss: () -> Void
    let onLaunch: (AILauncher) -> Void

    @State private var launchers: [AILauncher] = []
    @State private var selected: Int = 0

    var body: some View {
        DSModal(
            title: "Launch AI Tool",
            titleIcon: "sparkles",
            titleIconColor: DS.Colors.aiAccent,
            footerHint: "Runs in the active pane.  ↵ run  ·  ⎋ close",
            onClose: onDismiss
        ) {
            VStack(spacing: DS.Spacing.xs) {
                ForEach(Array(launchers.enumerated()), id: \.element.id) { idx, launcher in
                    LauncherRow(
                        launcher: launcher,
                        isHighlighted: idx == selected,
                        onTap: { commit(launcher) }
                    )
                }
            }
        }
        .onAppear { launchers = AILauncher.installed() }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) {
            if !launchers.isEmpty { commit(launchers[selected]) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !launchers.isEmpty { selected = (selected + 1) % launchers.count }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !launchers.isEmpty { selected = (selected - 1 + launchers.count) % launchers.count }
            return .handled
        }
    }

    private func commit(_ launcher: AILauncher) {
        onLaunch(launcher)
        onDismiss()
    }
}

private struct LauncherRow: View {
    let launcher: AILauncher
    let isHighlighted: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: launcher.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tintColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(launcher.displayName)
                        .font(DS.Typo.body.weight(.medium))
                    Text(launcher.commandPreview)
                        .font(DS.Typo.monoMicro)
                        .foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                Image(systemName: "return")
                    .font(DS.Typo.micro)
                    .foregroundStyle(DS.Colors.tertiary)
                    .opacity(isHighlighted ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(isHighlighted || isHovering ? DS.Colors.chipBgHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) { isHovering = hovering }
        }
    }

    private var tintColor: Color {
        switch launcher.tint {
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .red: return .red
        case .neutral: return DS.Colors.secondary
        }
    }
}

extension AILauncher {
    var commandPreview: String {
        ([cli] + arguments).joined(separator: " ")
    }
}
