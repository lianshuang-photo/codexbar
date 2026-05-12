import Foundation

/// 1:1 Swift port of the OpenClaw `ccusage-openclaw` npm package (TS).
///
/// Layout: `$OPENCLAW_HOME/agents/<agent>/sessions/<id>.jsonl[.<rotation>]`
/// Records: `{ type: "message", timestamp, message: { role, model, usage: { input, output,
/// cacheRead, cacheWrite, totalTokens, cost?: { total } } } }`
///
/// We embed the official pricing table (verified March 2026) and skip the live LiteLLM fetch —
/// no network calls inside scanners. Embedded `usage.cost.total` is always preferred when present,
/// matching the TS behavior.
public struct OpenClawLocalUsageScanner: LocalUsageScanner {
    public let provider: UsageProvider = .openclaw

    /// Override for `$OPENCLAW_HOME`. When `nil`, the scanner consults the environment and falls
    /// back to `~/.openclaw`.
    private let homeOverride: URL?
    private let environment: [String: String]

    public init(
        homeOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.homeOverride = homeOverride
        self.environment = environment
    }

    public func loadDailyReport(
        since: Date,
        until: Date,
        now _: Date,
        options _: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        let baseDir = self.resolveHome()
        let sessionFiles = OpenClawSessionDiscovery.findSessionFiles(
            in: baseDir,
            fileManager: .default)
        guard !sessionFiles.isEmpty else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        var messages: [OpenClawParsedMessage] = []
        for url in sessionFiles {
            messages.append(contentsOf: OpenClawSessionParser.parse(fileAt: url))
        }

        return OpenClawDailyAggregator.aggregate(
            messages: messages,
            pricing: OpenClawPricing.officialPricing,
            since: since,
            until: until)
    }

    private func resolveHome() -> URL {
        if let homeOverride { return homeOverride }
        if let envHome = self.environment["OPENCLAW_HOME"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome, isDirectory: true)
        }
        let home = self.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".openclaw")
    }
}

// MARK: - Session discovery (parser.ts: findSessionFiles)

enum OpenClawSessionDiscovery {
    static func findSessionFiles(in baseDir: URL, fileManager: FileManager) -> [URL] {
        let agentsDir = baseDir.appendingPathComponent("agents")
        guard fileManager.fileExists(atPath: agentsDir.path) else { return [] }
        guard let agentEntries = try? fileManager.contentsOfDirectory(atPath: agentsDir.path) else {
            return []
        }

        var files: [URL] = []
        for agent in agentEntries {
            let sessionsDir = agentsDir
                .appendingPathComponent(agent)
                .appendingPathComponent("sessions")
            guard fileManager.fileExists(atPath: sessionsDir.path) else { continue }
            guard let entries = try? fileManager.contentsOfDirectory(atPath: sessionsDir.path) else {
                continue
            }
            for name in entries {
                // parser.ts: `name.endsWith(".jsonl") || name.includes(".jsonl.")`
                if name.hasSuffix(".jsonl") || name.contains(".jsonl.") {
                    files.append(sessionsDir.appendingPathComponent(name))
                }
            }
        }
        return files
    }
}

// MARK: - Session parsing (parser.ts: parseSessionFile)

struct OpenClawParsedMessage {
    let timestamp: String
    let model: String
    let usage: OpenClawUsage
}

struct OpenClawUsage {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let embeddedCostTotal: Double?
}

enum OpenClawSessionParser {
    /// Streams a JSONL file and yields valid assistant-message usage records. Mirrors
    /// `parseSessionFile` from parser.ts, including:
    ///  - skip lines that are empty / malformed JSON
    ///  - skip entries where `type != "message"`
    ///  - skip non-assistant roles
    ///  - skip records without `usage.totalTokens`
    ///  - skip the internal `delivery-mirror` routing model
    static func parse(fileAt url: URL) -> [OpenClawParsedMessage] {
        guard let stream = InputStream(url: url) else { return [] }
        stream.open()
        defer { stream.close() }

        var results: [OpenClawParsedMessage] = []
        var buffer = Data()
        let chunkSize = 4096
        var raw = [UInt8](repeating: 0, count: chunkSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: chunkSize)
            if read <= 0 { break }
            buffer.append(raw, count: read)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                if let parsed = self.parseLine(lineData) {
                    results.append(parsed)
                }
            }
        }
        if !buffer.isEmpty, let parsed = self.parseLine(buffer) {
            results.append(parsed)
        }
        return results
    }

    private static func parseLine(_ data: Data) -> OpenClawParsedMessage? {
        var bytes = data
        // Strip trailing \r from CRLF
        if bytes.last == 0x0D { bytes.removeLast() }
        // Skip empty / whitespace-only lines
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: bytes, options: []) else {
            return nil
        }
        guard let entry = json as? [String: Any] else { return nil }
        guard (entry["type"] as? String) == "message" else { return nil }
        guard let timestamp = entry["timestamp"] as? String else { return nil }
        guard let message = entry["message"] as? [String: Any] else { return nil }
        guard (message["role"] as? String) == "assistant" else { return nil }
        guard let usageDict = message["usage"] as? [String: Any] else { return nil }
        let totalTokens = self.intValue(usageDict["totalTokens"]) ?? 0
        guard totalTokens > 0 else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        if model == "delivery-mirror" { return nil }

        let usage = OpenClawUsage(
            input: self.intValue(usageDict["input"]) ?? 0,
            output: self.intValue(usageDict["output"]) ?? 0,
            cacheRead: self.intValue(usageDict["cacheRead"]) ?? 0,
            cacheWrite: self.intValue(usageDict["cacheWrite"]) ?? 0,
            totalTokens: totalTokens,
            embeddedCostTotal: self.embeddedCost(from: usageDict["cost"]))
        return OpenClawParsedMessage(timestamp: timestamp, model: model, usage: usage)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let v as Int: v
        case let v as Double: Int(v)
        case let v as NSNumber: v.intValue
        default: nil
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let v as Double: v
        case let v as Int: Double(v)
        case let v as NSNumber: v.doubleValue
        default: nil
        }
    }

    private static func embeddedCost(from raw: Any?) -> Double? {
        guard let dict = raw as? [String: Any] else { return nil }
        return self.doubleValue(dict["total"])
    }
}

