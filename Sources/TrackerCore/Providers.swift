import Foundation

/// AI providers (the companies whose models ran), as views across every tool.
///
/// A provider view has the same shape as a tool view (see Tools): that
/// provider's models, filtered out of each tool's per-day buckets. The numbers
/// are the tools' own counts, so no account or API key is needed for them.
public enum Providers {
    public static let providers: [(key: String, name: String)] = [
        ("openai", "OpenAI"), ("deepseek", "DeepSeek"), ("kimi", "Kimi"),
        ("google", "Google"), ("anthropic", "Anthropic"), ("xai", "xAI"),
        ("mistral", "Mistral"), ("qwen", "Qwen"), ("zai", "Z.ai (GLM)"), ("minimax", "MiniMax"),
    ]
    public static let providerNames: [String: String] = Dictionary(
        uniqueKeysWithValues: providers.map { ($0.key, $0.name) })

    // A "vendor/" prefix some tools put before the model name (e.g. OpenRouter's
    // "moonshotai/kimi-k2").
    static let vendors: [String: String] = [
        "openai": "openai",
        "deepseek": "deepseek",
        "deepseek-ai": "deepseek",
        "moonshotai": "kimi",
        "moonshot": "kimi",
        "google": "google",
        "anthropic": "anthropic",
        "x-ai": "xai",
        "xai": "xai",
        "mistralai": "mistral",
        "mistral": "mistral",
        "qwen": "qwen",
        "alibaba": "qwen",
        "z-ai": "zai",
        "zai": "zai",
        "zhipuai": "zai",
        "minimax": "minimax",
    ]

    // Model names, checked in order; the first match decides the provider.
    static let modelPatterns: [(provider: String, pattern: NSRegularExpression)] = [
        ("openai", #"^(gpt|chatgpt|codex)(-|$)|^o\d+(-|$)"#),
        ("deepseek", #"deepseek"#),
        ("kimi", #"kimi|moonshot"#),
        ("google", #"^(gemini|gemma)(-|\d|$)"#),
        ("anthropic", #"^claude(-|$)"#),
        ("xai", #"^grok(-|\d|$)"#),
        ("mistral", #"^(open-)?(mistral|mixtral|codestral|devstral|magistral|ministral|pixtral)(-|$)"#),
        ("qwen", #"qwen|^qwq(-|$)"#),
        ("zai", #"^glm(-|\d|$)"#),
        ("minimax", #"minimax"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// The provider key whose model this is, or nil.
    public static func providerOf(_ model: String?) -> String? {
        // Python's str.rpartition("/"): no "/" leaves the vendor empty.
        let lowered = (model ?? "").lowercased()
        var vendor = ""
        var name = lowered
        if let slash = lowered.range(of: "/", options: .backwards) {
            vendor = String(lowered[..<slash.lowerBound])
            name = String(lowered[slash.upperBound...])
        }
        let range = NSRange(name.startIndex..., in: name)
        for (provider, pattern) in modelPatterns where pattern.firstMatch(in: name, range: range) != nil {
            return provider
        }
        return vendors[vendor]
    }

    /// Enabled tools, plus every tool on this Mac while any provider is on
    /// (a provider's models can run in any of them).
    public static func toolsToScan(_ state: JSONObject, detected: [String]) -> [String] {
        var wanted = Set((state.array("enabled_tools") ?? []).compactMap { $0 as? String })
        if JSON.truthy(state["enabled_providers"]) {
            wanted.formUnion(detected)
        }
        return Tools.tools.map(\.key).filter(wanted.contains)
    }

    /// Usage of `key`'s models through every tool with data on this Mac.
    public static func providerView(_ state: JSONObject, _ key: String) -> Tools.View {
        var views = [Tools.View]()
        var errors = [String]()
        for (tool, _) in Tools.tools {
            var view = Tools.toolView(state, tool)
            if let error = view.error {
                errors.append("\(view.name): \(error)")
            }
            let daily = UsageStats.filterDaily(view.daily) { providerOf($0) == key }
            if !daily.isEmpty {
                view.daily = daily
                view.grandTotal = SourceFile.total(daily)
                views.append(view)
            }
        }
        let daily = UsageStats.mergeDaily(views.map(\.daily))
        return Tools.View(
            key: key,
            name: providerNames[key] ?? key,
            daily: daily,
            grandTotal: SourceFile.total(daily),
            error: errors.first,
            views: views  // per tool, so each tool's recorded costs stay its own
        )
    }
}
