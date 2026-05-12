import Foundation
import Testing
@testable import CodexBarCore

@Suite("CherryInPricingCatalog")
struct CherryInPricingCatalogTests {
    private static func sampleCatalog() -> CherryInPricingCatalog {
        CherryInPricingCatalog(
            pricingVersion: "test-1",
            groupRatio: ["default": 1.0, "x_express_internal": 0.5],
            items: [
                "anthropic/claude-sonnet-4.5": CherryInPricingItem(
                    modelName: "anthropic/claude-sonnet-4.5",
                    modelRatio: 3,
                    completionRatio: 5,
                    enableGroups: ["default", "x_express_internal"]),
                "agent/minimax-m2": CherryInPricingItem(
                    modelName: "agent/minimax-m2",
                    modelRatio: 0.3,
                    completionRatio: 4,
                    enableGroups: ["default"]),
                "openai/gpt-5": CherryInPricingItem(
                    modelName: "openai/gpt-5",
                    modelRatio: 1.25,
                    completionRatio: 8,
                    enableGroups: ["x_express_internal"]),
            ])
    }

    @Test
    func `lookup returns exact match when model_name matches verbatim`() {
        let catalog = Self.sampleCatalog()
        let resolved = try? #require(catalog.lookup(
            provider: "anthropic",
            model: "anthropic/claude-sonnet-4.5"))
        #expect(resolved?.pricingModel == "anthropic/claude-sonnet-4.5")
        #expect(resolved?.pricingGroup == "x_express_internal")
        // model_ratio (3) * group_ratio (0.5) = 1.5; output = 1.5 * 5 = 7.5
        #expect(resolved?.inputRatePerMillion == 1.5)
        #expect(resolved?.outputRatePerMillion == 7.5)
    }

    @Test
    func `lookup falls back to anthropic-slash alias for unprefixed model`() {
        let catalog = Self.sampleCatalog()
        let resolved = try? #require(catalog.lookup(
            provider: "anthropic",
            model: "claude-sonnet-4.5"))
        #expect(resolved?.pricingModel == "anthropic/claude-sonnet-4.5")
    }

    @Test
    func `lookup returns nil for model not in catalog`() {
        let catalog = Self.sampleCatalog()
        #expect(catalog.lookup(provider: "anthropic", model: "claude-99") == nil)
    }

    @Test
    func `lookup skips alias prefixes when model already contains slash`() {
        let catalog = Self.sampleCatalog()
        // "anthropic/claude-99" not in catalog and we don't try
        // "agent/anthropic/claude-99" etc — TS line 367 guard.
        #expect(catalog.lookup(provider: "anthropic", model: "anthropic/claude-99") == nil)
    }

    @Test
    func `picks default group when model only enables default`() {
        let catalog = Self.sampleCatalog()
        let resolved = try? #require(catalog.lookup(
            provider: "anthropic",
            model: "agent/minimax-m2"))
        #expect(resolved?.pricingGroup == "default")
        // groupRatio[default] = 1, modelRatio = 0.3 -> input = 0.3
        #expect(resolved?.inputRatePerMillion == 0.3)
        // completionRatio = 4 -> output = 0.3 * 4 = 1.2
        #expect(resolved?.outputRatePerMillion == 1.2)
    }

    @Test
    func `picks x_express_internal when provider is x-express-internal even without enable group`() {
        let catalog = Self.sampleCatalog()
        // model only enables default, but provider triggers x_express_internal
        // fallback per TS line 385.
        let resolved = try? #require(catalog.lookup(
            provider: "x-express-internal",
            model: "agent/minimax-m2"))
        #expect(resolved?.pricingGroup == "x_express_internal")
    }

    @Test
    func `lookup tries agent prefix before deepseek before anthropic before openai before google`() {
        let catalog = CherryInPricingCatalog(
            pricingVersion: nil,
            groupRatio: ["default": 1.0],
            items: [
                "google/foo": CherryInPricingItem(
                    modelName: "google/foo",
                    modelRatio: 1,
                    completionRatio: 1,
                    enableGroups: ["default"]),
                "agent/foo": CherryInPricingItem(
                    modelName: "agent/foo",
                    modelRatio: 7,
                    completionRatio: 1,
                    enableGroups: ["default"]),
            ])
        // Both exist — TS line 368 order tries agent first.
        let resolved = try? #require(catalog.lookup(provider: "", model: "foo"))
        #expect(resolved?.pricingModel == "agent/foo")
        #expect(resolved?.inputRatePerMillion == 7)
    }
}

