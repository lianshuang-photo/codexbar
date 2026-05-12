import CodexBarCore
import Foundation
import Testing

@Suite("MyCCusageUploadPayloadBuilder")
struct MyCCusageUploadPayloadBuilderTests {
    @Test
    func `daily record carries token + cost fields from CostUsageDailyReport`() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-05-12",
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 10,
            cacheCreationTokens: 5,
            totalTokens: 315,
            costUSD: 0.5,
            modelsUsed: ["claude-sonnet-4.5"],
            modelBreakdowns: [
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "claude-sonnet-4.5",
                    costUSD: 0.5,
                    totalTokens: 315),
            ])
        let report = CostUsageDailyReport(data: [entry], summary: nil)
        let payload = MyCCusageUploadPayloadBuilder.buildPayload(
            agentType: .claudeCode,
            report: report,
            deviceId: "abc",
            deviceName: "host",
            displayName: "tianyi")
        #expect(payload.device.deviceId == "abc")
        #expect(payload.device.deviceName == "host")
        #expect(payload.device.displayName == "tianyi")
        #expect(payload.device.agentType == "claude-code")
        let day = try? #require(payload.daily.first)
        #expect(day?.date == "2026-05-12")
        #expect(day?.inputTokens == 100)
        #expect(day?.outputTokens == 200)
        #expect(day?.cacheReadTokens == 10)
        #expect(day?.cacheCreationTokens == 5)
        #expect(day?.totalTokens == 315)
        #expect(day?.totalCost == 0.5)
        #expect(day?.modelsUsed == ["claude-sonnet-4.5"])
        #expect(day?.modelBreakdowns.first?.modelName == "claude-sonnet-4.5")
        #expect(day?.modelBreakdowns.first?.cost == 0.5)
    }

    @Test
    func `totals fall back to summing the daily records when summary is missing`() {
        let entries = [
            CostUsageDailyReport.Entry(
                date: "2026-05-10",
                inputTokens: 1, outputTokens: 2,
                cacheReadTokens: 0, cacheCreationTokens: 0,
                totalTokens: 3, costUSD: 0.1,
                modelsUsed: ["m"], modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-05-11",
                inputTokens: 4, outputTokens: 8,
                cacheReadTokens: 1, cacheCreationTokens: 2,
                totalTokens: 15, costUSD: 0.2,
                modelsUsed: ["m"], modelBreakdowns: nil),
        ]
        let report = CostUsageDailyReport(data: entries, summary: nil)
        let payload = MyCCusageUploadPayloadBuilder.buildPayload(
            agentType: .codex,
            report: report,
            deviceId: "d",
            deviceName: "h",
            displayName: nil)
        #expect(payload.totals.inputTokens == 5)
        #expect(payload.totals.outputTokens == 10)
        #expect(payload.totals.cacheReadTokens == 1)
        #expect(payload.totals.cacheCreationTokens == 2)
        #expect(payload.totals.totalTokens == 18)
        #expect(abs(payload.totals.totalCost - 0.3) < 1e-9)
    }

    @Test
    func `agent type rawValue matches upstream collector AgentType strings`() {
        // Server expects exactly these strings — see ccusage-cherry-collector/src/types.ts.
        #expect(MyCCusageAgentType.claudeCode.rawValue == "claude-code")
        #expect(MyCCusageAgentType.cherryStudio.rawValue == "cherry-studio")
        #expect(MyCCusageAgentType.opencode.rawValue == "opencode")
        #expect(MyCCusageAgentType.codex.rawValue == "codex")
        #expect(MyCCusageAgentType.openclaw.rawValue == "openclaw")
    }
}

@Suite("MyCCusageUploader")
struct MyCCusageUploaderTests {
    private final class StubTransport: MyCCusageUploadTransport, @unchecked Sendable {
        let responses: [(Int, Data)]
        var callCount = 0
        var lastBody: Data?
        var lastRequest: URLRequest?

        init(responses: [(Int, Data)]) {
            self.responses = responses
        }

