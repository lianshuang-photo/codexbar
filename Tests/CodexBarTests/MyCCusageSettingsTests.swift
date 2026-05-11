import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MyCCusageSettingsTests {
    @Test
    func `usage store writes MyCCusage settings back to collector json`() throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        try """
        {
          "enabled": false,
          "apiKey": "secret",
          "endpoint": "https://ccusage.cherry-ai.com/api/usage-sync",
          "schedule": "0 */4 * * *",
          "scheduleLabel": "Every 4 hours",
          "agentTypes": ["claude-code"],
          "unknownField": "preserve-me"
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let suite = "MyCCusageSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            myCCusageConfigStore: MyCCusageConfigStore(configURL: env.configURL))

        #expect(store.myCCusageConfig?.endpoint == "https://ccusage.cherry-ai.com/api/usage-sync")
        store.updateMyCCusageConfig {
            $0.endpoint = "https://example.com/api/usage-sync"
            $0.displayName = "desk"
            $0.schedule = "0 * * * *"
            $0.scheduleLabel = "Every 1 hour"
            $0.agentTypes = [.cherryStudio, .opencode]
        }

        let data = try Data(contentsOf: env.configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["enabled"] as? Bool == false)
        #expect(json["endpoint"] as? String == "https://example.com/api/usage-sync")
        #expect(json["displayName"] as? String == "desk")
        #expect(json["schedule"] as? String == "0 * * * *")
        #expect(json["scheduleLabel"] as? String == "Every 1 hour")
        #expect(json["agentTypes"] as? [String] == ["cherry-studio", "opencode"])
        #expect(json["unknownField"] as? String == "preserve-me")
    }

    @Test
    func `manual sync still refreshes leaderboard when collector binary is missing`() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        try """
        {
          "enabled": true,
          "apiKey": "secret",
          "endpoint": "https://example.test/api/usage-sync",
          "deviceId": "mine",
          "agentTypes": ["claude-code", "cherry-studio"]
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MyCCusageStatsStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let today = UsageStore.myCCusageTodayString()
        MyCCusageStatsStubURLProtocol.requests = []
        MyCCusageStatsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            let data = Data("""
            {
              "devices": [
                { "deviceId": "mine", "displayName": "lianshuang" },
                { "deviceId": "leader", "displayName": "jd" }
              ],
              "deviceData": [
                { "date": "\(today)", "deviceId": "mine",
                  "totalCost": 70.74, "totalTokens": 102500000 },
                { "date": "\(today)", "deviceId": "leader",
                  "totalCost": 140.73, "totalTokens": 1 }
              ]
            }
            """.utf8)
            return (response, data)
        }
        defer {
            MyCCusageStatsStubURLProtocol.requests = []
            MyCCusageStatsStubURLProtocol.handler = nil
        }

        let suite = "MyCCusageSettingsTests-sync-fallback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["PATH": "", "SHELL": "/bin/false"],
            myCCusageConfigStore: MyCCusageConfigStore(configURL: env.configURL),
            myCCusageStatsClient: MyCCusageStatsClient(session: session))

        await store.syncMyCCusageNow()

        #expect(MyCCusageStatsStubURLProtocol.requests.map(\.url?.path) == ["/api/usage-stats", "/api/usage-stats"])
        #expect(store.myCCusageLeaderboard?.own.displayName == "lianshuang")
        #expect(store.myCCusageLeaderboard?.rank == 2)
        #expect(store.myCCusageLastError == nil)
    }

    @Test
    func `manual sync polls leaderboard until daemon upload is visible`() async throws {
        let env = try TestEnv()
        defer { env.cleanup() }
        try """
        {
          "enabled": true,
          "apiKey": "secret",
          "endpoint": "https://example.test/api/usage-sync",
          "deviceId": "mine",
          "agentTypes": ["claude-code", "cherry-studio"]
        }
        """.write(to: env.configURL, atomically: true, encoding: .utf8)

        let syncURL = env.root.appendingPathComponent("ccusage-cherry-collector")
        try """
        #!/bin/sh
        echo "daemon sync triggered"
        exit 0
        """.write(to: syncURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: syncURL.path)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MyCCusagePollingStatsStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let today = UsageStore.myCCusageTodayString()
        MyCCusagePollingStatsStubURLProtocol.requests = []
        MyCCusagePollingStatsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            let ownCost = MyCCusagePollingStatsStubURLProtocol.requests.count >= 3 ? "25.00" : "10.00"
            let data = Data("""
            {
              "devices": [
                { "deviceId": "mine", "displayName": "lianshuang" },
                { "deviceId": "leader", "displayName": "jd" }
              ],
              "deviceData": [
                { "date": "\(today)", "deviceId": "mine",
                  "totalCost": \(ownCost), "totalTokens": 1000 },
                { "date": "\(today)", "deviceId": "leader",
                  "totalCost": 50.00, "totalTokens": 1 }
              ]
            }
            """.utf8)
            return (response, data)
        }
        defer {
            MyCCusagePollingStatsStubURLProtocol.requests = []
            MyCCusagePollingStatsStubURLProtocol.handler = nil
        }

        let suite = "MyCCusageSettingsTests-sync-poll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["PATH": "", "SHELL": "/bin/false"],
            myCCusageConfigStore: MyCCusageConfigStore(configURL: env.configURL),
            myCCusageStatsClient: MyCCusageStatsClient(session: session),
            myCCusageSyncRunner: MyCCusageSyncRunner(binaryURL: syncURL))
        store.myCCusagePostSyncPollInterval = 0
        store.myCCusagePostSyncPollAttempts = 3

        await store.syncMyCCusageNow()

        #expect(MyCCusagePollingStatsStubURLProtocol.requests.map(\.url?.path) == [
            "/api/usage-stats",
            "/api/usage-stats",
            "/api/usage-stats",
        ])
        #expect(store.myCCusageLeaderboard?.own.totalCost == 25.00)
        #expect(store.myCCusageSyncInFlight == false)
        #expect(store.myCCusageLastError == nil)
    }

    private struct TestEnv {
        let root: URL
        let configURL: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-myccusage-settings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.configURL = self.root.appendingPathComponent("config.json")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}

final class MyCCusageStatsStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class MyCCusagePollingStatsStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
