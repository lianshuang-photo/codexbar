import CodexBarCore
import Foundation
import SweetCookieKit

@MainActor
extension UsageStore {
    func debugClaudeDump() async -> String {
        await ClaudeStatusProbe.latestDumps()
    }
}

extension UsageStore {
    struct ClaudeDebugLogConfiguration {
        let runtime: CodexBarCore.ProviderRuntime
        let sourceMode: ProviderSourceMode
        let environment: [String: String]
        let webExtrasEnabled: Bool
        let usageDataSource: ClaudeUsageDataSource
        let cookieSource: ProviderCookieSource
        let cookieHeader: String
        let keepCLISessionsAlive: Bool
    }

    static func debugClaudeLog(
        browserDetection: BrowserDetection,
        configuration: ClaudeDebugLogConfiguration) async -> String
    {
        struct OAuthDebugProbe: Sendable {
            let hasCredentials: Bool
            let ownerRawValue: String
            let sourceRawValue: String
            let isExpired: Bool
        }

        return await runWithTimeout(seconds: 15) {
            var lines: [String] = []
            let oauthProbe = await withTaskGroup(of: OAuthDebugProbe.self) { group in
                // Preserve task-local test overrides while keeping the keychain read off the calling task.
                group.addTask(priority: .utility) {
                    let oauthRecord = try? ClaudeOAuthCredentialsStore.loadRecord(
                        environment: configuration.environment,
                        allowKeychainPrompt: false,
                        respectKeychainPromptCooldown: true,
                        allowClaudeKeychainRepairWithoutPrompt: false)
                    return OAuthDebugProbe(
                        hasCredentials: oauthRecord?.credentials.scopes.contains("user:profile") == true,
                        ownerRawValue: oauthRecord?.owner.rawValue ?? "none",
                        sourceRawValue: oauthRecord?.source.rawValue ?? "none",
                        isExpired: oauthRecord?.credentials.isExpired ?? false)
                }
                return await group.next() ?? OAuthDebugProbe(
                    hasCredentials: false,
                    ownerRawValue: "none",
                    sourceRawValue: "none",
                    isExpired: false)
            }
            let hasOAuthCredentials = ClaudeOAuthPlanningAvailability.isAvailable(
                runtime: configuration.runtime,
                sourceMode: configuration.sourceMode,
                environment: configuration.environment)
            let hasClaudeBinary = ClaudeCLIResolver.isAvailable(environment: configuration.environment)
            let delegatedCooldownSeconds = ClaudeOAuthDelegatedRefreshCoordinator.cooldownRemainingSeconds()
            let planningInput = ClaudeSourcePlanningInput(
                runtime: configuration.runtime,
                selectedDataSource: configuration.usageDataSource,
                webExtrasEnabled: configuration.webExtrasEnabled,
                hasCLI: hasClaudeBinary,
                hasOAuthCredentials: hasOAuthCredentials)
            let plan = ClaudeSourcePlanner.resolve(input: planningInput)
            let strategy = plan.compatibilityStrategy

            lines.append(contentsOf: plan.debugLines())
            lines.append("hasOAuthCredentials=\(hasOAuthCredentials)")
            lines.append("oauthCredentialOwner=\(oauthProbe.ownerRawValue)")
            lines.append("oauthCredentialSource=\(oauthProbe.sourceRawValue)")
            lines.append("oauthCredentialExpired=\(oauthProbe.isExpired)")
            lines.append("delegatedRefreshCLIAvailable=\(hasClaudeBinary)")
            lines.append("delegatedRefreshCooldownActive=\(delegatedCooldownSeconds != nil)")
            if let delegatedCooldownSeconds {
                lines.append("delegatedRefreshCooldownSeconds=\(delegatedCooldownSeconds)")
            }
            lines.append("hasClaudeBinary=\(hasClaudeBinary)")
            if strategy?.useWebExtras == true {
                lines.append("web_extras=enabled")
            }
            lines.append("")

            guard let strategy else {
                lines.append("No planner-selected Claude source.")
                return lines.joined(separator: "\n")
            }

            switch strategy.dataSource {
            case .auto:
                lines.append("Auto source selected.")
                return lines.joined(separator: "\n")
            case .cli:
                let fetcher = ClaudeUsageFetcher(
                    browserDetection: browserDetection,
                    environment: configuration.environment,
                    runtime: configuration.runtime,
                    dataSource: configuration.usageDataSource,
                    keepCLISessionsAlive: configuration.keepCLISessionsAlive)
                let cli = await fetcher.debugRawProbe(model: "sonnet")
                lines.append(cli)
                return lines.joined(separator: "\n")
            case .oauth:
                lines.append("OAuth source selected.")
                return lines.joined(separator: "\n")
            }
        }
    }
}
