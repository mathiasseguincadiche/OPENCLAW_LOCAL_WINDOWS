from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml

from clawlocal.routing import select_route
from clawlocal.runtime import model_ref

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config" / "v1"

EXPECTED_MODELS = {
    "qwen-max": "qwen3.5:9b-q4_K_M",
    "gemma-deep": "gemma4:12b-it-q4_K_M",
    "devstral-devops": "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M",
}
EXPECTED_VULKAN_RUNTIME_IDS = {
    "qwen-max": "qwen3.5:9b-q4_K_M",
    "gemma-deep": "gemma4:Q4_K_M",
    "devstral-devops": "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M",
}
EXPECTED_CHALLENGERS = {
    "granite-devops": "granite4.2:8b-q4_K_M",
}
EXPECTED_PRIMARY = {
    "chef-operations": "qwen-max",
    "expert-recherche": "qwen-max",
    "architecte-solutions": "gemma-deep",
    "ingenieur-devops": "devstral-devops",
    "ingenieur-securite": "qwen-max",
    "ingenieur-release-forges": "qwen-max",
    "redacteur-technique": "gemma-deep",
    "auditeur-qualite": "gemma-deep",
}

RETIRED_ACTIVE_RUNTIME_IDS = (
    "gemma3:12b-it-q4_K_M",
    "qwen2.5-coder:14b-instruct-q4_K_M",
    "ministral-3:14b-instruct-2512-q4_K_M",
    "qwen3.8:27b",
    "gemma4:26b",
    "devstral-small-2:24b",
    "qwen3.5:27b",
    "sera-14b",
)

ACTIVE_MODEL_TEXT_FILES = (
    "README.md",
    "STATUS.md",
    "docs/ARCHITECTURE.md",
    "docs/BENCHMARK.md",
    "docs/INSTALLATION_WINDOWS_11.md",
    "docs/INTEL_ARC_B580.md",
    "docs/MODELES_LOCAUX.md",
    "docs/OPENCLAW_INTEGRATION.md",
    "docs/OPERATIONS.md",
    "docs/PREMIERS_PAS_OPENCLAW_LOCAL.md",
    "docs/QUALIFICATION.md",
    "docs/README.md",
    "docs/ROUTAGE_HYBRIDE.md",
    "docs/RUNTIME_BACKENDS.md",
    "docs/TELEMETRY.md",
    "docs/TROUBLESHOOTING.md",
    "config/openclaw.local.example.json5",
    "config/v1/hardware_profiles/intel_arc_b580_12gb.yaml",
    "config/v1/model_catalog.yaml",
    "config/v1/model_routing.yaml",
    "config/v1/qualification_policy.yaml",
    "config/v1/runtime_backends.yaml",
    "config/v1/runtime_versions.json",
    "src/clawlocal/openclaw_config.py",
    "src/clawlocal/routing.py",
    "src/clawlocal/runtime.py",
    "menu.ps1",
    "scripts/windows/03_pull_models.ps1",
    "scripts/windows/04_verify_local.ps1",
    "scripts/windows/08_configure_openclaw.ps1",
    "scripts/windows/10_test_openclaw_e2e.ps1",
    "scripts/windows/18_setup_intel_vulkan.ps1",
    "scripts/windows/lib/intel_b580.ps1",
    "scripts/windows/lib/intel_vulkan.ps1",
    "scripts/windows/23_compare_model_challenger.ps1",
)


def load_yaml(name: str) -> dict[str, Any]:
    with (CONFIG / name).open(encoding="utf-8") as handle:
        value = yaml.safe_load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{name}: racine YAML invalide")
    return value


def load_json(name: str) -> dict[str, Any]:
    with (CONFIG / name).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{name}: racine JSON invalide")
    return value


def read_required(path: str, failures: list[str]) -> str:
    target = ROOT / path
    if not target.is_file():
        failures.append(f"fichier actif attendu absent: {path}")
        return ""
    return target.read_text(encoding="utf-8")


