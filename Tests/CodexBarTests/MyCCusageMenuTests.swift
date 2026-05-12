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

    @Test
    func `overview descriptor includes MyCCusage sync when contextual actions are hidden`() throws {
        let env = try Self.makeStore()
        env.store.myCCusageConfig = MyCCusageConfig(
            apiKey: "secret",
            endpoint: "https://ccusage.cherry-ai.com/api/usage-sync",
            deviceId: "mine",
            agentTypes: [.claudeCode, .cherryStudio, .opencode])
        env.store.myCCusageEnabled = true

        let descriptor = MenuDescriptor.build(
            provider: nil,
            store: env.store,
            settings: env.settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let entries = descriptor.sections.flatMap(\.entries)
        #expect(entries.contains { entry in
            guard case let .text(text, _) = entry else { return false }
            return text == "Community: no ranking data yet"
        })
        #expect(entries.contains { entry in
            guard case let .text(text, _) = entry else { return false }
            return text == "Uploads: Claude Code, Cherry Studio, OpenCode"
        })
        #expect(entries.contains { entry in
            guard case let .action(title, action) = entry else { return false }
            return title == "Sync MyCCusage Now" && action == .syncMyCCusageNow
        })
    }

    @Test
    func `overview can suppress text section because community card owns MyCCusage display`() throws {
        let env = try Self.makeStore()
        env.store.myCCusageConfig = MyCCusageConfig(
            apiKey: "secret",
            endpoint: "https://ccusage.cherry-ai.com/api/usage-sync",
            agentTypes: [.claudeCode, .cherryStudio, .opencode, .codex, .openclaw])
        env.store.myCCusageEnabled = true

        let descriptor = MenuDescriptor.build(
            provider: nil,
            store: env.store,
            settings: env.settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false,
            includeMyCCusageSection: false)

        let entries = descriptor.sections.flatMap(\.entries)
        #expect(!entries.contains { entry in
            guard case let .action(title, action) = entry else { return false }
            return title == "Sync MyCCusage Now" && action == .syncMyCCusageNow
        })
    }

    @Test
    func `community card model shows chasing progress and five upload providers`() throws {
        let payload = Data("""
        {
          "devices": [
            { "deviceId": "mine", "displayName": "lianshuang" },
            { "deviceId": "leader", "displayName": "jd" }
          ],
          "deviceData": [
            { "date": "2026-05-10", "deviceId": "mine", "totalCost": 50.00, "totalTokens": 2000 },
            { "date": "2026-05-10", "deviceId": "leader", "totalCost": 200.00, "totalTokens": 8000 }
          ]
        }
        """.utf8)
        let leaderboard = try MyCCusageLeaderboardSnapshot(
            statsData: payload,
            deviceId: "mine",
            today: "2026-05-10")
        let config = MyCCusageConfig(
            apiKey: "secret",
            endpoint: "https://ccusage.cherry-ai.com/api/usage-sync",
            agentTypes: [.claudeCode, .cherryStudio, .opencode, .codex, .openclaw])

        let model = try #require(MyCCusageCommunityCardModel(
            config: config,
            leaderboard: leaderboard,
            lastError: nil,
            isSyncing: false))

        #expect(model.progressPercent == 25)
        #expect(model.status == "#2 today $50.00 / 2.0K")
        #expect(model.leaderText == "Leader jd $200.00")
        #expect(model.gapText == "Gap $150.00")
        #expect(model.uploadText == "Providers: Claude Code, Cherry Studio, OpenCode, Codex, OpenClaw")
        #expect(model.actionText == "Sync Now")
        #expect(model.isActionEnabled)
    }

    @Test
    func `community card model disables sync action while syncing`() throws {
        let config = MyCCusageConfig(
            apiKey: "secret",
            endpoint: "https://ccusage.cherry-ai.com/api/usage-sync",
            deviceId: "mine",
            agentTypes: [.claudeCode, .cherryStudio])

        let model = try #require(MyCCusageCommunityCardModel(
            config: config,
            leaderboard: nil,
            lastError: nil,
            isSyncing: true))

        #expect(model.actionText == "Syncing...")
        #expect(!model.isActionEnabled)
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
