import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct OpenClawProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openclaw
}
