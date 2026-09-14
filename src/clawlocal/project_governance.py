from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from clawlocal.config import load_contract
from clawlocal.project_contracts import validate_project_manifest

_GATE_RELATIVE = Path("context/governance/criticality_gates.json")
_CONDITIONAL_GATES = {"external_service_requires_human_approval"}
_TRANSITION_GATES: dict[str, set[str]] = {
    "VALIDATING": {"evidence_required"},
    "REVIEW": {"evidence_required", "independent_audit_required"},
    "PACKAGING": {
        "evidence_required",
        "security_review_required",
        "independent_audit_required",
        "second_independent_review_required",
        "rollback_required_when_relevant",
    },
    "COMPLETE": {
        "evidence_required",
        "security_review_required",
        "independent_audit_required",
        "second_independent_review_required",
        "rollback_required_when_relevant",
        "human_final_approval_required",
    },
}


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _load_project_manifest(project: Path) -> dict[str, Any]:
    payload = json.loads((project / "project.json").read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("project.json invalide")
    return validate_project_manifest(payload)


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def initialize_governance(project: Path) -> None:
    root = project / "context" / "governance"
    root.mkdir(parents=True, exist_ok=True)
    decisions = root / "DECISIONS.md"
    risks = root / "RISKS.md"
    gates = project / _GATE_RELATIVE
    if not decisions.exists():
        decisions.write_text("# Journal des décisions\n\n", encoding="utf-8")
    if not risks.exists():
        risks.write_text("# Registre des risques\n\n", encoding="utf-8")
    if not gates.exists():
        _write_json(
            gates,
            {
                "schema_version": "1.0.0",
                "updated_at": _now(),
                "evidence": [],
            },
        )


def append_decision(project: Path, *, decision: str, rationale: str, actor: str) -> None:
    initialize_governance(project)
    path = project / "context" / "governance" / "DECISIONS.md"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(
            f"## {_now()} — {actor}\n\n- Décision : {decision.strip()}\n"
            f"- Justification : {rationale.strip()}\n\n"
        )


def append_risk(
    project: Path,
    *,
    risk: str,
    impact: str = "à évaluer",
    mitigation: str = "à définir",
) -> None:
    initialize_governance(project)
    path = project / "context" / "governance" / "RISKS.md"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(
            f"## {_now()}\n\n- Risque : {risk.strip()}\n- Impact : {impact.strip()}\n"
            f"- Mitigation : {mitigation.strip()}\n\n"
        )


def required_criticality_gates(manifest: dict[str, Any]) -> set[str]:
    validate_project_manifest(manifest)
    policy = load_contract("project_schema_policy.yaml")
    gates = policy.get("criticality_gates", {}).get(manifest["criticality"], [])
    if not isinstance(gates, list):
        raise ValueError("project_schema_policy: criticality_gates invalide")
    return {str(item) for item in gates}


def _known_criticality_gates() -> set[str]:
    policy = load_contract("project_schema_policy.yaml")
    configured = policy.get("criticality_gates", {})
    if not isinstance(configured, dict):
        raise ValueError("project_schema_policy: criticality_gates invalide")
    known: set[str] = set()
    for values in configured.values():
        if not isinstance(values, list):
            raise ValueError("project_schema_policy: liste de gates invalide")
        known.update(str(item) for item in values)
    return known


def load_criticality_gate_evidence(project: Path) -> dict[str, Any]:
    initialize_governance(project)
    payload = json.loads((project / _GATE_RELATIVE).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("criticality_gates.json invalide")
    evidence = payload.get("evidence")
    if not isinstance(evidence, list):
        raise ValueError("criticality_gates.json: evidence doit être une liste")
    if any(not isinstance(item, dict) for item in evidence):
        raise ValueError("criticality_gates.json: entrée de preuve invalide")
    return payload


def _satisfied_gate_entries(project: Path) -> list[dict[str, Any]]:
    payload = load_criticality_gate_evidence(project)
    evidence = payload["evidence"]
    assert isinstance(evidence, list)
    return [
        item
        for item in evidence
        if isinstance(item, dict) and item.get("status") == "SATISFIED"
    ]


def record_criticality_gate(
    project: Path,
    gate: str,
    *,
    actor: str,
    evidence: str,
    human_approved: bool = False,
) -> dict[str, Any]:
    manifest = _load_project_manifest(project)
    required = required_criticality_gates(manifest)
    normalized_gate = gate.strip()
    if normalized_gate not in _known_criticality_gates():
        raise ValueError(f"gate de criticité inconnu: {normalized_gate}")
    if normalized_gate not in required:
        raise ValueError(
            f"gate {normalized_gate} non requis pour criticité {manifest['criticality']}"
        )
    normalized_actor = actor.strip()
    normalized_evidence = evidence.strip()
    if not normalized_actor:
        raise ValueError("gate de criticité: actor vide")
    if not normalized_evidence:
        raise ValueError("gate de criticité: evidence vide")

    existing = _satisfied_gate_entries(project)
    if normalized_gate == "security_review_required" and normalized_actor != "ingenieur-securite":
        raise PermissionError("security_review_required exige ingenieur-securite")
    if normalized_gate == "independent_audit_required" and normalized_actor != "auditeur-qualite":
        raise PermissionError("independent_audit_required exige auditeur-qualite")
    if normalized_gate == "second_independent_review_required":
        first_reviews = [
            item for item in existing if item.get("gate") == "independent_audit_required"
        ]
        if not first_reviews:
            raise PermissionError("seconde revue impossible avant l'audit indépendant")
        first_actor = str(first_reviews[-1].get("actor", ""))
        if normalized_actor == first_actor:
            raise PermissionError("la seconde revue indépendante doit utiliser un autre reviewer")
    if normalized_gate in {
        "human_final_approval_required",
        "external_service_requires_human_approval",
    }:
        if normalized_actor != "human" or not human_approved:
            raise PermissionError(f"{normalized_gate} exige une approbation humaine explicite")

    payload = load_criticality_gate_evidence(project)
    entries = payload["evidence"]
    assert isinstance(entries, list)
    entries.append(
        {
            "gate": normalized_gate,
            "status": "SATISFIED",
            "actor": normalized_actor,
            "evidence": normalized_evidence,
            "human_approved": human_approved,
            "at": _now(),
        }
    )
    payload["updated_at"] = _now()
    _write_json(project / _GATE_RELATIVE, payload)
    return payload


def criticality_gate_status(project: Path, *, target: str | None = None) -> dict[str, Any]:
    manifest = _load_project_manifest(project)
    required = required_criticality_gates(manifest)
    conditional = required & _CONDITIONAL_GATES
    enforced = required - conditional
    if target is not None:
        enforced &= _TRANSITION_GATES.get(target, set())
    satisfied = {str(item.get("gate")) for item in _satisfied_gate_entries(project)}
    return {
        "criticality": manifest["criticality"],
        "target": target,
        "required": sorted(required),
        "conditional": sorted(conditional),
        "enforced": sorted(enforced),
        "satisfied": sorted(satisfied & required),
        "missing": sorted(enforced - satisfied),
    }


def assert_transition_criticality_gates(project: Path, target: str) -> None:
    status = criticality_gate_status(project, target=target)
    missing = status["missing"]
    if missing:
        raise PermissionError(
            f"transition vers {target} bloquée; gates de criticité manquants: "
            + ", ".join(str(item) for item in missing)
        )


def external_service_policy_for_project(
    manifest: dict[str, Any],
    *,
    redacted: bool = False,
    human_approved: bool = False,
) -> dict[str, Any]:
    validate_project_manifest(manifest)
    policy = load_contract("project_schema_policy.yaml")
    classification = str(manifest["classification"])
    entry = policy.get("external_service_policy", {}).get(classification, {})
    allowed = entry.get("allowed") is True
    redaction_required = entry.get("redaction_required") is True
    approval_required = entry.get("human_approval_required") is True
    if manifest["criticality"] in {"high", "critical"}:
        approval_required = True
    effective = allowed and (redacted or not redaction_required) and (
        human_approved or not approval_required
    )
    reason = "allowed" if effective else "project_data_governance_denied"
    return {
        "allowed": effective,
        "classification": classification,
        "criticality": manifest["criticality"],
        "redaction_required": redaction_required,
        "human_approval_required": approval_required,
        "reason": reason,
    }


def cloud_policy_for_project(
    manifest: dict[str, Any],
    *,
    redacted: bool = False,
    human_approved: bool = False,
) -> dict[str, Any]:
    """Compatibility shim: cloud LLM execution is always denied in Architecture V2."""
    del redacted, human_approved
    validate_project_manifest(manifest)
    return {
        "allowed": False,
        "classification": str(manifest["classification"]),
        "criticality": str(manifest["criticality"]),
        "redaction_required": False,
        "human_approval_required": False,
        "reason": "llm_cloud_not_supported",
    }


def assert_sensitive_action(
    manifest: dict[str, Any],
    action: str,
    *,
    human_approved: bool,
) -> None:
    validate_project_manifest(manifest)
    publication = load_contract("publication_policy.yaml")
    protected = {str(item) for item in publication.get("human_approval_actions", [])}
    if action not in protected:
        return
    if not human_approved:
        raise PermissionError(f"approbation humaine requise pour l'action: {action}")
    if action == "make_public" and manifest["classification"] == "restricted":
        raise PermissionError("un projet restricted ne peut pas être rendu public")
