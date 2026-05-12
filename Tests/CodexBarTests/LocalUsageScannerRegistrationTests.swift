import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Exercises the scanner-registration entry point CodexBarApp invokes at
/// launch. Kept in a serialized suite because LocalUsageScannerRegistry is a
/// global singleton; running these tests in parallel with other registry
/// users would clobber state.
@Suite(.serialized)
struct LocalUsageScannerRegistrationTests {
    @Test
    func `registerLocalUsageScanners installs the five ccusage providers plus vertex`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        CodexBarApp._test_registerLocalUsageScanners()

        for provider in [UsageProvider.claude, .codex, .opencode, .cherryStudio, .openclaw, .vertexai] {
            #expect(
                LocalUsageScannerRegistry.resolve(for: provider) != nil,
                "expected a registered scanner for \(provider)")
        }
    }

    @Test
    func `registerLocalUsageScanners does not install scanners for non-ccusage providers`() {
        LocalUsageScannerRegistry.unregisterAll()
        defer { LocalUsageScannerRegistry.unregisterAll() }

        CodexBarApp._test_registerLocalUsageScanners()

        for provider in [UsageProvider.cursor, .gemini, .copilot] {
            #expect(
                LocalUsageScannerRegistry.resolve(for: provider) == nil,
                "did not expect a registered scanner for \(provider)")
        }
    }
}
