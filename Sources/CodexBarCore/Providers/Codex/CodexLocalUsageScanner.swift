import Foundation

public struct CodexLocalUsageScanner: LocalUsageScanner {
    public let provider: UsageProvider = .codex

    public init() {}

    public func loadDailyReport(
        since: Date,
        until: Date,
        now: Date,
        options: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: now,
            options: options.toCostUsageScannerOptions())
    }
}
