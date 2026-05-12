// 1:1 port of MyCCusage Collector's `cherry-local.ts` (1109 lines).
//
// Source-of-truth: /tmp/MyCCusage-latest/packages/ccusage-collector/src/cherry-local.ts
// (private to the collector repo — not the public ccusage npm package).
//
// Scope of this port:
//   - JSONL Claude runtime scan (cherry-local.ts: readClaudeRuntime)
//   - SQLite agent DB scan         (cherry-local.ts: summarizeAgentDb)
//   - All aggregation helpers      (cherry-local.ts: usageParts, addGroupRow,
//                                   buildUsageDataFromRows, addSource, etc.)
//   - Model normalisation + the static PRICE_TABLE
//
// NOT ported in this PR (tracked as TODOs in the PR description):
//   - readIndexedDb / readOneOrigin / INDEXED_DB_EXPR  — these spawn headless
//     Chrome via CDP to read Cherry Studio's IndexedDB. Stubbed to empty.
//   - loadCherryInPricing / applyCherryInPricing      — network fetch of the
//     CherryIn pricing API. `pricing` is left nil; rows keep the cost their
//     producer assigned (usually `direct` / `none`).

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Public scanner

public struct CherryStudioLocalUsageScanner: LocalUsageScanner {
    public let provider: UsageProvider = .cherryStudio
    public let configuration: Configuration

    public init(configuration: Configuration = .systemDefault()) {
        self.configuration = configuration
    }

    public func loadDailyReport(
        since: Date,
        until: Date,
        now _: Date,
        options _: LocalUsageScanOptions) -> CostUsageDailyReport
    {
        let rows = self.collectLocalRows()
        let bundle = Self.buildUsageDataFromRows(rows)
        let filtered = self.filter(daily: bundle.daily, since: since, until: until)
        return Self.makeReport(from: filtered)
    }
}

// MARK: - Configuration

extension CherryStudioLocalUsageScanner {
    public struct Configuration: Sendable {
        /// Cherry Studio variant names (TS: `DEFAULT_APP_NAMES`).
        /// Each name maps to a separate Application Support directory.
        public var appNames: [String]

        /// Optional explicit override for the "Application Support" base directory.
        /// Falls back to the platform default when nil. Mirrors TS
        /// `CHERRY_APP_DATA_DIR` / `getDefaultSupportBase`.
        public var supportBaseOverride: URL?

        /// Additional explicit `<appDataDir>` URLs to scan, beyond the ones we'd
        /// derive from `appNames + supportBase`. Mirrors TS `CHERRY_APP_DATA_DIR`
        /// + the `appDataPath` entries inside `~/.cherrystudio/config/config.json`.
        public var extraAppDataDirs: [URL]

        public init(
            appNames: [String] = CherryStudioLocalUsageScanner.defaultAppNames,
            supportBaseOverride: URL? = nil,
            extraAppDataDirs: [URL] = [])
        {
            self.appNames = appNames
            self.supportBaseOverride = supportBaseOverride
            self.extraAppDataDirs = extraAppDataDirs
        }

        /// Resolves system paths the way TS does at startup.
        public static func systemDefault() -> Configuration {
            let env = ProcessInfo.processInfo.environment
            // TS: getAppNames -> CHERRY_LOCAL_APP_NAMES
            let names: [String] = {
                guard let raw = env["CHERRY_LOCAL_APP_NAMES"], !raw.isEmpty else {
                    return CherryStudioLocalUsageScanner.defaultAppNames
                }
                return raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }()
            // TS: getConfiguredAppDataDirs
            var extra: [URL] = []
            if let envDirs = env["CHERRY_APP_DATA_DIR"], !envDirs.isEmpty {
                extra.append(contentsOf: envDirs.split(separator: ":").map {
                    URL(fileURLWithPath: String($0))
                })
            }
            let configPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(CherryStudioLocalUsageScanner.homeCherryDir, isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: configPath.path),
               let data = try? Data(contentsOf: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                if let str = json["appDataPath"] as? String {
                    extra.append(URL(fileURLWithPath: str))
                } else if let arr = json["appDataPath"] as? [[String: Any]] {
                    for item in arr {
                        if let dp = item["dataPath"] as? String {
                            extra.append(URL(fileURLWithPath: dp))
                        }
                    }
                }
            }
            return Configuration(appNames: names, supportBaseOverride: nil, extraAppDataDirs: extra)
        }
    }
}

// MARK: - Top-level constants (TS line numbers in comments)

extension CherryStudioLocalUsageScanner {
    /// TS line 11: `DEFAULT_APP_NAMES`
    public static let defaultAppNames: [String] = [
        "CherryStudio",
        "CherryStudioDev",
        "CherryStudioEnterprise",
    ]

    /// TS line 16: `HOME_CHERRY_DIR`
    public static let homeCherryDir: String = ".cherrystudio"

