import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MyCCusageMenuTests {
    @Test
    func `menu includes community summary and manual sync action`() throws {
        let env = try Self.makeStore()
        let payload = Data("""
        {
          "devices": [
            { "deviceId": "mine", "displayName": "lianshuang" },
            { "deviceId": "leader", "displayName": "jd" }
          ],
          "deviceData": [
            { "date": "2026-05-10", "deviceId": "mine", "totalCost": 34.38, "totalTokens": 43500000 },
            { "date": "2026-05-10", "deviceId": "leader", "totalCost": 556.51, "totalTokens": 1 }
          ]
        }
        """.utf8)
        env.store.myCCusageConfig = MyCCusageConfig(
            apiKey: "secret",
            endpoint: "https://ccusage.cherry-ai.com/api/usage-sync",
            deviceId: "mine")
        env.store.myCCusageEnabled = true
        env.store.myCCusageLeaderboard = try MyCCusageLeaderboardSnapshot(
            statsData: payload,
            deviceId: "mine",
            today: "2026-05-10")

        let descriptor = MenuDescriptor.build(
            provider: nil,
            store: env.store,
            settings: env.settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false)

        let entries = descriptor.sections.flatMap(\.entries)
        #expect(entries.contains { entry in
            guard case let .text(text, _) = entry else { return false }
            return text == "Community: #2 today $34.38 / 43.5M - leader jd $556.51 - gap $522.13"
        })
        #expect(entries.contains { entry in
            guard case let .action(title, action) = entry else { return false }
            return title == "Sync MyCCusage Now" && action == .syncMyCCusageNow
        })
    }

    private static func makeStore() throws -> (settings: SettingsStore, store: UsageStore) {
        let suite = "MyCCusageMenuTests-\(UUID().uuidString)"
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
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        return (settings, store)
    }
}
