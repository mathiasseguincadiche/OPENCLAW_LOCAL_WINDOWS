import json
from pathlib import Path

import pytest

import clawlocal.project_migrations as migrations
import clawlocal.project_orchestrator_superset as superset
from clawlocal.project_contracts import normalize_task_contract
from clawlocal.project_governance import (
    criticality_gate_status,
    record_criticality_gate,
)
from clawlocal.project_ingestion import ingest_project_documents
from clawlocal.project_intake import create_project


def _analysis() -> dict[str, object]:
    return {
        "summary": "Projet critique",
        "objectives": ["livrer"],
        "constraints": [],
        "deliverables": ["README"],
        "ambiguities": [],
        "missing_information": [],
        "risks": [],
        "decisions_required": [],
        "source_coverage": [],
    }


def _plan() -> dict[str, object]:
    return {
        "workstreams": ["delivery"],
        "tasks": [
            {
                "id": "task-001",
                "role": "ingenieur-devops",
                "title": "Préparer le livrable",
                "objective": "Produire un livrable vérifiable",
                "depends_on": [],
                "expected_outputs": ["README.md"],
                "acceptance_criteria": ["README présent"],
                "required_evidence": ["evidence/run.json"],
                "producer": "ingenieur-devops",
                "reviewer": "auditeur-qualite",
            }
        ],
    }


def _advance_to_review(project: Path) -> None:
    ingest_project_documents(project)
    superset.store_analysis(project, _analysis())
    superset.store_clarifications_from_analysis(project)
    superset.transition_project(
        project,
        "ANALYZED",
        actor="chef-operations",
        reason="analysis_done",
    )
    superset.store_plan(project, _plan())
    superset.transition_project(
        project,
        "PLANNED",
        actor="chef-operations",
        reason="plan_done",
    )
    superset.create_assignments(project)
    superset.transition_project(
        project,
        "ASSIGNED",
        actor="chef-operations",
        reason="assigned",
    )
    superset.transition_project(
        project,
        "IN_PROGRESS",
        actor="chef-operations",
        reason="execution_started",
    )
    superset.record_task_result(
        project,
        "task-001",
        agent="ingenieur-devops",
        success=True,
        returncode=0,
        evidence_file="evidence/run.json",
        collected_outputs=[],
    )
    superset.transition_project(
        project,
        "VALIDATING",
        actor="chef-operations",
        reason="tasks_passed",
    )
    superset.store_validation_report(
        project,
        {
            "verdict": "PASS",
            "findings": [],
            "task_results_summary": "OK",
            "recommendations": [],
        },
    )
    superset.transition_project(
        project,
        "REVIEW",
        actor="auditeur-qualite",
        reason="validation_passed",
    )
    superset.store_review_report(
        project,
        {
            "verdict": "PASS",
            "coverage": "100%",
            "missing_deliverables": [],
            "blocking_findings": [],
            "recommendations": [],
        },
    )


def test_task_contract_rejects_same_producer_and_reviewer() -> None:
    with pytest.raises(ValueError, match="doivent être distincts"):
        normalize_task_contract(
            {
                "id": "same-reviewer",
                "role": "ingenieur-devops",
                "title": "Tâche",
                "objective": "Tester",
                "producer": "ingenieur-devops",
                "reviewer": "ingenieur-devops",
            }
        )


def test_high_criticality_blocks_packaging_until_security_and_rollback(
    tmp_path: Path,
) -> None:
    project = create_project(
        tmp_path / "platform",
        "high-gates",
        "High Gates",
        criticality="high",
    )
    _advance_to_review(project)
    status = criticality_gate_status(project, target="PACKAGING")
    assert status["missing"] == [
        "rollback_required_when_relevant",
        "security_review_required",
    ]
    with pytest.raises(PermissionError, match="gates de criticité manquants"):
        superset.transition_project(
            project,
            "PACKAGING",
            actor="auditeur-qualite",
            reason="review_passed",
        )

    with pytest.raises(PermissionError, match="ingenieur-securite"):
        record_criticality_gate(
            project,
            "security_review_required",
            actor="ingenieur-devops",
            evidence="security review",
        )
    record_criticality_gate(
        project,
        "security_review_required",
        actor="ingenieur-securite",
        evidence="evidence/security-review.md: PASS",
    )
    record_criticality_gate(
        project,
        "rollback_required_when_relevant",
        actor="ingenieur-devops",
        evidence="docs/rollback.md relu et testable",
    )
    superset.transition_project(
        project,
        "PACKAGING",
        actor="auditeur-qualite",
        reason="criticality_gates_satisfied",
    )
    assert superset.current_status(project) == "PACKAGING"


def test_critical_requires_second_independent_reviewer(tmp_path: Path) -> None:
    project = create_project(
        tmp_path / "platform",
        "critical-gates",
        "Critical Gates",
        criticality="critical",
    )
    _advance_to_review(project)
    record_criticality_gate(
        project,
        "security_review_required",
        actor="ingenieur-securite",
        evidence="security review PASS",
    )
    record_criticality_gate(
        project,
        "rollback_required_when_relevant",
        actor="ingenieur-devops",
        evidence="rollback revu",
    )
    with pytest.raises(PermissionError, match="second_independent_review_required"):
        superset.transition_project(
            project,
            "PACKAGING",
            actor="auditeur-qualite",
            reason="missing_second_review",
        )
    with pytest.raises(PermissionError, match="autre reviewer"):
        record_criticality_gate(
            project,
            "second_independent_review_required",
            actor="auditeur-qualite",
            evidence="seconde revue",
        )
    record_criticality_gate(
        project,
        "second_independent_review_required",
        actor="architecte-solutions",
        evidence="evidence/second-review.md: PASS",
    )
    superset.transition_project(
        project,
        "PACKAGING",
        actor="auditeur-qualite",
        reason="all_critical_gates_satisfied",
    )
    status = criticality_gate_status(project)
    assert status["conditional"] == ["external_service_requires_human_approval"]
    assert "external_service_requires_human_approval" not in status["missing"]


def test_failed_migration_restores_project_and_records_rollback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    project = create_project(
        tmp_path / "platform",
        "migration-rollback",
        "Migration Rollback",
    )
    manifest_path = project / "project.json"
    current = json.loads(manifest_path.read_text(encoding="utf-8"))
    legacy = {
        "schema_version": "1.1.0",
        "project_id": current["project_id"],
        "title": current["title"],
        "created_at": current["created_at"],
        "status": "INTAKE_READY",
        "expected_deliverables": [],
        "source_items": [],
        "intake_items": [],
        "intake_archive": current["intake_archive"],
    }
    manifest_path.write_text(json.dumps(legacy), encoding="utf-8")

    def fail_after_mutation(target: Path) -> None:
        (target / "project.json").write_text("{}", encoding="utf-8")
        raise RuntimeError("simulated migration failure")

    monkeypatch.setattr(migrations, "_migrate_1_1_to_2_0", fail_after_mutation)
    with pytest.raises(RuntimeError, match="simulated migration failure"):
        migrations.apply_project_migrations(project)

    assert json.loads(manifest_path.read_text(encoding="utf-8")) == legacy
    ledger = (project / ".migrations" / "ledger.jsonl").read_text(encoding="utf-8")
    assert '"status": "ROLLED_BACK"' in ledger
