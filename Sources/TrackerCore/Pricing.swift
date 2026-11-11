import Foundation

/// Estimated pay-as-you-go API cost of Claude Code usage.
///
/// This is for fun/context only: a Claude Pro or Max subscription is flat-rate,
/// so none of this is actually billed. Prices are USD per million tokens from
/// Anthropic's public API pricing and will drift over time.
public enum Pricing {
    /// USD per 1M tokens.
    public struct Price: Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double

        public init(_ input: Double, _ output: Double, _ cacheRead: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
        }
    }

    /// prefix -> (input, output, cache_read) USD per 1M tokens.
    /// Longest matching prefix wins, so "claude-opus-5-5" beats "claude-opus-5".
    public static let prices: [String: Price] = [
        "claude-fable-5-1": Price(10.00, 50.00, 0.25),
        "claude-fable-5": Price(10.00, 50.00, 1.00),
        "claude-mythos-5-1": Price(10.00, 50.00, 0.25),
        "claude-mythos-5": Price(10.00, 50.00, 1.00),
        "claude-opus-5-5": Price(4.00, 20.00, 0.20),
        "claude-opus-5": Price(5.00, 25.00, 0.50),
        "claude-opus-4-8": Price(5.00, 25.00, 0.50),
        "claude-opus-4-7": Price(5.00, 25.00, 0.50),
        "claude-opus-4-6": Price(5.00, 25.00, 0.50),
        "claude-opus-4-5": Price(5.00, 25.00, 0.50),
        "claude-opus-4-1": Price(15.00, 75.00, 1.50),
        "claude-opus-4": Price(15.00, 75.00, 1.50),
        "claude-sonnet-5-5": Price(2.00, 10.00, 0.20),
        "claude-sonnet-5": Price(2.00, 10.00, 0.20),
        "claude-sonnet-4": Price(3.00, 15.00, 0.30),
        "claude-haiku-5-5": Price(0.10, 0.50, 0.01),
        "claude-haiku-4-5": Price(1.00, 5.00, 0.10),
    ]

    // Cache writes are billed as a multiple of the model's input price.
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0

    /// (input, output, cache_read) per 1M tokens, or nil if unknown.
    public static func priceFor(_ model: String) -> Price? {
        let matches = prices.keys.filter { model == $0 || model.hasPrefix($0 + "-") }
        guard let longest = matches.max(by: { $0.count < $1.count }) else { return nil }
        return prices[longest]
    }

    /// Estimate USD for {model: {category: tokens}}.
    ///
    /// `recorded` is {model: dollars} a tool recorded itself (opencode does);
    /// those models use that amount instead of the price table. `extraPrices`
    /// supplies prices discovered from a BYOK catalog (e.g. opencode).
    /// Returns (dollars, unpriced): tokens from models with no known
    /// price are left out of the dollar figure and counted separately.
    public static func estimateCost(_ models: UsageStats.Models,
                                    recorded: [String: Double] = [:],
                                    extraPrices: [String: Price] = [:]) -> (dollars: Double, unpriced: Int) {
        var dollars = 0.0
        var unpriced = 0
        for (model, parts) in models {
            if let amount = recorded[model] {
                dollars += amount
                continue
            }
            guard let price = priceFor(model) ?? extraPrices[model] else {
                unpriced += parts.values.reduce(0, +)
                continue
            }
            func tokens(_ category: String) -> Double { Double(parts[category] ?? 0) }
            // Same order of operations as the Python, for the same rounding.
            let input = tokens("input") * price.input
            let output = tokens("output") * price.output
            let write5m = tokens("cache_write_5m") * price.input * cacheWrite5mMultiplier
            let write1h = tokens("cache_write_1h") * price.input * cacheWrite1hMultiplier
            let read = tokens("cache_read") * price.cacheRead
            dollars += (input + output + write5m + write1h + read) / 1_000_000
        }
        return (dollars, unpriced)
    }

    /// "$3.46", or "$12,346" from $1,000 up.
    public static func formatDollars(_ amount: Double) -> String {
        formatMoney(amount, currency: "USD")
    }

    /// A currency prices can be shown in.
    public struct Currency {
        public let code: String
        public let symbol: String
        public let name: String
        /// Whole units only (the currency has no minor unit worth showing).
        public let wholeUnits: Bool
    }

    public static let currencies: [Currency] = [
        Currency(code: "USD", symbol: "$", name: "US dollar", wholeUnits: false),
        Currency(code: "EUR", symbol: "€", name: "Euro", wholeUnits: false),
        Currency(code: "GBP", symbol: "£", name: "British pound", wholeUnits: false),
        Currency(code: "CAD", symbol: "CA$", name: "Canadian dollar", wholeUnits: false),
        Currency(code: "AUD", symbol: "A$", name: "Australian dollar", wholeUnits: false),
        Currency(code: "CHF", symbol: "CHF ", name: "Swiss franc", wholeUnits: false),
        Currency(code: "JPY", symbol: "¥", name: "Japanese yen", wholeUnits: true),
        Currency(code: "CNY", symbol: "CN¥", name: "Chinese yuan", wholeUnits: false),
        Currency(code: "KRW", symbol: "₩", name: "South Korean won", wholeUnits: true),
        Currency(code: "INR", symbol: "₹", name: "Indian rupee", wholeUnits: false),
        Currency(code: "MXN", symbol: "MX$", name: "Mexican peso", wholeUnits: false),
        Currency(code: "BRL", symbol: "R$", name: "Brazilian real", wholeUnits: false),
    ]

    /// Units of each currency per US dollar. These are fixed, approximate
    /// rates built into the app (it makes no network request for them), so
    /// they don't follow the market: update them here from time to time.
    public static let rates: [String: Double] = [
        "USD": 1, "EUR": 0.92, "GBP": 0.79, "CAD": 1.37, "AUD": 1.52, "CHF": 0.88,
        "JPY": 150, "CNY": 7.2, "KRW": 1380, "INR": 84, "MXN": 18.5, "BRL": 5.5,
    ]

    /// `dollars` in `currency` ("$3.46", "€3.18", "¥519"); an unknown code
    /// reads as US dollars. From 1,000 units up there are no decimals.
    public static func formatMoney(_ dollars: Double, currency code: String) -> String {
        let currency = currencies.first { $0.code == code } ?? currencies[0]
        let amount = dollars * (rates[currency.code] ?? 1)
        let digits = currency.wholeUnits || amount >= 1000 ? "%.0f" : "%.2f"
        return currency.symbol + withThousandsSeparators(String(format: digits, amount))
    }

    /// "12345.60" -> "12,345.60", as Python's "," format option groups digits.
    static func withThousandsSeparators(_ number: String) -> String {
        let sign = number.hasPrefix("-") ? "-" : ""
        let unsigned = number.dropFirst(sign.count)
        let whole = unsigned.prefix { $0 != "." }
        let rest = unsigned.dropFirst(whole.count)
        var grouped = ""
        for (index, digit) in whole.enumerated() {
            if index > 0 && (whole.count - index) % 3 == 0 {
                grouped += ","
            }
            grouped.append(digit)
        }
        return sign + grouped + rest
    }
}
