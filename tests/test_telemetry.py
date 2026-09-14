import json
from pathlib import Path

import pytest

from clawlocal.project_intake import create_project
from clawlocal.telemetry import (
    append_telemetry,
    read_telemetry,
    summarize_telemetry,
    telemetry_path,
)


def test_telemetry_records_observed_metrics_only(tmp_path: Path) -> None:
    project = create_project(tmp_path / "platform", "telemetry-demo", "Telemetry Demo")
    append_telemetry(
        project,
        {
            "project_id": "telemetry-demo",
            "agent": "ingenieur-devops",
            "model": "devstral-devops",
            "backend": "ollama-vulkan",
            "route_kind": "local_specialist",
            "duration_ms": 1200,
            "ttft_ms": 200,
            "generated_tokens": 120,
            "tokens_per_second": 12.5,
            "tool_calls": 2,
            "success": True,
        },
    )
    rows = read_telemetry(project)
    assert len(rows) == 1
    assert rows[0]["generated_tokens"] == 120
    summary = summarize_telemetry(project)
    assert summary["runs"] == 1
    assert summary["generated_tokens_total"] == 120
    assert summary["legacy_rows"] == 0
    assert summary["legacy_cloud_escalations"] == 0
    assert summary["legacy_cloud_cost_eur_total"] == 0


def test_telemetry_rejects_private_content_and_negative_metrics(tmp_path: Path) -> None:
    project = create_project(tmp_path / "platform", "telemetry-safe", "Telemetry Safe")
    base = {
        "project_id": "telemetry-safe",
        "agent": "chef-operations",
        "model": "qwen-max",
        "backend": "ollama-vulkan",
        "route_kind": "local_max",
        "duration_ms": 10,
    }
    with pytest.raises(ValueError):
        append_telemetry(project, {**base, "prompt": "secret"})
    with pytest.raises(ValueError):
        append_telemetry(project, {**base, "duration_ms": -1})


def test_telemetry_rejects_new_legacy_cloud_measurements(tmp_path: Path) -> None:
    project = create_project(tmp_path / "platform", "telemetry-local", "Telemetry Local")
    base = {
        "project_id": "telemetry-local",
        "agent": "chef-operations",
        "model": "qwen-max",
        "backend": "ollama-vulkan",
        "route_kind": "local_max",
        "duration_ms": 10,
    }
    with pytest.raises(ValueError, match="legacy en lecture seule"):
        append_telemetry(project, {**base, "cloud_escalation": False})
    with pytest.raises(ValueError, match="legacy en lecture seule"):
        append_telemetry(project, {**base, "cloud_cost_eur": 0.01})
    with pytest.raises(ValueError, match="route_kind legacy cloud"):
        append_telemetry(project, {**base, "route_kind": "cloud_escalation"})


def test_telemetry_reads_legacy_rows_without_reenabling_writes(tmp_path: Path) -> None:
    project = create_project(tmp_path / "platform", "telemetry-legacy", "Telemetry Legacy")
    path = telemetry_path(project)
    path.parent.mkdir(parents=True, exist_ok=True)
    legacy = {
        "timestamp": "2026-08-27T12:00:00+00:00",
        "project_id": "telemetry-legacy",
        "agent": "expert-recherche",
        "model": "historical-cloud-model",
        "backend": "historical-provider",
        "route_kind": "cloud_escalation",
        "duration_ms": 100,
        "cloud_escalation": True,
        "cloud_cost_eur": 0.08,
        "success": True,
    }
    path.write_text(json.dumps(legacy) + "\n", encoding="utf-8")

    rows = read_telemetry(project)
    assert rows == [legacy]
    summary = summarize_telemetry(project)
    assert summary["runs"] == 1
    assert summary["legacy_rows"] == 1
    assert summary["legacy_cloud_escalations"] == 1
    assert summary["legacy_cloud_cost_eur_total"] == 0.08
