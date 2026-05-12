// Minimal placeholder ProviderDescriptor.
//
// User-facing wiring (icon, branding, fetch strategy, settings pane) is
// out of scope for this PR — see PR description. The descriptor exists only
// so that `ProviderDescriptorRegistry.bootstrap` can register every
// UsageProvider case (the `.cherryStudio` enum case ships in this PR).
//
// `iconStyle: .codex` is an intentional placeholder; no menu surface currently
// renders Cherry Studio so the icon never appears. The follow-up Cherry
// Studio UI PR will replace this with the real descriptor + icon.

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
                iconStyle: .codex,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 231 / 255, green: 57 / 255, blue: 65 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Cherry Studio local usage scanner — see CherryStudioLocalUsageScanner." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [] })),
            cli: ProviderCLIConfig(
                name: "cherry-studio",
                aliases: ["cherrystudio", "cherry"],
                versionDetector: nil))
    }
}
