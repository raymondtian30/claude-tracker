import Foundation

/// Ordering of the models card: by token usage (the default) or by model tier,
/// low to high. A tier is a rank inside one company's own line-up; only Claude
/// has a table, since nothing in the logs says how capable a model is. A model
/// with no tier comes last, in token order among its kind.
public enum ModelTiers {
    public enum Order: String, CaseIterable {
        case tokens
        case tier
    }

    /// Claude's families, low to high capability. Tier 1 is the first.
    public static let claudeFamilies = ["haiku", "sonnet", "opus", "mythos", "fable"]

    /// The stored `model_sort` values and the labels of the Settings control.
    public static let choices: [(order: Order, label: String)] = [
        (.tokens, "Token usage"), (.tier, "Model, low to high"),
    ]

    /// The tier (1 is lowest) of a model id, or nil when the id names no known
    /// family. Matches the family as a word of the id, so `claude-3-5-sonnet-…`,
    /// `claude-opus-5-5` and `anthropic/claude-haiku-4` all have one.
    public static func tier(of modelId: String) -> Int? {
        let words = modelId.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.contains("claude") else { return nil }
        for (index, family) in claudeFamilies.enumerated() where words.contains(family) {
            return index + 1
        }
        return nil
    }

    /// The order in a stored value; token usage for a missing or bad one.
    public static func order(from stored: Any?) -> Order {
        (stored as? String).flatMap(Order.init(rawValue:)) ?? .tokens
    }

    /// `totals` (already most tokens first, as `UsageStats.modelTotals` gives
    /// them) in `order`. By tier: lowest tier first, then most tokens first,
    /// then name; models with no tier after all the others, most tokens first.
    public static func sorted(_ totals: [UsageStats.NamedTotal], by order: Order) -> [UsageStats.NamedTotal] {
        guard order == .tier else { return totals }
        return totals.sorted { left, right in
            let (a, b) = (tier(of: left.name) ?? Int.max, tier(of: right.name) ?? Int.max)
            if a != b { return a < b }
            if left.tokens != right.tokens { return left.tokens > right.tokens }
            return left.name < right.name
        }
    }
}