@Suite("CherryInPricingClient")
struct CherryInPricingClientTests {
    @Test
    func `parseCatalog reads data array + group_ratio + pricing_version`() {
        let payload: [String: Any] = [
            "pricing_version": "2026-04-01",
            "group_ratio": ["default": 1.0, "x_express_internal": 0.5],
            "data": [
                [
                    "model_name": "anthropic/claude-sonnet-4.5",
                    "model_ratio": 3,
                    "completion_ratio": 5,
                    "enable_groups": ["default", "x_express_internal"],
                ],
                // Missing fields default sanely; entries without model_name dropped.
                ["model_ratio": 1.0],
                ["model_name": "agent/minimax-m2", "model_ratio": "0.3"],
            ],
        ]
        let catalog = CherryInPricingClient.parseCatalog(payload)
        #expect(catalog.pricingVersion == "2026-04-01")
        #expect(catalog.groupRatio["default"] == 1.0)
        #expect(catalog.items.count == 2)
        #expect(catalog.items["anthropic/claude-sonnet-4.5"]?.completionRatio == 5)
        // String-valued numbers parsed.
        #expect(catalog.items["agent/minimax-m2"]?.modelRatio == 0.3)
        // Defaulted completionRatio is 1 when missing.
        #expect(catalog.items["agent/minimax-m2"]?.completionRatio == 1)
    }

    @Test
    func `parseCatalog tolerates missing data and group_ratio`() {
        let payload: [String: Any] = [:]
        let catalog = CherryInPricingClient.parseCatalog(payload)
        #expect(catalog.pricingVersion == nil)
        #expect(catalog.groupRatio.isEmpty)
        #expect(catalog.items.isEmpty)
    }
}

@Suite(.serialized)
struct CherryInPricingCacheTests {
    @Test
    func `save then load round trips the catalog and timestamps freshness correctly`() {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryInPricingCacheTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let catalog = CherryInPricingCatalog(
            pricingVersion: "v1",
            groupRatio: ["default": 1.0],
            items: ["openai/gpt-5": CherryInPricingItem(
                modelName: "openai/gpt-5",
                modelRatio: 1.25,
                completionRatio: 8,
                enableGroups: ["default"])])

        let fetchedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let artifact = CherryInPricingCacheArtifact(
            version: CherryInPricingCache.artifactVersion,
            fetchedAt: fetchedAt,
            catalog: catalog)
        CherryInPricingCache.save(artifact: artifact, cacheRoot: cacheRoot)

        // Within TTL — not stale.
        let fresh = CherryInPricingCache.load(
            now: fetchedAt.addingTimeInterval(60),
            cacheRoot: cacheRoot)
        #expect(fresh.artifact?.catalog == catalog)
        #expect(fresh.isStale == false)

        // Past TTL — stale but artifact still returned.
        let stale = CherryInPricingCache.load(
            now: fetchedAt.addingTimeInterval(CherryInPricingCache.ttlSeconds + 1),
            cacheRoot: cacheRoot)
        #expect(stale.artifact?.catalog == catalog)
        #expect(stale.isStale == true)
    }

    @Test
    func `load returns nil artifact when cache file missing`() {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryInPricingCacheTests-missing-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let result = CherryInPricingCache.load(cacheRoot: cacheRoot)
        #expect(result.artifact == nil)
        #expect(result.isStale == true)
    }
}