def validate_catalog(catalog: dict[str, Any], failures: list[str]) -> None:
    policy = catalog.get("policy", {})
    if policy.get("local_first") is not True or policy.get("local_only") is not True:
        failures.append("model_catalog: Architecture V2 doit être local-first et local-only")
    if policy.get("cloud_models_supported") is not False:
        failures.append("model_catalog: les modèles cloud doivent être explicitement non supportés")
    if "cloud_catalog" in catalog:
        failures.append("model_catalog: cloud_catalog est interdit en Architecture V2")
    if policy.get("local_model_count") != 3:
        failures.append("model_catalog: exactement trois modèles locaux routés")
    if policy.get("target_hardware_profile") != "intel_arc_b580_12gb":
        failures.append("model_catalog: profil matériel B580 12GB requis")
    if policy.get("gpu_llm_acceleration") != "vulkan":
        failures.append("model_catalog: Vulkan doit être l'unique accélération GPU LLM")
    if policy.get("nominal_context_tokens") != 8192:
        failures.append("model_catalog: contexte benchmark nominal 8192 attendu")
    if policy.get("openclaw_agent_context_tokens") != 16384:
        failures.append("model_catalog: contexte OpenClaw orchestration 16384 attendu")

    models = catalog.get("models", {})
    if not isinstance(models, dict) or set(models) != set(EXPECTED_MODELS):
        failures.append(
            "catalogue routé: exactement qwen-max, gemma-deep et devstral-devops requis"
        )
        return

    for alias, runtime_id in EXPECTED_MODELS.items():
        model = models.get(alias)
        if not isinstance(model, dict):
            failures.append(f"modèle V2 absent: {alias}")
            continue
        if model.get("runtime_id") != runtime_id:
            failures.append(
                f"{alias}: runtime_id={model.get('runtime_id')} attendu={runtime_id}"
            )
        if "sycl_runtime_id" in model:
            failures.append(f"{alias}: alias runtime SYCL interdit")
        expected_vulkan = EXPECTED_VULKAN_RUNTIME_IDS[alias]
        if model.get("vulkan_runtime_id") != expected_vulkan:
            failures.append(
                f"{alias}: vulkan_runtime_id={model.get('vulkan_runtime_id')} "
                f"attendu={expected_vulkan}"
            )
        if model.get("provider") != "ollama":
            failures.append(f"{alias}: provider Ollama local attendu")
        if model.get("required") is not True or model.get("routing_active") is not True:
            failures.append(f"{alias}: doit être requis et routable")
        if model.get("quantization") != "Q4_K_M":
            failures.append(f"{alias}: Q4_K_M requis")
        if model.get("nominal_context_tokens") != 8192:
            failures.append(f"{alias}: contexte nominal 8192 attendu")
        if float(model.get("registry_size_gb", 99)) > 9.5:
            failures.append(f"{alias}: poids registre trop élevé pour la flotte B580")

    gemma = models.get("gemma-deep", {})
    if isinstance(gemma, dict):
        if gemma.get("family") != "gemma4":
            failures.append("gemma-deep: Gemma 4 attendu")
        if gemma.get("input") != ["text", "image"]:
            failures.append("gemma-deep: texte + image requis")

    specialist = models.get("devstral-devops", {})
    if isinstance(specialist, dict):
        if specialist.get("family") != "mistral3-reasoning":
            failures.append("devstral-devops: Ministral 3 Reasoning attendu")
        if specialist.get("compatibility_alias") is not True:
            failures.append("devstral-devops: alias de compatibilité explicite requis")
        if specialist.get("input") != ["text"]:
            failures.append("devstral-devops: contrat nominal text-only attendu")
        if specialist.get("source_kind") != "huggingface_gguf":
            failures.append("devstral-devops: source GGUF officielle attendue")
        if specialist.get("multimodal_handoff") != ["qwen-max", "gemma-deep"]:
            failures.append("devstral-devops: handoff multimodal Qwen/Gemma requis")


def validate_vulkan_runtime_lock(
    runtime_versions: dict[str, Any],
    catalog: dict[str, Any],
    failures: list[str],
) -> None:
    lock = runtime_versions.get("llama_cpp_vulkan")
    if not isinstance(lock, dict):
        failures.append("runtime_versions: contrat llama_cpp_vulkan absent")
        return

    expected_sources = [
        EXPECTED_MODELS["gemma-deep"],
        EXPECTED_MODELS["devstral-devops"],
    ]
    expected_router = [
        EXPECTED_VULKAN_RUNTIME_IDS["gemma-deep"],
        EXPECTED_VULKAN_RUNTIME_IDS["devstral-devops"],
    ]
    source_models = [str(value) for value in lock.get("managed_source_models", [])]
    managed_models = [str(value) for value in lock.get("managed_models", [])]
    runtime_models = [str(value) for value in lock.get("managed_runtime_models", [])]

    if source_models != expected_sources:
        failures.append(
            "runtime_versions: managed_source_models doit conserver les IDs Ollama/GGUF"
        )
    if managed_models != expected_router:
        failures.append(
            "runtime_versions: managed_models doit utiliser les IDs canoniques du routeur llama.cpp"
        )
    if runtime_models != expected_router:
        failures.append(
            "runtime_versions: managed_runtime_models doit suivre les IDs canoniques du routeur"
        )
    if managed_models != runtime_models:
        failures.append("runtime_versions: managed_models/runtime_models divergent")

    models = catalog.get("models", {})
    catalog_router = [
        str(models.get("gemma-deep", {}).get("vulkan_runtime_id", "")),
        str(models.get("devstral-devops", {}).get("vulkan_runtime_id", "")),
    ]
    if catalog_router != expected_router:
        failures.append(
            "model_catalog/runtime_versions: IDs Vulkan routeur incohérents"
        )


