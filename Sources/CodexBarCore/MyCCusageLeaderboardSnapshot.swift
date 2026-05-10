import Foundation

public struct MyCCusageLeaderboardSnapshot: Equatable, Sendable {
    public struct Participant: Equatable, Sendable {
        public let deviceId: String
        public let displayName: String
        public let totalCost: Double
        public let totalTokens: Int
    }

    public let today: String
    public let rank: Int
    public let participantCount: Int
    public let own: Participant
    public let leader: Participant
    public let gapToLeader: Double

    public init(statsData: Data, deviceId: String, today: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: statsData) as? [String: Any] else {
            throw MyCCusageLeaderboardError.invalidPayload
        }
        let names = Self.deviceNames(root["devices"])
        var totals: [String: (cost: Double, tokens: Int)] = [:]

        for record in (root["deviceData"] as? [[String: Any]]) ?? [] {
            guard Self.string(record["date"]) == today,
                  let id = Self.string(record["deviceId"])
            else { continue }
            let current = totals[id] ?? (0, 0)
            totals[id] = (
                current.cost + Self.double(record["totalCost"]),
                current.tokens + Self.int(record["totalTokens"]))
        }

        if totals[deviceId] == nil {
            totals[deviceId] = (0, 0)
        }

        let participants = totals.map { id, total in
            Participant(
                deviceId: id,
                displayName: names[id] ?? id,
                totalCost: total.cost,
                totalTokens: total.tokens)
        }
        .sorted {
            if $0.totalCost != $1.totalCost { return $0.totalCost > $1.totalCost }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        guard let ownIndex = participants.firstIndex(where: { $0.deviceId == deviceId }),
              let leader = participants.first
        else {
            throw MyCCusageLeaderboardError.missingDevice
        }

        self.today = today
        self.rank = ownIndex + 1
        self.participantCount = participants.count
        self.own = participants[ownIndex]
        self.leader = leader
        self.gapToLeader = max(0, leader.totalCost - self.own.totalCost)
    }

    public var menuLine: String {
        "Community: #\(self.rank) today \(Self.usd(self.own.totalCost)) / \(Self.tokens(self.own.totalTokens)) - " +
            "leader \(self.leader.displayName) \(Self.usd(self.leader.totalCost)) - gap \(Self.usd(self.gapToLeader))"
    }

    public static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    public static func tokens(_ value: Int) -> String {
        let double = Double(value)
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", double / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", double / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", double / 1_000)
        }
        return "\(value)"
    }

    private static func deviceNames(_ value: Any?) -> [String: String] {
        var names: [String: String] = [:]
        for device in (value as? [[String: Any]]) ?? [] {
            guard let id = Self.string(device["deviceId"]) else { continue }
            names[id] = Self.string(device["displayName"]) ?? Self.string(device["deviceName"]) ?? id
        }
        return names
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private static func int(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}

public enum MyCCusageLeaderboardError: Error, Equatable {
    case invalidPayload
    case missingDevice
}