// MARK: - Daily aggregation (parser.ts: collectDailyUsage)

enum OpenClawDailyAggregator {
    private struct ModelAccum {
        var inputTokens = 0
        var outputTokens = 0
        var cacheRead = 0
        var cacheWrite = 0
        var cost = 0.0
    }

    private struct DayAccum {
        var inputTokens = 0
        var outputTokens = 0
        var cacheRead = 0
        var cacheWrite = 0
        var totalTokens = 0
        var cost = 0.0
        var models: [String: ModelAccum] = [:]
        var modelOrder: [String] = []
    }

    static func aggregate(
        messages: [OpenClawParsedMessage],
        pricing: [String: OpenClawPricing.ModelPricing],
        since: Date,
        until: Date) -> CostUsageDailyReport
    {
        var dailyMap: [String: DayAccum] = [:]
        var dayOrder: [String] = []

        for message in messages {
            // parser.ts derives the date from the first 10 chars of the timestamp — keep that
            // verbatim. Range filtering (since/until) is best-effort: we additionally drop dates
            // outside the requested window when the timestamp parses.
            guard message.timestamp.count >= 10 else { continue }
            let date = String(message.timestamp.prefix(10))
            if let absolute = OpenClawTimestampParser.parse(message.timestamp) {
                if absolute < since || absolute > until { continue }
            }

            let u = message.usage
            var cost = u.embeddedCostTotal ?? 0
            if cost == 0, let entry = OpenClawPricing.findPricing(pricing, rawModel: message.model) {
                cost = OpenClawPricing.calculateCost(
                    pricing: entry,
                    input: u.input,
                    output: u.output,
                    cacheRead: u.cacheRead,
                    cacheWrite: u.cacheWrite)
            }

            if dailyMap[date] == nil {
                dailyMap[date] = DayAccum()
                dayOrder.append(date)
            }
            var day = dailyMap[date]!
            day.inputTokens += u.input
            day.outputTokens += u.output
            day.cacheRead += u.cacheRead
            day.cacheWrite += u.cacheWrite
            day.totalTokens += u.totalTokens
            day.cost += cost

            // parser.ts: `const modelName = msg.model.split("/").pop() || msg.model;`
            let modelName = self.extractDisplayModel(message.model)
            if day.models[modelName] == nil {
                day.models[modelName] = ModelAccum()
                day.modelOrder.append(modelName)
            }
            var modelAccum = day.models[modelName]!
            modelAccum.inputTokens += u.input
            modelAccum.outputTokens += u.output
            modelAccum.cacheRead += u.cacheRead
            modelAccum.cacheWrite += u.cacheWrite
            modelAccum.cost += cost
            day.models[modelName] = modelAccum

            dailyMap[date] = day
        }

        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalTokens = 0
        var totalCost = 0.0

        for date in dailyMap.keys.sorted() {
            let day = dailyMap[date]!
            let modelsUsed = day.modelOrder
            let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = day.modelOrder.map { name in
                let m = day.models[name]!
                let mTotal = m.inputTokens + m.outputTokens + m.cacheRead + m.cacheWrite
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: m.cost,
                    totalTokens: mTotal)
            }

            entries.append(CostUsageDailyReport.Entry(
                date: date,
                inputTokens: day.inputTokens,
                outputTokens: day.outputTokens,
                cacheReadTokens: day.cacheRead,
                cacheCreationTokens: day.cacheWrite,
                totalTokens: day.totalTokens,
                costUSD: day.cost,
                modelsUsed: modelsUsed,
                modelBreakdowns: modelBreakdowns))

            totalInput += day.inputTokens
            totalOutput += day.outputTokens
            totalCacheRead += day.cacheRead
            totalCacheWrite += day.cacheWrite
            totalTokens += day.totalTokens
            totalCost += day.cost
        }

        let summary = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheWrite,
                totalTokens: totalTokens,
                totalCostUSD: totalCost)

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    private static func extractDisplayModel(_ raw: String) -> String {
        let parts = raw.split(separator: "/")
        return parts.last.map(String.init) ?? raw
    }
}

// MARK: - Timestamp parsing (parser.ts uses substring(0, 10), but we also need a Date for filtering)

enum OpenClawTimestampParser {
    static func parse(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