    /// TS line 15: `PRICING_API`. Not used in this v1 port (network fetch
    /// deferred — see TODO #2 in the PR description).
    public static let pricingAPIURLString: String =
        "https://express-ent-admin.cherryin.ai/api/pricing"

    /// TS line 313 divisor: per-token rates in `PRICE_TABLE` are quoted per
    /// **million** tokens, so cost = tokens * rate / 1_000_000.
    static let priceTablePerMillionDivisor: Double = 1_000_000

    /// TS line 146: `roundCost` rounds to 6 decimal places (×1e6 round / 1e6).
    static let roundCostMultiplier: Double = 1_000_000
}

// MARK: - Numeric helpers (TS lines 140–157)

extension CherryStudioLocalUsageScanner {
    /// TS `stableNumber`: any non-finite or null number becomes 0.
    static func stableNumber(_ value: Any?) -> Double {
        guard let value else { return 0 }
        switch value {
        case let n as Double: return n.isFinite ? n : 0
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : 0
        case let s as String:
            let d = Double(s) ?? 0
            return d.isFinite ? d : 0
        default: return 0
        }
    }

    static func stableInt(_ value: Any?) -> Int {
        let d = self.stableNumber(value)
        return Int(d.rounded(.toNearestOrEven))
    }

    /// TS `roundCost`.
    static func roundCost(_ value: Double) -> Double {
        let v = self.stableNumber(value)
        return (v * Self.roundCostMultiplier).rounded() / Self.roundCostMultiplier
    }

