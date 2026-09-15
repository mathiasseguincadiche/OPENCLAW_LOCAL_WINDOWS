import json
from pathlib import Path
from typing import Any

import pytest
import yaml

from clawlocal.openclaw_config import build_openclaw_patch

EXPECTED_AGENTS = {
    "chef-operations",
    "expert-recherche",
    "architecte-solutions",
    "ingenieur-devops",
    "ingenieur-securite",
    "ingenieur-release-forges",
    "redacteur-technique",
    "auditeur-qualite",
}

MINISTRAL = "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M"
EXPECTED_MODELS = {
    "qwen3.5:9b-q4_K_M",
    "gemma4:12b-it-q4_K_M",
    MINISTRAL,
}
EXPECTED_DIRECT_OLLAMA_MODELS = {
    "qwen3.5:9b-q4_K_M",
    "gemma4:12b-it-q4_K_M",
}
EXPECTED_VULKAN_MODELS = {
    "gemma4:12b-it-q4_K_M",
    MINISTRAL,
}
OPENCLAW_AGENT_CONTEXT_TOKENS = 16384
BENCHMARK_NOMINAL_CONTEXT_TOKENS = 8192

PINNED_OPENCLAW_VERSION = "2026.9.4"
PINNED_OPENCLAW_INTEGRITY = (
    "sha512-lTQpEEe1Xm3u2PCHaPEr+vP8paGk1vLdHuzdItsNToaLI6hAqRVvgJYg+GxukJhETJp4t"
    "Py/S1Gftl4KuB8n7A=="
)
PINNED_OPENCLAW_RELEASE_SHA = "3a9d69db306cd7f081e06254cb89c4bcc14a7107"
PINNED_MODEL_KEYS = {
    "id",
    "name",
    "api",
    "baseUrl",
    "reasoning",
    "input",
    "cost",
    "contextWindow",
    "contextTokens",
    "maxTokens",
    "thinkingLevelMap",
    "params",
    "agentRuntime",
    "headers",
    "compat",
    "mediaInput",
    "metadataSource",
}


def _entries_by_id(patch: dict[str, Any]) -> dict[str, dict[str, Any]]:
    entries = patch["agents"]["list"]
    return {str(entry["id"]): entry for entry in entries}


def test_patch_materializes_all_agents_without_cloud_fallback() -> None:
    patch = build_openclaw_patch(Path("E:/AI/OpenClawLocal"))
    entries = _entries_by_id(patch)
    assert set(entries) == EXPECTED_AGENTS
    assert patch["gateway"] == {"mode": "local", "bind": "loopback"}
    agents = patch["agents"]
    assert agents["ownership"] == "explicit"
    defaults = agents["defaults"]
    assert defaults["systemAgent"] == {"agentId": "chef-operations"}
    assert defaults["sessionStore"] == {"agentId": "chef-operations"}
    assert defaults["skipBootstrap"] is True
    assert defaults["skipOptionalBootstrapFiles"] == [
        "SOUL.md",
        "USER.md",
        "HEARTBEAT.md",
        "IDENTITY.md",
    ]
    assert defaults["bootstrapMaxChars"] == 6500
    assert defaults["bootstrapTotalMaxChars"] == 8000
    assert "compaction" not in defaults
    assert defaults["pdfMaxMb"] == 50
    assert defaults["pdfMaxPages"] == 20
    assert all("default" not in entry for entry in agents["list"])
    for agent_id, entry in entries.items():
        assert entry["workspace"].replace("\\", "/").endswith(
            f"workspaces/{agent_id}"
        )
        primary_provider = entry["model"]["primary"].split("/", 1)[0]
        assert primary_provider in {"ollama", "ollama-ministral"}
        assert all(
            model.startswith("ollama/")
            for model in entry["model"]["fallbacks"]
        )
        assert "openrouter/" not in str(entry["model"])
        assert entry["experimental"] == {"localModelLean": True}
        assert entry["tools"]["profile"] == "minimal"
        assert entry["tools"]["fs"]["workspaceOnly"] is True
        assert entry["tools"]["exec"]["mode"] == "ask"
        assert entry["tools"]["elevated"]["enabled"] is False


