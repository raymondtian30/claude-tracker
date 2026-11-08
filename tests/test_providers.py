from datetime import date

from providers import PROVIDERS, provider_of, provider_view
from usage_stats import add_usage


def test_provider_names():
    assert PROVIDERS == [
        ("openai", "OpenAI"), ("deepseek", "DeepSeek"), ("kimi", "Kimi"),
        ("google", "Google"), ("anthropic", "Anthropic"), ("xai", "xAI"),
        ("mistral", "Mistral"), ("qwen", "Qwen"), ("zai", "Z.ai (GLM)"), ("minimax", "MiniMax"),
    ]


def test_more_providers_models():
    cases = {
        "gemini-4-argon": "google", "gemini-2.5-pro": "google", "google/gemma-3-27b": "google",
        "claude-opus-5-5": "anthropic", "anthropic/claude-sonnet-4": "anthropic",
        "grok-code-fast": "xai", "x-ai/grok-4": "xai",
        "mistral-large-latest": "mistral", "codestral-2508": "mistral", "devstral-medium": "mistral",
        "mistralai/mixtral-8x7b": "mistral", "magistral-medium": "mistral",
        "qwen3-coder": "qwen", "qwen/qwen3-235b": "qwen", "qwq-32b": "qwen",
        "glm-4.6": "zai", "z-ai/glm-4.5-air": "zai", "zhipuai/glm-4": "zai",
        "minimax-m2": "minimax", "MiniMax-M1": "minimax", "minimax/minimax-m2": "minimax",
    }
    for model, provider in cases.items():
        assert provider_of(model) == provider, model


def test_names_that_only_look_alike_stay_unmatched():
    for model in ["olmo-2", "big-pickle", "llama-4-scout", "phi-4", "unknown"]:
        assert provider_of(model) is None, model


def test_openai_models():
    for model in ["gpt-5", "gpt-5.1-codex", "gpt-oss-120b", "o3", "o4-mini", "o1",
                  "codex-mini-latest", "chatgpt-4o-latest", "openai/gpt-5", "GPT-5"]:
        assert provider_of(model) == "openai", model


def test_deepseek_and_kimi_models():
    assert provider_of("deepseek-chat") == "deepseek"
    assert provider_of("deepseek/deepseek-r1") == "deepseek"
    assert provider_of("deepseek-v3.2-exp") == "deepseek"
    assert provider_of("kimi-k2-0905-preview") == "kimi"
    assert provider_of("moonshotai/kimi-k2") == "kimi"
    assert provider_of("moonshot-v1-8k") == "kimi"


def test_other_models_belong_to_none():
    for model in ["unknown", "olmo-2", ""]:
        assert provider_of(model) is None, model


def test_vendor_prefix_decides_unrecognised_names():
    assert provider_of("openai/some-new-model") == "openai"
    assert provider_of("moonshotai/k3") == "kimi"


def _state():
    claude, opencode, codex = {}, {}, {}
    add_usage(claude, date(2026, 11, 8), "claude-opus-5-5", "~/a", {"input": 100})
    add_usage(claude, date(2026, 11, 8), "deepseek-chat", "~/a", {"input": 7})
    add_usage(opencode, date(2026, 11, 8), "kimi-k2", "~/b", {"input": 5}, cost=0.01)
    add_usage(opencode, date(2026, 11, 8), "gpt-5", "~/b", {"input": 3}, cost=0.02)
    add_usage(codex, date(2026, 11, 7), "gpt-5-codex", "~/c", {"output": 11})
    return {
        "grand_total": 107, "daily": claude,
        "sources": {
            "opencode": {"daily": opencode},
            "codex": {"files": {"f": {"size": 1, "mtime": 1, "daily": codex}}},
        },
    }


def test_provider_view_collects_its_models_from_every_tool():
    view = provider_view(_state(), "openai")

    assert view["key"] == "openai"
    assert view["name"] == "OpenAI"
    assert view["grand_total"] == 14
    assert set(view["daily"]["2026-11-08"]["models"]) == {"gpt-5"}
    assert view["daily"]["2026-11-07"]["projects"] == {"~/c": 11}
    assert view["error"] is None


def test_provider_view_keeps_each_tools_costs_apart():
    view = provider_view(_state(), "kimi")

    assert view["grand_total"] == 5
    assert [v["daily"]["2026-11-08"]["recorded_cost"] for v in view["views"]] == [{"kimi-k2": 0.01}]


def test_provider_view_from_claude_code_routing():
    view = provider_view(_state(), "deepseek")

    assert view["grand_total"] == 7
    assert view["daily"]["2026-11-08"]["projects"] == {"~/a": 7}


def test_provider_view_with_no_data():
    view = provider_view({}, "kimi")

    assert view["daily"] == {}
    assert view["grand_total"] == 0


def test_tools_to_scan_adds_every_detected_tool_while_a_provider_is_on():
    from providers import tools_to_scan
    detected = ["claude_code", "codex", "opencode"]

    assert tools_to_scan({"enabled_tools": ["claude_code"]}, detected) == ["claude_code"]
    assert tools_to_scan({"enabled_tools": ["claude_code"], "enabled_providers": ["openai"]},
                         detected) == ["claude_code", "codex", "opencode"]
    # An enabled tool whose data is gone is still scanned, as before.
    assert tools_to_scan({"enabled_tools": ["codex"], "enabled_providers": ["kimi"]},
                         ["opencode"]) == ["codex", "opencode"]