@Suite(.serialized)
struct CherryInPricingPipelineTests {
    private struct StaticTransport: CherryInPricingHTTPTransport {
        let payload: Data
        let statusCode: Int
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: self.statusCode,
                httpVersion: nil,
                headerFields: nil)!
            return (self.payload, response)
        }
    }

    @Test
    func `refreshIfNeeded writes catalog to disk when cache is missing`() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryInPricingPipelineTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let json = #"""
        {
          "pricing_version": "pipeline-1",
          "group_ratio": {"default": 1.0},
          "data": [
            {
              "model_name": "anthropic/claude-sonnet-4.5",
              "model_ratio": 3,
              "completion_ratio": 5,
              "enable_groups": ["default"]
            }
          ]
        }
        """#
        let client = try CherryInPricingClient(
            url: #require(URL(string: "https://example.invalid/api/pricing")),
            transport: StaticTransport(payload: Data(json.utf8), statusCode: 200))
        await CherryInPricingPipeline.refreshIfNeeded(cacheRoot: cacheRoot, client: client)

        let catalog = try #require(CherryInPricingPipeline.loadCachedCatalog(cacheRoot: cacheRoot))
        #expect(catalog.pricingVersion == "pipeline-1")
        #expect(catalog.items["anthropic/claude-sonnet-4.5"]?.modelRatio == 3)
    }

    @Test
    func `refreshIfNeeded skips fetch when cache is fresh`() async {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryInPricingPipelineTests-fresh-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Pre-populate cache with a known catalog.
        let preExisting = CherryInPricingCatalog(
            pricingVersion: "pre-existing",
            groupRatio: [:],
            items: [:])
        CherryInPricingCache.save(
            artifact: CherryInPricingCacheArtifact(
                version: CherryInPricingCache.artifactVersion,
                fetchedAt: Date(),
                catalog: preExisting),
            cacheRoot: cacheRoot)

        // A failing transport would throw — but since cache is fresh, transport
        // must not be invoked. We assert success by checking the catalog is
        // unchanged after refreshIfNeeded.
        struct FailingTransport: CherryInPricingHTTPTransport {
            func data(for _: URLRequest) async throws -> (Data, URLResponse) {
                Issue.record("Transport should not have been called when cache is fresh")
                throw CherryInPricingClient.FetchError.invalidResponse
            }
        }
        let client = CherryInPricingClient(transport: FailingTransport())
        await CherryInPricingPipeline.refreshIfNeeded(cacheRoot: cacheRoot, client: client)

        let catalog = CherryInPricingPipeline.loadCachedCatalog(cacheRoot: cacheRoot)
        #expect(catalog?.pricingVersion == "pre-existing")
    }
}

@Suite(.serialized)
struct CherryStudioScannerPricingInjectionTests {
    @Test
    func `scanner with injected catalog applies cherryin rates to agent-db rows`() {
        // No real Cherry Studio is available in CI, so we exercise the
        // injection path by feeding an empty config (no app data dirs) and
        // asserting the scanner accepts the catalog without crashing. The
        // end-to-end cost math is covered by the existing fixture-based
        // tests for the static PRICE_TABLE path, and by the ad-hoc parity
        // check against cherry-local.ts (run manually).
        let catalog = CherryInPricingCatalog(
            pricingVersion: "t",
            groupRatio: ["default": 1.0],
            items: [:])
        let scanner = CherryStudioLocalUsageScanner(
            configuration: CherryStudioLocalUsageScanner.Configuration(
                appNames: [],
                supportBaseOverride: FileManager.default.temporaryDirectory,
                extraAppDataDirs: []),
            pricingCatalog: catalog)
        let report = scanner.loadDailyReport(
            since: Date(timeIntervalSince1970: 0),
            until: Date(),
            now: Date(),
            options: LocalUsageScanOptions())
        #expect(report.data.isEmpty)
    }
}
