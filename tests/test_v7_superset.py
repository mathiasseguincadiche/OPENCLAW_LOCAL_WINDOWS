import json
import zipfile
from pathlib import Path

import pytest

import clawlocal.project_orchestrator_superset as superset
from clawlocal.project_contracts import (
    build_project_manifest,
    normalize_task_contract,
    validate_project_manifest,
)
from clawlocal.project_governance import (
    assert_sensitive_action,
    cloud_policy_for_project,
    external_service_policy_for_project,
    required_criticality_gates,
)
from clawlocal.project_intake import create_project
from clawlocal.project_integrity import (
    latest_integrity_snapshot,
    snapshot_integrity,
    verify_integrity_snapshot,
)
from clawlocal.project_learning import (
    add_learning_objective,
    record_learning_evidence,
    set_learning_verdict,
)
from clawlocal.project_migrations import apply_project_migrations, plan_project_migration
from clawlocal.project_security import build_support_bundle, redact_text
from clawlocal.telemetry import (
    automatic_run_telemetry,
    extract_observed_metrics,
    read_telemetry,
)


def test_manifest_is_strict_and_governed() -> None:
    manifest = build_project_manifest(
        project_id="strict-demo",
        title="Strict Demo",
        created_at="2026-08-27T00:00:00+00:00",
        expected_deliverables=["README"],
        source_items=[],
        intake_items=[],
        intake_archive="state/intake/strict-demo/1",
        classification="confidential",
        criticality="high",
    )
    assert manifest["schema_version"] == "2.0.0"
    assert manifest["classification"] == "confidential"
    assert "security_review_required" in required_criticality_gates(manifest)
    broken = dict(manifest)
    broken["unexpected"] = True
    with pytest.raises(ValueError, match="champs inconnus"):
        validate_project_manifest(broken)


def test_task_contract_restores_v7_context_fields() -> None:
    task = normalize_task_contract(
        {
            "id": "terraform-plan",
            "role": "ingenieur-devops",
            "title": "Terraform plan",
            "objective": "Valider le plan",
        }
    )
    for field in (
        "scope_in",
        "scope_out",
        "facts",
        "assumptions",
        "unknowns",
        "required_evidence",
        "human_decisions",
    ):
        assert task[field] == []
    assert task["producer"] == "ingenieur-devops"
    with pytest.raises(ValueError):
        normalize_task_contract({**task, "random": "forbidden"})


def test_sources_are_secret_scanned_and_inventoried(tmp_path: Path) -> None:
    source = tmp_path / "repo"
    source.mkdir()
    (source / "README.md").write_text("safe", encoding="utf-8")
    project = create_project(
        tmp_path / "platform",
        "source-safe",
        "Source Safe",
        source_items=[source],
    )
    assert (project / "evidence" / "sources" / "checksums.sha256").is_file()
    unsafe = tmp_path / "unsafe"
    unsafe.mkdir()
    (unsafe / ".env").write_text("TOKEN=value", encoding="utf-8")
    with pytest.raises(ValueError, match="sources"):
        create_project(
            tmp_path / "platform",
            "source-unsafe",
            "Source Unsafe",
            source_items=[unsafe],
        )


def test_integrity_snapshot_detects_mutation(tmp_path: Path) -> None:
    project = create_project(
        tmp_path / "platform",
        "integrity-demo",
        "Integrity Demo",
    )
    file = project / "deliverables" / "result.txt"
    file.write_text("v1", encoding="utf-8")
    snapshot = snapshot_integrity(project, "DELIVERY", roots=["deliverables"])
    assert verify_integrity_snapshot(project, snapshot) == []
    file.write_text("v2", encoding="utf-8")
    assert verify_integrity_snapshot(project, snapshot) == [
        "modifié: deliverables/result.txt"
    ]


def test_classification_and_action_gates() -> None:
    restricted = build_project_manifest(
        project_id="restricted-demo",
        title="Restricted",
        created_at="2026-08-27T00:00:00+00:00",
        expected_deliverables=[],
        source_items=[],
        intake_items=[],
        intake_archive="archive",
        classification="restricted",
    )
    assert cloud_policy_for_project(restricted)["allowed"] is False
    assert cloud_policy_for_project(restricted)["reason"] == "llm_cloud_not_supported"
    assert external_service_policy_for_project(restricted)["allowed"] is False
    with pytest.raises(PermissionError):
        assert_sensitive_action(restricted, "make_public", human_approved=False)
    with pytest.raises(PermissionError):
        assert_sensitive_action(restricted, "make_public", human_approved=True)

    confidential = dict(restricted)
    confidential["classification"] = "confidential"
    assert cloud_policy_for_project(
        confidential,
        redacted=True,
        human_approved=True,
    )["allowed"] is False
    assert external_service_policy_for_project(confidential)["allowed"] is False
    assert external_service_policy_for_project(
        confidential,
        redacted=True,
        human_approved=True,
    )["allowed"] is True


