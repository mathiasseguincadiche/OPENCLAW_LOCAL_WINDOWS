from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from clawlocal.config import load_contract
from clawlocal.safe_fs import is_link_like


@dataclass(frozen=True)
class SpecialistToolResult:
    agent: str
    tool_id: str
    command: list[str]
    returncode: int
    stdout: str
    stderr: str
    evidence_path: str
    output_path: str | None
    output_sha256: str | None


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _timestamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")


def _policy() -> dict[str, Any]:
    return load_contract("specialist_tool_policy.yaml")


def _project_path(project: Path) -> Path:
    root = project.expanduser().resolve(strict=True)
    if not (root / "project.json").is_file():
        raise FileNotFoundError(root / "project.json")
    return root


def _safe_existing_path(project: Path, value: str | Path) -> Path:
    root = _project_path(project)
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    resolved = candidate.expanduser().resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise PermissionError(f"cible hors projet: {resolved}")
    if is_link_like(resolved):
        raise PermissionError(f"lien/reparse point interdit: {resolved}")
    return resolved


def _safe_output_path(project: Path, value: str | Path) -> Path:
    root = _project_path(project)
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    parent = candidate.parent.expanduser().resolve(strict=True)
    if not parent.is_relative_to(root):
        raise PermissionError(f"sortie hors projet: {candidate}")
    output = parent / candidate.name
    relative = output.relative_to(root)
    protected = relative.parts[:1] in {("intake",), ("sources",)} or relative.parts[:2] == (
        "context",
        "exchange",
    )
    if protected:
        raise PermissionError(f"sortie dans une entrée protégée interdite: {relative.as_posix()}")
    if is_link_like(output):
        raise PermissionError(f"sortie lien/reparse point interdite: {output}")
    return output


def available_tools_for(agent: str) -> tuple[str, ...]:
    policy = _policy()
    roles = policy.get("roles", {})
    if agent not in roles:
        raise KeyError(f"agent inconnu dans specialist_tool_policy.yaml: {agent}")
    tools = roles[agent]
    if not isinstance(tools, list):
        raise ValueError(f"{agent}: liste d'outils spécialisée invalide")
    return tuple(str(value) for value in tools)


def _tool_spec(agent: str, tool_id: str) -> dict[str, Any]:
    policy = _policy()
    if tool_id not in available_tools_for(agent):
        raise PermissionError(f"{agent}: outil spécialisé non autorisé: {tool_id}")
    tools = policy.get("tools", {})
    raw = tools.get(tool_id)
    if not isinstance(raw, dict):
        raise KeyError(f"outil spécialisé non défini: {tool_id}")
    return raw


def _validate_extension(path: Path, allowed: list[Any], *, label: str) -> None:
    if not allowed:
        return
    normalized = {str(value).lower() for value in allowed}
    if path.suffix.lower() not in normalized:
        raise ValueError(
            f"{label}: extension {path.suffix or '<aucune>'} interdite; "
            f"attendues: {', '.join(sorted(normalized))}"
        )


