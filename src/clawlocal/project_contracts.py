from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

PROJECT_SCHEMA_VERSION = "2.0.0"
PLATFORM_VERSION = "0.3.0"
CLASSIFICATIONS = {"public", "internal", "confidential", "restricted"}
CRITICALITIES = {"low", "standard", "high", "critical"}
PROJECT_STATUSES = {
    "INTAKE_READY",
    "ANALYZED",
    "CLARIFICATION_REQUIRED",
    "PLANNED",
    "ASSIGNED",
    "IN_PROGRESS",
    "VALIDATING",
    "REVIEW",
    "PACKAGING",
    "COMPLETE",
}

ACCEPTANCE_DEFAULTS = {
    "evidence_required": True,
    "rollback_when_relevant": True,
    "independent_audit_required": True,
    "documentation_required": True,
    "remote_ci_required_for_publication": True,
    "clean_clone_required_for_publication": True,
}

HUMAN_APPROVAL_ACTIONS = [
    "privileged_command",
    "destructive_action",
    "network_exposure",
    "firewall_change",
    "storage_change",
    "production_change",
    "disable_pedagogy",
    "disable_accessibility",
    "residual_risk_acceptance",
    "create_remote_repository",
    "change_repository_visibility",
    "make_public",
    "merge_pull_or_merge_request",
    "create_or_publish_release",
    "change_branch_protection",
    "force_push_or_history_rewrite",
    "delete_remote_repository_or_tag",
    "public_release",
]

_MANIFEST_FIELDS = {
    "schema_version",
    "platform_version",
    "project_id",
    "title",
    "owner",
    "classification",
    "criticality",
    "created_at",
    "updated_at",
    "status",
    "expected_deliverables",
    "source_items",
    "intake_items",
    "intake_archive",
    "acceptance",
    "human_approval_required",
    "governance",
    "orchestration",
}

_TASK_FIELDS = {
    "id",
    "role",
    "title",
    "objective",
    "depends_on",
    "expected_outputs",
    "acceptance_criteria",
    "scope_in",
    "scope_out",
    "facts",
    "assumptions",
    "unknowns",
    "required_evidence",
    "requirement_ids",
    "producer",
    "reviewer",
    "human_decisions",
}
_TASK_LIST_FIELDS = {
    "depends_on",
    "expected_outputs",
    "acceptance_criteria",
    "scope_in",
    "scope_out",
    "facts",
    "assumptions",
    "unknowns",
    "required_evidence",
    "requirement_ids",
    "human_decisions",
}


def _now() -> str:
    return datetime.now(UTC).isoformat()


def build_project_manifest(
    *,
    project_id: str,
    title: str,
    created_at: str,
    expected_deliverables: list[str],
    source_items: list[str],
    intake_items: list[str],
    intake_archive: str,
    owner: str = "dirigeant-operateur",
    classification: str = "internal",
    criticality: str = "standard",
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schema_version": PROJECT_SCHEMA_VERSION,
        "platform_version": PLATFORM_VERSION,
        "project_id": project_id,
        "title": title,
        "owner": owner,
        "classification": classification,
        "criticality": criticality,
        "created_at": created_at,
        "updated_at": created_at,
        "status": "INTAKE_READY",
        "expected_deliverables": expected_deliverables,
        "source_items": source_items,
        "intake_items": intake_items,
        "intake_archive": intake_archive,
        "acceptance": dict(ACCEPTANCE_DEFAULTS),
        "human_approval_required": list(HUMAN_APPROVAL_ACTIONS),
        "governance": {
            "schema_version": "1.0.0",
            "classification_policy": "config/v1/project_schema_policy.yaml",
            "criticality_policy": "config/v1/project_schema_policy.yaml",
        },
    }
    return validate_project_manifest(payload)


def _require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"project.json: {key} doit être une chaîne non vide")
    return value


def _require_string_list(payload: dict[str, Any], key: str) -> list[str]:
    value = payload.get(key)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValueError(f"project.json: {key} doit être une liste de chaînes")
    return value


