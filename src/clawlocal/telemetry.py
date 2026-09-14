from __future__ import annotations

import json
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from clawlocal.config import load_contract

_REQUIRED = {
    "project_id",
    "agent",
    "model",
    "backend",
    "route_kind",
    "duration_ms",
}
_NUMERIC_NONNEGATIVE = {
    "duration_ms",
    "ttft_ms",
    "tokens_per_second",
    "prompt_tokens",
    "generated_tokens",
    "vram_mb",
    "ram_mb",
    "tool_calls",
    "retries",
}
_FORBIDDEN_KEYS = {
    "prompt",
    "response",
    "content",
    "document",
    "secret",
    "api_key",
    "token_value",
}
_LEGACY_READ_ONLY_KEYS = {
    "cloud_escalation",
    "cloud_cost_eur",
}
_LEGACY_READ_ONLY_ROUTE_KINDS = {"cloud_escalation"}


def _now() -> str:
    return datetime.now(UTC).isoformat()


def telemetry_path(project: Path) -> Path:
    policy = load_contract("telemetry_policy.yaml")
    relative = policy.get("storage", {}).get(
        "relative_path",
        "evidence/telemetry/runs.jsonl",
    )
    return project / str(relative)


def _validate_measurement(payload: dict[str, Any]) -> None:
    missing = sorted(_REQUIRED - set(payload))
    if missing:
        raise ValueError("télémétrie incomplète: " + ", ".join(missing))
    forbidden = sorted(_FORBIDDEN_KEYS & set(payload))
    if forbidden:
        raise ValueError(
            "champs sensibles interdits en télémétrie: " + ", ".join(forbidden)
        )
    legacy = sorted(_LEGACY_READ_ONLY_KEYS & set(payload))
    if legacy:
        raise ValueError(
            "champs de télémétrie legacy en lecture seule: " + ", ".join(legacy)
        )
    if str(payload.get("route_kind", "")) in _LEGACY_READ_ONLY_ROUTE_KINDS:
        raise ValueError("route_kind legacy cloud interdit pour une nouvelle mesure")
    for key in _NUMERIC_NONNEGATIVE:
        value = payload.get(key)
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"métrique numérique invalide: {key}")
        if value < 0:
            raise ValueError(f"métrique négative interdite: {key}")


def append_telemetry(project: Path, measurement: dict[str, Any]) -> Path:
    payload = dict(measurement)
    _validate_measurement(payload)
    payload.setdefault("timestamp", _now())
    path = telemetry_path(project)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
    return path


def _find_numeric(value: Any, names: set[str]) -> float | int | None:
    if isinstance(value, dict):
        for key, child in value.items():
            if (
                key in names
                and isinstance(child, (int, float))
                and not isinstance(child, bool)
            ):
                return child
        for child in value.values():
            found = _find_numeric(child, names)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_numeric(child, names)
            if found is not None:
                return found
    return None


def extract_observed_metrics(value: Any) -> dict[str, Any]:
    aliases = {
        "ttft_ms": {"ttft_ms", "time_to_first_token_ms"},
        "tokens_per_second": {"tokens_per_second", "tps"},
        "prompt_tokens": {"prompt_tokens", "input_tokens"},
        "generated_tokens": {
            "generated_tokens",
            "output_tokens",
            "completion_tokens",
        },
        "vram_mb": {"vram_mb"},
        "ram_mb": {"ram_mb"},
        "retries": {"retries", "retry_count"},
    }
    observed: dict[str, Any] = {}
    for target, names in aliases.items():
        found = _find_numeric(value, names)
        if found is not None:
            observed[target] = found
    if isinstance(value, dict):
        calls = value.get("tool_calls")
        if isinstance(calls, list):
            observed["tool_calls"] = len(calls)
    return observed


@contextmanager
def automatic_run_telemetry(
    project: Path,
    *,
    project_id: str,
    agent: str,
    model: str,
    backend: str,
    route_kind: str,
    phase: str,
) -> Iterator[dict[str, Any]]:
    observed: dict[str, Any] = {}
    started = time.perf_counter()
    success = False
    error_class: str | None = None
    try:
        yield observed
        success = True
    except Exception as exc:
        error_class = type(exc).__name__
        raise
    finally:
        payload: dict[str, Any] = {
            "project_id": project_id,
            "agent": agent,
            "model": model,
            "backend": backend,
            "route_kind": route_kind,
            "phase": phase,
            "duration_ms": (time.perf_counter() - started) * 1000.0,
            "success": success,
            "local_to_deep_transition": route_kind == "local_deep",
            **observed,
        }
        if error_class:
            payload["error_class"] = error_class
        append_telemetry(project, payload)


def read_telemetry(project: Path) -> list[dict[str, Any]]:
    path = telemetry_path(project)
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            text = line.strip()
            if not text:
                continue
            payload = json.loads(text)
            if not isinstance(payload, dict):
                raise ValueError("ligne de télémétrie invalide")
            rows.append(payload)
    return rows


def summarize_telemetry(project: Path) -> dict[str, Any]:
    rows = read_telemetry(project)
    durations = [float(row["duration_ms"]) for row in rows if "duration_ms" in row]
    generated = [
        float(row["generated_tokens"])
        for row in rows
        if row.get("generated_tokens") is not None
    ]
    legacy_cloud_costs = [
        float(row["cloud_cost_eur"])
        for row in rows
        if row.get("cloud_cost_eur") is not None
    ]
    legacy_cloud_escalations = sum(
        1
        for row in rows
        if row.get("cloud_escalation") is True
        or row.get("route_kind") == "cloud_escalation"
    )
    legacy_rows = sum(
        1
        for row in rows
        if bool(_LEGACY_READ_ONLY_KEYS & set(row))
        or row.get("route_kind") in _LEGACY_READ_ONLY_ROUTE_KINDS
    )
    return {
        "runs": len(rows),
        "duration_ms_total": sum(durations),
        "generated_tokens_total": sum(generated),
        "local_to_deep_transitions": sum(
            1 for row in rows if row.get("local_to_deep_transition") is True
        ),
        "legacy_rows": legacy_rows,
        "legacy_cloud_cost_eur_total": round(sum(legacy_cloud_costs), 6),
        "legacy_cloud_escalations": legacy_cloud_escalations,
    }
