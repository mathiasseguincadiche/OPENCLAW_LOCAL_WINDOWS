from __future__ import annotations

from pathlib import Path
from typing import Any

from clawlocal.config import load_contract

SUPPORTED_BACKENDS = ("ollama-vulkan", "b580-hybrid")
OLLAMA_PROVIDER_ID = "ollama"
OLLAMA_COMPAT_PROVIDER_ID = "ollama-ministral"
INTEL_VULKAN_PROVIDER_ID = "intel-vulkan"
SYSTEM_AGENT_ID = "chef-operations"
OPTIONAL_BOOTSTRAP_FILES = ["SOUL.md", "USER.md", "HEARTBEAT.md", "IDENTITY.md"]


def _runtime_id(model: dict[str, Any], backend_id: str) -> str:
    if backend_id == "ollama-vulkan":
        return str(model["runtime_id"])
    if backend_id == "llama-cpp-vulkan":
        runtime_id = model.get("vulkan_runtime_id")
        if not runtime_id:
            raise ValueError("vulkan_runtime_id absent pour un modèle local requis")
        return str(runtime_id)
    raise ValueError(f"Backend local non supporté pour OpenClaw: {backend_id}")


def _resolved_model_backend(
    alias: str,
    backends: dict[str, Any],
    backend_id: str,
) -> str:
    if backend_id != "b580-hybrid":
        return backend_id
    profile = backends["backends"]["b580-hybrid"]
    model_backends = profile.get("model_backends", {})
    resolved = model_backends.get(alias)
    if not resolved:
        raise ValueError(f"Backend hybride absent pour le modèle: {alias}")
    return str(resolved)


def _ollama_compat_config(backends: dict[str, Any]) -> dict[str, Any]:
    ollama_backend = backends["backends"]["ollama-vulkan"]
    compat = ollama_backend.get("openclaw_compat")
    if not isinstance(compat, dict):
        raise ValueError("Contrat openclaw_compat absent pour ollama-vulkan")
    provider_id = str(compat.get("provider_id", ""))
    endpoint = str(compat.get("endpoint", ""))
    upstream = str(compat.get("upstream", ""))
    aliases = {str(alias) for alias in compat.get("normalize_aliases", [])}
    if provider_id != OLLAMA_COMPAT_PROVIDER_ID:
        raise ValueError(f"Provider compat Ollama inattendu: {provider_id}")
    if not endpoint.startswith("http://127.0.0.1:"):
        raise ValueError(f"Endpoint compat Ollama non loopback: {endpoint}")
    if upstream != str(ollama_backend["endpoint"]):
        raise ValueError("Le proxy compat Ollama doit pointer vers l endpoint Ollama nominal")
    if not aliases:
        raise ValueError("Aucun alias n est déclaré pour la compatibilité Ollama")
    return {
        "provider_id": provider_id,
        "endpoint": endpoint,
        "upstream": upstream,
        "aliases": aliases,
    }


def _ollama_provider_id_for_alias(
    alias: str,
    backends: dict[str, Any],
    backend_id: str,
) -> str:
    if backend_id != "ollama-vulkan":
        return OLLAMA_PROVIDER_ID
    compat = _ollama_compat_config(backends)
    if alias in compat["aliases"]:
        return str(compat["provider_id"])
    return OLLAMA_PROVIDER_ID


def _backend_ref(
    alias: str,
    catalog: dict[str, Any],
    backends: dict[str, Any],
    backend_id: str,
) -> str:
    model = catalog["models"][alias]
    resolved_backend = _resolved_model_backend(alias, backends, backend_id)
    if resolved_backend == "ollama-vulkan":
        provider_id = _ollama_provider_id_for_alias(alias, backends, backend_id)
        return f"{provider_id}/{_runtime_id(model, resolved_backend)}"
    if resolved_backend == "llama-cpp-vulkan":
        return f"{INTEL_VULKAN_PROVIDER_ID}/{_runtime_id(model, resolved_backend)}"
    raise ValueError(f"Backend modèle non supporté: {resolved_backend}")


def _agent_tools(
    agent_id: str,
    policy: dict[str, Any],
) -> dict[str, Any]:
    entry = policy["agents"][agent_id]
    tools: dict[str, Any] = {
        "profile": entry["profile"],
        "fs": {
            "workspaceOnly": bool(
                policy["security_defaults"]["fs_workspace_only"]
            )
        },
        "exec": {"mode": policy["security_defaults"]["exec_mode"]},
        "elevated": {
            "enabled": bool(
                policy["security_defaults"]["elevated_enabled"]
            )
        },
    }
    if entry.get("also_allow"):
        tools["alsoAllow"] = list(entry["also_allow"])
    if entry.get("deny"):
        tools["deny"] = list(entry["deny"])
    return tools