        func data(for request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
            let idx = min(self.callCount, self.responses.count - 1)
            self.callCount += 1
            self.lastBody = body
            self.lastRequest = request
            let (status, payload) = self.responses[idx]
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil)!
            return (payload, response)
        }
    }

    private static let endpoint = URL(string: "https://example.invalid/api/usage-sync")!

    private static func samplePayload() -> MyCCusageUsageDataPayload {
        MyCCusageUploadPayloadBuilder.buildPayload(
            agentType: .codex,
            report: CostUsageDailyReport(data: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-12",
                    inputTokens: 1, outputTokens: 2,
                    totalTokens: 3, costUSD: 0.1,
                    modelsUsed: ["m"], modelBreakdowns: nil),
            ], summary: nil),
            deviceId: "did", deviceName: "name", displayName: nil)
    }

    @Test
    func `sends x-api-key header and JSON body`() async throws {
        let stub = StubTransport(responses: [(200, Data(#"{"success":true,"processed":1,"results":[]}"#.utf8))])
        let uploader = MyCCusageUploader(transport: stub, retryBaseDelay: 0)
        _ = try await uploader.upload(
            payload: Self.samplePayload(),
            endpoint: Self.endpoint,
            apiKey: "k123")
        #expect(stub.callCount == 1)
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "k123")
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(stub.lastBody)
        #expect(body.count > 10)
    }

    @Test
    func `returns processed count on 200 response`() async throws {
        let stub = StubTransport(responses: [(200, Data(#"{"success":true,"processed":3,"results":[]}"#.utf8))])
        let uploader = MyCCusageUploader(transport: stub, retryBaseDelay: 0)
        let result = try await uploader.upload(
            payload: Self.samplePayload(),
            endpoint: Self.endpoint,
            apiKey: "k")
        #expect(result.processed == 3)
        #expect(result.errors.isEmpty)
    }

    @Test
    func `fails fast on 401 without retry`() async {
        let stub = StubTransport(responses: [(401, Data(#"{"error":"bad key"}"#.utf8))])
        let uploader = MyCCusageUploader(transport: stub, retryBaseDelay: 0)
        do {
            _ = try await uploader.upload(
                payload: Self.samplePayload(),
                endpoint: Self.endpoint,
                apiKey: "wrong",
                maxRetries: 3)
            Issue.record("Expected unauthorized error")
        } catch let error as MyCCusageUploadError {
            guard case let .unauthorized(status, message) = error else {
                Issue.record("Expected .unauthorized, got \(error)")
                return
            }
            #expect(status == 401)
            #expect(message == "bad key")
            #expect(stub.callCount == 1)
        } catch {
            Issue.record("Expected MyCCusageUploadError, got \(error)")
        }
    }

    @Test
    func `retries on 500 then succeeds on third attempt`() async throws {
        let stub = StubTransport(responses: [
            (500, Data(#"{"error":"oops"}"#.utf8)),
            (502, Data(#"{"error":"again"}"#.utf8)),
            (200, Data(#"{"success":true,"processed":7,"results":[]}"#.utf8)),
        ])
        let uploader = MyCCusageUploader(transport: stub, retryBaseDelay: 0)
        let result = try await uploader.upload(
            payload: Self.samplePayload(),
            endpoint: Self.endpoint,
            apiKey: "k",
            maxRetries: 3)
        #expect(result.processed == 7)
        #expect(stub.callCount == 3)
    }

    @Test
    func `exhausts retries on persistent 503`() async {
        let stub = StubTransport(responses: [
            (503, Data(#"{"error":"down"}"#.utf8)),
            (503, Data(#"{"error":"down"}"#.utf8)),
            (503, Data(#"{"error":"down"}"#.utf8)),
        ])
        let uploader = MyCCusageUploader(transport: stub, retryBaseDelay: 0)
        do {
            _ = try await uploader.upload(
                payload: Self.samplePayload(),
                endpoint: Self.endpoint,
                apiKey: "k",
                maxRetries: 3)
            Issue.record("Expected retriesExhausted")
        } catch let error as MyCCusageUploadError {
            guard case let .retriesExhausted(status, message) = error else {
                Issue.record("Expected retriesExhausted, got \(error)")
                return
            }
            #expect(status == 503)
            #expect(message == "down")
            #expect(stub.callCount == 3)
        } catch {
            Issue.record("Expected MyCCusageUploadError, got \(error)")
        }
    }
}
