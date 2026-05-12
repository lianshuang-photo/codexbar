import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func loadMyCCusageConfig() {
        do {
            let config = try self.myCCusageConfigStore.load()
            self.myCCusageConfig = config
            self.myCCusageEnabled = config?.enabled ?? false
            self.myCCusageCollectorStatus = self.myCCusageSyncRunner.installedStatus(
                environment: self.environmentBase)
        } catch {
            self.myCCusageConfig = nil
            self.myCCusageEnabled = false
            self.myCCusageLastError = error.localizedDescription
            self.myCCusageCollectorStatus = self.myCCusageSyncRunner.installedStatus(
                environment: self.environmentBase)
        }
    }

    func startMyCCusageIfNeeded() {
        self.myCCusageTimerTask?.cancel()
        self.myCCusageTimerTask = nil
        self.myCCusageNextSyncAt = nil
        guard self.myCCusageEnabled,
              let config = self.myCCusageConfig
        else { return }

        Task { @MainActor [weak self] in
            await self?.refreshMyCCusageLeaderboard()
        }

        guard let interval = Self.myCCusageIntervalSeconds(for: config.schedule) else { return }
        self.myCCusageNextSyncAt = Date().addingTimeInterval(interval)
        self.myCCusageTimerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.syncMyCCusageNow()
            }
        }
    }

    func setMyCCusageEnabled(_ enabled: Bool) {
        guard var config = self.myCCusageConfig else { return }
        config.enabled = enabled
        self.saveMyCCusageConfig(config)
    }

    func updateMyCCusageConfig(_ update: (inout MyCCusageConfig) -> Void) {
        guard var config = self.myCCusageConfig else { return }
        update(&config)
        self.saveMyCCusageConfig(config)
    }

    func saveMyCCusageConfig(_ config: MyCCusageConfig) {
        do {
            try self.myCCusageConfigStore.save(config)
            self.myCCusageConfig = config
            self.myCCusageEnabled = config.enabled
            self.myCCusageLastError = nil
            self.startMyCCusageIfNeeded()
        } catch {
            self.myCCusageLastError = error.localizedDescription
        }
    }

    func syncMyCCusageNow(didStart: (@MainActor @Sendable () -> Void)? = nil) async {
        guard !self.myCCusageSyncInFlight else { return }
        guard let config = self.myCCusageConfig else {
            self.myCCusageLastError = "MyCCusage is not configured."
            return
        }
        self.myCCusageSyncInFlight = true
        self.myCCusageLastError = nil
        didStart?()
        await self.refreshMyCCusageLeaderboard()
        let preSyncLeaderboard = self.myCCusageLeaderboard

        let uploadError = await self.uploadMyCCusageThroughSwift(config: config)
        if uploadError == nil {
            self.myCCusageLastSyncAt = Date()
            await self.refreshMyCCusageLeaderboardAfterSync(previous: preSyncLeaderboard)
        } else {
            self.myCCusageLastError = uploadError
            await self.refreshMyCCusageLeaderboard()
        }
        self.myCCusageSyncInFlight = false
        if let interval = Self.myCCusageIntervalSeconds(for: config.schedule) {
            self.myCCusageNextSyncAt = Date().addingTimeInterval(interval)
        }
    }

    /// Swift-native replacement for the legacy `ccusage-cherry-collector sync`
    /// subprocess path. Iterates the configured agent types, scans local
    /// usage via the registered LocalUsageScanners, and POSTs one UsageData
    /// payload per agent to the configured endpoint. Returns a human-readable
    /// error description on failure, or `nil` on success.
    func uploadMyCCusageThroughSwift(config: MyCCusageConfig) async -> String? {
        guard let endpoint = URL(string: config.endpoint) else {
            return "MyCCusage endpoint is not a valid URL."
        }
        let deviceId = MyCCusageDeviceID.resolve(persisted: config)
        let deviceName = Self.nonEmpty(config.deviceName) ?? MyCCusageDeviceID.systemHostname()
        let displayName = Self.nonEmpty(config.displayName)
        let now = Date()
        let until = now
        let since = Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now

        var errors: [String] = []
        for agent in config.agentTypes {
            guard let provider = Self.usageProvider(for: agent) else { continue }
            let report = await self.loadCcusageReport(
                provider: provider,
                since: since,
                until: until,
                now: now)
            let payload = MyCCusageUploadPayloadBuilder.buildPayload(
                agentType: agent,
                report: report,
                deviceId: deviceId,
                deviceName: deviceName,
                displayName: displayName)
            do {
                _ = try await self.myCCusageUploader.upload(
                    payload: payload,
                    endpoint: endpoint,
                    apiKey: config.apiKey,
                    maxRetries: config.maxRetries)
            } catch let error as MyCCusageUploadError {
                errors.append("\(agent.label): \(Self.describe(uploadError: error))")
            } catch {
                errors.append("\(agent.label): \(error.localizedDescription)")
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: " · ")
    }

    private func loadCcusageReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date) async -> CostUsageDailyReport
    {
        // Cherry Studio specifically needs its remote pricing cache primed
        // before the scanner runs; the other providers either ship their
        // own pricing tables or are refreshed elsewhere in the app lifecycle.
        if provider == .cherryStudio {
            await CherryInPricingPipeline.refreshIfNeeded(now: now)
        }
        return LocalUsageScannerRegistry.loadDailyReport(
            provider: provider,
            since: since,
            until: until,
            now: now)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func usageProvider(for agent: MyCCusageAgentType) -> UsageProvider? {
        switch agent {
        case .claudeCode: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .cherryStudio: .cherryStudio
        case .openclaw: .openclaw
        }
    }

    private static func describe(uploadError: MyCCusageUploadError) -> String {
        switch uploadError {
        case .invalidResponse:
            return "invalid HTTP response"
        case let .unauthorized(status, message):
            return "authentication failed (HTTP \(status)\(message.map { ": \($0)" } ?? ""))"
        case let .retriesExhausted(status, message):
            let s = status.map { "HTTP \($0)" } ?? "network error"
            return "upload retries exhausted (\(s)\(message.map { ": \($0)" } ?? ""))"
        case .encodingFailed:
            return "failed to encode payload"
        case let .recordErrors(records):
            return "record errors: \(records.joined(separator: ", "))"
        }
    }

    @discardableResult
    func refreshMyCCusageLeaderboard() async -> Bool {
        guard self.myCCusageEnabled,
              let config = self.myCCusageConfig,
              let deviceId = config.deviceId,
              let endpoint = URL(string: config.endpoint)
        else { return false }

        do {
            let data = try await self.myCCusageStatsClient.fetchStats(syncEndpoint: endpoint)
            self.myCCusageLeaderboard = try MyCCusageLeaderboardSnapshot(
                statsData: data,
                deviceId: deviceId,
                today: Self.myCCusageTodayString())
            self.myCCusageLastError = nil
            return true
        } catch {
            self.myCCusageLastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func refreshMyCCusageLeaderboardAfterSync(previous: MyCCusageLeaderboardSnapshot?) async -> Bool {
        let attempts = max(1, self.myCCusagePostSyncPollAttempts)
        for attempt in 0..<attempts {
            if attempt > 0, self.myCCusagePostSyncPollInterval > 0 {
                let nanoseconds = UInt64(self.myCCusagePostSyncPollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            let refreshed = await self.refreshMyCCusageLeaderboard()
            guard refreshed else { continue }
            guard let previous else { return true }
            if self.myCCusageLeaderboard != previous {
                return true
            }
        }
        return self.myCCusageLeaderboard != nil
    }

    static func myCCusageTodayString(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    static func myCCusageIntervalSeconds(for schedule: String) -> TimeInterval? {
        switch schedule {
        case "*/30 * * * *": 30 * 60
        case "0 * * * *": 60 * 60
        case "0 */2 * * *": 2 * 60 * 60
        case "0 */4 * * *": 4 * 60 * 60
        case "0 */8 * * *": 8 * 60 * 60
        case "0 0 * * *": 24 * 60 * 60
        default: nil
        }
    }
}
