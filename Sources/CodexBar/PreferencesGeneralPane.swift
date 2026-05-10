import AppKit
import CodexBarCore
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .system: L("language_system")
        case .english: L("language_english")
        case .chineseSimplified: L("language_chinese_simplified")
        }
    }
}

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text(L("section_system"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("language_title"))
                                    .font(.body)
                                Text(L("language_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker(L("language_title"), selection: self.$settings.appLanguage) {
                                ForEach(AppLanguage.allCases) { option in
                                    Text(option.label).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                    }

                    PreferenceToggleRow(
                        title: L("start_at_login_title"),
                        subtitle: L("start_at_login_subtitle"),
                        binding: self.$settings.launchAtLogin)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L("section_usage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: self.$settings.costUsageEnabled) {
                                Text(L("show_cost_summary"))
                                    .font(.body)
                            }
                            .toggleStyle(.checkbox)

                            Text(L("show_cost_summary_subtitle"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if self.settings.costUsageEnabled {
                                Text(L("cost_auto_refresh_info"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)

                                self.costStatusLine(provider: .claude)
                                self.costStatusLine(provider: .codex)
                            }
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L("section_automation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("refresh_cadence_title"))
                                    .font(.body)
                                Text(L("refresh_cadence_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker("Refresh cadence", selection: self.$settings.refreshFrequency) {
                                ForEach(RefreshFrequency.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        if self.settings.refreshFrequency == .manual {
                            Text(L("manual_refresh_hint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferenceToggleRow(
                        title: L("check_provider_status_title"),
                        subtitle: L("check_provider_status_subtitle"),
                        binding: self.$settings.statusChecksEnabled)
                    PreferenceToggleRow(
                        title: L("session_quota_notifications_title"),
                        subtitle: L("session_quota_notifications_subtitle"),
                        binding: self.$settings.sessionQuotaNotificationsEnabled)
                    PreferenceToggleRow(
                        title: "Quota warning notifications",
                        subtitle: "Warns when session or weekly quota remaining crosses configured thresholds.",
                        binding: self.$settings.quotaWarningNotificationsEnabled)
                    if self.settings.quotaWarningNotificationsEnabled {
                        GlobalQuotaWarningSettingsView(settings: self.settings)
                    }

                    Divider()

                    self.myCCusageSettings
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    HStack {
                        Spacer()
                        Button(L("quit_app")) { NSApp.terminate(nil) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func costStatusLine(provider: UsageProvider) -> some View {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard provider == .claude || provider == .codex else {
            return Text(String(format: L("cost_status_unsupported"), name))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }

        if self.store.isTokenRefreshInFlight(for: provider) {
            let elapsed: String = {
                guard let startedAt = self.store.tokenLastAttemptAt(for: provider) else { return "" }
                let seconds = max(0, Date().timeIntervalSince(startedAt))
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
                formatter.unitsStyle = .abbreviated
                return formatter.string(from: seconds).map { " (\($0))" } ?? ""
            }()
            return Text(String(format: L("cost_status_fetching"), name, elapsed))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
            return Text(String(format: L("cost_status_snapshot"), name, updated, cost))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text(String(format: L("cost_status_error"), name, truncated))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "en_US")
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            return Text(String(format: L("cost_status_last_attempt"), name, when))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        return Text(String(format: L("cost_status_no_data"), name))
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var myCCusageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: self.myCCusageEnabledBinding) {
                    Text("Enable MyCCusage")
                        .font(.body)
                }
                .toggleStyle(.checkbox)
                .disabled(self.store.myCCusageConfig == nil)

                Text("Uses ~/.ccusage-collector/config.json and runs ccusage-cherry-collector sync.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let config = self.store.myCCusageConfig {
                HStack(alignment: .center, spacing: 12) {
                    Text("Endpoint")
                        .frame(width: 110, alignment: .leading)
                    TextField("https://ccusage.cherry-ai.com/api/usage-sync", text: self.myCCusageEndpointBinding)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Display name")
                        .frame(width: 110, alignment: .leading)
                    TextField("Device display name", text: self.myCCusageDisplayNameBinding)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("Upload types")
                        .frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(MyCCusageAgentType.allCases, id: \.rawValue) { agent in
                            Toggle(isOn: self.myCCusageAgentBinding(agent)) {
                                Text(agent.label)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Frequency")
                        .frame(width: 110, alignment: .leading)
                    Picker("MyCCusage upload frequency", selection: self.myCCusageScheduleBinding) {
                        ForEach(MyCCusageScheduleOption.all, id: \.schedule) { option in
                            Text(option.label).tag(option.schedule)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }

                if let status = self.myCCusageStatusLine(config: config) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Sync MyCCusage Now") {
                        Task { @MainActor in
                            await self.store.syncMyCCusageNow()
                        }
                    }
                    .disabled(!self.store.myCCusageEnabled || self.store.myCCusageSyncInFlight)

                    if self.store.myCCusageSyncInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MyCCusage collector is not configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Install: \(self.store.myCCusageCollectorStatus.installCommand)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                    Text("Configure: ccusage-cherry-collector config")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var myCCusageEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.store.myCCusageEnabled },
            set: { self.store.setMyCCusageEnabled($0) })
    }

    private var myCCusageEndpointBinding: Binding<String> {
        Binding(
            get: { self.store.myCCusageConfig?.endpoint ?? "" },
            set: { value in
                self.store.updateMyCCusageConfig { $0.endpoint = value }
            })
    }

    private var myCCusageDisplayNameBinding: Binding<String> {
        Binding(
            get: { self.store.myCCusageConfig?.displayName ?? "" },
            set: { value in
                self.store.updateMyCCusageConfig {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.displayName = trimmed.isEmpty ? nil : trimmed
                }
            })
    }

    private var myCCusageScheduleBinding: Binding<String> {
        Binding(
            get: { self.store.myCCusageConfig?.schedule ?? "0 */4 * * *" },
            set: { schedule in
                let option = MyCCusageScheduleOption.all.first { $0.schedule == schedule }
                self.store.updateMyCCusageConfig {
                    $0.schedule = schedule
                    $0.scheduleLabel = option?.label ?? schedule
                }
            })
    }

    private func myCCusageAgentBinding(_ agent: MyCCusageAgentType) -> Binding<Bool> {
        Binding(
            get: { self.store.myCCusageConfig?.agentTypes.contains(agent) ?? false },
            set: { isEnabled in
                self.store.updateMyCCusageConfig {
                    var agents = $0.agentTypes
                    if isEnabled {
                        if !agents.contains(agent) { agents.append(agent) }
                    } else {
                        agents.removeAll { $0 == agent }
                    }
                    if agents.isEmpty {
                        agents = [.claudeCode]
                    }
                    $0.agentTypes = agents
                }
            })
    }

    private func myCCusageStatusLine(config: MyCCusageConfig) -> String? {
        var parts: [String] = []
        if let version = self.store.myCCusageCollectorStatus.version {
            parts.append("collector \(version)")
        } else if !self.store.myCCusageCollectorStatus.isInstalled {
            parts.append("collector not installed")
        }
        if let last = self.store.myCCusageLastSyncAt {
            parts.append("last \(UsageFormatter.updatedString(from: last))")
        }
        if let next = self.store.myCCusageNextSyncAt {
            parts.append("next \(UsageFormatter.updatedString(from: next))")
        } else {
            parts.append(config.scheduleLabel)
        }
        if let error = self.store.myCCusageLastError, !error.isEmpty {
            parts.append("error: \(UsageFormatter.truncatedSingleLine(error, max: 100))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct MyCCusageScheduleOption {
    let schedule: String
    let label: String

    static let all: [MyCCusageScheduleOption] = [
        MyCCusageScheduleOption(schedule: "*/30 * * * *", label: "Every 30 minutes"),
        MyCCusageScheduleOption(schedule: "0 * * * *", label: "Every 1 hour"),
        MyCCusageScheduleOption(schedule: "0 */2 * * *", label: "Every 2 hours"),
        MyCCusageScheduleOption(schedule: "0 */4 * * *", label: "Every 4 hours"),
        MyCCusageScheduleOption(schedule: "0 */8 * * *", label: "Every 8 hours"),
        MyCCusageScheduleOption(schedule: "0 0 * * *", label: "Once daily"),
    ]
}
