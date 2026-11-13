import Foundation
import Testing
@testable import TrackerCore

private let addedProviders: [(key: String, vendor: String, model: String)] = [
    ("meta", "meta-llama", "llama-3.3-70b"),
    ("microsoft", "microsoft", "phi-4"),
    ("amazon", "amazon", "amazon.nova-pro-v1:0"),
    ("nvidia", "nvidia", "nemotron-4-340b"),
    ("ibm", "ibm-granite", "granite-3.3-8b"),
    ("cohere", "coherelabs", "command-r-plus"),
    ("ai21", "ai21labs", "jamba-large-1.6"),
    ("perplexity", "perplexity-ai", "sonar-pro"),
    ("allenai", "allenai", "olmo-2-0325-32b"),
    ("deepcogito", "deepcogito", "cogito-v1-preview-llama-70b"),
    ("nous", "nousresearch", "hermes-3-llama-3.1-8b"),
    ("arcee", "arcee-ai", "arcee-blitz"),
    ("liquid", "liquidai", "lfm2-1.2b"),
    ("reka", "rekaai", "reka-core"),
    ("inflection", "inflection-ai", "inflection_3_pi"),
    ("baidu", "baidu", "ernie-4.5-21b"),
    ("bytedance", "bytedance-seed", "seed-oss-36b"),
    ("tencent", "tencent", "hunyuan-a13b"),
    ("xiaomi", "xiaomimimo", "mimo-7b-rl"),
    ("stepfun", "stepfun-ai", "step3"),
    ("huggingface", "huggingfacetb", "smollm2-1.7b"),
    ("tii", "tiiuae", "falcon3-10b"),
    ("writer", "writer", "palmyra-fin-70b"),
    ("upstage", "upstage", "solar-10.7b"),
    ("lgai", "lgai-exaone", "exaone-3.5-32b"),
]

@Test func expandedProviderCatalogIsDistinctAndComplete() {
    let keys = Providers.providers.map(\.key)
    #expect(keys.count == 35)
    #expect(Set(keys).count == keys.count)
    #expect(Set(Providers.providers.map { $0.name.lowercased() }).count == keys.count)
    #expect(Array(keys.dropFirst(10)) == addedProviders.map(\.key))
    #expect(Set(keys).isDisjoint(with: Set(Tools.tools.map(\.key) + ["all"])))
    for item in addedProviders {
        #expect(Providers.normalizeProvider(item.vendor.uppercased()) == item.key)
        #expect(Providers.providerOf(item.model) == item.key, "Bare model: \(item.model)")
        #expect(Providers.providerOf("  \(item.vendor)/\(item.model.uppercased())  ") == item.key)
        #expect(Providers.providerOf("openrouter/\(item.vendor)/\(item.model)") == item.key)
        #expect(ToolIconSource.monograms[item.key] != nil)
        #expect(Accounts.keyHelp[item.key] == nil)
    }
}

