import Foundation

public struct LocalUsageScanOptions: Sendable {
    public var codexSessionsRoot: URL?
    public var claudeProjectsRoots: [URL]?
    public var cacheRoot: URL?
    public var refreshMinIntervalSeconds: TimeInterval
    public var forceRescan: Bool

    public enum ClaudeLogProviderFilter: Sendable {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    public var claudeLogProviderFilter: ClaudeLogProviderFilter

    public init(
        codexSessionsRoot: URL? = nil,
        claudeProjectsRoots: [URL]? = nil,
        cacheRoot: URL? = nil,
        refreshMinIntervalSeconds: TimeInterval = 60,
        claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
        forceRescan: Bool = false)
    {
        self.codexSessionsRoot = codexSessionsRoot
        self.claudeProjectsRoots = claudeProjectsRoots
        self.cacheRoot = cacheRoot
        self.refreshMinIntervalSeconds = refreshMinIntervalSeconds
        self.claudeLogProviderFilter = claudeLogProviderFilter
        self.forceRescan = forceRescan
    }
}

public protocol LocalUsageScanner: Sendable {
    var provider: UsageProvider { get }

    func loadDailyReport(
        since: Date,
        until: Date,
        now: Date,
        options: LocalUsageScanOptions) -> CostUsageDailyReport
}

public enum LocalUsageScannerRegistry {
    private static let storage = Storage()

    public static func register(_ scanner: LocalUsageScanner) {
        self.storage.register(scanner)
    }

    public static func unregister(provider: UsageProvider) {
        self.storage.unregister(provider: provider)
    }

    public static func unregisterAll() {
        self.storage.unregisterAll()
    }

    public static func resolve(for provider: UsageProvider) -> LocalUsageScanner? {
        self.storage.scanner(for: provider)
    }

    public static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: LocalUsageScanOptions = LocalUsageScanOptions()) -> CostUsageDailyReport
    {
        if let scanner = resolve(for: provider) {
            return scanner.loadDailyReport(since: since, until: until, now: now, options: options)
        }
        return CostUsageScanner.loadDailyReport(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options.toCostUsageScannerOptions())
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var scanners: [UsageProvider: LocalUsageScanner] = [:]

        func register(_ scanner: LocalUsageScanner) {
            self.lock.lock(); defer { self.lock.unlock() }
            self.scanners[scanner.provider] = scanner
        }

        func unregister(provider: UsageProvider) {
            self.lock.lock(); defer { self.lock.unlock() }
            self.scanners.removeValue(forKey: provider)
        }

        func unregisterAll() {
            self.lock.lock(); defer { self.lock.unlock() }
            self.scanners.removeAll()
        }

        func scanner(for provider: UsageProvider) -> LocalUsageScanner? {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.scanners[provider]
        }
    }
}

extension LocalUsageScanOptions {
    func toCostUsageScannerOptions() -> CostUsageScanner.Options {
        let filter: CostUsageScanner.ClaudeLogProviderFilter = switch self.claudeLogProviderFilter {
        case .all: .all
        case .vertexAIOnly: .vertexAIOnly
        case .excludeVertexAI: .excludeVertexAI
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: self.codexSessionsRoot,
            claudeProjectsRoots: self.claudeProjectsRoots,
            cacheRoot: self.cacheRoot,
            claudeLogProviderFilter: filter,
            forceRescan: self.forceRescan)
        options.refreshMinIntervalSeconds = self.refreshMinIntervalSeconds
        return options
    }
}
