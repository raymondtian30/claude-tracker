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
        ("meta", "Meta"),
        ("microsoft", "Microsoft"),
        ("amazon", "Amazon"),
        ("nvidia", "NVIDIA"),
        ("ibm", "IBM"),
        ("cohere", "Cohere"),
        ("ai21", "AI21 Labs"),
        ("perplexity", "Perplexity"),
        ("allenai", "Allen Institute for AI"),
        ("deepcogito", "Deep Cogito"),
        ("nous", "Nous Research"),
        ("arcee", "Arcee AI"),
        ("liquid", "Liquid AI"),
        ("reka", "Reka"),
        ("inflection", "Inflection"),
        ("baidu", "Baidu"),
        ("bytedance", "ByteDance"),
        ("tencent", "Tencent"),
        ("xiaomi", "Xiaomi"),
        ("stepfun", "StepFun"),
        ("huggingface", "Hugging Face"),
        ("tii", "Technology Innovation Institute"),
        ("writer", "Writer"),
        ("upstage", "Upstage"),
        ("lgai", "LG AI Research"),
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
        "meta-llama": "meta",
        "microsoft": "microsoft",
        "amazon": "amazon",
        "nvidia": "nvidia",
        "ibm-granite": "ibm",
        "coherelabs": "cohere",
        "ai21labs": "ai21",
        "perplexity-ai": "perplexity",
        "allenai": "allenai",
        "deepcogito": "deepcogito",
        "nousresearch": "nous",
        "arcee-ai": "arcee",
        "liquidai": "liquid",
        "rekaai": "reka",
        "inflection-ai": "inflection",
        "baidu": "baidu",
        "bytedance-seed": "bytedance",
        "tencent": "tencent",
        "xiaomimimo": "xiaomi",
        "stepfun-ai": "stepfun",
        "huggingfacetb": "huggingface",
        "tiiuae": "tii",
        "writer": "writer",
        "upstage": "upstage",
        "lgai-exaone": "lgai",
        "cohereforai": "cohere", "nous": "nous", "ai21": "ai21",
        "arcee": "arcee", "liquid": "liquid", "reka": "reka", "stepfun": "stepfun",
        "ibm": "ibm", "meta": "meta", "bytedance": "bytedance", "xiaomi": "xiaomi",
        "cohere": "cohere",
    ]

    // Model names, checked in order; the first match decides the provider.
    static let modelPatterns: [(provider: String, pattern: NSRegularExpression)] = [
        ("microsoft", #"^(phi|mai-ds)(-|\d|$)|^wizardlm(-|\d|$)"#),
        ("amazon", #"^(?:(?:us|eu|apac|global)\.)?(amazon\.)?(nova|titan)(-|\d|\.|$)"#),
        ("nvidia", #"^(nvidia-|openreasoning-)?nemotron(-|\d|$)|^llama[-_\d].*[-_]nemotron(-|$)"#),
        ("ibm", #"^granite(-|\d|$)"#),
        ("cohere", #"^(cohere-)?(c4ai-)?(command-(r|a|light|nightly)(-|\d|\+|$)|aya(-|\d|$))"#),
        ("ai21", #"^(ai21-)?jamba(-|\d|$)"#),
        ("perplexity", #"^r1-1776$|^sonar(-|$)|^llama-\d.*-sonar(-|$)"#),
        ("allenai", #"^(olmo|molmo)(-|\d|$)"#),
        ("deepcogito", #"^cogito(-|\d|$)"#),
        ("nous", #"^(nous-)?hermes(-|\d|$)"#),
        ("arcee", #"^arcee(-|$)|^afm-\d"#),
        ("liquid", #"^lfm(-|\d|$)"#),
        ("reka", #"^reka(-|$)"#),
        ("inflection", #"^inflection[-_]\d"#),
        ("baidu", #"^ernie(-|\d|$)"#),
        ("bytedance", #"^seed-(oss|coder|\d)|^doubao(-|\d|$)|^ui-tars(-|$)"#),
        ("tencent", #"^hunyuan(-|\d|$)"#),
        ("xiaomi", #"^mimo(-|\d|$)"#),
        ("stepfun", #"^step-?\d"#),
        ("huggingface", #"^smollm(-|\d|$)"#),
        ("tii", #"^falcon(-|\d|$)"#),
        ("writer", #"^palmyra(-|$)"#),
        ("upstage", #"^solar(-|\d|$)"#),
        ("lgai", #"^(k-)?exaone(-|\d|$)"#),
        ("meta", #"^(meta-)?(code)?llama(-|\d|$)"#),
        ("openai", #"^(gpt|chatgpt|codex)(-|$)|^o\d+(-|$)"#),
        ("deepseek", #"^deepseek(-|$)"#),
        ("kimi", #"^(kimi|moonshot)(-|$)"#),
        ("google", #"^(gemini|gemma)(-|\d|$)"#),
        ("anthropic", #"^claude(-|$)"#),
        ("xai", #"^grok(-|\d|$)"#),
        ("mistral", #"^(open-)?(mistral|mixtral|codestral|devstral|magistral|ministral|pixtral)(-|$)"#),
        ("qwen", #"^(code)?(qwen|qwq|qvq)(-|\d|$)|^tongyi(-|$)"#),
        ("zai", #"^glm(-|\d|$)"#),
        ("minimax", #"^minimax(-|$)"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Canonical provider key for a vendor or integration name (e.g. "moonshotai" -> "kimi"), or nil.
    public static func normalizeProvider(_ raw: String?) -> String? {
        guard let lowered = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !lowered.isEmpty
        else { return nil }
        if providerNames[lowered] != nil {
            return lowered
        }
        return vendors[lowered]
    }

    /// The provider key whose model this is, or nil.
    public static func providerOf(_ model: String?) -> String? {
        let lowered = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = lowered.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard var name = parts.last, !name.isEmpty else { return nil }
        let vendor = parts.count > 1 ? parts[parts.count - 2] : ""
        // Dedicated publisher namespaces may describe derivatives of another
        // family's model. Hosting services cannot establish authorship.
        if !hostingIntegrations.contains(vendor), let author = vendors[vendor] {
            return author
        }
        // Bedrock's "vendor.model" form, with an optional region in front:
        // "us.deepseek.r1-v1:0", "meta.llama3-3-70b-instruct-v1:0". Only a
        // known vendor counts, so dotted versions like "qwen2.5" are left alone.
        if let match = bedrockID.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let vendorRange = Range(match.range(at: 1), in: name),
           let modelRange = Range(match.range(at: 2), in: name) {
            let dotted = String(name[vendorRange])
            if hostingIntegrations.contains(dotted) {
                name = String(name[modelRange])
            } else if let author = vendors[dotted] ?? (providerNames[dotted] != nil ? dotted : nil) {
                return author
            }
        }
        if let provider = matchPatterns(name) { return provider }
        // Ollama's "family:tag" form, e.g. "mistral:7b" or "qwq:32b".
        if let colon = name.firstIndex(of: ":"), colon != name.startIndex,
           let provider = matchPatterns(String(name[..<colon])) {
            return provider
        }
        // These four once matched anywhere in a name; keep counting names that
        // hold them as a word, like an Azure deployment "my-deepseek-r1".
        let range = NSRange(name.startIndex..., in: name)
        for (provider, pattern) in familyWords where pattern.firstMatch(in: name, range: range) != nil {
            return provider
        }
        // A host's own namespace names nothing better (OpenRouter's
        // "alibaba/tongyi-deepresearch-30b-a3b").
        return vendors[vendor]
    }

    static let familyWords: [(provider: String, pattern: NSRegularExpression)] = [
        ("deepseek", #"(^|[-_.])deepseek([-_.:]|\d|$)"#),
        ("kimi", #"(^|[-_.])(kimi|moonshot)([-_.:]|\d|$)"#),
        ("qwen", #"(^|[-_.])(qwen|qwq)([-_.:]|\d|$)"#),
        ("minimax", #"(^|[-_.])minimax([-_.:]|\d|$)"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    private static func matchPatterns(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        for (provider, pattern) in modelPatterns where pattern.firstMatch(in: name, range: range) != nil {
            return provider
        }
        return nil
    }

    private static let bedrockID = try! NSRegularExpression(
        pattern: #"^(?:(?:us|eu|apac|global|us-gov|jp|au|ca)\.)?([a-z0-9]+)\.([a-z].*)$"#)

    /// These integrations host other authors as well as their own models.
    /// Their generic model IDs cannot establish a model's author.
    static let hostingIntegrations: Set<String> = [
        "amazon", "aws", "bedrock", "azure", "microsoft", "nvidia", "huggingface", "perplexity",
        "alibaba", "tencent", "baidu", "bytedance",
    ]

    static func catalogProvider(model: String, integration: String) -> String? {
        if model.contains("/"), let author = providerOf(model) { return author }
        let vendor = integration.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !hostingIntegrations.contains(vendor), let author = normalizeProvider(vendor) { return author }
        return providerOf(model)
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
        let catalog = OpencodeSource.byokModels(state)
        var views = [Tools.View]()
        var errors = [String]()
        for (tool, _) in Tools.tools {
            var view = Tools.toolView(state, tool)
            if let error = view.error {
                errors.append("\(view.name): \(error)")
            }
            let daily = UsageStats.filterDaily(view.daily) { model in
                // Catalog metadata belongs only to opencode's logs. It may
                // identify a derivative whose bare name resembles a base model.
                // When integrations disagree, only the name can decide.
                let entry = catalog[model]
                let listed = JSON.truthy(entry?["provider_ambiguous"]) ? nil
                    : normalizeProvider(entry?.string("provider"))
                if tool == "opencode", let listed = listed {
                    return listed == key
                }
                // Other tools: the name first, the catalog for names it can't place.
                return (providerOf(model) ?? listed) == key
            }
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
