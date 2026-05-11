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

    func syncMyCCusageNow() async {
        guard !self.myCCusageSyncInFlight else { return }
        guard self.myCCusageConfig != nil else {
            self.myCCusageLastError = "MyCCusage is not configured."
            return
        }
        self.myCCusageSyncInFlight = true
        self.myCCusageLastError = nil
        await self.refreshMyCCusageLeaderboard()
        let runner = self.myCCusageSyncRunner
        let environment = self.environmentBase
        let result = await Task.detached(priority: .utility) {
            runner.sync(environment: environment)
        }.value
        self.myCCusageSyncInFlight = false
        if result.succeeded {
            self.myCCusageLastSyncAt = Date()
            await self.refreshMyCCusageLeaderboard()
        } else {
            self.myCCusageLastError = result.output.isEmpty
                ? "ccusage-cherry-collector sync failed with exit code \(result.exitCode)."
                : result.output
            await self.refreshMyCCusageLeaderboard()
        }
        if let interval = self.myCCusageConfig.flatMap({ Self.myCCusageIntervalSeconds(for: $0.schedule) }) {
            self.myCCusageNextSyncAt = Date().addingTimeInterval(interval)
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
