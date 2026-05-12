import CodexBarCore
import Foundation
import Testing

@Suite("OpenClawLocalUsageScanner")
struct OpenClawLocalUsageScannerTests {
    // MARK: - Scanner provider + Sendable

    @Test
    func `provider id is openclaw`() {
        let scanner = OpenClawLocalUsageScanner(homeOverride: URL(fileURLWithPath: "/tmp/none"))
        #expect(scanner.provider == .openclaw)
    }

    @Test
    func `scanner is Sendable and can cross actor boundaries`() async {
        let scanner = OpenClawLocalUsageScanner(homeOverride: URL(fileURLWithPath: "/tmp/none"))
        await Task.detached { _ = scanner.provider }.value
    }

    // MARK: - Fixture: empty home

    @Test
    func `empty home produces empty report`() throws {
        let home = try Self.fixtureHome("empty-home")
        let scanner = OpenClawLocalUsageScanner(
            homeOverride: home,
            environment: [:])
        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())
        #expect(report.data.isEmpty)
        #expect(report.summary == nil)
    }

    @Test
    func `missing home directory produces empty report`() {
        let nonexistent = URL(fileURLWithPath: "/tmp/openclaw-test-does-not-exist-\(UUID().uuidString)")
        let scanner = OpenClawLocalUsageScanner(homeOverride: nonexistent, environment: [:])
        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())
        #expect(report.data.isEmpty)
    }

    // MARK: - Fixture: one record

    @Test
    func `one record produces single day with expected tokens`() throws {
        let home = try Self.fixtureHome("one-record")
        let scanner = OpenClawLocalUsageScanner(homeOverride: home, environment: [:])

        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2026-04-10")
        #expect(entry.inputTokens == 1000)
        #expect(entry.outputTokens == 500)
        #expect(entry.cacheReadTokens == 0)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.totalTokens == 1500)
        #expect(entry.modelsUsed == ["gpt-5"])

        // gpt-5 pricing: input perM(1.25), output perM(10.00)
        let expectedInputCost = 1000.0 * (1.25 / 1_000_000.0)
        let expectedOutputCost = 500.0 * (10.00 / 1_000_000.0)
        let expectedCost = expectedInputCost + expectedOutputCost
        #expect(abs((entry.costUSD ?? 0) - expectedCost) < 1e-9)

        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-5")
        #expect(breakdown.totalTokens == 1500)
        #expect(abs((breakdown.costUSD ?? 0) - expectedCost) < 1e-9)

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == 1000)
        #expect(summary.totalOutputTokens == 500)
        #expect(summary.totalTokens == 1500)
        #expect(abs((summary.totalCostUSD ?? 0) - expectedCost) < 1e-9)
    }

    // MARK: - Fixture: multi-model (golden output)

    @Test
    func `multi model record aggregates per model and skips invalid entries`() throws {
        let home = try Self.fixtureHome("multi-model")
        let scanner = OpenClawLocalUsageScanner(homeOverride: home, environment: [:])

        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2026-04-15")
        // user role + delivery-mirror + summary type should all be skipped.
        // Remaining: 2 claude-opus-4-6 messages + 1 minimax-m2.5
        #expect(entry.inputTokens == 2000 + 1000 + 500)
        #expect(entry.outputTokens == 800 + 400 + 250)
        #expect(entry.cacheReadTokens == 100 + 50)
        #expect(entry.cacheCreationTokens == 200)
        #expect(entry.totalTokens == 3100 + 1450 + 750)

        let models = try #require(entry.modelsUsed).sorted()
        #expect(models == ["claude-opus-4-6", "minimax-m2.5"])

        let breakdowns = try #require(entry.modelBreakdowns)
        let claude = try #require(breakdowns.first(where: { $0.modelName == "claude-opus-4-6" }))
        let mm = try #require(breakdowns.first(where: { $0.modelName == "minimax-m2.5" }))

        // claude-opus-4-6: input 3000, output 1200, cacheRead 150, cacheWrite 200
        // pricing: input 5.00/M, output 25.00/M, cacheRead 0.50/M, cacheCreation 6.25/M
        let claudeInputCost = 3000.0 * (5.00 / 1_000_000.0)
        let claudeOutputCost = 1200.0 * (25.00 / 1_000_000.0)
        let claudeCacheReadCost = 150.0 * (0.50 / 1_000_000.0)
        let claudeCacheCreateCost = 200.0 * (6.25 / 1_000_000.0)
        let claudeCost = claudeInputCost + claudeOutputCost + claudeCacheReadCost + claudeCacheCreateCost
        #expect(abs((claude.costUSD ?? 0) - claudeCost) < 1e-9)
        #expect(claude.totalTokens == 3000 + 1200 + 150 + 200)

        // minimax-m2.5: input 500, output 250
        // pricing: input 0.30/M, output 1.20/M, cacheRead 0.03/M, cacheCreation 0
        let mmInputCost = 500.0 * (0.30 / 1_000_000.0)
        let mmOutputCost = 250.0 * (1.20 / 1_000_000.0)
        let mmCost = mmInputCost + mmOutputCost
        #expect(abs((mm.costUSD ?? 0) - mmCost) < 1e-9)
        #expect(mm.totalTokens == 750)

        let summary = try #require(report.summary)
        #expect(abs((summary.totalCostUSD ?? 0) - (claudeCost + mmCost)) < 1e-9)
    }

    // MARK: - Fixture: cross-day (embedded cost + malformed lines)

    @Test
    func `cross day fixture produces sorted distinct day entries`() throws {
        let home = try Self.fixtureHome("cross-day")
        let scanner = OpenClawLocalUsageScanner(homeOverride: home, environment: [:])

        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())

        #expect(report.data.map(\.date) == ["2026-04-20", "2026-04-21", "2026-04-22"])

        let d20 = try #require(report.data.first(where: { $0.date == "2026-04-20" }))
        // Embedded cost.total preferred.
        #expect(abs((d20.costUSD ?? 0) - 0.0125) < 1e-9)
        let d21 = try #require(report.data.first(where: { $0.date == "2026-04-21" }))
        #expect(abs((d21.costUSD ?? 0) - 0.025) < 1e-9)

        // d22 had embedded cost.total = 0 → falls back to pricing table (gpt-5)
        let d22 = try #require(report.data.first(where: { $0.date == "2026-04-22" }))
        let expected22Input = 500.0 * (1.25 / 1_000_000.0)
        let expected22Output = 200.0 * (10.00 / 1_000_000.0)
        let expected22 = expected22Input + expected22Output
        #expect(abs((d22.costUSD ?? 0) - expected22) < 1e-9)
    }

    // MARK: - Range filtering

    @Test
    func `since until window excludes earlier days`() throws {
        let home = try Self.fixtureHome("cross-day")
        let scanner = OpenClawLocalUsageScanner(homeOverride: home, environment: [:])

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = try #require(iso.date(from: "2026-04-21T00:00:00.000Z"))
        let until = try #require(iso.date(from: "2026-04-23T00:00:00.000Z"))

        let report = scanner.loadDailyReport(
            since: since,
            until: until,
            now: until,
            options: LocalUsageScanOptions())

        #expect(report.data.map(\.date) == ["2026-04-21", "2026-04-22"])
    }

    // MARK: - Pricing lookup edge cases

    @Test
    func `pricing lookup strips provider prefix`() {
        let pricing = OpenClawPricing.findPricing(
            OpenClawPricing.officialPricing,
            rawModel: "anthropic/claude-opus-4-6")
        #expect(pricing != nil)
        #expect(pricing?.inputCostPerToken == 5.00 / 1_000_000)
    }

    @Test
    func `pricing lookup is case insensitive`() {
        let pricing = OpenClawPricing.findPricing(
            OpenClawPricing.officialPricing,
            rawModel: "OpenAI/GPT-5")
        #expect(pricing != nil)
    }

    @Test
    func `pricing lookup returns nil for unknown model`() {
        let pricing = OpenClawPricing.findPricing(
            OpenClawPricing.officialPricing,
            rawModel: "totally-unknown-model-xyz")
        #expect(pricing == nil)
    }

    @Test
    func `OPENCLAW_HOME environment variable resolves`() throws {
        let home = try Self.fixtureHome("one-record")
        let scanner = OpenClawLocalUsageScanner(
            homeOverride: nil,
            environment: ["OPENCLAW_HOME": home.path])

        let report = scanner.loadDailyReport(
            since: Self.dateRangeStart,
            until: Self.dateRangeEnd,
            now: Self.dateRangeEnd,
            options: LocalUsageScanOptions())

        #expect(report.data.count == 1)
    }

    // MARK: - Helpers

    private static let dateRangeStart: Date = {
        let iso = ISO8601DateFormatter()
        return iso.date(from: "2026-01-01T00:00:00Z") ?? Date(timeIntervalSince1970: 0)
    }()

    private static let dateRangeEnd: Date = {
        let iso = ISO8601DateFormatter()
        return iso.date(from: "2026-12-31T23:59:59Z") ?? Date()
    }()

    /// Resolves a fixture sub-tree under `Tests/CodexBarTests/Fixtures/OpenClaw/<name>` from the
    /// test bundle. Each subtree mimics `$OPENCLAW_HOME` (with an `agents/` directory inside).
    private static func fixtureHome(_ name: String) throws -> URL {
        let resourceURL = try #require(Bundle.module.resourceURL)
        return resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("OpenClaw", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
