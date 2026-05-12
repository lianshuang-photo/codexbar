import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MyCCusageUploadError: Error, Equatable, Sendable {
    case invalidResponse
    case unauthorized(status: Int, message: String?)
    case retriesExhausted(lastStatus: Int?, lastMessage: String?)
    case encodingFailed
    case recordErrors([String])
}

public struct MyCCusageUploadResult: Sendable, Equatable {
    public let processed: Int
    public let errors: [String]

    public init(processed: Int, errors: [String]) {
        self.processed = processed
        self.errors = errors
    }
}

public protocol MyCCusageUploadTransport: Sendable {
    func data(for request: URLRequest, body: Data) async throws -> (Data, URLResponse)
}

public struct URLSessionMyCCusageUploadTransport: MyCCusageUploadTransport {
    public init() {}

    public func data(for request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        var mutableRequest = request
        mutableRequest.httpBody = body
        return try await URLSession.shared.data(for: mutableRequest)
    }
}

/// Swift-native equivalent of the collector daemon's `syncData()`. Posts one
/// `UsageData` payload per agent type to the configured `/api/usage-sync`
/// endpoint. Retries on transient (5xx / network) failures, fails fast on
/// authentication errors. Co-exists safely with a running PM2 daemon — the
/// server is idempotent on (deviceId, date) so duplicate uploads are merged.
public struct MyCCusageUploader: Sendable {
    public let transport: any MyCCusageUploadTransport
    public let retryBaseDelay: TimeInterval
    public let now: @Sendable () -> Date

    public init(
        transport: any MyCCusageUploadTransport = URLSessionMyCCusageUploadTransport(),
        retryBaseDelay: TimeInterval = 1.0,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.transport = transport
        self.retryBaseDelay = retryBaseDelay
        self.now = now
    }

    public func upload(
        payload: MyCCusageUsageDataPayload,
        endpoint: URL,
        apiKey: String,
        maxRetries: Int = 3) async throws -> MyCCusageUploadResult
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else {
            throw MyCCusageUploadError.encodingFailed
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        var lastStatus: Int?
        var lastMessage: String?
        let attempts = max(1, maxRetries)

        for attempt in 1...attempts {
            do {
                let (data, response) = try await self.transport.data(for: request, body: body)
                guard let http = response as? HTTPURLResponse else {
                    throw MyCCusageUploadError.invalidResponse
                }
                lastStatus = http.statusCode

                if http.statusCode == 401 || http.statusCode == 403 {
                    let message = Self.errorMessage(from: data)
                    throw MyCCusageUploadError.unauthorized(status: http.statusCode, message: message)
                }

                if (200..<300).contains(http.statusCode) {
                    return try Self.parseSuccess(data: data)
                }

                lastMessage = Self.errorMessage(from: data)
            } catch let error as MyCCusageUploadError {
                throw error
            } catch {
                lastMessage = error.localizedDescription
            }

            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(Self.delay(
                    base: self.retryBaseDelay,
                    attempt: attempt) * 1_000_000_000))
            }
        }

        throw MyCCusageUploadError.retriesExhausted(lastStatus: lastStatus, lastMessage: lastMessage)
    }

    static func parseSuccess(data: Data) throws -> MyCCusageUploadResult {
        struct ResponseBody: Decodable {
            let success: Bool?
            let processed: Int?
            let results: [Record]?

            struct Record: Decodable {
                let date: String?
                let status: String?
                let message: String?
            }
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            return MyCCusageUploadResult(processed: 0, errors: [])
        }
        let recordErrors = (decoded.results ?? [])
            .filter { $0.status == "error" }
            .map { "\($0.date ?? "?"): \($0.message ?? "unknown error")" }
        if !recordErrors.isEmpty {
            throw MyCCusageUploadError.recordErrors(recordErrors)
        }
        return MyCCusageUploadResult(processed: decoded.processed ?? 0, errors: [])
    }

    static func errorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable { let error: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }

    static func delay(base: TimeInterval, attempt: Int) -> TimeInterval {
        // Match collector's linear retryDelay × attempt (no exponential).
        base * Double(attempt)
    }
}
