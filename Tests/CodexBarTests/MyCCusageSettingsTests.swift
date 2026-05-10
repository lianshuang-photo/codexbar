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