def test_tool_surface_is_role_bounded_and_search_compacted() -> None:
    patch = build_openclaw_patch(Path("C:/OpenClawLocal"))
    entries = _entries_by_id(patch)
    assert patch["tools"]["profile"] == "minimal"
    assert patch["tools"]["toolSearch"] == {
        "enabled": True,
        "mode": "tools",
        "searchDefaultLimit": 5,
        "maxSearchLimit": 10,
    }

    chef = set(entries["chef-operations"]["tools"]["alsoAllow"])
    assert {"read", "sessions_spawn", "sessions_send", "agents_list"} <= chef
    assert not {"write", "edit", "apply_patch", "exec", "process"} & chef

    devops = set(entries["ingenieur-devops"]["tools"]["alsoAllow"])
    assert {"read", "write", "edit", "apply_patch", "exec", "process"} <= devops
    assert {"web_search", "web_fetch", "pdf", "view_image"} <= devops


def test_research_agent_gets_browser_and_local_web_is_configured() -> None:
    patch = build_openclaw_patch(Path("C:/OpenClawLocal"))
    research_tools = _entries_by_id(patch)["expert-recherche"]["tools"]
    assert "browser" in research_tools["alsoAllow"]
    web = patch["tools"]["web"]
    assert web["search"]["enabled"] is True
    assert web["search"]["provider"] == "parallel-free"
    assert web["fetch"]["enabled"] is True


def test_read_only_roles_cannot_mutate_or_exec() -> None:
    entries = _entries_by_id(build_openclaw_patch(Path("C:/OpenClawLocal")))
    review_roles = (
        "chef-operations",
        "expert-recherche",
        "architecte-solutions",
        "auditeur-qualite",
    )
    for agent_id in review_roles:
        denied = set(entries[agent_id]["tools"]["deny"])
        assert {"write", "edit", "apply_patch", "exec", "process"} <= denied


def test_direct_benchmark_context_stays_8k_while_openclaw_agents_get_16k() -> None:
    catalog = yaml.safe_load(
        Path("config/v1/model_catalog.yaml").read_text(encoding="utf-8")
    )
    policy = catalog["policy"]
    assert policy["nominal_context_tokens"] == BENCHMARK_NOMINAL_CONTEXT_TOKENS
    assert policy["openclaw_agent_context_tokens"] == OPENCLAW_AGENT_CONTEXT_TOKENS
    assert policy["openclaw_agent_context_is_benchmark_promotion"] is False
    for model in catalog["models"].values():
        assert model["nominal_context_tokens"] == BENCHMARK_NOMINAL_CONTEXT_TOKENS
        assert OPENCLAW_AGENT_CONTEXT_TOKENS in model["qualification_context_tokens"]


def test_nominal_ollama_models_are_split_across_direct_and_compat_providers() -> None:
    patch = build_openclaw_patch(Path("C:/OpenClawLocal"))
    providers = patch["models"]["providers"]
    assert set(providers) == {"ollama", "ollama-ministral"}

    direct = providers["ollama"]
    compat = providers["ollama-ministral"]
    assert direct["api"] == "ollama"
    assert direct["baseUrl"] == "http://127.0.0.1:11434"
    assert compat["api"] == "ollama"
    assert compat["baseUrl"] == "http://127.0.0.1:11436"
    assert direct["apiKey"] == "ollama-local"
    assert compat["apiKey"] == "ollama-local"

    direct_by_id = {model["id"]: model for model in direct["models"]}
    compat_by_id = {model["id"]: model for model in compat["models"]}
    assert set(direct_by_id) == EXPECTED_DIRECT_OLLAMA_MODELS
    assert set(compat_by_id) == {MINISTRAL}
    assert set(direct_by_id) | set(compat_by_id) == EXPECTED_MODELS
    assert direct_by_id["qwen3.5:9b-q4_K_M"]["input"] == ["text", "image"]
    assert direct_by_id["gemma4:12b-it-q4_K_M"]["input"] == ["text", "image"]
    assert compat_by_id[MINISTRAL]["input"] == ["text"]

    all_models = [*direct["models"], *compat["models"]]
    assert all(
        model["contextWindow"] == OPENCLAW_AGENT_CONTEXT_TOKENS
        for model in all_models
    )
    assert all(
        model["contextTokens"] == OPENCLAW_AGENT_CONTEXT_TOKENS
        for model in all_models
    )
    assert all(
        model["params"]["num_ctx"] == OPENCLAW_AGENT_CONTEXT_TOKENS
        for model in all_models
    )
    assert all("metadata" not in model for model in all_models)

    devops = _entries_by_id(patch)["ingenieur-devops"]["model"]
    assert devops == {
        "primary": f"ollama-ministral/{MINISTRAL}",
        "fallbacks": ["ollama/qwen3.5:9b-q4_K_M"],
    }


