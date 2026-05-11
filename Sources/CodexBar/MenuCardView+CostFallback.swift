import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func subtitle(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        lastError: String?,
        costFallbackText: String?,
        now: Date) -> (text: String, style: SubtitleStyle)
    {
        if let lastError, !lastError.isEmpty {
            if let costFallbackText, !costFallbackText.isEmpty {
                return (costFallbackText, .info)
            }
            return (lastError.trimmingCharacters(in: .whitespacesAndNewlines), .error)
        }

        if isRefreshing, snapshot == nil {
            return ("Refreshing...", .loading)
        }

        if let updated = snapshot?.updatedAt {
            return (UsageFormatter.updatedString(from: updated, now: now), .info)
        }

        return ("Not fetched yet", .info)
    }

    static func costFallbackSubtitle(
        input: Input,
        providerCost: ProviderCostSection?,
        tokenUsage: TokenUsageSection?) -> String?
    {
        guard let lastError = input.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastError.isEmpty
        else { return nil }

        if tokenUsage != nil, let updatedAt = input.tokenSnapshot?.updatedAt {
            return Self.costUpdatedText(updatedAt: updatedAt, now: input.now)
        }

        if providerCost != nil, let updatedAt = input.snapshot?.providerCost?.updatedAt {
            return Self.costUpdatedText(updatedAt: updatedAt, now: input.now)
        }

        let descriptor = ProviderDescriptorRegistry.descriptor(for: input.provider)
        if descriptor.tokenCost.supportsTokenCost {
            return "\(input.metadata.displayName) cost is temporarily unavailable. Try refreshing."
        }

        let noData = descriptor.tokenCost.noDataMessage().trimmingCharacters(in: .whitespacesAndNewlines)
        return noData.isEmpty ? "Cost data unavailable." : noData
    }

    private static func costUpdatedText(updatedAt: Date, now: Date) -> String {
        "Cost " + UsageFormatter.updatedString(from: updatedAt, now: now).lowercased()
    }
}
