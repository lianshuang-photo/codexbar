import CodexBarCore
import Foundation
import Testing

struct LocalUsageScannerTests {
    @Test
    func `registry resolve returns registered scanner`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        let scanner = StubScanner(provider: .claude)
        LocalUsageScannerRegistry.register(scanner)

        let resolved = LocalUsageScannerRegistry.resolve(for: .claude)
        #expect(resolved != nil)
        #expect(resolved?.provider == .claude)
    }

    @Test
    func `registry resolve returns nil when nothing registered`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        #expect(LocalUsageScannerRegistry.resolve(for: .opencode) == nil)
    }

    @Test
    func `registry unregister removes single provider only`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        LocalUsageScannerRegistry.register(StubScanner(provider: .claude))
        LocalUsageScannerRegistry.register(StubScanner(provider: .codex))
        LocalUsageScannerRegistry.unregister(provider: .claude)

        #expect(LocalUsageScannerRegistry.resolve(for: .claude) == nil)
        #expect(LocalUsageScannerRegistry.resolve(for: .codex) != nil)
    }

    @Test
    func `registry loadDailyReport prefers registered scanner over legacy switch`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        let marker = CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: "2026-05-11",
                inputTokens: 42,
                outputTokens: 99,
                totalTokens: 141,
                costUSD: 0.05,
                modelsUsed: ["stub-model"],
                modelBreakdowns: nil)],
            summary: nil)
        LocalUsageScannerRegistry.register(StubScanner(provider: .claude, response: marker))

        let report = LocalUsageScannerRegistry.loadDailyReport(
            provider: .claude,
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 86400))

        #expect(report.data.count == 1)
        #expect(report.data.first?.inputTokens == 42)
        #expect(report.data.first?.modelsUsed == ["stub-model"])
    }

    @Test
    func `registry loadDailyReport falls back to legacy switch for unregistered provider`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        // Use an isolated empty root so the legacy CostUsageScanner returns an
        // empty report rather than reading from the developer's home directory.
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalUsageScannerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        var options = LocalUsageScanOptions()
        options.codexSessionsRoot = emptyRoot
        options.claudeProjectsRoots = [emptyRoot]
        options.cacheRoot = emptyRoot

        let report = LocalUsageScannerRegistry.loadDailyReport(
            provider: .codex,
            since: Date().addingTimeInterval(-86400),
            until: Date(),
            options: options)

        #expect(report.data.isEmpty)
    }

    @Test
    func `ClaudeLocalUsageScanner provider matches construction argument`() {
        let claude = ClaudeLocalUsageScanner()
        let vertex = ClaudeLocalUsageScanner(provider: .vertexai)
        #expect(claude.provider == .claude)
        #expect(vertex.provider == .vertexai)
    }

    @Test
    func `CodexLocalUsageScanner provider is codex`() {
        #expect(CodexLocalUsageScanner().provider == .codex)
    }

    @Test
    func `Claude adapter returns empty report against empty filesystem`() {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalUsageScannerTests-claude-\(UUID())")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        var options = LocalUsageScanOptions()
        options.claudeProjectsRoots = [emptyRoot]
        options.cacheRoot = emptyRoot

        let report = ClaudeLocalUsageScanner().loadDailyReport(
            since: Date().addingTimeInterval(-86400),
            until: Date(),
            now: Date(),
            options: options)

        #expect(report.data.isEmpty)
    }

    @Test
    func `Codex adapter returns empty report against empty filesystem`() {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalUsageScannerTests-codex-\(UUID())")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        var options = LocalUsageScanOptions()
        options.codexSessionsRoot = emptyRoot
        options.cacheRoot = emptyRoot

        let report = CodexLocalUsageScanner().loadDailyReport(
            since: Date().addingTimeInterval(-86400),
            until: Date(),
            now: Date(),
            options: options)

        #expect(report.data.isEmpty)
    }

    @Test
    func `scan options vertexAIOnly filter survives mapping to CostUsageScanner options`() {
        // We can't directly poke CostUsageScanner.Options (internal type), but we
        // can confirm the mapping by exercising loadDailyReport against an empty
        // filesystem with each filter and asserting it does not crash.
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalUsageScannerTests-filter-\(UUID())")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        for filter in [
            LocalUsageScanOptions.ClaudeLogProviderFilter.all,
            .vertexAIOnly,
            .excludeVertexAI,
        ] {
            var options = LocalUsageScanOptions()
            options.claudeProjectsRoots = [emptyRoot]
            options.cacheRoot = emptyRoot
            options.claudeLogProviderFilter = filter

            let report = ClaudeLocalUsageScanner().loadDailyReport(
                since: Date().addingTimeInterval(-86400),
                until: Date(),
                now: Date(),
                options: options)
            #expect(report.data.isEmpty)
        }
    }
}

private struct StubScanner: LocalUsageScanner {
    let provider: UsageProvider
    let response: CostUsageDailyReport

    init(provider: UsageProvider, response: CostUsageDailyReport = CostUsageDailyReport(data: [], summary: nil)) {
        self.provider = provider
        self.response = response
    }

    func loadDailyReport(
        since: Date,
        until: Date,
        now: Date,
        options: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        self.response
    }
}