@Test func providerAuthorsAreDistinctFromHostsAndBaseModels() {
    let examples = [
        "NousResearch/DeepSeek-R1-Distill-Qwen-32B": "nous",
        "us.amazon.nova-pro-v1:0": "amazon", "eu.amazon.nova-pro-v1:0": "amazon",
        "apac.amazon.nova-pro-v1:0": "amazon", "microsoft/MAI-DS-R1": "microsoft",
        "nvidia/OpenReasoning-Nemotron-7B": "nvidia",
        "deepcogito/cogito-v1-preview-qwen-32B": "deepcogito",
        "nvidia/Llama-3_3-Nemotron-Super-49B-v1": "nvidia",
        "Llama-3.1-Nemotron-70B-Instruct": "nvidia",
        "openrouter/nvidia/Llama-3_3-Nemotron-Super-49B-v1": "nvidia",
        "nvidia/llama-3.3-70b": "meta",
        "huggingface/meta-llama/llama-3.3-70b": "meta",
        "amazon/claude-sonnet-4": "anthropic",
        "microsoft/gpt-4o": "openai",
        "hermes-3-llama-3.1-8b": "nous",
        "llama-3.1-sonar-large-128k-online": "perplexity",
    ]
    for (model, author) in examples { #expect(Providers.providerOf(model) == author, "\(model)") }
    // A family named as a word still counts, as it did before names were anchored.
    for (model, author) in ["my-deepseek-r1": "deepseek", "deepseek_r1": "deepseek", "azure-qwen-72b": "qwen",
                            "team.minimax-m2": "minimax", "alibaba/tongyi-deepresearch-30b-a3b": "qwen",
                            "nvidia/some-new-model": "nvidia"] {
        #expect(Providers.providerOf(model) == author, "\(model)")
    }
    for model in ["unknown", "notqwen3", "mydeepseek", "minimaximum", "stepwise", "novacode",
                  "solarized", "seedling", "command-line", "falconry", "phixture", "", "meta-llama/"] {
        #expect(Providers.providerOf(model) == nil, "\(model)")
    }
    for host in ["nvidia", "amazon", "microsoft", "huggingface", "perplexity", "azure", "bedrock"] {
        #expect(Providers.catalogProvider(model: "unknown", integration: host) == nil)
        #expect(Providers.catalogProvider(model: "claude-sonnet-4", integration: host) == "anthropic")
    }
}

@Test func newProviderViewsPreserveUsageAndNeverInflateCombinedTotals() {
    var daily = JSONObject()
    for item in addedProviders {
        UsageStats.addUsage(&daily, day: Day(2026, 11, 12), model: "\(item.vendor)/\(item.model)",
                            project: "~/fixture", parts: ["input": 7, "output": 3], cost: 0.02)
    }
    var state: JSONObject = ["enabled_tools": ["opencode"], "onboarding_done": true,
                            "sources": ["opencode": ["daily": daily]]]
    for item in addedProviders {
        AppState.setProviderEnabled(&state, item.key, true)
        state["selected_tool"] = item.key
        #expect(AppState.currentView(state, detected: ["opencode"]).key == item.key)
        let view = Providers.providerView(state, item.key)
        #expect(view.grandTotal == 10)
        #expect(view.daily.object("2026-11-12")?.object("models")?.count == 1)
        #expect(view.views?.count == 1)
    }
    #expect(Providers.providers.reduce(0) { $0 + Providers.providerView(state, $1.key).grandTotal } == 250)
    #expect(Tools.combinedView(state, enabled: ["opencode"]).grandTotal == 250)
    #expect(PanelModel.toolChoices(state, detected: ["opencode"]).count == 26)
    for item in addedProviders { AppState.setProviderEnabled(&state, item.key, false) }
    #expect(AppState.strings(state["enabled_providers"]).isEmpty)
    #expect(Tools.combinedView(state, enabled: ["opencode"]).grandTotal == 250)
}

@Test func bedrockAndOllamaFormsNameTheirAuthor() {
    let examples = [
        // Bedrock "vendor.model", with and without a region.
        "us.deepseek.r1-v1:0": "deepseek", "deepseek.r1-v1:0": "deepseek",
        "qwen.qwen3-coder-480b-a35b-v1:0": "qwen", "moonshot.kimi-k2-thinking": "kimi",
        "minimax.minimax-m2": "minimax", "bedrock/us.meta.llama3-3-70b-instruct-v1:0": "meta",
        "meta.llama3-1-70b-instruct-v1:0": "meta", "us.anthropic.claude-sonnet-4-20250514-v1:0": "anthropic",
        "global.anthropic.claude-sonnet-4-5-20250929-v1:0": "anthropic",
        "cohere.command-r-plus-v1:0": "cohere", "mistral.mistral-large-2407-v1:0": "mistral",
        "ai21.jamba-1-5-large-v1:0": "ai21", "openai.gpt-oss-120b-1:0": "openai",
        "writer.palmyra-x5-v1:0": "writer", "us.amazon.nova-pro-v1:0": "amazon", "amazon.titan-text-express-v1": "amazon",
        // Ollama "family:tag".
        "mistral:7b": "mistral", "mixtral:8x7b": "mistral", "codestral:22b": "mistral",
        "qwq:32b": "qwen", "solar:10.7b": "upstage", "llama3.2:3b": "meta", "qwen2.5-coder:7b": "qwen",
        "deepseek-r1:14b": "deepseek", "phi3:mini": "microsoft", "granite3.1-dense:8b": "ibm",
        // Smaller families.
        "Cohere-command-r-plus": "cohere", "aya-expanse:32b": "cohere", "c4ai-aya-expanse-32b": "cohere",
        "openrouter/microsoft/wizardlm-2-8x22b": "microsoft", "codeqwen:7b": "qwen", "codeqwen1.5": "qwen",
        "codellama:7b": "meta", "qvq-max": "qwen", "alibaba/qvq-72b-preview": "qwen",
        "bytedance/ui-tars-1.5-7b": "bytedance", "llama3.1-nemotron": "nvidia",
        // Hosts of others' models don't claim them.
        "alibaba/deepseek-v3": "deepseek", "tencent/deepseek-v3": "deepseek", "baidu/deepseek-r1": "deepseek",
    ]
    for (model, author) in examples { #expect(Providers.providerOf(model) == author, "\(model)") }
    // Dotted versions are not vendors.
    for (model, author) in ["qwen2.5-72b": "qwen", "gpt-4.1": "openai", "glm-4.5-air": "zai",
                            "claude-3.5-sonnet": "anthropic", "gemini-2.5-pro": "google"] {
        #expect(Providers.providerOf(model) == author, "\(model)")
    }
    for model in ["unknown.thing-v1", ":7b", "notavendor.llama-3"] {
        #expect(Providers.providerOf(model) == nil, "\(model)")
    }
}