def test_learning_contract_has_distinct_verdict(tmp_path: Path) -> None:
    project = create_project(
        tmp_path / "platform",
        "learning-contract",
        "Learning",
    )
    add_learning_objective(
        project,
        objective="Expliquer Terraform plan",
        skill="terraform",
    )
    record_learning_evidence(project, evidence="terraform plan interprété")
    set_learning_verdict(project, "ACQUIS_AVEC_RESERVES")
    contract = json.loads(
        (project / "context" / "learning" / "LEARNING_CONTRACT.json").read_text(
            encoding="utf-8"
        )
    )
    assert contract["technical_verdict_is_separate"] is True
    assert contract["verdict"] == "ACQUIS_AVEC_RESERVES"
    assert contract["target_skills"] == ["terraform"]


def test_legacy_project_migration_is_backed_up_and_idempotent(
    tmp_path: Path,
) -> None:
    project = create_project(
        tmp_path / "platform",
        "migration-demo",
        "Migration",
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
    assert plan_project_migration(project) == ["1.1.0->2.0.0"]
    assert apply_project_migrations(project) == ["1.1.0->2.0.0"]
    assert apply_project_migrations(project) == []
    assert (project / ".migrations" / "ledger.jsonl").is_file()
    migrated = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert migrated["schema_version"] == "2.0.0"


def test_support_bundle_redacts_and_excludes_private_inputs(tmp_path: Path) -> None:
    project = create_project(tmp_path / "platform", "support-demo", "Support")
    evidence = project / "evidence" / "orchestration"
    evidence.mkdir(parents=True)
    (evidence / "log.txt").write_text(
        "api_key=supersecretvalue",
        encoding="utf-8",
    )
    output = tmp_path / "support.zip"
    build_support_bundle(project, output)
    with zipfile.ZipFile(output) as archive:
        text = archive.read("evidence/orchestration/log.txt").decode()
        names = set(archive.namelist())
    assert "api_key=<REDACTED>" in text
    assert all(not name.startswith("intake/") for name in names)
    assert all(not name.startswith("sources/") for name in names)
    assert "supersecretvalue" not in redact_text("api_key=supersecretvalue")


def test_automatic_telemetry_records_observed_only(tmp_path: Path) -> None:
    project = create_project(
        tmp_path / "platform",
        "telemetry-auto",
        "Telemetry",
    )
    with automatic_run_telemetry(
        project,
        project_id="telemetry-auto",
        agent="ingenieur-devops",
        model="ollama/qwen3.5:9b",
        backend="ollama",
        route_kind="local_primary",
        phase="execute",
    ) as observed:
        observed["prompt_tokens"] = 12
        observed["generated_tokens"] = 4
    rows = read_telemetry(project)
    assert len(rows) == 1
    assert rows[0]["duration_ms"] >= 0
    assert rows[0]["prompt_tokens"] == 12
    assert "prompt" not in rows[0]


def test_observed_metric_extraction_is_recursive_and_non_fabricating() -> None:
    metrics = extract_observed_metrics(
        {
            "stats": {
                "time_to_first_token_ms": 18,
                "tps": 7.5,
                "input_tokens": 40,
                "output_tokens": 12,
                "vram_mb": 8192,
            },
            "tool_calls": [{"name": "read"}, {"name": "exec"}],
        }
    )
    assert metrics == {
        "ttft_ms": 18,
        "tokens_per_second": 7.5,
        "prompt_tokens": 40,
        "generated_tokens": 12,
        "vram_mb": 8192,
        "tool_calls": 2,
    }
    assert "ram_mb" not in metrics


def test_superset_orchestrator_facade_records_governance_and_integrity(
    tmp_path: Path,
) -> None:
    project = create_project(
        tmp_path / "platform",
        "facade-demo",
        "Facade Demo",
    )
    assert superset.current_status(project) == "INTAKE_READY"
    assert superset.load_project_manifest(project)["schema_version"] == "2.0.0"

    superset.store_analysis(
        project,
        {
            "summary": "Projet de test",
            "objectives": ["livrer"],
            "constraints": [],
            "deliverables": ["README"],
            "ambiguities": [],
            "missing_information": [],
            "risks": ["Risque de dérive"],
            "decisions_required": ["Choisir la cible"],
        },
    )
    decisions = (project / "context" / "governance" / "DECISIONS.md").read_text(
        encoding="utf-8"
    )
    risks = (project / "context" / "governance" / "RISKS.md").read_text(
        encoding="utf-8"
    )
    assert "Choisir la cible" in decisions
    assert "Risque de dérive" in risks

    superset.transition_project(
        project,
        "ANALYZED",
        actor="chef-operations",
        reason="analysis_tested",
    )
    superset.store_plan(
        project,
        {
            "workstreams": ["delivery"],
            "tasks": [
                {
                    "id": "write-readme",
                    "role": "redacteur-technique",
                    "title": "Rédiger README",
                    "objective": "Produire la documentation",
                    "facts": ["README requis"],
                    "assumptions": ["format Markdown"],
                    "unknowns": [],
                    "required_evidence": ["README.md"],
                }
            ],
        },
    )
    superset.transition_project(
        project,
        "PLANNED",
        actor="chef-operations",
        reason="plan_tested",
    )
    assert superset.current_status(project) == "PLANNED"
    snapshot = latest_integrity_snapshot(project, "PLANNED")
    assert snapshot is not None
    assert verify_integrity_snapshot(project, snapshot) == []