def validate_challenger(catalog: dict[str, Any], failures: list[str]) -> None:
    challengers = catalog.get("benchmark_challengers", {})
    if not isinstance(challengers, dict) or set(challengers) != set(EXPECTED_CHALLENGERS):
        failures.append("model_catalog: Granite 4.2 8B doit être l'unique challenger")
        return
    challenger = challengers.get("granite-devops")
    if not isinstance(challenger, dict):
        failures.append("model_catalog: challenger Granite invalide")
        return
    expected_runtime = EXPECTED_CHALLENGERS["granite-devops"]
    expected = {
        "runtime_id": expected_runtime,
        "provider": "ollama",
        "family": "granite4.2",
        "quantization": "Q4_K_M",
        "registry_size_gb": 5.3,
        "nominal_context_tokens": 8192,
        "required_for_selection": True,
        "routing_active": False,
        "incumbent_alias": "devstral-devops",
        "automatic_promotion": False,
    }
    for key, value in expected.items():
        if challenger.get(key) != value:
            failures.append(f"Granite challenger: {key}={value!r} requis")
    scope = set(challenger.get("challenge_scope", []))
    if not {"coding", "native_tool_calling", "tool_feedback_repair", "b580_fit"} <= scope:
        failures.append("Granite challenger: périmètre DevOps/tool-calling incomplet")


def validate_routing(routing: dict[str, Any], failures: list[str]) -> None:
    if routing.get("local_only") is not True:
        failures.append("model_routing: local_only=true requis")
    if "cloud_enabled_by_default" in routing:
        failures.append("model_routing: cloud_enabled_by_default doit être supprimé")
    order = routing.get("routing_order", [])
    if "cloud_escalation" in order:
        failures.append("model_routing: cloud_escalation interdite dans routing_order")

    agents = routing.get("agents", {})
    allowed = set(EXPECTED_MODELS)
    for agent, expected in EXPECTED_PRIMARY.items():
        route = agents.get(agent, {})
        if not isinstance(route, dict):
            failures.append(f"{agent}: route absente")
            continue
        if route.get("local_primary") != expected:
            failures.append(f"{agent}: local_primary doit être {expected}")
        if "cloud_escalation" in route:
            failures.append(f"{agent}: route cloud interdite en Architecture V2")
        for field in (
            "local_primary",
            "local_fallback",
            "local_specialist",
            "local_deep",
            "local_max",
            "independent_alternative",
        ):
            alias = route.get(field)
            if alias is not None and alias not in allowed:
                failures.append(f"{agent}: {field} référence un modèle non supporté: {alias}")


