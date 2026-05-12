import Foundation

/// 1:1 Swift port of `pricing.ts` from the OpenClaw npm package — embedded official pricing only.
///
/// Network-fetched LiteLLM pricing is intentionally NOT ported: scanners must remain offline. If a
/// model isn't in the table, the message's embedded `usage.cost.total` is still honored; otherwise
/// the message contributes zero cost (matching `findPricing → null` behavior in the TS code).
public enum OpenClawPricing {
    public struct ModelPricing: Sendable, Equatable {
        public var inputCostPerToken: Double
        public var outputCostPerToken: Double
        public var cacheReadInputTokenCost: Double
        public var cacheCreationInputTokenCost: Double

        public init(
            input: Double = 0,
            output: Double = 0,
            cacheRead: Double = 0,
            cacheCreation: Double = 0)
        {
            self.inputCostPerToken = input
            self.outputCostPerToken = output
            self.cacheReadInputTokenCost = cacheRead
            self.cacheCreationInputTokenCost = cacheCreation
        }
    }

    /// $/1M tokens → $/token.
    private static func perM(_ price: Double) -> Double {
        price / 1_000_000
    }

    /// Official pricing (verified from provider websites, March 2026). Mirrors `OFFICIAL_PRICING`
    /// in pricing.ts. Order is preserved for human readability — lookup uses the dictionary.
    public static let officialPricing: [String: ModelPricing] = [
        // OpenAI
        "gpt-5.4": ModelPricing(input: perM(2.50), output: perM(15.00), cacheRead: perM(0.625)),
        "gpt-5.4-mini": ModelPricing(input: perM(0.50), output: perM(3.00)),
        "gpt-5.3-codex": ModelPricing(input: perM(1.75), output: perM(14.00), cacheRead: perM(0.4375)),
        "gpt-5.3": ModelPricing(input: perM(1.75), output: perM(14.00)),
        "gpt-5": ModelPricing(input: perM(1.25), output: perM(10.00)),
        "gpt-5-mini": ModelPricing(input: perM(0.25), output: perM(2.00)),

        // Qwen (Alibaba, OpenRouter pricing)
        "qwen3.5-plus": ModelPricing(input: perM(0.26), output: perM(1.56)),
        "qwen3.5-397b-a17b": ModelPricing(input: perM(0.39), output: perM(0.90)),
        "qwen3.5-122b-a10b": ModelPricing(input: perM(0.26), output: perM(2.08)),
        "qwen3.5-27b": ModelPricing(input: perM(0.20), output: perM(1.56)),
        "qwen3.5-flash": ModelPricing(input: perM(0.07), output: perM(0.26)),

        // MiniMax
        "minimax-m2.5-highspeed": ModelPricing(input: perM(0.30), output: perM(2.40), cacheRead: perM(0.03)),
        "minimax-m2.5-lightning": ModelPricing(input: perM(0.30), output: perM(2.40), cacheRead: perM(0.03)),
        "minimax-m2.5": ModelPricing(input: perM(0.30), output: perM(1.20), cacheRead: perM(0.03)),
        "minimax-m2.1": ModelPricing(input: perM(0.30), output: perM(1.20)),
        "minimax-m2": ModelPricing(input: perM(0.30), output: perM(1.20)),

        // Anthropic
        "claude-opus-4-6": ModelPricing(
            input: perM(5.00), output: perM(25.00), cacheRead: perM(0.50), cacheCreation: perM(6.25)),
        "claude-sonnet-4-6": ModelPricing(
            input: perM(3.00), output: perM(15.00), cacheRead: perM(0.30), cacheCreation: perM(3.75)),
        "claude-haiku-4-5": ModelPricing(
            input: perM(0.80), output: perM(4.00), cacheRead: perM(0.08), cacheCreation: perM(1.00)),
        "opus-4-6": ModelPricing(
            input: perM(5.00), output: perM(25.00), cacheRead: perM(0.50), cacheCreation: perM(6.25)),
        "sonnet-4-6": ModelPricing(
            input: perM(3.00), output: perM(15.00), cacheRead: perM(0.30), cacheCreation: perM(3.75)),
        "opus": ModelPricing(input: perM(5.00), output: perM(25.00)),
        "sonnet": ModelPricing(input: perM(3.00), output: perM(15.00)),

        // Google
        "gemini-2.5-pro": ModelPricing(input: perM(1.25), output: perM(10.00)),

        // xAI
        "grok-4": ModelPricing(input: perM(3.00), output: perM(15.00)),
        "grok-4-fast": ModelPricing(input: perM(5.00), output: perM(25.00)),
    ]

    /// `findPricing(db, rawModel)` from pricing.ts. Match order:
    ///   1. exact key match on the last "/"-delimited segment
    ///   2. case-insensitive match (full key OR last segment of key)
    ///   3. partial substring match
    public static func findPricing(
        _ db: [String: ModelPricing],
        rawModel: String) -> ModelPricing?
    {
        let modelName = self.extractModelName(rawModel)

        if let exact = db[modelName] { return exact }

        let lower = modelName.lowercased()
        for (key, val) in db {
            if key.lowercased() == lower { return val }
            let keyLast = key.split(separator: "/").last.map(String.init)?.lowercased()
            if keyLast == lower { return val }
        }

        for (key, val) in db where key.lowercased().contains(lower) {
            return val
        }

        return nil
    }

    public static func calculateCost(
        pricing: ModelPricing,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int) -> Double
    {
        Double(input) * pricing.inputCostPerToken
            + Double(output) * pricing.outputCostPerToken
            + Double(cacheRead) * pricing.cacheReadInputTokenCost
            + Double(cacheWrite) * pricing.cacheCreationInputTokenCost
    }

    /// `extractModelName` from pricing.ts: take the last `/`-separated segment.
    static func extractModelName(_ rawModel: String) -> String {
        let parts = rawModel.split(separator: "/")
        return parts.last.map(String.init) ?? rawModel
    }
}
