import CodexBarMacroSupport
import Foundation

/// OpenClaw is a local-only provider: usage data is read from `~/.openclaw/agents/*/sessions/*.jsonl`
/// via ``OpenClawLocalUsageScanner``. It has no web dashboard, no OAuth, and no cookie/API auth, so
/// the fetch plan is intentionally empty — callers go through the LocalUsageScanner pipeline.
///
/// TODO: ship the `ProviderIcon-openclaw` asset in a follow-up PR. For now the resource name is
/// declared so branding code can resolve it; until the SVG lands, the menu/widget will fall back
/// to a placeholder.
@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenClawProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openclaw,
            metadata: ProviderMetadata(
                id: .openclaw,
                displayName: "OpenClaw",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenClaw usage",
                cliName: "openclaw",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .openclaw,
                iconResourceName: "ProviderIcon-openclaw",
                color: ProviderColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No OpenClaw session data found." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [] })),
            cli: ProviderCLIConfig(
                name: "openclaw",
                versionDetector: nil))
    }
}
