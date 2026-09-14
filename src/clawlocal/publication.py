from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import zipfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from clawlocal.config import load_contract
from clawlocal.safe_fs import is_link_like
from clawlocal.specialist_tools import run_specialist_tool


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _policy() -> dict[str, Any]:
    return load_contract("documentation_publication_policy.yaml")


def _project_root(project: Path) -> Path:
    root = project.expanduser().resolve(strict=True)
    if not (root / "project.json").is_file():
        raise FileNotFoundError(root / "project.json")
    return root


def _safe_existing(project: Path, value: str | Path) -> Path:
    root = _project_root(project)
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    resolved = candidate.expanduser().resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise PermissionError(f"publication: chemin hors projet: {resolved}")
    if is_link_like(resolved):
        raise PermissionError(f"publication: lien/reparse point interdit: {resolved}")
    return resolved


def _safe_output_dir(project: Path, value: str | Path) -> Path:
    root = _project_root(project)
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    parent = candidate.parent.expanduser().resolve(strict=True)
    if not parent.is_relative_to(root):
        raise PermissionError(f"publication: sortie hors projet: {candidate}")
    output = parent / candidate.name
    if output.exists() and is_link_like(output):
        raise PermissionError(f"publication: sortie lien/reparse point interdite: {output}")
    output.mkdir(parents=True, exist_ok=True)
    return output.resolve(strict=True)


def _tool_version(executable: str, args: list[str] | None = None) -> str | None:
    resolved = shutil.which(executable)
    if resolved is None:
        return None
    completed = subprocess.run(
        [resolved, *(args or ["--version"])],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
        shell=False,
    )
    if completed.returncode != 0:
        return None
    value = (completed.stdout or completed.stderr).strip().splitlines()
    return value[0] if value else None


def _inspect_markdown(path: Path) -> list[str]:
    failures: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    if len(text.strip()) < 80:
        failures.append("markdown trop court")
    if not any(line.startswith("#") for line in text.splitlines()):
        failures.append("markdown sans titre")
    return failures


