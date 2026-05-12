import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Port of the network-fetched pricing table that `cherry-local.ts` calls
// `PRICING_API`. cherry-local.ts pulls this from
// `https://express-ent-admin.cherryin.ai/api/pricing` and applies it inside
// `applyCherryInPricing` (TS line 377). The v1 Swift port skipped this entirely
// and left cost at 0 for most models; this file fills that gap.
//
// Pipeline mirrors the existing `ModelsDevPricing.swift` layout:
//   - Catalog value type with the `model_name → PricingItem` map and
//     `group_ratio` table.
//   - On-disk cache (`CherryInPricingCache`) with TTL + atomic writes.
//   - HTTP transport + `CherryInPricingClient` for the actual fetch.
//   - `CherryInPricingPipeline.refreshIfNeeded()` for callers to invoke
//     before opening the scanner; `CherryInPricingPipeline.loadCachedCatalog()`
//     for the scanner's synchronous read path.

public struct CherryInPricingItem: Codable, Sendable, Equatable {
    public let modelName: String
    public let modelRatio: Double
    public let completionRatio: Double
    public let enableGroups: [String]

    public init(modelName: String, modelRatio: Double, completionRatio: Double, enableGroups: [String]) {
        self.modelName = modelName
        self.modelRatio = modelRatio
        self.completionRatio = completionRatio
        self.enableGroups = enableGroups
    }
}

public struct CherryInPricingCatalog: Codable, Sendable, Equatable {
    public let pricingVersion: String?
    public let groupRatio: [String: Double]
    public let items: [String: CherryInPricingItem]

    public init(
        pricingVersion: String?,
        groupRatio: [String: Double],
        items: [String: CherryInPricingItem])
    {
        self.pricingVersion = pricingVersion
        self.groupRatio = groupRatio
        self.items = items
    }

    public struct Resolved: Sendable, Equatable {
        public let inputRatePerMillion: Double
        public let outputRatePerMillion: Double
        public let pricingModel: String
        public let pricingGroup: String
    }

    public func lookup(provider: String, model: String) -> Resolved? {
        if let exact = self.items[model] {
            return self.resolve(item: exact, provider: provider)
        }
        guard !model.contains("/") else { return nil }
        for prefix in ["agent/", "deepseek/", "anthropic/", "openai/", "google/"] {
            if let aliased = self.items[prefix + model] {
                return self.resolve(item: aliased, provider: provider)
            }
        }
        return nil
    }

    private func resolve(item: CherryInPricingItem, provider: String) -> Resolved {
        let group = self.pickGroup(item: item, provider: provider)
        let groupRatio = self.sanitizedGroupRatio(for: group)
        let inputRate = item.modelRatio * groupRatio
        let completionRatio = item.completionRatio == 0 ? 1 : item.completionRatio
        let outputRate = inputRate * completionRatio
        return Resolved(
            inputRatePerMillion: inputRate,
            outputRatePerMillion: outputRate,
            pricingModel: item.modelName,
            pricingGroup: group)
    }

    private func pickGroup(item: CherryInPricingItem, provider: String) -> String {
        let groups = item.enableGroups
        if groups.contains("x_express_internal") || provider == "x-express-internal" {
            return "x_express_internal"
        }
        if groups.contains("default") {
            return "default"
        }
        return groups.first ?? "default"
    }

    private func sanitizedGroupRatio(for group: String) -> Double {
        let raw = self.groupRatio[group] ?? 1
        if !raw.isFinite || raw == 0 { return 1 }
        return raw
    }
}

public struct CherryInPricingCacheArtifact: Codable, Sendable, Equatable {
    public let version: Int
    public let fetchedAt: Date
    public let catalog: CherryInPricingCatalog

    public init(version: Int, fetchedAt: Date, catalog: CherryInPricingCatalog) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.catalog = catalog
    }
}

public enum CherryInPricingCache {
    public static let artifactVersion = 1
    public static let ttlSeconds: TimeInterval = 6 * 60 * 60

