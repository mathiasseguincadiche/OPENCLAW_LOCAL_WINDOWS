from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config" / "v1"


def load(name: str) -> dict[str, Any]:
    payload = yaml.safe_load((CONFIG / name).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{name}: racine YAML invalide")
    return payload


def main() -> int:
    failures: list[str] = []
    schema = load("project_schema_policy.yaml")
    intake = load("intake_policy.yaml")
    pedagogy = load("pedagogy_policy.yaml")
    accessibility = load("accessibility_policy.yaml")
    publication = load("publication_policy.yaml")
    telemetry = load("telemetry_policy.yaml")
    security = load("security.yaml")
    matrix = load("v7_superset_matrix.yaml")

    if schema.get("project_manifest_schema") != "2.0.0":
        failures.append("project manifest schema 2.0.0 requis")
    if schema.get("strict_unknown_fields") is not True:
        failures.append("project manifest doit refuser les champs inconnus")
    if set(schema.get("classifications", [])) != {
        "public", "internal", "confidential", "restricted"
    }:
        failures.append("classifications projet V7 incomplètes")
    if set(schema.get("criticalities", [])) != {"low", "standard", "high", "critical"}:
        failures.append("criticités projet V7 incomplètes")

    llm_cloud = schema.get("llm_cloud_policy", {})
    if llm_cloud.get("allowed") is not False:
        failures.append("Architecture V2: le LLM cloud doit être interdit globalement")
    if llm_cloud.get("fallback_allowed") is not False:
        failures.append("Architecture V2: aucun fallback LLM cloud n'est autorisé")
    if llm_cloud.get("providers") != []:
        failures.append("Architecture V2: aucun fournisseur LLM cloud ne doit être déclaré")

    restricted = schema.get("external_service_policy", {}).get("restricted", {})
    if restricted.get("allowed") is not False:
        failures.append("classification restricted doit interdire les services externes")
    confidential = schema.get("external_service_policy", {}).get("confidential", {})
    if confidential.get("redaction_required") is not True:
        failures.append("classification confidential doit exiger redaction")
    if confidential.get("human_approval_required") is not True:
        failures.append("classification confidential doit exiger approbation humaine")

    high_gates = set(schema.get("criticality_gates", {}).get("high", []))
    if not {
        "security_review_required",
        "independent_audit_required",
        "rollback_required_when_relevant",
        "human_final_approval_required",
    } <= high_gates:
        failures.append("criticité high: gates exécutables incomplets")
    critical_gates = set(schema.get("criticality_gates", {}).get("critical", []))
    if not {
        "second_independent_review_required",
        "external_service_requires_human_approval",
    } <= critical_gates:
        failures.append("criticité critical: seconde revue/service externe approval absents")

    intake_security = intake.get("security", {})
    for key in (
        "scan_project_sources_before_copy",
        "stream_text_secret_scan_without_size_skip",
        "block_secret_filenames",
    ):
        if intake_security.get(key) is not True:
            failures.append(f"intake source hardening absent: {key}")
    integrity = intake.get("integrity", {})
    for key in (
        "source_inventory_required",
        "project_phase_snapshots_required",
        "aggregate_digest_required",
    ):
        if integrity.get(key) is not True:
            failures.append(f"intégrité projet absente: {key}")

    verdicts = set(pedagogy.get("learning_verdicts", []))
    if verdicts != {"ACQUIS", "ACQUIS_AVEC_RESERVES", "A_RENFORCER", "NON_EVALUE"}:
        failures.append("verdicts pédagogiques V7 incomplets")
    if pedagogy.get("help_ladder") != [
        "short_question", "hint", "targeted_correction", "full_solution_with_justification"
    ]:
        failures.append("échelle d'aide pédagogique V7 incomplète")
    if len(pedagogy.get("competence_evidence", [])) < 6:
        failures.append("critères de preuve d'autonomie incomplets")

    responsibilities = accessibility.get("role_responsibilities", {})
    expected_roles = {
        "chef-operations",
        "expert-recherche",
        "architecte-solutions",
        "ingenieur-devops",
        "ingenieur-securite",
        "ingenieur-release-forges",
        "redacteur-technique",
        "auditeur-qualite",
    }
    if set(responsibilities) != expected_roles:
        failures.append("responsabilités accessibilité des 8 rôles incomplètes")
    if len(accessibility.get("audit_checklist", [])) < 10:
        failures.append("checklist d'audit documentaire incomplète")

    protected_actions = set(publication.get("human_approval_actions", []))
    v7_actions = {
        "create_remote_repository",
        "change_visibility",
        "make_public",
        "merge_pull_or_merge_request",
        "create_or_publish_release",
        "change_branch_protection",
        "force_push_or_history_rewrite",
        "delete_remote_repository_or_tag",
    }
    if not v7_actions <= protected_actions:
        failures.append("publication: action-gates V7 incomplets")
    if publication.get("action_gates_are_independent_from_state_gates") is not True:
        failures.append("publication: state gates et action gates doivent être indépendants")

    if telemetry.get("automatic_capture_for_orchestrator_calls") is not True:
        failures.append("télémétrie orchestrateur automatique requise")
    if security.get("runtime_redaction", {}).get("enabled") is not True:
        failures.append("runtime redaction V7 requise")
    if security.get("support_bundle", {}).get("second_pass_secret_scan_required") is not True:
        failures.append("support bundle second-pass requis")
    supply_chain = security.get("supply_chain", {})
    for key in (
        "bounded_dependency_versions",
        "lockfile_required_before_release_when_ecosystem_supports_it",
        "prefer_official_images",
        "sbom_in_ci",
        "secret_scan_in_ci",
        "vulnerability_scan_or_dependency_review_in_ci",
    ):
        if supply_chain.get(key) is not True:
            failures.append(f"supply-chain guard absent: {key}")

    allowed_statuses = set(matrix.get("allowed_statuses", []))
    if allowed_statuses != {"PRESERVED", "IMPROVED", "REPLACED"}:
        failures.append("superset matrix: statuts invalides")
    capabilities = matrix.get("capabilities", {})
    if not isinstance(capabilities, dict) or len(capabilities) < 20:
        failures.append("superset matrix: baseline V7 insuffisamment couverte")
    else:
        for capability, entry in capabilities.items():
            if not isinstance(entry, dict):
                failures.append(f"superset matrix: {capability} invalide")
                continue
            if entry.get("status") not in allowed_statuses:
                failures.append(f"superset matrix: {capability} sans verdict valide")
            evidence = ROOT / str(entry.get("evidence", ""))
            if not evidence.exists():
                failures.append(f"superset matrix: preuve absente pour {capability}")

    required_files = (
        "src/clawlocal/project_contracts.py",
        "src/clawlocal/project_integrity.py",
        "src/clawlocal/project_migrations.py",
        "src/clawlocal/project_governance.py",
        "src/clawlocal/project_security.py",
        "src/clawlocal/project_orchestrator_superset.py",
        "scripts/37_project_migrate.py",
        "scripts/38_project_integrity.py",
        "scripts/41_project_gates.py",
        "docs/V7_FULL_PARITY_SUPERSET.md",
    )
    for relative in required_files:
        if not (ROOT / relative).exists():
            failures.append(f"fichier superset requis absent: {relative}")

    orchestrator_script = (ROOT / "scripts/32_orchestrate_project.py").read_text(encoding="utf-8")
    for marker in (
        "project_orchestrator_superset",
        "ensure_current_project_schema",
        "automatic_run_telemetry",
    ):
        if marker not in orchestrator_script:
            failures.append(f"orchestrateur non branché au superset: {marker}")
    publication_script = (ROOT / "scripts/33_project_publication.py").read_text(encoding="utf-8")
    if "assert_sensitive_action" not in publication_script:
        failures.append("publication CLI non branchée aux action gates")

    governance_source = (ROOT / "src/clawlocal/project_governance.py").read_text(encoding="utf-8")
    for marker in (
        "record_criticality_gate",
        "assert_transition_criticality_gates",
        "second_independent_review_required",
        "external_service_policy_for_project",
    ):
        if marker not in governance_source:
            failures.append(f"gates de criticité non exécutables: {marker}")
    facade_source = (ROOT / "src/clawlocal/project_orchestrator_superset.py").read_text(
        encoding="utf-8"
    )
    if "assert_transition_criticality_gates" not in facade_source:
        failures.append("orchestrateur superset ne bloque pas sur les gates de criticité")
    contract_source = (ROOT / "src/clawlocal/project_contracts.py").read_text(encoding="utf-8")
    if "producer et reviewer doivent être distincts" not in contract_source:
        failures.append("Task Contract: séparation producer/reviewer non exécutable")
    migration_source = (ROOT / "src/clawlocal/project_migrations.py").read_text(encoding="utf-8")
    for marker in ("_restore_backup", '"ROLLED_BACK"'):
        if marker not in migration_source:
            failures.append(f"migration transactionnelle absente: {marker}")

    if failures:
        for failure in failures:
            print(f"KO  {failure}")
        print(f"\nVerdict: KO ({len(failures)} anomalie(s))")
        return 2
    print("OK  V7 Full Parity / Superset Gate")
    print(f"OK  {len(capabilities)} capacités V7 classées PRESERVED/IMPROVED/REPLACED")
    print("OK  manifeste strict + classification/criticité + migrations transactionnelles")
    print("OK  gates high/critical exécutables + séparation producer/reviewer")
    print("OK  services externes gouvernés + LLM cloud interdit globalement")
    print("OK  Intake/sources + intégrité multi-phase")
    print("OK  pédagogie/accessibilité/publication/télémétrie/sécurité")
    print("Verdict: CONFORME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
