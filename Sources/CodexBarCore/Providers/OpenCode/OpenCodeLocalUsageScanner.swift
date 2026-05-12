import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

/// Local usage scanner for OpenCode (https://opencode.ai).
///
/// Reads token usage from OpenCode's on-disk session storage. OpenCode
/// supports two on-disk shapes; this scanner tries them in order:
///
///   1. Per-message JSON files at `<root>/storage/message/<session>/<msg>.json`
///      (used by the OpenCode CLI). Mirrors the layout in
///      https://github.com/ryoppippi/ccusage `apps/opencode/src/data-loader.ts`.
///   2. SQLite database at `<root>/opencode.db` (used by the OpenCode Desktop
///      App). Mirrors `readOpencodeDB` in MyCCusage `ccusage-collector`.
///
/// The scanner is read-only and Sendable. It does not write to the user's
/// OpenCode data directory.
public struct OpenCodeLocalUsageScanner: LocalUsageScanner {
    public let provider: UsageProvider = .opencode

    /// Override the OpenCode data root. When nil, the scanner consults the
    /// `OPENCODE_DATA_DIR` environment variable and then falls back to
    /// `~/.local/share/opencode`.
    public let dataRootOverride: URL?

    public init(dataRoot: URL? = nil) {
        self.dataRootOverride = dataRoot
    }

    public func loadDailyReport(
        since: Date,
        until: Date,
        now: Date,
        options: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        _ = options // reserved for future use; OpenCode has no plan/filter today
        _ = now

        guard let root = self.resolveDataRoot() else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        let range = OpenCodeDayRange(since: since, until: until)

        let jsonlEntries = Self.loadFromMessageDirectory(root: root)
        if !jsonlEntries.isEmpty {
            return Self.buildReport(entries: jsonlEntries, range: range)
        }

        #if canImport(SQLite3)
        let sqliteEntries = Self.loadFromSQLite(root: root)
        return Self.buildReport(entries: sqliteEntries, range: range)
        #else
        // SQLite3 is not available on Linux; the Desktop App fallback is
        // a no-op there and we return an empty report.
        return CostUsageDailyReport(data: [], summary: nil)
        #endif
    }

    // MARK: - Root resolution

    private func resolveDataRoot() -> URL? {
        if let override = self.dataRootOverride { return override }

        let env = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    // MARK: - Per-message JSON path

    static func loadFromMessageDirectory(root: URL) -> [OpenCodeLoadedEntry] {
        let messagesDir = root
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("message", isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: messagesDir.path, isDirectory: &isDir),
              isDir.boolValue
        else { return [] }

        guard let enumerator = FileManager.default.enumerator(
            at: messagesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var entries: [OpenCodeLoadedEntry] = []
        var seenIds: Set<String> = []

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let entry = OpenCodeMessageParser.parse(data: data) else { continue }
            guard !seenIds.contains(entry.messageId) else { continue }
            seenIds.insert(entry.messageId)
            entries.append(entry)
        }

        return entries
    }

    // MARK: - SQLite path

    #if canImport(SQLite3)
    static func loadFromSQLite(root: URL) -> [OpenCodeLoadedEntry] {
        let dbURL = root.appendingPathComponent("opencode.db", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        return (try? OpenCodeLocalScannerSQLite.readMessages(dbPath: dbURL.path)) ?? []
    }
    #endif

    // MARK: - Aggregation

    static func buildReport(
        entries: [OpenCodeLoadedEntry],
        range: OpenCodeDayRange) -> CostUsageDailyReport
    {
        // dayKey -> modelName -> running totals
        var days: [String: [String: OpenCodeModelAccumulator]] = [:]

        for entry in entries {
            let dayKey = OpenCodeDayRange.dayKey(from: entry.timestamp)
            guard OpenCodeDayRange.isInRange(dayKey: dayKey, since: range.sinceKey, until: range.untilKey) else {
                continue
            }
            var models = days[dayKey] ?? [:]
            var acc = models[entry.model] ?? OpenCodeModelAccumulator()
            acc.add(entry)
            models[entry.model] = acc
            days[dayKey] = models
        }

        var dayEntries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var sawAnyCost = false

        for dayKey in days.keys.sorted() {
            guard let modelMap = days[dayKey] else { continue }
            let modelNames = modelMap.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheCreation = 0
            var dayCost: Double = 0
            var dayCostSeen = false

            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for modelName in modelNames {
                let acc = modelMap[modelName] ?? OpenCodeModelAccumulator()
                dayInput += acc.inputTokens
                dayOutput += acc.outputTokens
                dayCacheRead += acc.cacheReadTokens
                dayCacheCreation += acc.cacheCreationTokens
                let cost = acc.sawCost ? acc.costUSD : nil
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
                let modelTotalTokens = acc.inputTokens
                    + acc.outputTokens
                    + acc.cacheReadTokens
                    + acc.cacheCreationTokens
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: cost,
                    totalTokens: modelTotalTokens))
            }

            let dayTotal = dayInput + dayOutput + dayCacheRead + dayCacheCreation
            let entryCost = dayCostSeen ? dayCost : nil

            dayEntries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                cacheCreationTokens: dayCacheCreation,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedBreakdowns(breakdowns)))

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalCacheCreation += dayCacheCreation
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                sawAnyCost = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = dayEntries.isEmpty ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheCreation,
                totalTokens: totalTokens,
                totalCostUSD: sawAnyCost ? totalCost : nil)

        return CostUsageDailyReport(data: dayEntries, summary: summary)
    }

    private static func sortedBreakdowns(
        _ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return lhs.modelName > rhs.modelName
        }
    }
}

