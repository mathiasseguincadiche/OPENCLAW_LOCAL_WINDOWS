from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Any

import yaml

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
_REQUIRED_EVIDENCE_HASHES = (
    "model_identity_sha256",
    "automated_qualification_sha256",
    "openclaw_e2e_sha256",
    "vulkan_runtime_stability_sha256",
    "golden_projects_sha256",
    "multimodal_evidence_sha256",
    "telemetry_evidence_sha256",
    "representative_project_package_sha256",
)


def requires_v1_readiness(version: str) -> bool:
    major_text = version.split(".", 1)[0]
    try:
        return int(major_text) >= 1
    except ValueError as exc:
        raise ValueError(f"version invalide pour release readiness: {version!r}") from exc


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"release readiness: section {label} invalide")
    return value


def _require_sha256(section: dict[str, Any], key: str) -> None:
    value = str(section.get(key, "")).strip().lower()
    if not _SHA256_RE.fullmatch(value):
        raise ValueError(f"release readiness: empreinte SHA-256 absente/invalide: {key}")


def _require_utc_timestamp(value: Any) -> None:
    text = str(value or "").strip()
    if not text:
        raise ValueError("release readiness: approved_at_utc absent")
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValueError("release readiness: approved_at_utc invalide") from exc
    offset = parsed.utcoffset()
    if parsed.tzinfo is None or offset is None:
        raise ValueError("release readiness: approved_at_utc doit contenir un fuseau UTC")
    if offset.total_seconds() != 0:
        raise ValueError("release readiness: approved_at_utc doit être en UTC")


def validate_v1_release_readiness(root: Path, version: str) -> None:
    if not requires_v1_readiness(version):
        return

    path = root / "config" / "v1" / "release_readiness.yaml"
    if not path.is_file():
        raise ValueError("release readiness: manifeste config/v1/release_readiness.yaml absent")

    try:
        payload = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise ValueError("release readiness: YAML invalide") from exc
    manifest = _mapping(payload, "racine")
    if str(manifest.get("schema_version")) != "1.0.0":
        raise ValueError("release readiness: schema_version doit être 1.0.0")
    if str(manifest.get("target_version", "")).strip() != version:
        raise ValueError(
            "release readiness: target_version doit correspondre exactement à VERSION"
        )
    if manifest.get("approved") is not True:
        raise ValueError("release readiness: approved=true requis pour une release >=1.0.0")

    qualification = _mapping(manifest.get("qualification"), "qualification")
    if str(qualification.get("verdict", "")).strip() != "APPROVED_FOR_V1":
        raise ValueError("release readiness: verdict APPROVED_FOR_V1 requis")
    source_commit = str(qualification.get("source_commit", "")).strip().lower()
    if not _COMMIT_RE.fullmatch(source_commit):
        raise ValueError("release readiness: source_commit Git 40 hex requis")
    for key in _REQUIRED_EVIDENCE_HASHES:
        _require_sha256(qualification, key)
    if qualification.get("limits_documented") is not True:
        raise ValueError("release readiness: limits_documented=true requis")
    if qualification.get("no_cloud_fallback_confirmed") is not True:
        raise ValueError("release readiness: no_cloud_fallback_confirmed=true requis")

    approval = _mapping(manifest.get("human_approval"), "human_approval")
    if approval.get("approved") is not True:
        raise ValueError("release readiness: approbation humaine explicite requise")
    if not str(approval.get("approved_by", "")).strip():
        raise ValueError("release readiness: approved_by requis")
    _require_utc_timestamp(approval.get("approved_at_utc"))