def validate_qualification(qualification: dict[str, Any], failures: list[str]) -> None:
    allowed = set(EXPECTED_MODELS)
    automated = qualification.get("automated_gates", {})
    if set(automated.get("required_models", [])) != allowed:
        failures.append("qualification: les trois modèles V2 doivent être requis")

    fleet = qualification.get("supported_fleet", {})
    if set(fleet.get("exact_aliases", [])) != allowed:
        failures.append("qualification: supported_fleet doit contenir trois alias")
    if fleet.get("allow_optional_local_models") is not False:
        failures.append("qualification: aucun quatrième modèle routé optionnel")
    if fleet.get("benchmark_challengers_count_as_routed_models") is not False:
        failures.append("qualification: challenger ne compte pas comme modèle routé")

    runtime_policy = qualification.get("runtime_backend_policy", {})
    if runtime_policy.get("gpu_llm_acceleration") != "vulkan":
        failures.append("qualification: accélération GPU LLM Vulkan requise")
    if runtime_policy.get("backend_choice_locked") is not True:
        failures.append("qualification: le choix de backend Vulkan doit être verrouillé")
    if set(runtime_policy.get("allowed_backends", [])) != {
        "ollama-vulkan",
        "llama-cpp-vulkan",
        "b580-hybrid",
    }:
        failures.append("qualification: seuls les backends Vulkan actifs sont autorisés")
    if set(runtime_policy.get("openclaw_selectable_profiles", [])) != {
        "ollama-vulkan",
        "b580-hybrid",
    }:
        failures.append("qualification: profils OpenClaw Vulkan inattendus")
    if runtime_policy.get("backend_recomparison_required") is not False:
        failures.append("qualification: la comparaison de backends retirée ne doit pas revenir")
    if runtime_policy.get("real_b580_runtime_evidence_required") is not True:
        failures.append("qualification: preuves runtime B580 réelles requises")

    safety = qualification.get("safety", {})
    if safety.get("cloud_calls_allowed_during_qualification") is not False:
        failures.append("qualification: aucun appel LLM cloud")
    if safety.get("cloud_models_supported") is not False or safety.get("local_only") is not True:
        failures.append("qualification: contrat local-only requis")

    challenge = qualification.get("model_selection_challenger", {})
    expected = {
        "required_before_manual_model_selection": True,
        "incumbent_alias": "devstral-devops",
        "challenger_alias": "granite-devops",
        "challenger_runtime_id": "granite4.2:8b-q4_K_M",
        "context_tokens": 8192,
        "repetitions": 3,
        "protocol": "native_tool_calling_v1",
        "automatic_promotion": False,
        "human_decision_required": True,
        "evidence_required": True,
    }
    for key, value in expected.items():
        if challenge.get(key) != value:
            failures.append(f"qualification challenger: {key}={value!r} requis")
    capabilities = set(challenge.get("required_capabilities", []))
    if capabilities != {"native_tool_calling", "tool_feedback_repair", "coding"}:
        failures.append("qualification challenger: capacités Granite incomplètes")


def validate_runtime_routes(failures: list[str]) -> None:
    for agent, alias in EXPECTED_PRIMARY.items():
        decision = select_route(agent, qualified_models=set())
        if decision.model_alias != alias:
            failures.append(f"{agent}: route nominale {alias} attendue")

    independent = select_route(
        "auditeur-qualite",
        producer_model_alias="gemma-deep",
        qualified_models=set(),
    )
    if independent.model_alias != "qwen-max" or independent.route_kind != "local_independent":
        failures.append("Auditeur: production Gemma doit être revue par Qwen")

    for alias, runtime_id in EXPECTED_MODELS.items():
        if model_ref(alias) != f"ollama/{runtime_id}":
            failures.append(f"{alias}: résolution runtime incohérente")

    try:
        select_route("chef-operations", request_cloud=True)
    except PermissionError:
        pass
    else:
        failures.append("Architecture V2: une demande cloud doit échouer fermement")


def validate_active_surfaces(failures: list[str]) -> None:
    retired_backend_marker = "sy" + "cl"
    for relative in ACTIVE_MODEL_TEXT_FILES:
        text = read_required(relative, failures)
        folded = text.casefold()
        for runtime_id in RETIRED_ACTIVE_RUNTIME_IDS:
            if runtime_id.casefold() in folded:
                failures.append(f"{relative}: runtime retiré encore actif: {runtime_id}")
        if retired_backend_marker in folded:
            failures.append(
                f"{relative}: backend GPU retiré encore présent dans une surface active"
            )


def main() -> int:
    failures: list[str] = []
    catalog = load_yaml("model_catalog.yaml")
    routing = load_yaml("model_routing.yaml")
    qualification = load_yaml("qualification_policy.yaml")
    runtime_versions = load_json("runtime_versions.json")

    validate_catalog(catalog, failures)
    validate_vulkan_runtime_lock(runtime_versions, catalog, failures)
    validate_challenger(catalog, failures)
    validate_routing(routing, failures)
    validate_qualification(qualification, failures)
    validate_runtime_routes(failures)
    validate_active_surfaces(failures)

    if failures:
        for failure in failures:
            print(f"KO  {failure}")
        print(f"Verdict: KO ({len(failures)} anomalie(s))")
        return 2

    print("OK  Architecture V2 local-only")
    print("OK  flotte routée: Qwen3.5 9B + Gemma 4 12B + Ministral 3 14B Reasoning")
    print("OK  IDs llama.cpp/Vulkan canoniques alignés avec les sources GGUF")
    print("OK  accélération GPU LLM: Vulkan uniquement")
    print("OK  challenger local: Granite 4.2 8B")
    print("OK  aucun catalogue ni routage de modèle cloud")
    print("Verdict: CONFORME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
