import Foundation

public struct ClaudeLocalUsageScanner: LocalUsageScanner {
    public let provider: UsageProvider

    public init(provider: UsageProvider = .claude) {
        precondition(
            provider == .claude || provider == .vertexai,
            "ClaudeLocalUsageScanner only handles .claude or .vertexai; got \(provider)")
        self.provider = provider
    }

    public func loadDailyReport(
        since: Date,
        until: Date,
        now: Date,
        options: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        CostUsageScanner.loadDailyReport(
            provider: self.provider,
            since: since,
            until: until,
            now: now,
            options: options.toCostUsageScannerOptions())
    }
}