    /// TS `safeJson` for arbitrary JSON-decoded fallback. Swift port returns
    /// the parsed object or `nil` (caller substitutes a fallback).
    static func safeJson(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Model normalisation + price table (TS lines 256–322)

extension CherryStudioLocalUsageScanner {
    /// TS `normalizeModel`.
    static func normalizeModel(_ raw: String?) -> String {
        let base = (raw?.isEmpty == false ? raw! : "unknown").lowercased()
        var s = base.replacingOccurrences(of: ".", with: "-")
        for prefix in ["anthropic/", "openai/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // Strip @suffix
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }
        // Strip trailing -YYYYMMDD
        s = self.stripTrailingDate8(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// TS `replace(/-\d{8}$/, "")`.
    static func stripTrailingDate8(_ s: String) -> String {
        guard s.count >= 9 else { return s }
        let tail = s.suffix(9)
        guard tail.first == "-" else { return s }
        let digits = tail.dropFirst()
        if digits.allSatisfy(\.isNumber) {
            return String(s.dropLast(9))
        }
        return s
    }

    /// One row of the TS `PRICE_TABLE`. Named struct (was a 5-tuple) so
    /// SwiftLint's large_tuple rule passes.
    private struct PriceTableRow {
        let key: String
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    /// TS line 267 `PRICE_TABLE`. Numbers are per-million-token USD rates.
    /// Key match goes through `normalizeModel` first (see `NORMALIZED_PRICES`,
    /// TS line 301).
    static let priceTable: [String: ModelPrice] = {
        // (key, input, output, cacheRead, cacheWrite)  — TS lines 268–298
        let raw: [PriceTableRow] = [
            PriceTableRow(key: "claude-opus-4-1", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
            PriceTableRow(key: "claude-opus-4-20250514", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
            PriceTableRow(key: "claude-opus-4-0", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
            PriceTableRow(key: "claude-opus-4-6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
            PriceTableRow(key: "claude-opus-4-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
            PriceTableRow(key: "claude-opus-4-5-20251101", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
            PriceTableRow(key: "claude-sonnet-4-6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-sonnet-4-5-20250929", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-sonnet-4-20250514", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-3-7-sonnet-20250219", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-3-5-sonnet-20241022", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-3-5-sonnet-20240620", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            PriceTableRow(key: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
            PriceTableRow(key: "claude-haiku-4-5-20251001", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
            PriceTableRow(key: "claude-3-5-haiku-20241022", input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
            PriceTableRow(key: "claude-3-opus-20240229", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
            PriceTableRow(key: "claude-3-haiku-20240307", input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3),
            PriceTableRow(key: "gpt-5.4-pro", input: 30, output: 180, cacheRead: 0, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.4", input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.3-codex", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.2-codex", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.2", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.1-codex-max", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.1-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.1-codex-mini", input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0),
            PriceTableRow(key: "gpt-5.1", input: 1.25, output: 10, cacheRead: 0.13, cacheWrite: 0),
            PriceTableRow(key: "gpt-5-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
            PriceTableRow(key: "gpt-5-pro", input: 15, output: 120, cacheRead: 0, cacheWrite: 0),
            PriceTableRow(key: "gpt-5", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
            PriceTableRow(key: "mimo-v2.5-pro", input: 1, output: 3, cacheRead: 0.2, cacheWrite: 1),
        ]
        var dict: [String: ModelPrice] = [:]
        for row in raw {
            let price = ModelPrice(
                input: row.input,
                output: row.output,
                cacheRead: row.cacheRead,
                cacheWrite: row.cacheWrite)
            // TS line 301: `NORMALIZED_PRICES` — keyed by `normalizeModel(key)`.
            dict[Self.normalizeModel(row.key)] = price
        }
        return dict
    }()

    public struct ModelPrice: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
    }

    /// TS `computeRuntimeCost` (line 305).
    static func computeRuntimeCost(
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheCreate: Double,
        model: String) -> RuntimeCost
    {
        let normalized = self.normalizeModel(model)
        let price = self.priceTable[normalized] ?? self.priceTable[Self.stripTrailingDate8(normalized)]
        guard let price else {
            return RuntimeCost(
                cost: 0,
                mode: "unknown-model",
                pricingModel: nil,
                normalizedModel: normalized,
                netInput: 0)
        }
        let netInput = max(input - cacheRead, 0)
        let cost = (
            netInput * price.input
                + output * price.output
                + cacheCreate * price.cacheWrite
                + cacheRead * price.cacheRead) / Self.priceTablePerMillionDivisor
        return RuntimeCost(
            cost: cost,
            mode: "myccusage-fillMissingCost",
            pricingModel: normalized,
            normalizedModel: normalized,
            netInput: netInput)
    }

    struct RuntimeCost: Sendable, Equatable {
        var cost: Double
        var mode: String
        var pricingModel: String?
        var normalizedModel: String
        var netInput: Double
    }
}

// MARK: - Internal row types (TS lines 19–138)

extension CherryStudioLocalUsageScanner {
    struct LocalRow: Sendable, Equatable {
        var date: String
        var appName: String
        var source: String
        var modelName: String
        var inputTokens: Double
        var outputTokens: Double
        var cacheCreationTokens: Double
        var cacheReadTokens: Double
        var totalTokens: Double
        var totalCost: Double
        var calls: Double
        var costMode: String?
        var pricingModel: String?
        var pricingGroup: String?
    }

    struct LocalSource: Sendable, Equatable {
        var source: String
        var appName: String
        var costMode: String?
        var pricingModel: String?
        var pricingGroup: String?
        var calls: Double
        var totalTokens: Double
        var totalCost: Double
    }

    struct UsageParts: Sendable, Equatable {
        var input: Double
        var output: Double
        var total: Double
        var directCost: Double?
    }

    struct GroupRow: Sendable, Equatable {
        var date: String
        var provider: String
        var model: String
        var costMode: String
        var calls: Double
        var input: Double
        var output: Double
        var total: Double
        var cost: Double
        var pricingModel: String?
        var pricingGroup: String?
    }

    struct ClaudeRuntimeRow: Sendable, Equatable {
        var date: String
        var sourceModel: String
        var model: String
        var pricingModel: String?
        var costMode: String
        var calls: Double
        var input: Double
        var netInput: Double
        var output: Double
        var cacheRead: Double
        var cacheCreate: Double
        var total: Double
        var cost: Double
    }
}

// MARK: - Generic usage-aggregation helpers (TS lines 400–468)

extension CherryStudioLocalUsageScanner {
    /// TS `usageParts` (line 400).
    static func usageParts(from usage: [String: Any]?) -> UsageParts? {
        guard let usage else { return nil }
        let input = self.stableNumber(usage["prompt_tokens"] ?? usage["input_tokens"] ?? usage["inputTokens"])
        let output = self.stableNumber(usage["completion_tokens"] ?? usage["output_tokens"] ?? usage["outputTokens"])
        let totalRaw = usage["total_tokens"] ?? usage["totalTokens"]
        let total = totalRaw != nil ? self.stableNumber(totalRaw) : (input + output)
        let directCost: Double? = if usage["cost"] != nil {
            self.stableNumber(usage["cost"])
        } else {
            nil
        }
        let hasPositiveDirect = (directCost ?? 0) > 0
        if input == 0, output == 0, total == 0, !hasPositiveDirect {
            return nil
        }
        return UsageParts(input: input, output: output, total: total, directCost: directCost)
    }

    /// TS `emptyGroupRow` (line 410).
    static func emptyGroupRow(date: String, provider: String, model: String, costMode: String) -> GroupRow {
        GroupRow(
            date: date,
            provider: provider,
            model: model,
            costMode: costMode,
            calls: 0,
            input: 0,
            output: 0,
            total: 0,
            cost: 0,
            pricingModel: nil,
            pricingGroup: nil)
    }

    struct AddGroupOptions: Sendable {
        var date: String
        var provider: String
        var model: String
        var parts: UsageParts
        /// TS pricing inputs flattened to scalars. In the SQLite agent-DB path
        /// these are always 0 because no inline pricing was attached. They are
        /// kept so the helper still mirrors TS `addGroupRow` exactly when the
        /// IndexedDB path eventually lands.
        var inputRatePerMillion: Double = 0
        var outputRatePerMillion: Double = 0
        var metaCost: Double?
        var isBillable: Bool
    }

    /// TS `addGroupRow` (line 414). Mutates `group` and increments
    /// `unknownPriceCount` when no pricing source is found.
    static func addGroupRow(
        group: inout [String: GroupRow],
        unknownPriceCount: inout Int,
        options: AddGroupOptions)
    {
        var cost: Double = 0
        var costMode = "none"
        let inputRate = options.inputRatePerMillion
        let outputRate = options.outputRatePerMillion

        if let metaCost = options.metaCost, metaCost.isFinite, metaCost > 0 {
            cost = metaCost
            costMode = "direct"
        } else if options.provider == "openrouter", let direct = options.parts.directCost {
            cost = direct
            costMode = "direct"
        } else if inputRate != 0 || outputRate != 0 {
            cost = (options.parts.input * inputRate + options.parts.output * outputRate)
                / Self.priceTablePerMillionDivisor
            costMode = "estimated"
        } else {
            unknownPriceCount += 1
        }

        let key = [options.date, options.provider, options.model, costMode].joined(separator: "||")
        var row = group[key] ?? self.emptyGroupRow(
            date: options.date,
            provider: options.provider,
            model: options.model,
            costMode: costMode)
        row.calls += options.isBillable ? 1 : 0
        row.input += options.parts.input
        row.output += options.parts.output
        row.total += options.parts.total
        row.cost += cost
        group[key] = row
    }

    /// TS `rows` (line 466).
    static func sortedRows(_ group: [String: GroupRow]) -> [GroupRow] {
        Array(group.values).sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.total > b.total
        }
    }
}

// MARK: - File-system path discovery (TS lines 159–209, 455–463)

extension CherryStudioLocalUsageScanner {
    /// TS `getDefaultSupportBase` (line 170).
    static func defaultSupportBase() -> URL {
        // We compile macOS-only (Package.swift platforms = [.macOS(.v14)]).
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    func resolvedAppDataDirs(for appName: String) -> [URL] {
        let base = self.configuration.supportBaseOverride ?? Self.defaultSupportBase()
        let candidates: [URL] = self.configuration.extraAppDataDirs
            + [base.appendingPathComponent(appName, isDirectory: true)]
        // TS `uniqueExisting` — preserve order, dedupe, filter to existing dirs.
        var seen = Set<String>()
        var out: [URL] = []
        for candidate in candidates {
            let path = candidate.path
            if seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) {
                out.append(candidate)
            }
        }
        return out
    }

    /// TS `walkFiles` (line 455).
    static func walkFiles(root: URL, suffix: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            out.append(url)
        }
        // TS `readdirSync` order is FS-dependent; we sort to make tests deterministic.
        return out.sorted { $0.path < $1.path }
    }
}

// MARK: - Claude runtime JSONL (TS lines 843–917)

extension CherryStudioLocalUsageScanner {
    /// Single Claude-runtime JSONL event. Named struct (was a 6-/7-tuple) so
    /// SwiftLint's large_tuple rule passes.
    struct RuntimeEvent: Sendable, Equatable {
        var date: String
        var model: String
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheCreate: Double
        /// Dedup signature — populated when read from disk (TS line 906) and
        /// ignored by `summarizeRuntimeEvents`.
        var dedupKey: String = ""
    }

    /// TS `summarizeRuntimeEvents` (line 843).
    static func summarizeRuntimeEvents(_ events: [RuntimeEvent]) -> [ClaudeRuntimeRow] {
        var grouped: [String: ClaudeRuntimeRow] = [:]
        for event in events {
            let pricing = self.computeRuntimeCost(
                input: event.input,
                output: event.output,
                cacheRead: event.cacheRead,
                cacheCreate: event.cacheCreate,
                model: event.model)
            let key = [event.date, pricing.normalizedModel, pricing.mode].joined(separator: "||")
            var row = grouped[key] ?? ClaudeRuntimeRow(
                date: event.date,
                sourceModel: event.model,
                model: pricing.normalizedModel,
                pricingModel: pricing.pricingModel,
                costMode: pricing.mode,
                calls: 0,
                input: 0,
                netInput: 0,
                output: 0,
                cacheRead: 0,
                cacheCreate: 0,
                total: 0,
                cost: 0)
            row.calls += 1
            row.input += event.input
            row.netInput += pricing.netInput
            row.output += event.output
            row.cacheRead += event.cacheRead
            row.cacheCreate += event.cacheCreate
            // TS line 871: explicit re-sum, NOT row.total += parts.total.
            row.total += event.input + event.output + event.cacheRead + event.cacheCreate
            row.cost += pricing.cost
            grouped[key] = row
        }
        return Array(grouped.values).sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.total > b.total
        }
    }

    /// TS `readClaudeRuntime` (line 877). Returns `nil` if no events were found.
    func readClaudeRuntime(appName: String) -> ClaudeRuntimeApp? {
        var raw: [RuntimeEvent] = []
        var dedup: [RuntimeEvent] = []
        var seen = Set<String>()

        for appDataDir in self.resolvedAppDataDirs(for: appName) {
            let root = appDataDir
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            for file in Self.walkFiles(root: root, suffix: ".jsonl") {
                let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
                guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    guard let item = Self.safeJson(trimmed) as? [String: Any] else { continue }
                    let type = item["type"] as? String
                    guard type == "assistant" else { continue }
                    guard let message = item["message"] as? [String: Any] else { continue }
                    guard let usage = message["usage"] as? [String: Any] else { continue }
                    let input = Self.stableNumber(usage["input_tokens"])
                    let output = Self.stableNumber(usage["output_tokens"])
                    let cacheRead = Self.stableNumber(usage["cache_read_input_tokens"])
                    let cacheCreate = Self.stableNumber(usage["cache_creation_input_tokens"])
                    if input == 0, output == 0, cacheRead == 0, cacheCreate == 0 { continue }
                    let timestamp = (item["timestamp"] as? String) ?? ""
                    let date = String(timestamp.prefix(10)).isEmpty ? "unknown-date" : String(timestamp.prefix(10))
                    let model = (message["model"] as? String) ?? "unknown"
                    let messageId = (message["id"] as? String)
                        ?? (item["uuid"] as? String)
                        ?? rel
                    let dedupKey = [
                        messageId,
                        model,
                        "\(Int(input))",
                        "\(Int(output))",
                        "\(Int(cacheRead))",
                        "\(Int(cacheCreate))",
                    ].joined(separator: "|")
                    let event = RuntimeEvent(
                        date: date,
                        model: model,
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheCreate: cacheCreate,
                        dedupKey: dedupKey)
                    raw.append(event)
                    if seen.insert(event.dedupKey).inserted {
                        dedup.append(event)
                    }
                }
            }
        }
        if raw.isEmpty { return nil }
        return ClaudeRuntimeApp(
            appName: appName,
            rawRows: Self.summarizeRuntimeEvents(raw),
            dedupRows: Self.summarizeRuntimeEvents(dedup))
    }

    struct ClaudeRuntimeApp: Sendable, Equatable {
        var appName: String
        var rawRows: [ClaudeRuntimeRow]
        var dedupRows: [ClaudeRuntimeRow]
    }
}

// MARK: - Agent SQLite DB (TS lines 780–841)

//
// SQLite3 is system-provided on Darwin and missing from upstream Swift on
// Linux. The aggregation pipeline still references `summarizeAgentDb` /
// `AgentSummary`, so the type stays always-defined; the actual SQL path is
// gated and returns nil on non-Darwin (the JSONL path still works).

extension CherryStudioLocalUsageScanner {
    public struct AgentSummary: Sendable, Equatable {
        public var appName: String
        public var dbPath: String
        public var ok: Bool
        public var rows: Int
        var billable: [String: GroupRow]
        var userEstimate: [String: GroupRow]
        public var unknownPriceCount: Int
        public var error: String?
    }

    #if canImport(SQLite3)
    /// TS `summarizeAgentDb` (line 780).
    func summarizeAgentDb(appName: String, dbURL: URL) -> AgentSummary? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return AgentSummary(
                appName: appName,
                dbPath: dbURL.path,
                ok: false,
                rows: 0,
                billable: [:],
                userEstimate: [:],
                unknownPriceCount: 0,
                error: "open failed")
        }
        defer { sqlite3_close(db) }

        // TS line 784: read all `session_messages` rows with the same json_extract columns.
        let sql = """
        select
          id,
          role as row_role,
          created_at,
          json_extract(content, '$.message.role') as message_role,
          json_extract(content, '$.message.createdAt') as message_created_at,
          json_extract(content, '$.message.model.provider') as provider,
          json_extract(content, '$.message.model.id') as model_id,
          json_extract(content, '$.message.modelId') as model_id_fallback,
          json_extract(content, '$.message.usage.prompt_tokens') as prompt_tokens,
          json_extract(content, '$.message.usage.completion_tokens') as completion_tokens,
          json_extract(content, '$.message.usage.total_tokens') as total_tokens,
          json_extract(content, '$.message.usage.inputTokens') as input_tokens_ai,
          json_extract(content, '$.message.usage.outputTokens') as output_tokens_ai,
          json_extract(content, '$.message.usage.totalTokens') as total_tokens_ai,
          json_extract(content, '$.message.usage.cost') as usage_cost,
          json_extract(content, '$.message.providerMetadata.costUsd') as cost_usd,
          json_extract(content, '$.message.providerMetadata.raw.total_cost_usd') as raw_cost_usd
        from session_messages
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            return AgentSummary(
                appName: appName,
                dbPath: dbURL.path,
                ok: false,
                rows: 0,
                billable: [:],
                userEstimate: [:],
                unknownPriceCount: 0,
                error: err)
        }
        defer { sqlite3_finalize(stmt) }

        var summary = AgentSummary(
            appName: appName,
            dbPath: dbURL.path,
            ok: true,
            rows: 0,
            billable: [:],
            userEstimate: [:],
            unknownPriceCount: 0,
            error: nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            summary.rows += 1
            let rowRole = Self.columnString(stmt, 1)
            let messageRole = Self.columnString(stmt, 3)
            let createdAt = Self.columnString(stmt, 2)
            let messageCreatedAt = Self.columnString(stmt, 4)
            let provider = Self.columnString(stmt, 5)
            let modelId = Self.columnString(stmt, 6)
            let modelIdFallback = Self.columnString(stmt, 7)
            let promptTokens = Self.columnAny(stmt, 8)
            let completionTokens = Self.columnAny(stmt, 9)
            let totalTokens = Self.columnAny(stmt, 10)
            let inputTokensAI = Self.columnAny(stmt, 11)
            let outputTokensAI = Self.columnAny(stmt, 12)
            let totalTokensAI = Self.columnAny(stmt, 13)
            let usageCost = Self.columnAny(stmt, 14)
            let costUsd = Self.columnAny(stmt, 15)
            let rawCostUsd = Self.columnAny(stmt, 16)

            let role = messageRole ?? rowRole
            let rawDate = (messageCreatedAt ?? createdAt) ?? ""
            let date: String = String(rawDate.prefix(10)).isEmpty ? "unknown-date" : String(rawDate.prefix(10))
            let providerVal = provider ?? "unknown"
            let modelVal = (modelId ?? modelIdFallback) ?? "unknown"

            let usageDict: [String: Any?] = [
                "prompt_tokens": promptTokens ?? inputTokensAI ?? 0,
                "completion_tokens": completionTokens ?? outputTokensAI ?? 0,
                "total_tokens": totalTokens ?? totalTokensAI ?? 0,
                "cost": usageCost,
            ]
            // TS converts undefined → number(0) for these three; preserve.
            let usage: [String: Any] = usageDict.compactMapValues { $0 }
            guard let parts = Self.usageParts(from: usage) else { continue }

            let isBillable = role == "assistant" || rowRole == "assistant" || rowRole == "agent"
            let metaCost: Double? = {
                let raw = costUsd ?? rawCostUsd
                guard let raw else { return nil }
                let d = Self.stableNumber(raw)
                return d.isFinite ? d : nil
            }()
            let options = AddGroupOptions(
                date: date,
                provider: providerVal,
                model: modelVal,
                parts: parts,
                metaCost: metaCost,
                isBillable: isBillable)
            if isBillable {
                Self.addGroupRow(
                    group: &summary.billable,
                    unknownPriceCount: &summary.unknownPriceCount,
                    options: options)
            } else {
                Self.addGroupRow(
                    group: &summary.userEstimate,
                    unknownPriceCount: &summary.unknownPriceCount,
                    options: options)
            }
        }
        return summary
    }

    static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    static func columnAny(_ stmt: OpaquePointer?, _ index: Int32) -> Any? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return nil
        case SQLITE_INTEGER: return sqlite3_column_int64(stmt, index)
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, index)
        case SQLITE_TEXT:
            guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cstr)
        default: return nil
        }
    }
    #else
    /// Linux fallback — SQLite3 isn't part of upstream Swift's standard
    /// distribution. We skip the agent-DB path entirely; the JSONL pipeline
    /// is unaffected.
    func summarizeAgentDb(appName _: String, dbURL _: URL) -> AgentSummary? {
        nil
    }
    #endif
}

// MARK: - Per-app local-row collection (TS `readCherryStudioLocalUsage`, line 1031)

extension CherryStudioLocalUsageScanner {
    func collectLocalRows() -> [LocalRow] {
        var rows: [LocalRow] = []
        for appName in self.configuration.appNames {
            // (1) IndexedDB — NOT PORTED in this PR. See file-top TODO.
            // (2) Agent DBs (TS line 1062)
            for appDataDir in self.resolvedAppDataDirs(for: appName) {
                for relPath in ["agents-enterprise.db", "Data/agents-enterprise.db", "Data/agents.db", "agents.db"] {
                    let dbURL = appDataDir.appendingPathComponent(relPath)
                    guard let summary = self.summarizeAgentDb(appName: "\(appName):\(relPath)", dbURL: dbURL)
                    else { continue }
                    if summary.rows == 0 { continue }
                    for row in Self.sortedRows(summary.billable) {
                        rows.append(LocalRow(
                            date: row.date,
                            appName: appName,
                            source: "agents-db",
                            modelName: row.model.isEmpty ? "unknown" : row.model,
                            inputTokens: row.input,
                            outputTokens: row.output,
                            cacheCreationTokens: 0,
                            cacheReadTokens: 0,
                            totalTokens: row.total,
                            totalCost: row.cost,
                            calls: row.calls,
                            costMode: row.costMode,
                            pricingModel: row.pricingModel,
                            pricingGroup: row.pricingGroup))
                    }
                }
            }
            // (3) Claude runtime JSONL (TS line 1088 — uses `runtime.dedup.rows`).
            if let runtime = self.readClaudeRuntime(appName: appName) {
                for row in runtime.dedupRows {
                    rows.append(LocalRow(
                        date: row.date,
                        appName: appName,
                        source: "claude-runtime-jsonl",
                        modelName: row.sourceModel.isEmpty ? (row.model.isEmpty ? "unknown" : row.model) : row
                            .sourceModel,
                        inputTokens: row.input,
                        outputTokens: row.output,
                        cacheCreationTokens: row.cacheCreate,
                        cacheReadTokens: row.cacheRead,
                        totalTokens: row.total,
                        totalCost: row.cost,
                        calls: row.calls,
                        costMode: row.costMode,
                        pricingModel: row.pricingModel,
                        pricingGroup: nil))
                }
            }
        }
        return rows
    }
}

// MARK: - Day-bucket aggregation (TS `buildUsageDataFromRows`, line 941)

extension CherryStudioLocalUsageScanner {
    struct DailyRecord: Sendable, Equatable {
        var date: String
        var inputTokens: Double
        var outputTokens: Double
        var cacheCreationTokens: Double
        var cacheReadTokens: Double
        var totalTokens: Double
        var totalCost: Double
        var modelsUsed: [String]
        var modelBreakdowns: [ModelBreakdown]
        var calls: Double
        var localSources: [LocalSource]
    }

    struct ModelBreakdown: Sendable, Equatable {
        var modelName: String
        var inputTokens: Double
        var outputTokens: Double
        var cacheCreationTokens: Double
        var cacheReadTokens: Double
        var totalTokens: Double
        var cost: Double
        var calls: Double
        var localSources: [LocalSource]
    }

    struct Totals: Sendable, Equatable {
        var inputTokens: Double = 0
        var outputTokens: Double = 0
        var cacheCreationTokens: Double = 0
        var cacheReadTokens: Double = 0
        var totalTokens: Double = 0
        var totalCost: Double = 0
    }

    /// TS `addSource` (line 919). Buckets sources by (source, appName, costMode, pricingModel, pricingGroup).
    static func addSource(_ sources: inout [LocalSource], row: LocalRow) {
        let key = [row.source, row.appName, row.costMode ?? "", row.pricingModel ?? "", row.pricingGroup ?? ""]
            .joined(separator: "||")
        if let idx = sources.firstIndex(where: { Self.sourceKey($0) == key }) {
            sources[idx].calls += self.stableNumber(row.calls == 0 ? 1 : row.calls)
            sources[idx].totalTokens += self.stableNumber(row.totalTokens)
            sources[idx].totalCost = self.roundCost(sources[idx].totalCost + self.stableNumber(row.totalCost))
        } else {
            sources.append(LocalSource(
                source: row.source,
                appName: row.appName,
                costMode: row.costMode,
                pricingModel: row.pricingModel,
                pricingGroup: row.pricingGroup,
                calls: self.stableNumber(row.calls == 0 ? 1 : row.calls),
                totalTokens: self.stableNumber(row.totalTokens),
                totalCost: self.roundCost(self.stableNumber(row.totalCost))))
        }
    }

    static func sourceKey(_ s: LocalSource) -> String {
        [s.source, s.appName, s.costMode ?? "", s.pricingModel ?? "", s.pricingGroup ?? ""]
            .joined(separator: "||")
    }

    /// TS `buildUsageDataFromRows` (line 941).
    static func buildUsageDataFromRows(_ rows: [LocalRow]) -> (daily: [DailyRecord], totals: Totals) {
        var dayMap: [String: DailyRecord] = [:]
        var breakdownMaps: [String: [String: ModelBreakdown]] = [:]

        for row in rows {
            // TS skips rows with no/unknown date.
            if row.date.isEmpty || row.date == "unknown-date" { continue }
            var day = dayMap[row.date] ?? DailyRecord(
                date: row.date,
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalTokens: 0,
                totalCost: 0,
                modelsUsed: [],
                modelBreakdowns: [],
                calls: 0,
                localSources: [])
            day.inputTokens += self.stableNumber(row.inputTokens)
            day.outputTokens += self.stableNumber(row.outputTokens)
            day.cacheCreationTokens += self.stableNumber(row.cacheCreationTokens)
            day.cacheReadTokens += self.stableNumber(row.cacheReadTokens)
            day.totalTokens += self.stableNumber(row.totalTokens)
            day.totalCost += self.stableNumber(row.totalCost)
            day.modelsUsed.append(row.modelName)
            day.calls += self.stableNumber(row.calls == 0 ? 1 : row.calls)
            self.addSource(&day.localSources, row: row)
            dayMap[row.date] = day

            var modelMap = breakdownMaps[row.date] ?? [:]
            var breakdown = modelMap[row.modelName] ?? ModelBreakdown(
                modelName: row.modelName,
                inputTokens: 0,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                totalTokens: 0,
                cost: 0,
                calls: 0,
                localSources: [])
            breakdown.inputTokens += self.stableNumber(row.inputTokens)
            breakdown.outputTokens += self.stableNumber(row.outputTokens)
            breakdown.cacheCreationTokens += self.stableNumber(row.cacheCreationTokens)
            breakdown.cacheReadTokens += self.stableNumber(row.cacheReadTokens)
            breakdown.totalTokens += self.stableNumber(row.totalTokens)
            breakdown.cost += self.stableNumber(row.totalCost)
            breakdown.calls += self.stableNumber(row.calls == 0 ? 1 : row.calls)
            self.addSource(&breakdown.localSources, row: row)
            modelMap[row.modelName] = breakdown
            breakdownMaps[row.date] = modelMap
        }

        var daily: [DailyRecord] = []
        for date in dayMap.keys.sorted() {
            guard var day = dayMap[date] else { continue }
            // TS: dedupe + sort the modelsUsed list.
            day.modelsUsed = Array(Set(day.modelsUsed)).sorted()
            day.totalCost = self.roundCost(day.totalCost)
            // TS: model breakdowns sorted by (cost desc, totalTokens desc, modelName asc).
            let modelMap = breakdownMaps[date] ?? [:]
            day.modelBreakdowns = modelMap.values.map {
                var b = $0
                b.cost = self.roundCost(b.cost)
                return b
            }.sorted { a, b in
                if a.cost != b.cost { return a.cost > b.cost }
                if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
                return a.modelName < b.modelName
            }
            daily.append(day)
        }
        var totals = Totals()
        for day in daily {
            totals.inputTokens += day.inputTokens
            totals.outputTokens += day.outputTokens
            totals.cacheCreationTokens += day.cacheCreationTokens
            totals.cacheReadTokens += day.cacheReadTokens
            totals.totalTokens += day.totalTokens
            totals.totalCost += day.totalCost
        }
        totals.totalCost = self.roundCost(totals.totalCost)
        return (daily, totals)
    }
}

// MARK: - Map DailyRecord → CostUsageDailyReport (codexbar protocol output)

extension CherryStudioLocalUsageScanner {
    func filter(daily: [DailyRecord], since: Date, until: Date) -> [DailyRecord] {
        let sinceKey = Self.dayKey(from: since)
        let untilKey = Self.dayKey(from: until)
        return daily.filter { record in
            record.date >= sinceKey && record.date <= untilKey
        }
    }

    static func dayKey(from date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1)
    }

    static func makeReport(from daily: [DailyRecord]) -> CostUsageDailyReport {
        let entries = daily.map { record -> CostUsageDailyReport.Entry in
            let breakdowns: [CostUsageDailyReport.ModelBreakdown]? = record.modelBreakdowns.isEmpty ? nil : record
                .modelBreakdowns.map {
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: $0.modelName,
                        costUSD: $0.cost,
                        totalTokens: Int($0.totalTokens.rounded(.toNearestOrEven)))
                }
            return CostUsageDailyReport.Entry(
                date: record.date,
                inputTokens: Int(record.inputTokens.rounded(.toNearestOrEven)),
                outputTokens: Int(record.outputTokens.rounded(.toNearestOrEven)),
                cacheReadTokens: Int(record.cacheReadTokens.rounded(.toNearestOrEven)),
                cacheCreationTokens: Int(record.cacheCreationTokens.rounded(.toNearestOrEven)),
                totalTokens: Int(record.totalTokens.rounded(.toNearestOrEven)),
                costUSD: record.totalCost,
                modelsUsed: record.modelsUsed.isEmpty ? nil : record.modelsUsed,
                modelBreakdowns: breakdowns)
        }
        var totals = Totals()
        for r in daily {
            totals.inputTokens += r.inputTokens
            totals.outputTokens += r.outputTokens
            totals.cacheCreationTokens += r.cacheCreationTokens
            totals.cacheReadTokens += r.cacheReadTokens
            totals.totalTokens += r.totalTokens
            totals.totalCost += r.totalCost
        }
        let summary: CostUsageDailyReport.Summary? = entries.isEmpty ? nil : CostUsageDailyReport.Summary(
            totalInputTokens: Int(totals.inputTokens.rounded(.toNearestOrEven)),
            totalOutputTokens: Int(totals.outputTokens.rounded(.toNearestOrEven)),
            cacheReadTokens: Int(totals.cacheReadTokens.rounded(.toNearestOrEven)),
            cacheCreationTokens: Int(totals.cacheCreationTokens.rounded(.toNearestOrEven)),
            totalTokens: Int(totals.totalTokens.rounded(.toNearestOrEven)),
            totalCostUSD: Self.roundCost(totals.totalCost))
        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
