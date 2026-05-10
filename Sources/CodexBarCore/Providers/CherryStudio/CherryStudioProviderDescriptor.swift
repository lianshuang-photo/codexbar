import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CherryStudioProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cherryStudio,
            metadata: ProviderMetadata(
                id: .cherryStudio,
                displayName: "Cherry Studio",
                sessionLabel: "Today",
                weeklyLabel: "Total",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Cherry Studio usage",
                cliName: "cherry-studio",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .cherryStudio,
                iconResourceName: "ProviderIcon-cherrystudio",
                color: ProviderColor(red: 231 / 255, green: 57 / 255, blue: 65 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Cherry Studio cost summary is handled by MyCCusage Collector." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [] })),
            cli: ProviderCLIConfig(
                name: "cherry-studio",
                aliases: ["cherrystudio", "cherry"],
                versionDetector: nil))
    }
}