def _openclaw_agent_context_tokens(
    catalog: dict[str, Any],
    model: dict[str, Any],
) -> int:
    policy = catalog.get("policy", {})
    nominal = int(model.get("nominal_context_tokens", 8192))
    context_tokens = int(
        model.get(
            "openclaw_agent_context_tokens",
            policy.get("openclaw_agent_context_tokens", nominal),
        )
    )
    if context_tokens < nominal:
        raise ValueError(
            "Le contexte d'orchestration OpenClaw ne peut pas être inférieur au contexte nominal"
        )
    declared = {int(value) for value in model.get("qualification_context_tokens", [])}
    if context_tokens != nominal and context_tokens not in declared:
        raise ValueError(
            "Le contexte d'orchestration OpenClaw doit être un contexte de qualification déclaré"
        )
    return context_tokens


def _ollama_models(
    catalog: dict[str, Any],
    aliases: set[str] | None = None,
) -> list[dict[str, Any]]:
    models: list[dict[str, Any]] = []
    for alias, model in catalog["models"].items():
        if model["provider"] != "ollama":
            continue
        if aliases is not None and alias not in aliases:
            continue
        context_tokens = _openclaw_agent_context_tokens(catalog, model)
        models.append(
            {
                "id": model["runtime_id"],
                "name": model["runtime_id"],
                "input": list(model.get("input", ["text"])),
                "contextWindow": context_tokens,
                "contextTokens": context_tokens,
                "params": {
                    "num_ctx": context_tokens,
                    "keep_alive": "15m",
                },
            }
        )
    return models


def _ollama_provider(
    catalog: dict[str, Any],
    base_url: str = "http://127.0.0.1:11434",
    aliases: set[str] | None = None,
) -> dict[str, Any]:
    return {
        "baseUrl": base_url,
        "apiKey": "ollama-local",
        "api": "ollama",
        "timeoutSeconds": 300,
        "models": _ollama_models(catalog, aliases=aliases),
    }


def _llamacpp_models(
    catalog: dict[str, Any],
    context_tokens: int,
    backend_id: str,
    aliases: set[str] | None = None,
) -> list[dict[str, Any]]:
    models: list[dict[str, Any]] = []
    for alias, model in catalog["models"].items():
        if not model.get("required"):
            continue
        if aliases is not None and alias not in aliases:
            continue
        runtime_id = _runtime_id(model, backend_id)
        models.append(
            {
                "id": runtime_id,
                "name": runtime_id,
                "input": ["text"],
                "contextWindow": context_tokens,
                "contextTokens": context_tokens,
                "maxTokens": 2048,
                "cost": {
                    "input": 0,
                    "output": 0,
                    "cacheRead": 0,
                    "cacheWrite": 0,
                },
                "compat": {
                    "supportsTools": True,
                    "toolSchemaProfile": "llamacpp",
                },
            }
        )
    return models


def _llamacpp_provider(
    catalog: dict[str, Any],
    backend: dict[str, Any],
    backend_id: str,
    provider_id: str,
    api_key: str,
    aliases: set[str] | None = None,
) -> dict[str, Any]:
    context_tokens = int(backend["router"]["context_tokens"])
    return {
        "baseUrl": str(backend["endpoint"]),
        "apiKey": api_key,
        "api": "openai-completions",
        "timeoutSeconds": 300,
        "models": _llamacpp_models(
            catalog,
            context_tokens,
            backend_id,
            aliases=aliases,
        ),
    }


def _model_providers(
    catalog: dict[str, Any],
    backends: dict[str, Any],
    backend_id: str,
) -> dict[str, Any]:
    configured = backends["backends"]
    if backend_id == "ollama-vulkan":
        compat = _ollama_compat_config(backends)
        compat_aliases = set(compat["aliases"])
        direct_aliases = set(catalog["models"]) - compat_aliases
        return {
            OLLAMA_PROVIDER_ID: _ollama_provider(
                catalog,
                base_url=str(configured["ollama-vulkan"]["endpoint"]),
                aliases=direct_aliases,
            ),
            str(compat["provider_id"]): _ollama_provider(
                catalog,
                base_url=str(compat["endpoint"]),
                aliases=compat_aliases,
            ),
        }

    providers: dict[str, Any] = {
        OLLAMA_PROVIDER_ID: _ollama_provider(
            catalog,
            base_url=str(configured["ollama-vulkan"]["endpoint"]),
        )
    }
    if backend_id == "b580-hybrid":
        profile = configured["b580-hybrid"]
        vulkan_aliases = {
            str(alias)
            for alias, selected in profile["model_backends"].items()
            if str(selected) == "llama-cpp-vulkan"
        }
        providers[INTEL_VULKAN_PROVIDER_ID] = _llamacpp_provider(
            catalog,
            configured["llama-cpp-vulkan"],
            "llama-cpp-vulkan",
            INTEL_VULKAN_PROVIDER_ID,
            "intel-vulkan-local",
            aliases=vulkan_aliases,
        )
        return providers
    raise ValueError(f"Backend OpenClaw non supporté: {backend_id}")


