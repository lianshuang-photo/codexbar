import Foundation
import Testing
@testable import CodexBarCore

/// Parity tests verifying that codexbar's local Claude and Codex usage scanners
/// produce token / cost numbers that match the ccusage upstream CLI on the same
/// fixtures. Tokens are compared exactly; cost is compared within a 0.01% band
/// to absorb floating-point noise from pricing-table representations.
///
/// ccusage upstream version used to regenerate the golden files: 18.0.11
/// (commands recorded inside each golden JSON file).
struct CCUsageParityTests {
    private struct ClaudeGolden: Decodable {
        let ccusageVersion: String
        let date: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let totalCostUSD: Double
    }

    private struct CodexGolden: Decodable {
        let ccusageVersion: String
        let date: String
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let totalCostUSD: Double
    }

    /// Cost tolerance: relative 0.01% (1e-4) — see PR description for rationale.
    private static let costRelativeTolerance: Double = 1e-4

    @Test
    func `claude scanner matches ccusage upstream daily numbers`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fixtureURL = try Self.fixtureURL(name: "claude-fixture", ext: "jsonl")
        let fixtureContents = try String(contentsOf: fixtureURL, encoding: .utf8)
        _ = try env.writeClaudeProjectFile(
            relativePath: "parity-fixture/session.jsonl",
            contents: fixtureContents)

        let golden = try Self.loadGolden(ClaudeGolden.self, name: "claude-golden")
        let day = try Self.parseDayUTCNoon(golden.date)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        try #require(report.data.count == 1, "expected exactly one daily entry, got \(report.data.count)")
        let entry = report.data[0]

        #expect(entry.date == golden.date)
        #expect(entry.inputTokens == golden.inputTokens, "claude inputTokens diverged")
        #expect(entry.outputTokens == golden.outputTokens, "claude outputTokens diverged")
        #expect(entry.cacheCreationTokens == golden.cacheCreationTokens, "claude cacheCreationTokens diverged")
        #expect(entry.cacheReadTokens == golden.cacheReadTokens, "claude cacheReadTokens diverged")
        #expect(entry.totalTokens == golden.totalTokens, "claude totalTokens diverged")

        let actualCost = try #require(entry.costUSD, "claude costUSD missing")
        #expect(
            Self.costsMatch(actual: actualCost, golden: golden.totalCostUSD),
            "claude cost \(actualCost) outside tolerance of golden \(golden.totalCostUSD)")

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == golden.inputTokens)
        #expect(summary.totalOutputTokens == golden.outputTokens)
        #expect(summary.cacheCreationTokens == golden.cacheCreationTokens)
        #expect(summary.cacheReadTokens == golden.cacheReadTokens)
        #expect(summary.totalTokens == golden.totalTokens)
        let summaryCost = try #require(summary.totalCostUSD)
        #expect(Self.costsMatch(actual: summaryCost, golden: golden.totalCostUSD))
    }

    @Test
    func `codex scanner matches ccusage upstream daily numbers`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fixtureURL = try Self.fixtureURL(name: "codex-fixture", ext: "jsonl")
        let fixtureContents = try String(contentsOf: fixtureURL, encoding: .utf8)
        let golden = try Self.loadGolden(CodexGolden.self, name: "codex-golden")
        let day = try Self.parseDayUTCNoon(golden.date)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2025-10-15T12-00-00-parity-codex-session.jsonl",
            contents: fixtureContents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        try #require(report.data.count == 1, "expected exactly one daily entry, got \(report.data.count)")
        let entry = report.data[0]

        // codexbar's codex report exposes inputTokens that already include cached
        // (raw input_tokens from the upstream payload), matching ccusage upstream.
        #expect(entry.date == golden.date)
        #expect(entry.inputTokens == golden.inputTokens, "codex inputTokens diverged")
        #expect(entry.outputTokens == golden.outputTokens, "codex outputTokens diverged")

        // Total tokens: codexbar excludes cached/reasoning from total (input + output);
        // ccusage upstream's totalTokens with input+output for legacy logs is the same here
        // because reasoning_output_tokens is 0 and we emit no extra cached charge in total.
        let expectedTotal = golden.inputTokens + golden.outputTokens
        #expect(entry.totalTokens == expectedTotal, "codex totalTokens diverged")
        #expect(golden.totalTokens == expectedTotal, "golden totalTokens inconsistency")

        let actualCost = try #require(entry.costUSD, "codex costUSD missing")
        #expect(
            Self.costsMatch(actual: actualCost, golden: golden.totalCostUSD),
            "codex cost \(actualCost) outside tolerance of golden \(golden.totalCostUSD)")

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == golden.inputTokens)
        #expect(summary.totalOutputTokens == golden.outputTokens)
        #expect(summary.totalTokens == expectedTotal)
        let summaryCost = try #require(summary.totalCostUSD)
        #expect(Self.costsMatch(actual: summaryCost, golden: golden.totalCostUSD))
    }

    // MARK: - Helpers

    private static func costsMatch(actual: Double, golden: Double) -> Bool {
        if actual == golden { return true }
        let denom = max(abs(golden), 1e-9)
        return abs(actual - golden) / denom <= self.costRelativeTolerance
    }

    private static func fixtureURL(name: String, ext: String) throws -> URL {
        try #require(Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Fixtures/CCUsageParity"))
    }

    private static func loadGolden<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let url = try self.fixtureURL(name: name, ext: "json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Parse YYYY-MM-DD into a Date positioned at noon UTC so that any local
    /// timezone the host machine uses still resolves the same calendar day.
    private static func parseDayUTCNoon(_ key: String) throws -> Date {
        let parts = key.split(separator: "-")
        try #require(parts.count == 3, "invalid day key \(key)")
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw NSError(domain: "CCUsageParityTests", code: 1)
        }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        guard let date = comps.date else { throw NSError(domain: "CCUsageParityTests", code: 2) }
        return date
    }
}
