import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import CodexBarCore

@Suite("CherryStudioLocalUsageScanner")
struct CherryStudioLocalUsageScannerTests {
    // MARK: - Sendable conformance

    @Test
    func conformsToLocalUsageScanner() {
        let scanner: any LocalUsageScanner = CherryStudioLocalUsageScanner()
        #expect(scanner.provider == .cherryStudio)
    }

    @Test
    func sendable() async {
        let scanner = CherryStudioLocalUsageScanner()
        await Task.detached {
            _ = scanner.provider
        }.value
    }

    // MARK: - Empty fixture

    @Test
    func emptyDataReturnsEmptyReport() throws {
        let workspace = try TempWorkspace()
        let scanner = CherryStudioLocalUsageScanner(configuration: workspace.configuration)
        let report = scanner.loadDailyReport(
            since: Self.day("2026-01-01"),
            until: Self.day("2026-12-31"),
            now: Date(),
            options: LocalUsageScanOptions())
        #expect(report.data.isEmpty)
        #expect(report.summary == nil)
    }

    // MARK: - Single day single model JSONL

    @Test
    func singleDaySingleModelJSONLGolden() throws {
        let workspace = try TempWorkspace()
        try workspace.installClaudeRuntimeFixture(name: "single-day-single-model.jsonl", projectName: "demo")
        let scanner = CherryStudioLocalUsageScanner(configuration: workspace.configuration)
        let report = scanner.loadDailyReport(
            since: Self.day("2026-04-01"),
            until: Self.day("2026-04-30"),
            now: Date(),
            options: LocalUsageScanOptions())

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2026-04-10")
        // msg-001 + msg-002 (msg-002 has a duplicate in the fixture; dedup
        // by message.id keeps only one). Expected aggregate tokens:
        //   input  = 1000 + 2000 = 3000
        //   output =  200 +  400 =  600
        //   cacheRead  = 500 + 1000 = 1500
        //   cacheCreate=   0 +  500 =  500
        //   total = input + output + cacheRead + cacheCreate = 5600
        #expect(entry.inputTokens == 3000)
        #expect(entry.outputTokens == 600)
        #expect(entry.cacheReadTokens == 1500)
        #expect(entry.cacheCreationTokens == 500)
        #expect(entry.totalTokens == 5600)
        // Sonnet 4.5 rates: input=3, output=15, cacheRead=0.3, cacheWrite=3.75
        // per million.
        // msg-001: netInput=500, cost = (500*3 + 200*15 + 0*3.75 + 500*0.3)/1e6 = 0.00465
        // msg-002: netInput=1000, cost = (1000*3 + 400*15 + 500*3.75 + 1000*0.3)/1e6 = 0.011175
        // sum = 0.015825 → roundCost preserves 6 decimals.
        #expect(entry.costUSD == 0.015825)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5"])
        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(breakdown.modelName == "claude-sonnet-4-5")
        #expect(breakdown.totalTokens == 5600)
        #expect(breakdown.costUSD == 0.015825)

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == 3000)
        #expect(summary.totalOutputTokens == 600)
        #expect(summary.cacheReadTokens == 1500)
        #expect(summary.cacheCreationTokens == 500)
        #expect(summary.totalTokens == 5600)
        #expect(summary.totalCostUSD == 0.015825)
    }

    // MARK: - Multi-day multi-model JSONL

    @Test
    func multiDayMultiModelJSONLGolden() throws {
        let workspace = try TempWorkspace()
        try workspace.installClaudeRuntimeFixture(name: "multi-day-multi-model.jsonl", projectName: "demo")
        let scanner = CherryStudioLocalUsageScanner(configuration: workspace.configuration)
        let report = scanner.loadDailyReport(
            since: Self.day("2026-04-01"),
            until: Self.day("2026-04-30"),
            now: Date(),
            options: LocalUsageScanOptions())

        #expect(report.data.count == 3)

        // Day 2026-04-09: opus only.
        // claude-opus-4-5 rates (5, 25, 0.5, 6.25). netInput=500.
        // cost = (500*5 + 100*25)/1e6 = 0.005.
        let d09 = try #require(report.data.first { $0.date == "2026-04-09" })
        #expect(d09.inputTokens == 500)
        #expect(d09.outputTokens == 100)
        #expect(d09.cacheReadTokens == 0)
        #expect(d09.cacheCreationTokens == 0)
        #expect(d09.totalTokens == 600)
        #expect(d09.costUSD == 0.005)
        #expect(d09.modelsUsed == ["claude-opus-4-5"])

        // Day 2026-04-10: sonnet + haiku.
        // Sonnet: input=1500, output=300, cacheRead=200, cacheCreate=100.
        //   netInput=1300, cost = (1300*3 + 300*15 + 100*3.75 + 200*0.3)/1e6 = 0.008835.
        //   total = 1500+300+200+100 = 2100.
        // Haiku-4-5 rates (1, 5, 0.1, 1.25). input=800, output=150.
        //   netInput=800, cost = (800*1 + 150*5)/1e6 = 0.00155.
        //   total = 950.
        let d10 = try #require(report.data.first { $0.date == "2026-04-10" })
        #expect(d10.inputTokens == 1500 + 800)
        #expect(d10.outputTokens == 300 + 150)
        #expect(d10.cacheReadTokens == 200)
        #expect(d10.cacheCreationTokens == 100)
        #expect(d10.totalTokens == 2100 + 950)
        #expect(d10.costUSD == 0.010385) // 0.008835 + 0.00155
        #expect(d10.modelsUsed == ["claude-haiku-4-5", "claude-sonnet-4-5"])
        // Breakdowns sorted by cost desc → sonnet first.
        let d10Breakdowns = try #require(d10.modelBreakdowns)
        #expect(d10Breakdowns.count == 2)
        #expect(d10Breakdowns[0].modelName == "claude-sonnet-4-5")
        #expect(d10Breakdowns[0].costUSD == 0.008835)
        #expect(d10Breakdowns[0].totalTokens == 2100)
        #expect(d10Breakdowns[1].modelName == "claude-haiku-4-5")
        #expect(d10Breakdowns[1].costUSD == 0.00155)
        #expect(d10Breakdowns[1].totalTokens == 950)

        // Day 2026-04-11: sonnet + unknown model.
        // Sonnet: input=3000, output=600, cacheRead=1500, cacheCreate=750.
        //   netInput=1500, cost = (1500*3 + 600*15 + 750*3.75 + 1500*0.3)/1e6
        //                       = (4500 + 9000 + 2812.5 + 450)/1e6 = 0.0167625
        //   roundCost(0.0167625) = round(16762.5)/1e6 = 16763/1e6 = 0.016763 (away from zero).
        //   total = 5850.
        // Unknown model: no entry in priceTable → cost=0, mode="unknown-model".
        //   total = 150, all input/output only.
        let d11 = try #require(report.data.first { $0.date == "2026-04-11" })
        #expect(d11.inputTokens == 3000 + 100)
        #expect(d11.outputTokens == 600 + 50)
        #expect(d11.cacheReadTokens == 1500)
        #expect(d11.cacheCreationTokens == 750)
        #expect(d11.totalTokens == 5850 + 150)
        #expect(d11.costUSD == 0.016763)
        #expect(d11.modelsUsed == ["claude-sonnet-4-5", "some-unknown-model"])
        let d11Breakdowns = try #require(d11.modelBreakdowns)
        #expect(d11Breakdowns.count == 2)
        #expect(d11Breakdowns[0].modelName == "claude-sonnet-4-5")
        #expect(d11Breakdowns[0].costUSD == 0.016763)
        #expect(d11Breakdowns[1].modelName == "some-unknown-model")
        #expect(d11Breakdowns[1].costUSD == 0)

        // Summary sums rounded daily totals.
        // 0.005 + 0.010385 + 0.016763 = 0.032148.
        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == 500 + 2300 + 3100)
        #expect(summary.totalOutputTokens == 100 + 450 + 650)
        #expect(summary.cacheReadTokens == 0 + 200 + 1500)
        #expect(summary.cacheCreationTokens == 0 + 100 + 750)
        #expect(summary.totalTokens == 600 + 3050 + 6000)
        #expect(summary.totalCostUSD == 0.032148)
    }

    // MARK: - SQLite agent DB

    #if canImport(SQLite3)
    @Test
    func agentDBProducesBillableRows() throws {
        let workspace = try TempWorkspace()
        try workspace.installAgentsDB(
            relativePath: "agents.db",
            sessionMessages: [
                .init(
                    role: "assistant",
                    createdAt: "2026-04-10T01:00:00Z",
                    content: #"""
                    {
                      "message": {
                        "role": "assistant",
                        "createdAt": "2026-04-10T01:00:00Z",
                        "model": {"provider": "x-express-internal", "id": "claude-sonnet-4-5"},
                        "usage": {"prompt_tokens": 1000, "completion_tokens": 200, "total_tokens": 1200},
                        "providerMetadata": {"costUsd": 0.042}
                      }
                    }
                    """#),
                .init(
                    role: "user",
                    createdAt: "2026-04-10T00:59:59Z",
                    content: #"""
                    {
                      "message": {
                        "role": "user",
                        "createdAt": "2026-04-10T00:59:59Z",
                        "usage": {"prompt_tokens": 50}
                      }
                    }
                    """#),
            ])

        let scanner = CherryStudioLocalUsageScanner(configuration: workspace.configuration)
        let report = scanner.loadDailyReport(
            since: Self.day("2026-04-01"),
            until: Self.day("2026-04-30"),
            now: Date(),
            options: LocalUsageScanOptions())

        // Only the assistant row is billable. user rows go to userEstimate
        // and don't make it into the daily LocalRow stream.
        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2026-04-10")
        #expect(entry.inputTokens == 1000)
        #expect(entry.outputTokens == 200)
        #expect(entry.totalTokens == 1200)
        // metaCost=0.042 → costMode "direct", cost = 0.042 directly.
        #expect(entry.costUSD == 0.042)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5"])
    }
    #endif

    // MARK: - Date filter

    @Test
    func filtersOutsideSinceUntilWindow() throws {
        let workspace = try TempWorkspace()
        try workspace.installClaudeRuntimeFixture(name: "multi-day-multi-model.jsonl", projectName: "demo")
        let scanner = CherryStudioLocalUsageScanner(configuration: workspace.configuration)
        // Only day 2026-04-10 should be retained.
        let report = scanner.loadDailyReport(
            since: Self.day("2026-04-10"),
            until: Self.day("2026-04-10"),
            now: Date(),
            options: LocalUsageScanOptions())
        #expect(report.data.count == 1)
        #expect(report.data.first?.date == "2026-04-10")
    }

    // MARK: - Pure-function unit checks (these don't need fixtures)

    @Test
    func normalizeModel_lowercases_stripsDots_andDateSuffix() {
        #expect(CherryStudioLocalUsageScanner.normalizeModel("Claude-Sonnet-4.5-20251101")
            == "claude-sonnet-4-5")
        #expect(CherryStudioLocalUsageScanner.normalizeModel("anthropic/claude-opus-4-5")
            == "claude-opus-4-5")
        #expect(CherryStudioLocalUsageScanner.normalizeModel("openai/gpt-5.1@latest")
            == "gpt-5-1")
        #expect(CherryStudioLocalUsageScanner.normalizeModel(nil) == "unknown")
        #expect(CherryStudioLocalUsageScanner.normalizeModel("") == "unknown")
    }

    @Test
    func computeRuntimeCost_unknownModel_returnsZero() {
        let result = CherryStudioLocalUsageScanner.computeRuntimeCost(
            input: 100,
            output: 50,
            cacheRead: 10,
            cacheCreate: 5,
            model: "not-a-real-model")
        #expect(result.cost == 0)
        #expect(result.mode == "unknown-model")
        #expect(result.pricingModel == nil)
        #expect(result.normalizedModel == "not-a-real-model")
    }

    @Test
    func computeRuntimeCost_knownModel_appliesPerMillionRates() {
        let result = CherryStudioLocalUsageScanner.computeRuntimeCost(
            input: 1000,
            output: 200,
            cacheRead: 500,
            cacheCreate: 0,
            model: "claude-sonnet-4-5")
        // netInput = 500, cost = (500*3 + 200*15 + 0 + 500*0.3)/1e6 = 0.00465.
        #expect(result.cost == 0.00465)
        #expect(result.netInput == 500)
        #expect(result.mode == "myccusage-fillMissingCost")
        #expect(result.normalizedModel == "claude-sonnet-4-5")
    }

    @Test
    func roundCost_clampsToSixDecimals() {
        #expect(CherryStudioLocalUsageScanner.roundCost(0.123456789) == 0.123457)
        #expect(CherryStudioLocalUsageScanner.roundCost(0.0167625) == 0.016763)
        #expect(CherryStudioLocalUsageScanner.roundCost(0) == 0)
    }

    // MARK: - Helpers

    private static func day(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso) ?? Date()
    }
}

// MARK: - Workspace helper

private struct TempWorkspace {
    let root: URL
    let appName: String = "CherryStudioTest"
    let appDataDir: URL

    init() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CherryStudioScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.root = tmp
        self.appDataDir = tmp.appendingPathComponent(self.appName, isDirectory: true)
        try FileManager.default.createDirectory(at: self.appDataDir, withIntermediateDirectories: true)
    }

    var configuration: CherryStudioLocalUsageScanner.Configuration {
        CherryStudioLocalUsageScanner.Configuration(
            appNames: [self.appName],
            supportBaseOverride: self.root,
            extraAppDataDirs: [])
    }

    func installClaudeRuntimeFixture(name: String, projectName: String) throws {
        let src = try #require(Bundle.module.url(
            forResource: name.replacingOccurrences(of: ".jsonl", with: ""),
            withExtension: "jsonl",
            subdirectory: "Fixtures/CherryStudio"))
        let projects = self.appDataDir
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let dst = projects.appendingPathComponent("usage.jsonl")
        try FileManager.default.copyItem(at: src, to: dst)
    }

    struct AgentMessage {
        let role: String
        let createdAt: String
        let content: String
    }

    #if canImport(SQLite3)
    /// Builds a tiny `session_messages` SQLite DB inside the app data dir.
    /// Mirrors the columns TS `summarizeAgentDb` reads.
    func installAgentsDB(relativePath: String, sessionMessages: [AgentMessage]) throws {
        let dbURL = self.appDataDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var db: OpaquePointer?
        precondition(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let create = """
        CREATE TABLE session_messages (
          id INTEGER PRIMARY KEY,
          role TEXT,
          created_at TEXT,
          content TEXT
        );
        """
        var err: UnsafeMutablePointer<CChar>?
        precondition(
            sqlite3_exec(db, create, nil, nil, &err) == SQLITE_OK,
            "create failed: \(err.map { String(cString: $0) } ?? "?")")
        for message in sessionMessages {
            var stmt: OpaquePointer?
            precondition(sqlite3_prepare_v2(
                db,
                "INSERT INTO session_messages (role, created_at, content) VALUES (?, ?, ?)",
                -1,
                &stmt,
                nil) == SQLITE_OK)
            sqlite3_bind_text(stmt, 1, message.role, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, message.createdAt, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, message.content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            precondition(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }
    #endif
}

/// Provides #require visibility from Bundle.module.
extension TempWorkspace {
    private func bundleResource(name: String, ext: String, subdir: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir))
    }
}