def test_multimodal_defaults_use_qwen35_then_gemma4() -> None:
    defaults = build_openclaw_patch(Path("C:/OpenClawLocal"))["agents"]["defaults"]
    expected = {
        "primary": "ollama/qwen3.5:9b-q4_K_M",
        "fallbacks": ["ollama/gemma4:12b-it-q4_K_M"],
    }
    assert defaults["model"] == expected
    assert defaults["imageModel"] == expected
    assert defaults["pdfModel"] == expected


def test_b580_hybrid_routes_each_model_to_vulkan_backend() -> None:
    patch = build_openclaw_patch(Path("C:/OpenClawLocal"), backend_id="b580-hybrid")
    providers = patch["models"]["providers"]
    assert set(providers) == {"ollama", "intel-vulkan"}
    vulkan = providers["intel-vulkan"]
    assert vulkan["baseUrl"] == "http://127.0.0.1:8081/v1"
    assert vulkan["api"] == "openai-completions"
    assert vulkan["apiKey"] == "intel-vulkan-local"
    assert {model["id"] for model in vulkan["models"]} == EXPECTED_VULKAN_MODELS
    assert all(model["contextWindow"] == 8192 for model in vulkan["models"])

    entries = _entries_by_id(patch)
    assert entries["chef-operations"]["model"] == {
        "primary": "ollama/qwen3.5:9b-q4_K_M",
        "fallbacks": ["intel-vulkan/gemma4:12b-it-q4_K_M"],
    }
    assert entries["architecte-solutions"]["model"] == {
        "primary": "intel-vulkan/gemma4:12b-it-q4_K_M",
        "fallbacks": ["ollama/qwen3.5:9b-q4_K_M"],
    }
    assert entries["ingenieur-devops"]["model"] == {
        "primary": f"intel-vulkan/{MINISTRAL}",
        "fallbacks": ["ollama/qwen3.5:9b-q4_K_M"],
    }
    defaults = patch["agents"]["defaults"]
    assert defaults["model"] == {
        "primary": "ollama/qwen3.5:9b-q4_K_M",
        "fallbacks": ["intel-vulkan/gemma4:12b-it-q4_K_M"],
    }
    expected_multimodal = {
        "primary": "ollama/qwen3.5:9b-q4_K_M",
        "fallbacks": ["ollama/gemma4:12b-it-q4_K_M"],
    }
    assert defaults["imageModel"] == expected_multimodal
    assert defaults["pdfModel"] == expected_multimodal
    assert "openrouter/" not in str(patch["agents"])


def test_unknown_backend_is_fail_closed() -> None:
    with pytest.raises(ValueError, match="Backend OpenClaw invalide"):
        build_openclaw_patch(Path("C:/OpenClawLocal"), backend_id="unknown")


def test_patch_matches_pinned_openclaw_schema_surface() -> None:
    runtime_lock = json.loads(
        Path("config/v1/runtime_versions.json").read_text(encoding="utf-8")
    )
    assert runtime_lock["openclaw"]["preferred"] == PINNED_OPENCLAW_VERSION
    assert runtime_lock["openclaw"]["integrity"] == PINNED_OPENCLAW_INTEGRITY
    assert runtime_lock["openclaw"]["release_sha"] == PINNED_OPENCLAW_RELEASE_SHA
    assert runtime_lock["openclaw"]["plugins"]["parallel"]["preferred"] == "2026.9.4"

    patch = build_openclaw_patch(Path("C:/OpenClawLocal"))
    agents = patch["agents"]
    assert set(agents) == {"ownership", "defaults", "list"}
    assert agents["ownership"] == "explicit"
    assert "entries" not in agents
    assert isinstance(agents["list"], list)
    assert len(agents["list"]) == 8
    assert len({entry["id"] for entry in agents["list"]}) == 8
    assert all("default" not in entry for entry in agents["list"])
    assert agents["defaults"]["systemAgent"] == {"agentId": "chef-operations"}
    assert agents["defaults"]["sessionStore"] == {"agentId": "chef-operations"}

    for provider in patch["models"]["providers"].values():
        for model in provider["models"]:
            assert set(model) <= PINNED_MODEL_KEYS
            assert "metadata" not in model
