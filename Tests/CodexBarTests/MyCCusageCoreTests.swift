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
    func `config store upgrades legacy all-agent selection to include Cherry Studio`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        try """
        {
          "apiKey": "secret",
          "endpoint": "https://ccusage.cherry-ai.com/api/usage-sync",
          "agentTypes": ["claude-code", "codex", "opencode", "openclaw"]
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let store = MyCCusageConfigStore(configURL: env.configURL)
        let config = try #require(try store.load())

        #expect(config.agentTypes == [.claudeCode, .cherryStudio, .opencode, .codex, .openclaw])

        let data = try Data(contentsOf: env.configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["agentTypes"] as? [String] == [
            "claude-code",
            "cherry-studio",
            "opencode",
            "codex",
            "openclaw",
        ])
    }

    @Test
    func `config store normalizes Cherry Studio selection order`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        try """
        {
          "apiKey": "secret",
          "endpoint": "https://ccusage.cherry-ai.com/api/usage-sync",
          "agentTypes": ["claude-code", "codex", "opencode", "openclaw", "cherry-studio"]
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let store = MyCCusageConfigStore(configURL: env.configURL)
        let config = try #require(try store.load())

        #expect(config.agentTypes == [.claudeCode, .cherryStudio, .opencode, .codex, .openclaw])

        let data = try Data(contentsOf: env.configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["agentTypes"] as? [String] == [
            "claude-code",
            "cherry-studio",
            "opencode",
            "codex",
            "openclaw",
        ])
    }

    @Test
    func `stats endpoint is derived from sync endpoint`() throws {
        let sync = try #require(URL(string: "https://ccusage.cherry-ai.com/api/usage-sync"))
        let stats = try #require(MyCCusageStatsClient.statsEndpointURL(fromSyncEndpoint: sync))

        #expect(stats.absoluteString == "https://ccusage.cherry-ai.com/api/usage-stats")
    }

    @Test
    func `leaderboard snapshot ranks today's device against leader`() throws {
        let payload = Data("""
        {
          "devices": [
            { "deviceId": "mine", "deviceName": "MacBookAir.lan", "displayName": "lianshuang" },
            { "deviceId": "leader", "deviceName": "JD-Mac", "displayName": "jd" },
            { "deviceId": "other", "deviceName": "Other" }
          ],
          "deviceData": [
            { "date": "2026-05-10", "deviceId": "mine", "agentType": "codex",
              "totalCost": 20.00, "totalTokens": 35000000 },
            { "date": "2026-05-10", "deviceId": "mine", "agentType": "opencode",
              "totalCost": 14.38, "totalTokens": 8500000 },
            { "date": "2026-05-10", "deviceId": "leader", "agentType": "cherry-studio",
              "totalCost": 556.51, "totalTokens": 1000 },
            { "date": "2026-05-10", "deviceId": "other", "agentType": "claude-code",
              "totalCost": 100.00, "totalTokens": 2000 },
            { "date": "2026-05-09", "deviceId": "mine", "agentType": "codex", "totalCost": 999.00, "totalTokens": 999 }
          ]
        }
        """.utf8)

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
    func `sync runner parses collector version and builds sync command`() {
        #expect(MyCCusageSyncRunner.normalizedVersion("1.0.4") == "1.0.4")
        #expect(MyCCusageSyncRunner.normalizedVersion("ccusage-cherry-collector 1.2.3") == "1.2.3")
        #expect(MyCCusageSyncRunner.normalizedVersion("not a version") == nil)

        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/ccusage-cherry-collector")
        let command = MyCCusageSyncRunner.syncCommand(binaryURL: binaryURL)
        #expect(command.executableURL == binaryURL)
        #expect(command.arguments == ["sync"])
    }

    @Test
    func `sync runner invokes collector binary without test command`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        let binaryURL = env.root.appendingPathComponent("ccusage-cherry-collector")
        let envURL = env.root.appendingPathComponent("sync-env.txt")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "ccusage-cherry-collector 1.0.4"
          exit 0
        fi
        if [ "$1" = "sync" ]; then
          echo "$CHROME_PATH" > "\(envURL.path)"
          echo "synced"
          exit 0
        fi
        echo "unexpected $1"
        exit 2
        """.write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let runner = MyCCusageSyncRunner(binaryURL: binaryURL)
        let status = runner.installedStatus(environment: [:])
        let result = runner.sync(environment: [:])

        #expect(status.binaryURL == binaryURL)
        #expect(status.version == "1.0.4")
        #expect(result == MyCCusageSyncResult(exitCode: 0, output: "synced"))
        #if os(macOS)
        let chromePath = try String(contentsOf: envURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(chromePath == "/bin/false")
        #endif
    }

    @Test
    func `sync runner disables browser app executable lookup`() {
        let environment = MyCCusageSyncRunner.syncEnvironment([
            "CHROME_PATH": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "PUPPETEER_EXECUTABLE_PATH": "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ])

        #if os(macOS)
        #expect(environment["CHROME_PATH"] == "/bin/false")
        #expect(environment["PUPPETEER_EXECUTABLE_PATH"] == "/bin/false")
        #endif
    }

    @Test
    func `sync runner prefers existing pm2 collector daemon`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        let pm2URL = env.root.appendingPathComponent("pm2")
        let collectorURL = env.root.appendingPathComponent("ccusage-cherry-collector")
        let argsURL = env.root.appendingPathComponent("pm2-args.txt")
        let envURL = env.root.appendingPathComponent("pm2-env.txt")
        try """
        #!/bin/sh
        if [ "$1" = "jlist" ]; then
          echo '[{"name":"ccusage-cherry-collector","pm2_env":{"status":"online"}}]'
          exit 0
        fi
        echo "$*" > "\(argsURL.path)"
        echo "$CHROME_PATH|$PUPPETEER_EXECUTABLE_PATH" > "\(envURL.path)"
        echo "pm2 restarted"
        exit 0
        """.write(to: pm2URL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        echo "direct collector should not run"
        exit 9
        """.write(to: collectorURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pm2URL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: collectorURL.path)

        let runner = MyCCusageSyncRunner()
        let result = runner.sync(environment: ["PATH": env.root.path])

        #expect(result == MyCCusageSyncResult(exitCode: 0, output: "pm2 restarted"))
        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(args == "restart ccusage-cherry-collector --update-env")
        #if os(macOS)
        let envText = try String(contentsOf: envURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(envText == "/bin/false|/bin/false")
        #endif
    }

    @Test
    func `default sync runner refuses direct collector when daemon is unavailable`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }

        let collectorURL = env.root.appendingPathComponent("ccusage-cherry-collector")
        try """
        #!/bin/sh
        echo "direct collector should not run"
        exit 9
        """.write(to: collectorURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: collectorURL.path)

        let runner = MyCCusageSyncRunner()
        let result = runner.sync(environment: ["PATH": env.root.path])

        #expect(result.exitCode == 127)
        #expect(result.output.contains("background daemon is not running"))
        #expect(result.output.contains("ccusage-cherry-collector start --daemon"))
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
