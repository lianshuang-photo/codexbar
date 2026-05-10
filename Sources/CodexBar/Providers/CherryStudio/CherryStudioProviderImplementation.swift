import CodexBarCore
import CodexBarMacroSupport

@ProviderImplementationRegistration
struct CherryStudioProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cherryStudio

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "collector" }
    }

    @MainActor
    func defaultSourceLabel(context _: ProviderSourceLabelContext) -> String? {
        "collector"
    }
}
