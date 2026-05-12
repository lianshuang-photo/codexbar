import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardSubtitleTests {
    @Test
    func `subtitle uses injected current time`() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        let now = updatedAt.addingTimeInterval(5 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Plus Plan"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.subtitleText == UsageFormatter.updatedString(from: updatedAt, now: now))
    }

    @Test
    func `usage error falls back to neutral cost subtitle`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: "Probe failed for Codex",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))

        // Review issue #4: the original MVP swallowed the underlying probe
        // failure with "Codex cost is temporarily unavailable" even when no
        // cost data was available, hiding OAuth-expired / rate-limit / cookie
        // diagnostics. With no token cost snapshot to fall back to, the raw
        // error must surface.
        #expect(model.subtitleStyle == .error)
        #expect(model.subtitleText.contains("Probe failed"))
        #expect(model.placeholder == nil)
    }

    @Test
    func `usage error shows token cost fallback when available`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 78.9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-11",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 456,
                    costUSD: 78.9,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: "Probe failed for Codex",
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.subtitleStyle == .info)
        #expect(model.subtitleText == "Cost updated just now")
        #expect(model.tokenUsage?.sessionLine == "Today: $1.23 · 123 tokens")
        #expect(model.tokenUsage?.monthLine == "Last 30 days: $78.90 · 456 tokens")
        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == nil)
    }
}
