import Foundation

public struct MyCCusageStatsClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func statsEndpointURL(fromSyncEndpoint syncEndpoint: URL) -> URL? {
        var components = URLComponents(url: syncEndpoint, resolvingAgainstBaseURL: false)
        var path = components?.path ?? syncEndpoint.path
        if path.hasSuffix("/usage-sync") {
            path.removeLast("usage-sync".count)
            path += "usage-stats"
        } else if path.hasSuffix("/api/usage-sync/") {
            path = path.replacingOccurrences(of: "/api/usage-sync/", with: "/api/usage-stats/")
        } else {
            path = "/api/usage-stats"
        }
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    public func fetchStats(syncEndpoint: URL) async throws -> Data {
        guard let url = Self.statsEndpointURL(fromSyncEndpoint: syncEndpoint) else {
            throw MyCCusageStatsClientError.invalidStatsEndpoint
        }
        let (data, response) = try await self.session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            throw MyCCusageStatsClientError.httpStatus(http.statusCode)
        }
        return data
    }
}

public enum MyCCusageStatsClientError: Error, Equatable {
    case invalidStatsEndpoint
    case httpStatus(Int)
}
