import Foundation
import Testing
@testable import CodexBarCore

struct MyCCusageCoreTests {
    @Test
    func `config store reads collector json and migrates legacy agent type`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        try """
        {
          "apiKey": "secret",
          "endpoint": "https://ccusage.cherry-ai.com/api/usage-sync",
          "schedule": "0 */4 * * *",
          "scheduleLabel": "Every 4 hours",
          "deviceId": "device-1",
          "deviceName": "MacBookAir.lan",
          "displayName": "lianshuang",
          "agentType": "opencode",
          "unknownField": "preserve-me"
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let store = MyCCusageConfigStore(configURL: env.configURL)
        let config = try #require(try store.load())

        #expect(config.apiKey == "secret")
        #expect(config.endpoint == "https://ccusage.cherry-ai.com/api/usage-sync")
        #expect(config.schedule == "0 */4 * * *")
        #expect(config.scheduleLabel == "Every 4 hours")
        #expect(config.deviceId == "device-1")
        #expect(config.deviceName == "MacBookAir.lan")
        #expect(config.displayName == "lianshuang")
        #expect(config.agentTypes == [.opencode])

        var updated = config
        updated.agentTypes = [.cherryStudio, .codex]
        try store.save(updated)

        let data = try Data(contentsOf: env.configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["unknownField"] as? String == "preserve-me")
        #expect(json["agentType"] == nil)
        #expect(json["agentTypes"] as? [String] == ["cherry-studio", "codex"])
    }

    @Test
    func `stats endpoint is derived from sync endpoint`() throws {
        let sync = try #require(URL(string: "https://ccusage.cherry-ai.com/api/usage-sync"))
        let stats = try #require(MyCCusageStatsClient.statsEndpointURL(fromSyncEndpoint: sync))

        #expect(stats.absoluteString == "https://ccusage.cherry-ai.com/api/usage-stats")
    }

    @Test
    func `leaderboard snapshot ranks today's device against leader`() throws {
        let payload = """
        {
          "devices": [
            { "deviceId": "mine", "deviceName": "MacBookAir.lan", "displayName": "lianshuang" },
            { "deviceId": "leader", "deviceName": "JD-Mac", "displayName": "jd" },
            { "deviceId": "other", "deviceName": "Other" }
          ],
          "deviceData": [
            { "date": "2026-05-10", "deviceId": "mine", "agentType": "codex", "totalCost": 20.00, "totalTokens": 35000000 },
            { "date": "2026-05-10", "deviceId": "mine", "agentType": "opencode", "totalCost": 14.38, "totalTokens": 8500000 },
            { "date": "2026-05-10", "deviceId": "leader", "agentType": "cherry-studio", "totalCost": 556.51, "totalTokens": 1000 },
            { "date": "2026-05-10", "deviceId": "other", "agentType": "claude-code", "totalCost": 100.00, "totalTokens": 2000 },
            { "date": "2026-05-09", "deviceId": "mine", "agentType": "codex", "totalCost": 999.00, "totalTokens": 999 }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try MyCCusageLeaderboardSnapshot(
            statsData: payload,
            deviceId: "mine",
            today: "2026-05-10")

        #expect(snapshot.rank == 3)
        #expect(snapshot.participantCount == 3)
        #expect(snapshot.own.displayName == "lianshuang")
        #expect(abs(snapshot.own.totalCost - 34.38) < 0.001)
        #expect(snapshot.own.totalTokens == 43_500_000)
        #expect(snapshot.leader.displayName == "jd")
        #expect(abs(snapshot.gapToLeader - 522.13) < 0.001)
        #expect(snapshot.menuLine == "Community: #3 today $34.38 / 43.5M - leader jd $556.51 - gap $522.13")
    }

    @Test
    func `sync runner parses collector version and builds sync command`() throws {
        #expect(MyCCusageSyncRunner.normalizedVersion("1.0.4") == "1.0.4")
        #expect(MyCCusageSyncRunner.normalizedVersion("ccusage-cherry-collector 1.2.3") == "1.2.3")
        #expect(MyCCusageSyncRunner.normalizedVersion("not a version") == nil)

        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/ccusage-cherry-collector")
        let command = MyCCusageSyncRunner.syncCommand(binaryURL: binaryURL)
        #expect(command.executableURL == binaryURL)
        #expect(command.arguments == ["sync"])
    }

    private struct TestEnv {
        let root: URL
        let configURL: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-myccusage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.configURL = self.root.appendingPathComponent("config.json")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
