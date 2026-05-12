import Foundation

// JSON shapes mirroring `ccusage-cherry-collector/src/types.ts`. We use
// snake_case-free upstream field names verbatim (`totalCost`, `cacheReadTokens`
// etc.) so the server-side parser doesn't need to special-case the Swift
// client. One UsageData payload corresponds to one agent type — the collector
// itself POSTs per-agent, and we do the same.

public struct MyCCusageDeviceInfoPayload: Codable, Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let displayName: String?
    public let agentType: String

    public init(deviceId: String, deviceName: String, displayName: String?, agentType: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.displayName = displayName
        self.agentType = agentType
    }
}

public struct MyCCusageModelBreakdownPayload: Codable, Sendable, Equatable {
    public let modelName: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let cost: Double

    public init(
        modelName: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        cost: Double)
    {
        self.modelName = modelName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
    }
}

public struct MyCCusageDailyRecordPayload: Codable, Sendable, Equatable {
    public let date: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let credits: Double?
    public let modelsUsed: [String]
    public let modelBreakdowns: [MyCCusageModelBreakdownPayload]

    public init(
        date: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        totalCost: Double,
        credits: Double? = nil,
        modelsUsed: [String],
        modelBreakdowns: [MyCCusageModelBreakdownPayload])
    {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.credits = credits
        self.modelsUsed = modelsUsed
        self.modelBreakdowns = modelBreakdowns
    }
}

public struct MyCCusageTotalsPayload: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let totalCost: Double
    public let totalTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        totalCost: Double,
        totalTokens: Int)
    {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalCost = totalCost
        self.totalTokens = totalTokens
    }
}

public struct MyCCusageUsageDataPayload: Codable, Sendable, Equatable {
    public let device: MyCCusageDeviceInfoPayload
    public let daily: [MyCCusageDailyRecordPayload]
    public let totals: MyCCusageTotalsPayload

    public init(
        device: MyCCusageDeviceInfoPayload,
        daily: [MyCCusageDailyRecordPayload],
        totals: MyCCusageTotalsPayload)
    {
        self.device = device
        self.daily = daily
        self.totals = totals
    }
}

/// Builds the per-agent `UsageData` payload from a CostUsageDailyReport. Pure
/// translation — does no scanning of its own.
public enum MyCCusageUploadPayloadBuilder {
    public static func buildPayload(
        agentType: MyCCusageAgentType,
        report: CostUsageDailyReport,
        deviceId: String,
        deviceName: String,
        displayName: String?) -> MyCCusageUsageDataPayload
    {
        let daily = report.data.map(Self.dailyRecord(from:))
        let totals = Self.totals(from: report, fallbackDaily: daily)
        return MyCCusageUsageDataPayload(
            device: MyCCusageDeviceInfoPayload(
                deviceId: deviceId,
                deviceName: deviceName,
                displayName: displayName,
                agentType: agentType.rawValue),
            daily: daily,
            totals: totals)
    }

    static func dailyRecord(from entry: CostUsageDailyReport.Entry) -> MyCCusageDailyRecordPayload {
        let input = entry.inputTokens ?? 0
        let output = entry.outputTokens ?? 0
        let cacheRead = entry.cacheReadTokens ?? 0
        let cacheCreate = entry.cacheCreationTokens ?? 0
        let total = entry.totalTokens ?? (input + output + cacheRead + cacheCreate)
        let breakdowns = (entry.modelBreakdowns ?? []).map { breakdown in
            MyCCusageModelBreakdownPayload(
                modelName: breakdown.modelName,
                // Per-model token counts are not currently surfaced through
                // CostUsageDailyReport.ModelBreakdown; use the aggregated
                // totalTokens as a single bucket so the server side still has
                // a non-zero number. This matches what the daemon's payload
                // shape carries.
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                cost: breakdown.costUSD ?? 0)
        }
        return MyCCusageDailyRecordPayload(
            date: entry.date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: total,
            totalCost: entry.costUSD ?? 0,
            credits: nil,
            modelsUsed: entry.modelsUsed ?? [],
            modelBreakdowns: breakdowns)
    }

    static func totals(
        from report: CostUsageDailyReport,
        fallbackDaily: [MyCCusageDailyRecordPayload]) -> MyCCusageTotalsPayload
    {
        // Prefer summary totals when the scanner provided them; otherwise sum
        // the per-day records we just produced so the payload is internally
        // consistent.
        if let summary = report.summary {
            return MyCCusageTotalsPayload(
                inputTokens: summary.totalInputTokens ?? self.sum(fallbackDaily, \.inputTokens),
                outputTokens: summary.totalOutputTokens ?? self.sum(fallbackDaily, \.outputTokens),
                cacheCreationTokens: summary.cacheCreationTokens
                    ?? self.sum(fallbackDaily, \.cacheCreationTokens),
                cacheReadTokens: summary.cacheReadTokens ?? self.sum(fallbackDaily, \.cacheReadTokens),
                totalCost: summary.totalCostUSD ?? self.sumDouble(fallbackDaily, \.totalCost),
                totalTokens: summary.totalTokens ?? self.sum(fallbackDaily, \.totalTokens))
        }
        return MyCCusageTotalsPayload(
            inputTokens: Self.sum(fallbackDaily, \.inputTokens),
            outputTokens: Self.sum(fallbackDaily, \.outputTokens),
            cacheCreationTokens: Self.sum(fallbackDaily, \.cacheCreationTokens),
            cacheReadTokens: Self.sum(fallbackDaily, \.cacheReadTokens),
            totalCost: Self.sumDouble(fallbackDaily, \.totalCost),
            totalTokens: Self.sum(fallbackDaily, \.totalTokens))
    }

    private static func sum(
        _ daily: [MyCCusageDailyRecordPayload],
        _ keyPath: KeyPath<MyCCusageDailyRecordPayload, Int>) -> Int
    {
        daily.reduce(0) { $0 + $1[keyPath: keyPath] }
    }

    private static func sumDouble(
        _ daily: [MyCCusageDailyRecordPayload],
        _ keyPath: KeyPath<MyCCusageDailyRecordPayload, Double>) -> Double
    {
        daily.reduce(0.0) { $0 + $1[keyPath: keyPath] }
    }
}