def build_openclaw_patch(
    platform_root: Path,
    backend_id: str = "ollama-vulkan",
) -> dict[str, Any]:
    """Build the deterministic OpenClaw patch for one explicit local Vulkan profile."""
    if backend_id not in SUPPORTED_BACKENDS:
        raise ValueError(
            f"Backend OpenClaw invalide: {backend_id}; "
            f"attendus: {', '.join(SUPPORTED_BACKENDS)}"
        )

    catalog = load_contract("model_catalog.yaml")
    routing = load_contract("model_routing.yaml")
    tool_policy = load_contract("tool_policy.yaml")
    web_policy = load_contract("web_policy.yaml")
    ingestion_policy = load_contract("document_ingestion_policy.yaml")
    backends = load_contract("runtime_backends.yaml")

    configured_backends = backends.get("backends", {})
    if backend_id not in configured_backends:
        raise ValueError(f"Backend absent de runtime_backends.yaml: {backend_id}")

    workspaces_root = platform_root / "workspaces"
    agent_list: list[dict[str, Any]] = []
    for agent_id, route in routing["agents"].items():
        primary = _backend_ref(route["local_primary"], catalog, backends, backend_id)
        fallbacks: list[str] = []
        fallback_alias = route.get("local_fallback")
        if fallback_alias:
            fallbacks.append(_backend_ref(fallback_alias, catalog, backends, backend_id))
        agent_list.append(
            {
                "id": agent_id,
                "name": agent_id,
                "workspace": str(workspaces_root / agent_id),
                "model": {
                    "primary": primary,
                    "fallbacks": fallbacks,
                },
                "experimental": {"localModelLean": True},
                "tools": _agent_tools(agent_id, tool_policy),
            }
        )

    qwen = str(catalog["models"]["qwen-max"]["runtime_id"])
    gemma = str(catalog["models"]["gemma-deep"]["runtime_id"])
    qwen_text_ref = _backend_ref("qwen-max", catalog, backends, backend_id)
    gemma_text_ref = _backend_ref("gemma-deep", catalog, backends, backend_id)
    qwen_multimodal_ref = f"ollama/{qwen}"
    gemma_multimodal_ref = f"ollama/{gemma}"

    web = web_policy["nominal_path"]
    pdf_policy = ingestion_policy.get("formats", {}).get("pdf", {})
    return {
        "gateway": {
            "mode": "local",
            "bind": "loopback",
        },
        "models": {
            "providers": _model_providers(catalog, backends, backend_id),
        },
        "agents": {
            "ownership": "explicit",
            "defaults": {
                "systemAgent": {"agentId": SYSTEM_AGENT_ID},
                "sessionStore": {"agentId": SYSTEM_AGENT_ID},
                "skipBootstrap": True,
                "skipOptionalBootstrapFiles": OPTIONAL_BOOTSTRAP_FILES,
                "bootstrapMaxChars": 6500,
                "bootstrapTotalMaxChars": 8000,
                "model": {
                    "primary": qwen_text_ref,
                    "fallbacks": [gemma_text_ref],
                },
                "imageModel": {
                    "primary": qwen_multimodal_ref,
                    "fallbacks": [gemma_multimodal_ref],
                },
                "pdfModel": {
                    "primary": qwen_multimodal_ref,
                    "fallbacks": [gemma_multimodal_ref],
                },
                "pdfMaxMb": int(pdf_policy.get("max_bytes_mb", 50)),
                "pdfMaxPages": int(pdf_policy.get("max_pages_per_tool_call", 20)),
            },
            "list": agent_list,
        },
        "tools": {
            "profile": tool_policy["security_defaults"]["profile"],
            "toolSearch": {
                "enabled": True,
                "mode": "tools",
                "searchDefaultLimit": 5,
                "maxSearchLimit": 10,
            },
            "fs": {
                "workspaceOnly": bool(
                    tool_policy["security_defaults"]["fs_workspace_only"]
                )
            },
            "exec": {
                "mode": tool_policy["security_defaults"]["exec_mode"],
                "applyPatch": {"workspaceOnly": True},
            },
            "elevated": {
                "enabled": bool(
                    tool_policy["security_defaults"]["elevated_enabled"]
                )
            },
            "web": {
                "search": {
                    "enabled": bool(web["web_search_enabled"]),
                    "provider": web["search_provider"],
                    "maxResults": int(web["max_results"]),
                    "timeoutSeconds": int(web["search_timeout_seconds"]),
                    "cacheTtlMinutes": int(web["cache_ttl_minutes"]),
                },
                "fetch": {
                    "enabled": bool(web["web_fetch_enabled"]),
                    "maxChars": 20000,
                    "maxCharsCap": 20000,
                    "timeoutSeconds": 30,
                },
            },
        },
    }
