import Foundation

public enum MyCCusageAgentType: String, CaseIterable, Codable, Equatable, Sendable {
    case claudeCode = "claude-code"
    case cherryStudio = "cherry-studio"
    case opencode
    case codex
    case openclaw

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cherryStudio: "Cherry Studio"
        case .opencode: "OpenCode"
        case .codex: "Codex"
        case .openclaw: "OpenClaw"
        }
    }
}

public struct MyCCusageConfig: Equatable, Sendable {
    public var enabled: Bool
    public var apiKey: String
    public var endpoint: String
    public var schedule: String
    public var scheduleLabel: String
    public var maxRetries: Int
    public var retryDelay: Int
    public var deviceId: String?
    public var deviceName: String?
    public var displayName: String?
    public var agentTypes: [MyCCusageAgentType]

    public init(
        enabled: Bool = true,
        apiKey: String,
        endpoint: String,
        schedule: String = "0 */4 * * *",
        scheduleLabel: String = "Every 4 hours",
        maxRetries: Int = 3,
        retryDelay: Int = 1000,
        deviceId: String? = nil,
        deviceName: String? = nil,
        displayName: String? = nil,
        agentTypes: [MyCCusageAgentType] = [.claudeCode])
    {
        self.enabled = enabled
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.schedule = schedule
        self.scheduleLabel = scheduleLabel
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.displayName = displayName
        self.agentTypes = agentTypes
    }
}

public final class MyCCusageConfigStore {
    public let configURL: URL
    private var preservedRaw: [String: Any] = [:]

    public init(
        configURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ccusage-collector", isDirectory: true)
            .appendingPathComponent("config.json"))
    {
        self.configURL = configURL
    }

    public func load() throws -> MyCCusageConfig? {
        guard FileManager.default.fileExists(atPath: self.configURL.path) else { return nil }
        let data = try Data(contentsOf: self.configURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let apiKey = Self.nonEmptyString(raw["apiKey"]),
              let endpoint = Self.nonEmptyString(raw["endpoint"])
        else { return nil }

        self.preservedRaw = raw
        return MyCCusageConfig(
            enabled: Self.boolValue(raw["enabled"]) ?? true,
            apiKey: apiKey,
            endpoint: endpoint,
            schedule: Self.nonEmptyString(raw["schedule"]) ?? "0 */4 * * *",
            scheduleLabel: Self.nonEmptyString(raw["scheduleLabel"]) ?? "Every 4 hours",
            maxRetries: Self.intValue(raw["maxRetries"]) ?? 3,
            retryDelay: Self.intValue(raw["retryDelay"]) ?? 1000,
            deviceId: Self.nonEmptyString(raw["deviceId"]),
            deviceName: Self.nonEmptyString(raw["deviceName"]),
            displayName: Self.nonEmptyString(raw["displayName"]),
            agentTypes: Self.agentTypes(from: raw))
    }

    public func save(_ config: MyCCusageConfig) throws {
        var raw = self.preservedRaw
        raw["enabled"] = config.enabled
        raw["apiKey"] = config.apiKey
        raw["endpoint"] = config.endpoint
        raw["schedule"] = config.schedule
        raw["scheduleLabel"] = config.scheduleLabel
        raw["maxRetries"] = config.maxRetries
        raw["retryDelay"] = config.retryDelay
        raw["deviceId"] = config.deviceId
        raw["deviceName"] = config.deviceName
        raw["displayName"] = config.displayName
        raw["agentTypes"] = config.agentTypes.map(\.rawValue)
        raw.removeValue(forKey: "agentType")

        let directory = self.configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: self.configURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.configURL.path)
        self.preservedRaw = raw
    }

    private static func agentTypes(from raw: [String: Any]) -> [MyCCusageAgentType] {
        if let values = raw["agentTypes"] as? [String] {
            let parsed = values.compactMap(MyCCusageAgentType.init(rawValue:))
            if !parsed.isEmpty { return parsed }
        }
        if let value = raw["agentType"] as? String,
           let agent = MyCCusageAgentType(rawValue: value)
        {
            return [agent]
        }
        return [.claudeCode]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
