import AppKit
import CodexBarCore
import SwiftUI

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(provider):
            provider
        }
    }
}

struct OverviewMenuCardRowView: View {
    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.model,
                showDivider: self.hasUsageBlock,
                width: self.width)
            if self.hasUsageBlock {
                UsageMenuCardUsageSectionView(
                    model: self.model,
                    showBottomDivider: false,
                    bottomPadding: 6,
                    width: self.width)
            }
            if let storageText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Storage:")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Text(storageText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, self.hasUsageBlock ? 0 : 8)
                .padding(.bottom, 6)
                .frame(width: self.width, alignment: .leading)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var hasUsageBlock: Bool {
        !self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty || self.model.placeholder != nil
    }
}

struct MyCCusageCommunityCardModel: Equatable {
    let title: String
    let status: String
    let progressPercent: Double
    let leaderText: String?
    let gapText: String?
    let uploadText: String
    let actionText: String
    let isActionEnabled: Bool
    let isSyncing: Bool

    init?(
        config: MyCCusageConfig?,
        leaderboard: MyCCusageLeaderboardSnapshot?,
        lastError: String?,
        isSyncing: Bool)
    {
        guard let config else { return nil }
        self.title = "MyCCusage Community"
        let orderedAgents = MyCCusageAgentType.allCases.filter { config.agentTypes.contains($0) }
        self.uploadText = "Providers: " + orderedAgents.map(\.label).joined(separator: ", ")
        self.actionText = isSyncing ? "Syncing..." : "Sync Now"
        self.isActionEnabled = !isSyncing
        self.isSyncing = isSyncing

        if let leaderboard {
            self.status = "#\(leaderboard.rank) today " +
                "\(MyCCusageLeaderboardSnapshot.usd(leaderboard.own.totalCost)) / " +
                "\(MyCCusageLeaderboardSnapshot.tokens(leaderboard.own.totalTokens))"
            self.leaderText = "Leader \(leaderboard.leader.displayName) " +
                MyCCusageLeaderboardSnapshot.usd(leaderboard.leader.totalCost)
            self.gapText = "Gap " + MyCCusageLeaderboardSnapshot.usd(leaderboard.gapToLeader)
            self.progressPercent = Self.progressPercent(
                own: leaderboard.own.totalCost,
                leader: leaderboard.leader.totalCost)
        } else if let lastError, !lastError.isEmpty {
            self.status = "Community: " + UsageFormatter.truncatedSingleLine(lastError, max: 80)
            self.leaderText = nil
            self.gapText = nil
            self.progressPercent = 0
        } else {
            self.status = "Community: no ranking data yet"
            self.leaderText = nil
            self.gapText = nil
            self.progressPercent = 0
        }
    }

    private static func progressPercent(own: Double, leader: Double) -> Double {
        guard leader > 0 else { return 0 }
        return min(100, max(0, own / leader * 100))
    }
}

struct MyCCusageCommunityCardView: View {
    let model: MyCCusageCommunityCardModel
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @State private var isActionHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.model.title)
                    .font(.headline)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                Spacer(minLength: 8)
                self.actionButton
            }

            Text(self.model.status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)

            UsageProgressBar(
                percent: self.model.progressPercent,
                tint: CodexBarOrangeTheme.actionSecondaryColor,
                accessibilityLabel: "MyCCusage community chasing progress",
                pacePercent: 100,
                paceOnTop: false)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let leaderText = model.leaderText {
                    Text(leaderText)
                        .lineLimit(1)
                }
                if let gapText = model.gapText {
                    Text(gapText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }

    private var actionButton: some View {
        Text(self.model.actionText)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(CodexBarOrangeTheme.actionColor.opacity(self.model.isActionEnabled ? 1 : 0.72)))
            .overlay(
                Capsule()
                    .stroke(.white.opacity(self.isActionHovered ? 0.45 : 0), lineWidth: 1))
            .shadow(
                color: CodexBarOrangeTheme.actionColor.opacity(self.isActionHovered ? 0.34 : 0),
                radius: self.isActionHovered ? 5 : 0,
                y: self.isActionHovered ? 2 : 0)
            .scaleEffect(self.isActionHovered ? 1.08 : 1, anchor: .center)
            .animation(.snappy(duration: 0.12), value: self.isActionHovered)
            .onHover { hovering in
                self.isActionHovered = hovering && self.model.isActionEnabled
            }
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let showAll: Bool
    let showSwitcher: Bool
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
}
