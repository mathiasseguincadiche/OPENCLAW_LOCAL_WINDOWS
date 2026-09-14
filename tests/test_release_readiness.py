from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from clawlocal.release_readiness import (
    requires_v1_readiness,
    validate_v1_release_readiness,
)

HASH = "a" * 64
COMMIT = "b" * 40


def _manifest_path(root: Path) -> Path:
    return root / "config" / "v1" / "release_readiness.yaml"


def _write_manifest(root: Path, payload: dict) -> None:
    path = _manifest_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")


def _approved_manifest(version: str = "1.0.0") -> dict:
    return {
        "schema_version": "1.0.0",
        "target_version": version,
        "approved": True,
        "qualification": {
            "verdict": "APPROVED_FOR_V1",
            "source_commit": COMMIT,
            "model_identity_sha256": HASH,
            "automated_qualification_sha256": HASH,
            "openclaw_e2e_sha256": HASH,
            "vulkan_runtime_stability_sha256": HASH,
            "golden_projects_sha256": HASH,
            "multimodal_evidence_sha256": HASH,
            "telemetry_evidence_sha256": HASH,
            "representative_project_package_sha256": HASH,
            "limits_documented": True,
            "no_cloud_fallback_confirmed": True,
        },
        "human_approval": {
            "approved": True,
            "approved_by": "human-reviewer",
            "approved_at_utc": "2026-09-03T12:00:00Z",
        },
    }


def test_development_versions_do_not_require_v1_attestation(tmp_path: Path) -> None:
    assert requires_v1_readiness("0.2.0") is False
    validate_v1_release_readiness(tmp_path, "0.2.0")


def test_v1_is_fail_closed_without_manifest(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="manifeste"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_malformed_yaml_as_controlled_failure(tmp_path: Path) -> None:
    path = _manifest_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("qualification: [unterminated\n", encoding="utf-8")
    with pytest.raises(ValueError, match="YAML invalide"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_unapproved_template(tmp_path: Path) -> None:
    payload = _approved_manifest()
    payload["approved"] = False
    _write_manifest(tmp_path, payload)
    with pytest.raises(ValueError, match="approved=true"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_wrong_target_version(tmp_path: Path) -> None:
    _write_manifest(tmp_path, _approved_manifest("1.0.1"))
    with pytest.raises(ValueError, match="target_version"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_missing_or_invalid_evidence_hash(tmp_path: Path) -> None:
    payload = _approved_manifest()
    payload["golden_projects_sha256"] = "not-a-hash"
    payload["qualification"]["golden_projects_sha256"] = "not-a-hash"
    _write_manifest(tmp_path, payload)
    with pytest.raises(ValueError, match="golden_projects_sha256"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_missing_vulkan_runtime_stability_evidence(tmp_path: Path) -> None:
    payload = _approved_manifest()
    payload["qualification"]["vulkan_runtime_stability_sha256"] = ""
    _write_manifest(tmp_path, payload)
    with pytest.raises(ValueError, match="vulkan_runtime_stability_sha256"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_rejects_non_utc_human_approval(tmp_path: Path) -> None:
    payload = _approved_manifest()
    payload["human_approval"]["approved_at_utc"] = "2026-09-03T12:00:00-04:00"
    _write_manifest(tmp_path, payload)
    with pytest.raises(ValueError, match="doit être en UTC"):
        validate_v1_release_readiness(tmp_path, "1.0.0")


def test_v1_accepts_complete_hashed_evidence_and_human_approval(tmp_path: Path) -> None:
    _write_manifest(tmp_path, _approved_manifest())
    validate_v1_release_readiness(tmp_path, "1.0.0")
