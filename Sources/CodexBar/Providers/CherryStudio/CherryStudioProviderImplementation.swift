// Minimal stub. The user-facing wiring (ProviderDescriptor, icon, settings
// pane, menu cards) is out of scope for this PR — see PR description. The
// stub exists only because adding the `.cherryStudio` enum case to
// `UsageProvider` makes Swift's exhaustiveness checking force a placeholder
// inside `ProviderImplementationRegistry`.

import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct CherryStudioProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cherryStudio
}