    public static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? Self.defaultCacheRoot()
        return root
            .appendingPathComponent("cherry-in-pricing", isDirectory: true)
            .appendingPathComponent("v\(Self.artifactVersion).json", isDirectory: false)
    }

    public struct LoadResult: Sendable {
        public let artifact: CherryInPricingCacheArtifact?
        public let isStale: Bool
    }

    public static func load(now: Date = Date(), cacheRoot: URL? = nil) -> LoadResult {
        let url = Self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(artifact: nil, isStale: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(CherryInPricingCacheArtifact.self, from: data),
              decoded.version == Self.artifactVersion
        else {
            return LoadResult(artifact: nil, isStale: true)
        }
        let isStale = now.timeIntervalSince(decoded.fetchedAt) > Self.ttlSeconds
        return LoadResult(artifact: decoded, isStale: isStale)
    }

    public static func save(artifact: CherryInPricingCacheArtifact, cacheRoot: URL? = nil) {
        let url = Self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(artifact) else { return }
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func defaultCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("CodexBar", isDirectory: true)
    }
}

public protocol CherryInPricingHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionCherryInPricingTransport: CherryInPricingHTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

public struct CherryInPricingClient: Sendable {
    public enum FetchError: Swift.Error, Sendable, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case invalidJSON
    }

    public var url: URL
    public var transport: any CherryInPricingHTTPTransport

    public init(
        url: URL = URL(string: CherryStudioLocalUsageScanner.pricingAPIURLString)!,
        transport: any CherryInPricingHTTPTransport = URLSessionCherryInPricingTransport())
    {
        self.url = url
        self.transport = transport
    }

    public func fetchCatalog() async throws -> CherryInPricingCatalog {
        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await self.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let payload = json as? [String: Any]
        else {
            throw FetchError.invalidJSON
        }
        return Self.parseCatalog(payload)
    }

    public static func parseCatalog(_ payload: [String: Any]) -> CherryInPricingCatalog {
        let pricingVersion = payload["pricing_version"] as? String
        var groupRatio: [String: Double] = [:]
        if let raw = payload["group_ratio"] as? [String: Any] {
            for (key, value) in raw {
                if let parsed = Self.doubleValue(value) { groupRatio[key] = parsed }
            }
        }
        var items: [String: CherryInPricingItem] = [:]
        if let dataArr = payload["data"] as? [[String: Any]] {
            for entry in dataArr {
                guard let name = entry["model_name"] as? String, !name.isEmpty else { continue }
                let modelRatio = Self.doubleValue(entry["model_ratio"]) ?? 0
                let completionRatio = Self.doubleValue(entry["completion_ratio"]) ?? 1
                let groups = (entry["enable_groups"] as? [String]) ?? []
                items[name] = CherryInPricingItem(
                    modelName: name,
                    modelRatio: modelRatio,
                    completionRatio: completionRatio,
                    enableGroups: groups)
            }
        }
        return CherryInPricingCatalog(
            pricingVersion: pricingVersion,
            groupRatio: groupRatio,
            items: items)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = value as? String, let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }
}

public enum CherryInPricingPipeline {
    public static func loadCachedCatalog(cacheRoot: URL? = nil) -> CherryInPricingCatalog? {
        CherryInPricingCache.load(cacheRoot: cacheRoot).artifact?.catalog
    }

    public static func refreshIfNeeded(
        now: Date = Date(),
        cacheRoot: URL? = nil,
        client: CherryInPricingClient = CherryInPricingClient()) async
    {
        let cached = CherryInPricingCache.load(now: now, cacheRoot: cacheRoot)
        if cached.artifact != nil, !cached.isStale { return }
        guard let catalog = try? await client.fetchCatalog() else { return }
        let artifact = CherryInPricingCacheArtifact(
            version: CherryInPricingCache.artifactVersion,
            fetchedAt: now,
            catalog: catalog)
        CherryInPricingCache.save(artifact: artifact, cacheRoot: cacheRoot)
    }
}
