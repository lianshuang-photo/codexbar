import CodexBarCore
import Foundation
import SQLite3
import Testing

struct OpenCodeLocalUsageScannerTests {
    // MARK: - Provider conformance

    @Test
    func `provider is opencode`() {
        #expect(OpenCodeLocalUsageScanner().provider == .opencode)
    }

    // MARK: - Empty filesystem

    @Test
    func `empty data root returns empty report`() throws {
        let root = try Self.makeEmptyRoot(label: "empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let report = OpenCodeLocalUsageScanner(dataRoot: root).loadDailyReport(
            since: Self.refDate(daysOffset: -7),
            until: Self.refDate(daysOffset: 7),
            now: Self.refDate(daysOffset: 0),
            options: LocalUsageScanOptions())

        #expect(report.data.isEmpty)
        #expect(report.summary == nil)
    }

    @Test
    func `nonexistent data root returns empty report`() {
        let bogus = URL(fileURLWithPath: "/var/empty/opencode-does-not-exist-\(UUID())")
        let report = OpenCodeLocalUsageScanner(dataRoot: bogus).loadDailyReport(
            since: Self.refDate(daysOffset: -7),
            until: Self.refDate(daysOffset: 7),
            now: Self.refDate(daysOffset: 0),
            options: LocalUsageScanOptions())

        #expect(report.data.isEmpty)
        #expect(report.summary == nil)
    }

    // MARK: - JSON message scan (fixture-based golden)