// MARK: - Shared types

public struct OpenCodeLoadedEntry: Sendable, Equatable {
    public let messageId: String
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    /// Pre-computed cost from OpenCode; absent for SQLite rows.
    public let costUSD: Double?

    public init(
        messageId: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double?)
    {
        self.messageId = messageId
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }
}

struct OpenCodeDayRange: Sendable {
    let sinceKey: String
    let untilKey: String

    init(since: Date, until: Date) {
        self.sinceKey = Self.dayKey(from: since)
        self.untilKey = Self.dayKey(from: until)
    }

    static func dayKey(from date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1)
    }

    static func isInRange(dayKey: String, since: String, until: String) -> Bool {
        if dayKey < since { return false }
        if dayKey > until { return false }
        return true
    }
}

struct OpenCodeModelAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var costUSD: Double = 0
    var sawCost = false

    mutating func add(_ entry: OpenCodeLoadedEntry) {
        self.inputTokens += entry.inputTokens
        self.outputTokens += entry.outputTokens
        self.cacheReadTokens += entry.cacheReadTokens
        self.cacheCreationTokens += entry.cacheCreationTokens
        if let cost = entry.costUSD {
            self.costUSD += cost
            self.sawCost = true
        }
    }
}

// MARK: - Message JSON parser

enum OpenCodeMessageParser {
    static func parse(data: Data) -> OpenCodeLoadedEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        guard let providerID = obj["providerID"] as? String, !providerID.isEmpty else { return nil }
        guard let modelID = obj["modelID"] as? String, !modelID.isEmpty else { return nil }
        guard let time = obj["time"] as? [String: Any] else { return nil }
        guard let createdMs = (time["created"] as? NSNumber)?.doubleValue else { return nil }
        guard let tokens = obj["tokens"] as? [String: Any] else { return nil }

        let input = (tokens["input"] as? NSNumber)?.intValue ?? 0
        let output = (tokens["output"] as? NSNumber)?.intValue ?? 0
        // Skip entries that report zero input AND zero output, matching upstream.
        if input == 0, output == 0 { return nil }

        let cache = tokens["cache"] as? [String: Any]
        let cacheRead = (cache?["read"] as? NSNumber)?.intValue ?? 0
        let cacheWrite = (cache?["write"] as? NSNumber)?.intValue ?? 0
        let cost = (obj["cost"] as? NSNumber)?.doubleValue

        return OpenCodeLoadedEntry(
            messageId: id,
            timestamp: Date(timeIntervalSince1970: createdMs / 1000.0),
            model: modelID,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            costUSD: cost)
    }
}
