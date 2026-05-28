import Testing
import Foundation
@testable import Termy

/// The pure usage core behind the Claude Usage panel: model→tier mapping,
/// cost math, time-window aggregation, dedupe, and JSONL line parsing.
struct ClaudeUsageTests {

    @Test func modelTierMapping() {
        #expect(ModelTier.from("claude-opus-4-20250101") == .opus)
        #expect(ModelTier.from("claude-sonnet-4-5") == .sonnet)
        #expect(ModelTier.from("claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelTier.from("gpt-4o") == .unknown)
    }

    @Test func costMathMatchesPriceTable() {
        // 1M output tokens on Opus = $75.
        #expect(abs(UsagePricing.cost(model: "claude-opus-4", input: 0, output: 1_000_000,
                                      cacheWrite: 0, cacheRead: 0) - 75.0) < 0.0001)
        // 1M input on Sonnet = $3; 1M cache-read on Sonnet = $0.30.
        #expect(abs(UsagePricing.cost(model: "claude-sonnet-4", input: 1_000_000, output: 0,
                                      cacheWrite: 0, cacheRead: 1_000_000) - 3.30) < 0.0001)
    }

    private func entry(_ daysAgo: Int, model: String, output: Int, key: String,
                       now: Date) -> ClaudeUsageEntry {
        let ts = Calendar.current.date(byAdding: .day, value: -daysAgo,
                                       to: Calendar.current.startOfDay(for: now))!
            .addingTimeInterval(3600)   // mid-day so it's safely within the day bucket
        return ClaudeUsageEntry(timestamp: ts, model: model, input: 0, output: output,
                                cacheWrite: 0, cacheRead: 0, dedupeKey: key)
    }

    @Test func aggregationWindowsTodaySevenAll() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)  // fixed reference
        let entries = [
            entry(0, model: "claude-opus-4", output: 1_000_000, key: "a", now: now),    // today
            entry(3, model: "claude-sonnet-4", output: 1_000_000, key: "b", now: now),  // within 7d
            entry(30, model: "claude-haiku-4", output: 1_000_000, key: "c", now: now),  // old
        ]
        let s = UsageAggregator.summarize(entries, now: now)
        #expect(s.today.output == 1_000_000)
        #expect(s.last7.output == 2_000_000)   // today + 3-days-ago
        #expect(s.allTime.output == 3_000_000)
        // Opus today = $75.
        #expect(abs(s.today.cost - 75.0) < 0.001)
    }

    @Test func dedupeDropsDuplicateMessageTurns() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let entries = [
            entry(0, model: "claude-opus-4", output: 500_000, key: "msg1:req1", now: now),
            entry(0, model: "claude-opus-4", output: 500_000, key: "msg1:req1", now: now), // dup
        ]
        let s = UsageAggregator.summarize(entries, now: now)
        #expect(s.allTime.output == 500_000)   // counted once
    }

    @Test func byModelSortedByCostDescending() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let entries = [
            entry(0, model: "claude-haiku-4", output: 1_000_000, key: "h", now: now),  // $5
            entry(0, model: "claude-opus-4", output: 1_000_000, key: "o", now: now),   // $75
        ]
        let s = UsageAggregator.summarize(entries, now: now)
        #expect(s.byModel.first?.tier == .opus)   // most expensive first
    }

    @Test func parseLineExtractsAssistantUsage() {
        let line = #"{"type":"assistant","timestamp":"2026-01-02T03:04:05.000Z","requestId":"req_x","message":{"id":"msg_y","model":"claude-opus-4-1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#
        let e = ClaudeUsageReader.parseLine(line, file: "f.jsonl", lineNo: 1)
        #expect(e != nil)
        #expect(e?.output == 20)
        #expect(e?.cacheRead == 100)
        #expect(e?.dedupeKey == "msg_y:req_x")
        #expect(ModelTier.from(e?.model ?? "") == .opus)
    }

    @Test func parseLineSkipsNonAssistantAndEmptyUsage() {
        #expect(ClaudeUsageReader.parseLine(#"{"type":"user","message":{}}"#, file: "f", lineNo: 1) == nil)
        #expect(ClaudeUsageReader.parseLine("not json", file: "f", lineNo: 2) == nil)
        let zero = #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        #expect(ClaudeUsageReader.parseLine(zero, file: "f", lineNo: 3) == nil)
    }
}