def build_specialist_command(
    project: Path,
    *,
    agent: str,
    tool_id: str,
    target: str | Path | None = None,
    output: str | Path | None = None,
) -> tuple[list[str], Path | None, Path | None]:
    policy = _policy()
    execution = policy.get("execution", {})
    if execution.get("shell") is not False:
        raise ValueError("specialist_tool_policy.yaml doit imposer shell=false")
    if execution.get("workspace_only") is not True:
        raise ValueError("specialist_tool_policy.yaml doit imposer workspace_only=true")

    spec = _tool_spec(agent, tool_id)
    target_path = _safe_existing_path(project, target) if target is not None else None
    output_path = _safe_output_path(project, output) if output is not None else None

    if target_path is not None:
        kind = str(spec.get("target_kind", "any"))
        if kind == "file" and not target_path.is_file():
            raise ValueError(f"{tool_id}: fichier cible requis")
        if kind == "directory" and not target_path.is_dir():
            raise ValueError(f"{tool_id}: répertoire cible requis")
        if target_path.is_file():
            _validate_extension(
                target_path,
                list(spec.get("input_extensions", [])),
                label=f"{tool_id} entrée",
            )

    if output_path is not None:
        _validate_extension(
            output_path,
            list(spec.get("output_extensions", [])),
            label=f"{tool_id} sortie",
        )

    raw_args = spec.get("args", [])
    if not isinstance(raw_args, list) or any(not isinstance(value, str) for value in raw_args):
        raise ValueError(f"{tool_id}: args invalide")

    replacements = {
        "{target}": str(target_path) if target_path is not None else None,
        "{output}": str(output_path) if output_path is not None else None,
    }
    rendered_args: list[str] = []
    for raw in raw_args:
        rendered = raw
        for placeholder, replacement in replacements.items():
            if placeholder in rendered:
                if replacement is None:
                    raise ValueError(f"{tool_id}: valeur requise pour {placeholder}")
                rendered = rendered.replace(placeholder, replacement)
        if "{" in rendered or "}" in rendered:
            raise ValueError(f"{tool_id}: placeholder non supporté dans {raw!r}")
        rendered_args.append(rendered)

    executable = str(spec.get("executable", "")).strip()
    if not executable:
        raise ValueError(f"{tool_id}: executable absent")
    resolved_executable = shutil.which(executable)
    command_executable = resolved_executable or executable
    return [command_executable, *rendered_args], target_path, output_path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_specialist_tool(
    project: Path,
    *,
    agent: str,
    tool_id: str,
    target: str | Path | None = None,
    output: str | Path | None = None,
    timeout: int | None = None,
) -> SpecialistToolResult:
    root = _project_path(project)
    policy = _policy()
    execution = policy.get("execution", {})
    command, _, output_path = build_specialist_command(
        root,
        agent=agent,
        tool_id=tool_id,
        target=target,
        output=output,
    )
    executable = command[0]
    if shutil.which(executable) is None and not Path(executable).is_file():
        raise FileNotFoundError(f"{tool_id}: exécutable introuvable: {executable}")

    configured_timeout = int(execution.get("timeout_seconds", 120))
    effective_timeout = timeout if timeout is not None else configured_timeout
    if effective_timeout < 1 or effective_timeout > int(execution.get("max_timeout_seconds", 900)):
        raise ValueError("timeout spécialisé hors limites")

    completed = subprocess.run(
        command,
        cwd=root,
        shell=False,
        check=False,
        capture_output=True,
        text=True,
        timeout=effective_timeout,
    )

    output_sha: str | None = None
    if output_path is not None:
        if completed.returncode == 0 and not output_path.is_file():
            raise RuntimeError(f"{tool_id}: sortie attendue absente: {output_path}")
        if output_path.is_file():
            output_sha = _sha256(output_path)

    evidence_root = root / "evidence" / "tooling"
    evidence_root.mkdir(parents=True, exist_ok=True)
    evidence_path = evidence_root / f"{_timestamp()}-{agent}-{tool_id}.json"
    payload = {
        "schema_version": "1.0.0",
        "at": _now(),
        "agent": agent,
        "tool_id": tool_id,
        "command": command,
        "shell": False,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "output": (
            {
                "path": output_path.relative_to(root).as_posix(),
                "sha256": output_sha,
            }
            if output_path is not None and output_path.exists()
            else None
        ),
    }
    evidence_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return SpecialistToolResult(
        agent=agent,
        tool_id=tool_id,
        command=command,
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
        evidence_path=evidence_path.relative_to(root).as_posix(),
        output_path=(
            output_path.relative_to(root).as_posix()
            if output_path is not None and output_path.exists()
            else None
        ),
        output_sha256=output_sha,
    )


def _cli() -> int:
    parser = argparse.ArgumentParser(
        description="Exécute un outil métier borné défini par specialist_tool_policy.yaml."
    )
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--tool")
    parser.add_argument("--target")
    parser.add_argument("--output")
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if args.list:
        print(json.dumps({"agent": args.agent, "tools": available_tools_for(args.agent)}, indent=2))
        return 0
    if not args.tool:
        parser.error("--tool est requis sans --list")

    result = run_specialist_tool(
        args.project,
        agent=args.agent,
        tool_id=args.tool,
        target=args.target,
        output=args.output,
        timeout=args.timeout,
    )
    print(json.dumps(asdict(result), ensure_ascii=False, indent=2))
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(_cli())
