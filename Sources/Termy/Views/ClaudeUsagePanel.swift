import SwiftUI

/// Claude usage at a glance — tokens + estimated cost for today, the last 7
/// days, and all time, plus a per-model breakdown. Read natively from
/// ~/.claude/projects (the same data ccusage parses), no Node dependency.
/// Cost is an estimate (prices drift) and is labelled as such.
struct ClaudeUsagePanel: View {
    let onDismiss: () -> Void

    @State private var summary = UsageSummary()
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 13))
                        .foregroundStyle(DS.Colors.aiAccent)
                    Text("Claude Usage").font(DS.Typo.title)
                }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.secondary).help("Refresh")
                DSIconButton(icon: "xmark", action: onDismiss)
            }

            if loading {
                HStack { ProgressView().controlSize(.small); Text("Reading ~/.claude logs…").font(DS.Typo.caption) }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, DS.Spacing.xl)
            } else if summary.allTime.totalTokens == 0 {
                Text("No Claude Code usage found in ~/.claude/projects.")
                    .font(DS.Typo.caption).foregroundStyle(DS.Colors.tertiary)
                    .padding(.vertical, DS.Spacing.l)
            } else {
                HStack(spacing: DS.Spacing.m) {
                    statCard("Today", summary.today)
                    statCard("Last 7 days", summary.last7)
                    statCard("All time", summary.allTime)
                }
                if !summary.byModel.isEmpty {
                    DSSection("By model") {
                        VStack(spacing: DS.Spacing.xs) {
                            ForEach(summary.byModel, id: \.tier) { m in modelRow(m) }
                        }
                    }
                }
            }

            Text("Estimated from local Claude Code logs · prices approximate")
                .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
        }
        .padding(DS.Modal.padding)
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .onAppear(perform: reload)
    }

    private func statCard(_ title: String, _ t: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title.uppercased()).font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
            Text(Self.money(t.cost)).font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.aiAccent)
            Text("\(Self.tokens(t.totalTokens)) tokens").font(DS.Typo.caption).foregroundStyle(DS.Colors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m).fill(DS.Colors.chipBg))
    }

    private func modelRow(_ m: ModelUsage) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(m.tier.label).font(DS.Typo.caption.weight(.medium)).frame(width: 70, alignment: .leading)
            Text("\(Self.tokens(m.totals.totalTokens)) tok").font(DS.Typo.monoMicro)
                .foregroundStyle(DS.Colors.tertiary)
            Spacer()
            Text(Self.money(m.totals.cost)).font(DS.Typo.monoCaption).foregroundStyle(DS.Colors.secondary)
        }
        .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(DS.Colors.chipBg.opacity(0.6)))
    }

    private func reload() {
        loading = true
        Task.detached(priority: .utility) {
            let entries = ClaudeUsageReader.scan()
            let s = UsageAggregator.summarize(entries, now: Date())
            await MainActor.run { summary = s; loading = false }
        }
    }

    // MARK: - Formatting

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
        return "\(n)"
    }

    static func money(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}