def _inspect_html(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace").lower()
    failures: list[str] = []
    if "<html" not in text:
        failures.append("html sans balise <html>")
    if "<title" not in text:
        failures.append("html sans <title>")
    return failures


def _inspect_docx(path: Path) -> list[str]:
    failures: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
    except zipfile.BadZipFile:
        return ["docx invalide: conteneur ZIP illisible"]
    for required in ("[Content_Types].xml", "word/document.xml", "word/styles.xml"):
        if required not in names:
            failures.append(f"docx incomplet: {required} absent")
    return failures


def _inspect_pdf(path: Path) -> list[str]:
    with path.open("rb") as handle:
        prefix = handle.read(5)
    return [] if prefix == b"%PDF-" else ["pdf invalide: signature %PDF absente"]


def inspect_rendered_file(path: Path, kind: str) -> list[str]:
    if not path.is_file():
        return [f"{kind}: fichier absent"]
    if path.stat().st_size < 32:
        return [f"{kind}: fichier vide ou trop petit"]
    if kind == "markdown":
        return _inspect_markdown(path)
    if kind == "html":
        return _inspect_html(path)
    if kind == "docx":
        return _inspect_docx(path)
    if kind == "pdf":
        return _inspect_pdf(path)
    return [f"format de publication inconnu: {kind}"]


def _render_format(
    source: Path,
    *,
    quarto: str,
    quarto_format: str,
    expected_extension: str,
    timeout: int,
) -> tuple[list[str], Path, str, str, int]:
    command = [quarto, "render", source.name, "--to", quarto_format]
    completed = subprocess.run(
        command,
        cwd=source.parent,
        shell=False,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    rendered = source.with_suffix(expected_extension)
    return command, rendered, completed.stdout, completed.stderr, completed.returncode


def render_publication(
    project: Path,
    source: str | Path,
    *,
    output_dir: str | Path | None = None,
    timeout: int | None = None,
) -> Path:
    root = _project_root(project)
    source_path = _safe_existing(root, source)
    relative_source = source_path.relative_to(root)
    if relative_source.parts[:1] in {("intake",), ("sources",)} or relative_source.parts[:2] == (
        "context",
        "exchange",
    ):
        raise PermissionError(
            "publication: copier d'abord la source validée dans un répertoire de sortie de tâche"
        )
    policy = _policy()
    source_policy = policy.get("canonical_source", {})
    allowed_extensions = {str(value).lower() for value in source_policy.get("extensions", [])}
    if source_path.suffix.lower() not in allowed_extensions:
        raise ValueError(
            f"publication: source {source_path.suffix} interdite; "
            f"attendues: {', '.join(sorted(allowed_extensions))}"
        )

    output_root = _safe_output_dir(
        root,
        output_dir or source_path.parent / str(policy.get("default_output_directory", "rendered")),
    )
    render = policy.get("render", {})
    executable = str(render.get("executable", "quarto"))
    quarto = shutil.which(executable)
    if quarto is None:
        raise FileNotFoundError(f"publication: {executable} introuvable")

    max_timeout = int(render.get("max_timeout_seconds", 600))
    effective_timeout = timeout if timeout is not None else int(render.get("timeout_seconds", 300))
    if effective_timeout < 1 or effective_timeout > max_timeout:
        raise ValueError("publication: timeout hors limites")

    formats = render.get("formats", {})
    required_formats = [str(value) for value in policy.get("outputs", {}).get("required", [])]
    if not required_formats:
        raise ValueError("publication: aucun format requis")

    rendered_entries: list[dict[str, Any]] = []
    commands: list[dict[str, Any]] = []
    for kind in required_formats:
        spec = formats.get(kind)
        if not isinstance(spec, dict):
            raise ValueError(f"publication: format requis non configuré: {kind}")
        quarto_format = str(spec.get("quarto_format", "")).strip()
        extension = str(spec.get("extension", "")).strip()
        if not quarto_format or not extension.startswith("."):
            raise ValueError(f"publication: format {kind} invalide")

        command, generated, stdout, stderr, returncode = _render_format(
            source_path,
            quarto=quarto,
            quarto_format=quarto_format,
            expected_extension=extension,
            timeout=effective_timeout,
        )
        commands.append(
            {
                "kind": kind,
                "command": command,
                "returncode": returncode,
                "stdout": stdout,
                "stderr": stderr,
            }
        )
        if returncode != 0:
            raise RuntimeError(
                f"publication: rendu {kind} échoué ({returncode}): {stderr.strip()}"
            )
        if not generated.is_file():
            raise RuntimeError(f"publication: sortie {kind} absente: {generated}")

        destination = output_root / f"{source_path.stem}{extension}"
        if destination.exists() and is_link_like(destination):
            raise PermissionError(
                f"publication: sortie lien/reparse point interdite: {destination}"
            )
        if generated.resolve() != destination.resolve():
            shutil.copy2(generated, destination)
        failures = inspect_rendered_file(destination, kind)
        if failures:
            raise ValueError(f"publication: contrôle {kind} échoué: {'; '.join(failures)}")
        rendered_entries.append(
            {
                "kind": kind,
                "path": destination.relative_to(root).as_posix(),
                "sha256": _sha256(destination),
                "size": destination.stat().st_size,
            }
        )

    manifest = {
        "schema_version": "1.0.0",
        "generated_at": _now(),
        "source": {
            "path": source_path.relative_to(root).as_posix(),
            "sha256": _sha256(source_path),
        },
        "render_engine": "quarto",
        "tool_versions": {
            "quarto": _tool_version("quarto"),
            "typst": _tool_version("typst"),
        },
        "outputs": rendered_entries,
        "commands": commands,
        "quality": {
            "rendered_outputs_nonempty": True,
            "format_signatures_validated": True,
            "sha256_manifest": True,
            "source_preserved": True,
        },
    }
    manifest_path = output_root / "publication_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest_path


def validate_publication_manifest(project: Path, manifest: str | Path) -> list[str]:
    root = _project_root(project)
    manifest_path = _safe_existing(root, manifest)
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        return ["manifest de publication invalide"]
    failures: list[str] = []

    source = payload.get("source", {})
    if not isinstance(source, dict):
        failures.append("manifest: source invalide")
    else:
        source_path = root / str(source.get("path", ""))
        if not source_path.is_file():
            failures.append("manifest: source absente")
        elif _sha256(source_path) != str(source.get("sha256", "")):
            failures.append("manifest: SHA-256 source divergent")

    outputs = payload.get("outputs", [])
    if not isinstance(outputs, list) or not outputs:
        failures.append("manifest: sorties absentes")
        return failures
    seen: set[str] = set()
    for entry in outputs:
        if not isinstance(entry, dict):
            failures.append("manifest: entrée de sortie invalide")
            continue
        kind = str(entry.get("kind", ""))
        seen.add(kind)
        path = root / str(entry.get("path", ""))
        if not path.is_file():
            failures.append(f"{kind}: sortie absente")
            continue
        if _sha256(path) != str(entry.get("sha256", "")):
            failures.append(f"{kind}: SHA-256 divergent")
        failures.extend(f"{kind}: {value}" for value in inspect_rendered_file(path, kind))

    required = {str(value) for value in _policy().get("outputs", {}).get("required", [])}
    missing = sorted(required - seen)
    if missing:
        failures.append("formats requis absents: " + ", ".join(missing))
    return failures


def project_publication_failures(project: Path) -> list[str]:
    root = _project_root(project)
    failures: list[str] = []
    for manifest in sorted((root / "deliverables").rglob("publication_manifest.json")):
        relative = manifest.relative_to(root).as_posix()
        for failure in validate_publication_manifest(root, manifest):
            failures.append(f"{relative}: {failure}")
    return failures


def render_task_diagrams(project: Path, *, task_id: str, agent: str) -> list[str]:
    root = _project_root(project)
    diagrams = root / "diagrams" / task_id
    if not diagrams.is_dir():
        return []

    generated: list[str] = []
    for source in sorted(diagrams.rglob("*")):
        if not source.is_file():
            continue
        if source.suffix.lower() == ".mmd":
            output = source.with_suffix(".svg")
            result = run_specialist_tool(
                root,
                agent=agent,
                tool_id="mermaid_render_svg",
                target=source,
                output=output,
            )
            if result.returncode != 0:
                raise RuntimeError(f"diagramme Mermaid en échec: {source}")
            if result.output_path:
                generated.append(result.output_path)
        elif source.suffix.lower() == ".dot":
            output = source.with_suffix(".svg")
            result = run_specialist_tool(
                root,
                agent=agent,
                tool_id="graphviz_render_svg",
                target=source,
                output=output,
            )
            if result.returncode != 0:
                raise RuntimeError(f"diagramme Graphviz en échec: {source}")
            if result.output_path:
                generated.append(result.output_path)
    return generated


def postprocess_task_outputs(project: Path, *, task_id: str, agent: str) -> list[str]:
    root = _project_root(project)
    generated: list[str] = []

    if agent in {"architecte-solutions", "redacteur-technique"}:
        generated.extend(render_task_diagrams(root, task_id=task_id, agent=agent))

    if agent == "redacteur-technique":
        deliverable_root = root / "deliverables" / task_id
        if deliverable_root.is_dir():
            for source in sorted(deliverable_root.rglob("*.qmd")):
                if "rendered" in source.parts:
                    continue
                manifest = render_publication(
                    root,
                    source,
                    output_dir=source.parent / "rendered",
                )
                generated.append(manifest.relative_to(root).as_posix())
                payload = json.loads(manifest.read_text(encoding="utf-8"))
                for entry in payload.get("outputs", []):
                    if isinstance(entry, dict) and entry.get("path"):
                        generated.append(str(entry["path"]))
    return sorted(set(generated))


def _cli() -> int:
    parser = argparse.ArgumentParser(
        description="Rend et vérifie une source QMD OPENCLAW_LOCAL."
    )
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir")
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--validate-manifest")
    args = parser.parse_args()

    if args.validate_manifest:
        failures = validate_publication_manifest(args.project, args.validate_manifest)
        print(json.dumps({"failures": failures}, ensure_ascii=False, indent=2))
        return 1 if failures else 0

    manifest = render_publication(
        args.project,
        args.source,
        output_dir=args.output_dir,
        timeout=args.timeout,
    )
    failures = validate_publication_manifest(args.project, manifest)
    print(
        json.dumps(
            {
                "manifest": str(manifest),
                "failures": failures,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_cli())