def validate_project_manifest(payload: dict[str, Any]) -> dict[str, Any]:
    unknown = sorted(set(payload) - _MANIFEST_FIELDS)
    if unknown:
        raise ValueError("project.json: champs inconnus: " + ", ".join(unknown))
    required = _MANIFEST_FIELDS - {"orchestration"}
    missing = sorted(required - set(payload))
    if missing:
        raise ValueError("project.json: champs requis absents: " + ", ".join(missing))
    if payload.get("schema_version") != PROJECT_SCHEMA_VERSION:
        raise ValueError("project.json: schema_version non courant")
    if payload.get("platform_version") != PLATFORM_VERSION:
        raise ValueError("project.json: platform_version incompatible")
    for key in ("project_id", "title", "owner", "created_at", "updated_at", "intake_archive"):
        _require_string(payload, key)
    classification = _require_string(payload, "classification")
    criticality = _require_string(payload, "criticality")
    status = _require_string(payload, "status")
    if classification not in CLASSIFICATIONS:
        raise ValueError(f"project.json: classification invalide: {classification}")
    if criticality not in CRITICALITIES:
        raise ValueError(f"project.json: criticality invalide: {criticality}")
    if status not in PROJECT_STATUSES:
        raise ValueError(f"project.json: status invalide: {status}")
    for key in ("expected_deliverables", "source_items", "intake_items", "human_approval_required"):
        _require_string_list(payload, key)
    acceptance = payload.get("acceptance")
    if not isinstance(acceptance, dict):
        raise ValueError("project.json: acceptance doit être un objet")
    for key, expected in ACCEPTANCE_DEFAULTS.items():
        if acceptance.get(key) is not expected:
            raise ValueError(f"project.json: acceptance.{key} doit rester true")
    approvals = set(payload["human_approval_required"])
    if not set(HUMAN_APPROVAL_ACTIONS) <= approvals:
        raise ValueError("project.json: human_approval_required incomplet")
    governance = payload.get("governance")
    if not isinstance(governance, dict):
        raise ValueError("project.json: governance doit être un objet")
    orchestration = payload.get("orchestration")
    if orchestration is not None and not isinstance(orchestration, dict):
        raise ValueError("project.json: orchestration doit être un objet")
    return payload


def normalize_task_contract(task: dict[str, Any]) -> dict[str, Any]:
    unknown = sorted(set(task) - _TASK_FIELDS)
    if unknown:
        raise ValueError("task contract: champs inconnus: " + ", ".join(unknown))
    normalized = dict(task)
    for field in _TASK_LIST_FIELDS:
        normalized.setdefault(field, [])
    normalized.setdefault("producer", normalized.get("role"))
    normalized.setdefault("reviewer", None)
    return validate_task_contract(normalized)


def validate_task_contract(task: dict[str, Any]) -> dict[str, Any]:
    required = {"id", "role", "title", "objective"}
    missing = sorted(required - set(task))
    if missing:
        raise ValueError("task contract: champs requis absents: " + ", ".join(missing))
    for field in ("id", "role", "title", "objective"):
        value = task.get(field)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"task contract: {field} doit être une chaîne non vide")
    for field in _TASK_LIST_FIELDS:
        value = task.get(field)
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            raise ValueError(f"task contract: {field} doit être une liste de chaînes")
    for field in ("producer", "reviewer"):
        value = task.get(field)
        if value is not None and (not isinstance(value, str) or not value.strip()):
            raise ValueError(f"task contract: {field} doit être une chaîne non vide ou null")
    producer = task.get("producer")
    reviewer = task.get("reviewer")
    if isinstance(producer, str) and isinstance(reviewer, str):
        if producer.strip() == reviewer.strip():
            raise ValueError("task contract: producer et reviewer doivent être distincts")
    return task


def normalize_plan_payload(payload: dict[str, Any]) -> dict[str, Any]:
    workstreams = payload.get("workstreams", [])
    tasks = payload.get("tasks", [])
    if not isinstance(workstreams, list):
        raise ValueError("plan: workstreams doit être une liste")
    if not isinstance(tasks, list) or any(not isinstance(task, dict) for task in tasks):
        raise ValueError("plan: tasks doit être une liste d'objets")
    return {**payload, "tasks": [normalize_task_contract(task) for task in tasks]}
