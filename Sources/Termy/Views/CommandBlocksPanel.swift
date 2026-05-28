import SwiftUI
import AppKit

/// Command Blocks — each shell command + its output as a collapsible block,
/// captured from OSC 133 shell-integration marks. Click a block to expand its
/// output, copy the output, or jump the terminal to where it ran. Newest
/// first. SwiftTerm renders the grid itself so blocks live in this companion
/// panel rather than folding scrollback inline.
struct CommandBlocksPanel: View {
    @ObservedObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var expanded: Set<UUID> = []

    private var blocks: [CommandBlock] {
        (sessions.currentSession?.commandBlocks ?? []).reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "rectangle.split.1x2").font(.system(size: 13))
                        .foregroundStyle(DS.Colors.accent)
                    Text("Command Blocks").font(DS.Typo.title)
                    Text("\(blocks.count)").font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
                }
                Spacer()
                DSIconButton(icon: "xmark", action: onDismiss)
            }

            if blocks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(blocks) { block in
                            blockRow(block)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(DS.Modal.padding)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("No command blocks yet.").font(DS.Typo.body)
            Text("Blocks are captured from OSC 133 shell-integration marks. Enable shell integration in your shell (zsh/bash/fish prompt hooks) and each command + output will appear here.")
                .font(DS.Typo.caption).foregroundStyle(DS.Colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Spacing.m)
    }

    private func blockRow(_ block: CommandBlock) -> some View {
        let isOpen = expanded.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            // Header — click toggles expansion.
            Button {
                if isOpen { expanded.remove(block.id) } else { expanded.insert(block.id) }
            } label: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.tertiary)
                        .frame(width: 10)
                    Text(block.label).font(DS.Typo.monoCaption).lineLimit(1)
                    Spacer()
                    Button { sessions.scrollActivePane(toRow: block.row); onDismiss() } label: {
                        Image(systemName: "scope").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.secondary).help("Jump to this command")
                    Button { copy(block.output) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.secondary).help("Copy output")
                }
                .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(block.output.isEmpty ? "(no captured output)" : block.output)
                    .font(DS.Typo.monoMicro).foregroundStyle(DS.Colors.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.s)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(Color.black.opacity(0.18)))
                    .padding(.horizontal, DS.Spacing.s).padding(.bottom, DS.Spacing.xs)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(DS.Colors.chipBg))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
