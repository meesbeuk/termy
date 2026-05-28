import Foundation

/// One assistant turn's token usage, parsed from a Claude Code transcript
/// line (`~/.claude/projects/**/*.jsonl`). The same data ccusage reads — but
/// natively, with no Node dependency.
struct ClaudeUsageEntry: Equatable {
    let timestamp: Date
    let model: String
    let input: Int
    let output: Int
    let cacheWrite: Int       // cache_creation_input_tokens
    let cacheRead: Int        // cache_read_input_tokens
    /// `<messageId>:<requestId>` — Claude logs the same turn twice when a
    /// session is resumed/branched; dedupe on this so totals aren't doubled.
    let dedupeKey: String
}

/// Model families Claude Code reports, mapped from the model string.
enum ModelTier: String, CaseIterable {
    case opus, sonnet, haiku, unknown

    static func from(_ model: String) -> ModelTier {
        let m = model.lowercased()
        if m.contains("opus") { return .opus }
        if m.contains("sonnet") { return .sonnet }
        if m.contains("haiku") { return .haiku }
        return .unknown
    }

    var label: String {
        switch self {
        case .opus: return "Opus"; case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"; case .unknown: return "Other"
        }
    }
}

/// USD per million tokens. Cost is an ESTIMATE — prices drift, so the UI
/// labels it "est." Cache-write is the 5-minute write rate; cache-read is the
/// big discount that makes Claude Code economical.
struct ModelPrice { let input, output, cacheWrite, cacheRead: Double }

enum UsagePricing {
    static func price(for tier: ModelTier) -> ModelPrice {
        switch tier {
        case .opus:    return ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        case .sonnet:  return ModelPrice(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.30)
        case .haiku:   return ModelPrice(input: 1,  output: 5,  cacheWrite: 1.25,  cacheRead: 0.10)
        case .unknown: return ModelPrice(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.30)
        }
    }

    static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let p = price(for: .from(model))
        let m = 1_000_000.0
        return Double(input) / m * p.input
             + Double(output) / m * p.output
             + Double(cacheWrite) / m * p.cacheWrite
             + Double(cacheRead) / m * p.cacheRead
    }
}

/// Running totals for a time window or a model.
struct UsageTotals: Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var cost = 0.0

    var totalTokens: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ e: ClaudeUsageEntry) {
        input += e.input; output += e.output
        cacheWrite += e.cacheWrite; cacheRead += e.cacheRead
        cost += UsagePricing.cost(model: e.model, input: e.input, output: e.output,
                                  cacheWrite: e.cacheWrite, cacheRead: e.cacheRead)
    }
}

struct ModelUsage: Equatable { let tier: ModelTier; let totals: UsageTotals }

struct UsageSummary: Equatable {
    var today = UsageTotals()
    var last7 = UsageTotals()
    var allTime = UsageTotals()
    var byModel: [ModelUsage] = []
    var sessionCount = 0
}

/// Pure aggregation: dedupe by message/request id, then bucket into
/// today / last-7-days / all-time and per-model. `now` is injected so the
/// windowing is deterministic in tests.
enum UsageAggregator {
    static func summarize(_ entries: [ClaudeUsageEntry], now: Date,
                          calendar: Calendar = .current) -> UsageSummary {
        var seen = Set<String>()
        var unique: [ClaudeUsageEntry] = []
        unique.reserveCapacity(entries.count)
        for e in entries where seen.insert(e.dedupeKey).inserted { unique.append(e) }

        let startToday = calendar.startOfDay(for: now)
        // "Last 7 days" = today + the 6 prior days.
        let start7 = calendar.date(byAdding: .day, value: -6, to: startToday) ?? startToday

        var s = UsageSummary()
        var byTier: [ModelTier: UsageTotals] = [:]
        for e in unique {
            s.allTime.add(e)
            if e.timestamp >= startToday { s.today.add(e) }
            if e.timestamp >= start7 { s.last7.add(e) }
            byTier[ModelTier.from(e.model), default: UsageTotals()].add(e)
        }
        s.byModel = byTier
            .map { ModelUsage(tier: $0.key, totals: $0.value) }
            .sorted { $0.totals.cost > $1.totals.cost }
        return s
    }
}
