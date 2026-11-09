// Ported from tests/test_providers.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

@Test func providerNames() {
    #expect(Providers.providers.map { [$0.key, $0.name] } == [
        ["openai", "OpenAI"], ["deepseek", "DeepSeek"], ["kimi", "Kimi"],
        ["google", "Google"], ["anthropic", "Anthropic"], ["xai", "xAI"],
        ["mistral", "Mistral"], ["qwen", "Qwen"], ["zai", "Z.ai (GLM)"], ["minimax", "MiniMax"],
    ])
}

@Test func moreProvidersModels() {
    let cases = [
        "gemini-4-argon": "google", "gemini-2.5-pro": "google", "google/gemma-3-27b": "google",
        "claude-opus-5-5": "anthropic", "anthropic/claude-sonnet-4": "anthropic",
        "grok-code-fast": "xai", "x-ai/grok-4": "xai",
        "mistral-large-latest": "mistral", "codestral-2508": "mistral", "devstral-medium": "mistral",
        "mistralai/mixtral-8x7b": "mistral", "magistral-medium": "mistral",
        "qwen3-coder": "qwen", "qwen/qwen3-235b": "qwen", "qwq-32b": "qwen",
        "glm-4.6": "zai", "z-ai/glm-4.5-air": "zai", "zhipuai/glm-4": "zai",
        "minimax-m2": "minimax", "MiniMax-M1": "minimax", "minimax/minimax-m2": "minimax",
    ]
    for (model, provider) in cases {
        #expect(Providers.providerOf(model) == provider, "\(model)")
    }
}

@Test func namesThatOnlyLookAlikeStayUnmatched() {
    for model in ["olmo-2", "big-pickle", "llama-4-scout", "phi-4", "unknown"] {
        #expect(Providers.providerOf(model) == nil, "\(model)")
    }
}

@Test func openaiModels() {
    for model in ["gpt-5", "gpt-5.1-codex", "gpt-oss-120b", "o3", "o4-mini", "o1",
                  "codex-mini-latest", "chatgpt-4o-latest", "openai/gpt-5", "GPT-5"] {
        #expect(Providers.providerOf(model) == "openai", "\(model)")
    }
}

@Test func deepseekAndKimiModels() {
    #expect(Providers.providerOf("deepseek-chat") == "deepseek")
    #expect(Providers.providerOf("deepseek/deepseek-r1") == "deepseek")
    #expect(Providers.providerOf("deepseek-v3.2-exp") == "deepseek")
    #expect(Providers.providerOf("kimi-k2-0905-preview") == "kimi")
    #expect(Providers.providerOf("moonshotai/kimi-k2") == "kimi")
    #expect(Providers.providerOf("moonshot-v1-8k") == "kimi")
}

@Test func otherModelsBelongToNone() {
    for model in ["unknown", "olmo-2", ""] {
        #expect(Providers.providerOf(model) == nil, "\(model)")
    }
}

@Test func vendorPrefixDecidesUnrecognisedNames() {
    #expect(Providers.providerOf("openai/some-new-model") == "openai")
    #expect(Providers.providerOf("moonshotai/k3") == "kimi")
}

private func state() -> JSONObject {
    var claude = JSONObject(), opencode = JSONObject(), codex = JSONObject()
    UsageStats.addUsage(&claude, day: Day(2026, 11, 8), model: "claude-opus-5-5", project: "~/a", parts: ["input": 100])
    UsageStats.addUsage(&claude, day: Day(2026, 11, 8), model: "deepseek-chat", project: "~/a", parts: ["input": 7])
    UsageStats.addUsage(&opencode, day: Day(2026, 11, 8), model: "kimi-k2", project: "~/b", parts: ["input": 5],
                        cost: 0.01)
    UsageStats.addUsage(&opencode, day: Day(2026, 11, 8), model: "gpt-5", project: "~/b", parts: ["input": 3],
                        cost: 0.02)
    UsageStats.addUsage(&codex, day: Day(2026, 11, 7), model: "gpt-5-codex", project: "~/c", parts: ["output": 11])
    return [
        "grand_total": 107, "daily": claude,
        "sources": [
            "opencode": ["daily": opencode],
            "codex": ["files": ["f": ["size": 1, "mtime": 1, "daily": codex] as JSONObject]],
        ] as JSONObject,
    ]
}

@Test func providerViewCollectsItsModelsFromEveryTool() {
    let view = Providers.providerView(state(), "openai")

    #expect(view.key == "openai")
    #expect(view.name == "OpenAI")
    #expect(view.grandTotal == 14)
    #expect(Set((dig(view.daily, "2026-11-08", "models") as? JSONObject ?? [:]).keys) == ["gpt-5"])
    #expect(jsonEqual(dig(view.daily, "2026-11-07", "projects"), ["~/c": 11]))
    #expect(view.error == nil)
}

@Test func providerViewKeepsEachToolsCostsApart() {
    let view = Providers.providerView(state(), "kimi")

    #expect(view.grandTotal == 5)
    let costs = (view.views ?? []).map { dig($0.daily, "2026-11-08", "recorded_cost") }
    #expect(jsonEqual(costs, [["kimi-k2": 0.01]]))
}

@Test func providerViewFromClaudeCodeRouting() {
    let view = Providers.providerView(state(), "deepseek")

    #expect(view.grandTotal == 7)
    #expect(jsonEqual(dig(view.daily, "2026-11-08", "projects"), ["~/a": 7]))
}

@Test func providerViewWithNoData() {
    let view = Providers.providerView([:], "kimi")

    #expect(view.daily.isEmpty)
    #expect(view.grandTotal == 0)
}

@Test func toolsToScanAddsEveryDetectedToolWhileAProviderIsOn() {
    let detected = ["claude_code", "codex", "opencode"]

    #expect(Providers.toolsToScan(["enabled_tools": ["claude_code"]], detected: detected) == ["claude_code"])
    #expect(Providers.toolsToScan(["enabled_tools": ["claude_code"], "enabled_providers": ["openai"]],
                                  detected: detected) == ["claude_code", "codex", "opencode"])
    // An enabled tool whose data is gone is still scanned, as before.
    #expect(Providers.toolsToScan(["enabled_tools": ["codex"], "enabled_providers": ["kimi"]],
                                  detected: ["opencode"]) == ["codex", "opencode"])
}