    @Test
    func `scans bundled per-message JSON fixtures into aggregated daily report`() throws {
        let fixtureRoot = try Self.openCodeFixtureRoot()

        let report = OpenCodeLocalUsageScanner(dataRoot: fixtureRoot).loadDailyReport(
            since: Date(timeIntervalSince1970: 1_775_000_000),
            until: Date(timeIntervalSince1970: 1_775_999_999),
            now: Date(timeIntervalSince1970: 1_776_000_000),
            options: LocalUsageScanOptions())

        // 3 messages survive (msg_001, msg_002 on day A; msg_003 on day B).
        // msg_004 is dropped (zero tokens), msg_005 is dropped (no providerID).
        let dayA = Self.expectedDayKey(timestampMs: 1_775_304_000_000)
        let dayB = Self.expectedDayKey(timestampMs: 1_775_390_400_000)

        let entryByDay: [String: CostUsageDailyReport.Entry] = Dictionary(
            uniqueKeysWithValues: report.data.map { ($0.date, $0) })

        let entryA = try #require(entryByDay[dayA])
        #expect(entryA.inputTokens == 1500)
        #expect(entryA.outputTokens == 2800)
        #expect(entryA.cacheReadTokens == 700)
        #expect(entryA.cacheCreationTokens == 150)
        #expect(entryA.totalTokens == 1500 + 2800 + 700 + 150)
        #expect(entryA.modelsUsed == ["claude-sonnet-4-5"])
        // Pre-computed costs sum: 0.012 + 0.005 = 0.017
        let costA = try #require(entryA.costUSD)
        #expect(abs(costA - 0.017) < 1e-9)

        let breakdownA = try #require(entryA.modelBreakdowns)
        #expect(breakdownA.count == 1)
        #expect(breakdownA[0].modelName == "claude-sonnet-4-5")
        #expect(breakdownA[0].totalTokens == 1500 + 2800 + 700 + 150)

        let entryB = try #require(entryByDay[dayB])
        #expect(entryB.inputTokens == 300)
        #expect(entryB.outputTokens == 600)
        #expect(entryB.cacheReadTokens == 0)
        #expect(entryB.cacheCreationTokens == 0)
        #expect(entryB.modelsUsed == ["gpt-5.1"])
        let costB = try #require(entryB.costUSD)
        #expect(abs(costB - 0.003) < 1e-9)

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == 1500 + 300)
        #expect(summary.totalOutputTokens == 2800 + 600)
        let totalCost = try #require(summary.totalCostUSD)
        #expect(abs(totalCost - 0.020) < 1e-9)
    }

    @Test
    func `since-until range filters out-of-range fixture days`() throws {
        let fixtureRoot = try Self.openCodeFixtureRoot()
        let dayA = Self.expectedDayKey(timestampMs: 1_775_304_000_000)

        // Only day A in range — pick `until` 8 minutes after day A's first
        // message timestamp so the dayKey lands on day A regardless of the
        // local time zone. Day B's timestamp (~24h later) lands on the next
        // dayKey in every timezone and must be filtered out.
        let report = OpenCodeLocalUsageScanner(dataRoot: fixtureRoot).loadDailyReport(
            since: Date(timeIntervalSince1970: 1_775_000_000),
            until: Date(timeIntervalSince1970: 1_775_304_500),
            now: Date(timeIntervalSince1970: 1_776_000_000),
            options: LocalUsageScanOptions())

        #expect(report.data.count == 1)
        #expect(report.data.first?.date == dayA)
    }

    // MARK: - SQLite fallback (programmatic golden)

    @Test
    func `falls back to SQLite when no JSON messages present`() throws {
        let root = try Self.makeEmptyRoot(label: "sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        // Generate a deterministic sample.db at <root>/opencode.db.
        let dbURL = root.appendingPathComponent("opencode.db")
        try Self.buildSampleSQLiteDB(at: dbURL, rows: [
            .init(
                messageId: "msg_sql_1",
                role: "assistant",
                timestampMs: 1_775_304_000_000,
                model: "claude-sonnet-4-5",
                input: 1000,
                output: 2000,
                cacheRead: 500,
                cacheWrite: 100),
            .init(
                messageId: "msg_sql_2",
                role: "assistant",
                timestampMs: 1_775_306_400_000,
                model: "claude-sonnet-4-5",
                input: 500,
                output: 800,
                cacheRead: 200,
                cacheWrite: 50),
            .init(
                messageId: "msg_sql_3",
                role: "assistant",
                timestampMs: 1_775_390_400_000,
                model: "gpt-5.1",
                input: 300,
                output: 600,
                cacheRead: 0,
                cacheWrite: 0),
            // role != assistant → should be excluded.
            .init(
                messageId: "msg_sql_user",
                role: "user",
                timestampMs: 1_775_304_000_000,
                model: "claude-sonnet-4-5",
                input: 99,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0),
            // total = 0 → excluded by WHERE clause.
            .init(
                messageId: "msg_sql_zero",
                role: "assistant",
                timestampMs: 1_775_304_000_000,
                model: "claude-sonnet-4-5",
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0),
        ])

        let report = OpenCodeLocalUsageScanner(dataRoot: root).loadDailyReport(
            since: Date(timeIntervalSince1970: 1_775_000_000),
            until: Date(timeIntervalSince1970: 1_775_999_999),
            now: Date(timeIntervalSince1970: 1_776_000_000),
            options: LocalUsageScanOptions())

        let dayA = Self.expectedDayKey(timestampMs: 1_775_304_000_000)
        let dayB = Self.expectedDayKey(timestampMs: 1_775_390_400_000)
        let byDay: [String: CostUsageDailyReport.Entry] = Dictionary(
            uniqueKeysWithValues: report.data.map { ($0.date, $0) })

        let entryA = try #require(byDay[dayA])
        #expect(entryA.inputTokens == 1500)
        #expect(entryA.outputTokens == 2800)
        #expect(entryA.cacheReadTokens == 700)
        #expect(entryA.cacheCreationTokens == 150)
        #expect(entryA.modelsUsed == ["claude-sonnet-4-5"])
        // SQLite path has no cost data → costUSD must be nil.
        #expect(entryA.costUSD == nil)

        let entryB = try #require(byDay[dayB])
        #expect(entryB.inputTokens == 300)
        #expect(entryB.outputTokens == 600)
        #expect(entryB.modelsUsed == ["gpt-5.1"])
        #expect(entryB.costUSD == nil)

        let summary = try #require(report.summary)
        #expect(summary.totalCostUSD == nil)
        #expect(summary.totalInputTokens == 1500 + 300)
        #expect(summary.totalOutputTokens == 2800 + 600)
    }

    @Test
    func `JSON path takes precedence over SQLite when both present`() throws {
        let fixtureRoot = try Self.openCodeFixtureRoot()
        let workRoot = try Self.makeEmptyRoot(label: "precedence")
        defer { try? FileManager.default.removeItem(at: workRoot) }

        // Copy the JSON fixture tree into workRoot.
        try FileManager.default.copyItem(
            at: fixtureRoot.appendingPathComponent("storage"),
            to: workRoot.appendingPathComponent("storage"))

        // Put a SQLite db alongside that, if read, would inflate totals.
        let dbURL = workRoot.appendingPathComponent("opencode.db")
        try Self.buildSampleSQLiteDB(at: dbURL, rows: [
            .init(
                messageId: "should_not_be_read",
                role: "assistant",
                timestampMs: 1_775_304_000_000,
                model: "claude-sonnet-4-5",
                input: 9_999_999,
                output: 9_999_999,
                cacheRead: 0,
                cacheWrite: 0),
        ])

        let report = OpenCodeLocalUsageScanner(dataRoot: workRoot).loadDailyReport(
            since: Date(timeIntervalSince1970: 1_775_000_000),
            until: Date(timeIntervalSince1970: 1_775_999_999),
            now: Date(timeIntervalSince1970: 1_776_000_000),
            options: LocalUsageScanOptions())

        let summary = try #require(report.summary)
        #expect(summary.totalInputTokens == 1500 + 300)
        #expect(summary.totalOutputTokens == 2800 + 600)
    }

    // MARK: - Sendable / cross-actor

    @Test
    func `scanner can be passed to a non-main actor and produce a report`() async throws {
        let root = try Self.makeEmptyRoot(label: "sendable")
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = OpenCodeLocalUsageScanner(dataRoot: root)
        let since = Self.refDate(daysOffset: -7)
        let until = Self.refDate(daysOffset: 7)
        let now = Self.refDate(daysOffset: 0)

        let actor = TestActor()
        let result = await actor.run(
            scanner: scanner,
            since: since,
            until: until,
            now: now)
        #expect(result.data.isEmpty)
    }

    // MARK: - Helpers

    private actor TestActor {
        func run(
            scanner: OpenCodeLocalUsageScanner,
            since: Date,
            until: Date,
            now: Date) -> CostUsageDailyReport
        {
            scanner.loadDailyReport(
                since: since,
                until: until,
                now: now,
                options: LocalUsageScanOptions())
        }
    }

    private static func refDate(daysOffset: Int) -> Date {
        let base = Date(timeIntervalSince1970: 1_775_304_000)
        return base.addingTimeInterval(TimeInterval(daysOffset) * 86400)
    }

    private static func expectedDayKey(timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1)
    }

    private static func makeEmptyRoot(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageScannerTests-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func openCodeFixtureRoot() throws -> URL {
        try #require(Bundle.module.url(
            forResource: "cli",
            withExtension: nil,
            subdirectory: "Fixtures/OpenCode"))
    }

    // MARK: - SQLite fixture builder

    fileprivate struct DBRow {
        let messageId: String
        let role: String
        let timestampMs: Int64
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
    }

    fileprivate enum DBBuildError: Error {
        case openFailed(String)
        case execFailed(String)
    }

    fileprivate static func buildSampleSQLiteDB(at url: URL, rows: [DBRow]) throws {
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil)
        guard openResult == SQLITE_OK else {
            let detail = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DBBuildError.openFailed(detail)
        }
        defer { sqlite3_close(db) }

        try self.exec(db: db, sql: "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL)")

        for row in rows {
            let total = row.input + row.output + row.cacheRead + row.cacheWrite
            let json: [String: Any] = [
                "id": row.messageId,
                "role": row.role,
                "modelID": row.model,
                "time": ["created": row.timestampMs],
                "tokens": [
                    "input": row.input,
                    "output": row.output,
                    "total": total,
                    "cache": [
                        "read": row.cacheRead,
                        "write": row.cacheWrite,
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            let dataString = String(bytes: data, encoding: .utf8) ?? ""
            try exec(
                db: db,
                sql: "INSERT INTO message (id, data) VALUES (\(quote(row.messageId)), \(self.quote(dataString)))")
        }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let detail = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DBBuildError.execFailed(detail)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
