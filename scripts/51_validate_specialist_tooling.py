from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config" / "v1"


def _load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        payload = yaml.safe_load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path.name}: racine YAML invalide")
    return payload


def _fail(failures: list[str], condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []
    specialist = _load_yaml(CONFIG / "specialist_tool_policy.yaml")
    publication = _load_yaml(CONFIG / "documentation_publication_policy.yaml")
    diagrams = _load_yaml(CONFIG / "diagram_policy.yaml")
    roles = _load_yaml(CONFIG / "role_matrix.yaml")
    tools = _load_yaml(CONFIG / "tool_policy.yaml")
    runtime = json.loads((CONFIG / "runtime_versions.json").read_text(encoding="utf-8"))

    repository_version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    for name, contract in (
        ("specialist_tool_policy.yaml", specialist),
        ("documentation_publication_policy.yaml", publication),
        ("diagram_policy.yaml", diagrams),
    ):
        _fail(
            failures,
            str(contract.get("platform_version")) == repository_version,
            f"{name}: platform_version incohérente",
        )

    execution = specialist.get("execution", {})
    _fail(failures, execution.get("shell") is False, "outils spécialisés: shell=false requis")
    _fail(
        failures,
        execution.get("workspace_only") is True,
        "outils spécialisés: workspace_only=true requis",
    )
    _fail(
        failures,
        execution.get("mediated_by_control_plane") is True,
        "outils spécialisés: médiation control plane requise",
    )

    role_ids = set(roles.get("roles", {}))
    specialist_roles = set(specialist.get("roles", {}))
    _fail(
        failures,
        role_ids == specialist_roles,
        "specialist_tool_policy.yaml doit couvrir exactement les huit rôles",
    )
    defined_tools = specialist.get("tools", {})
    if not isinstance(defined_tools, dict):
        failures.append("specialist_tool_policy.yaml: tools doit être un objet")
        defined_tools = {}

    referenced: set[str] = set()
    for agent, values in specialist.get("roles", {}).items():
        if not isinstance(values, list):
            failures.append(f"{agent}: liste specialist tools invalide")
            continue
        referenced |= {str(value) for value in values}
    for tool_id in sorted(referenced - set(defined_tools)):
        failures.append(f"outil spécialisé référencé mais absent: {tool_id}")

    for agent in sorted(role_ids):
        contract_tools = {
            str(value)
            for value in specialist.get("roles", {}).get(agent, [])
        }
        openclaw_tools = {
            str(value)
            for value in tools.get("agents", {}).get(agent, {}).get("specialist_tools", [])
        }
        if contract_tools != openclaw_tools:
            failures.append(
                f"{agent}: tool_policy.yaml et specialist_tool_policy.yaml divergent"
            )

    allowed_placeholders = {"{target}", "{output}"}
    for tool_id, spec in defined_tools.items():
        if not isinstance(spec, dict):
            failures.append(f"{tool_id}: spec invalide")
            continue
        if not str(spec.get("executable", "")).strip():
            failures.append(f"{tool_id}: executable absent")
        args = spec.get("args", [])
        if not isinstance(args, list) or any(not isinstance(value, str) for value in args):
            failures.append(f"{tool_id}: args invalide")
            continue
        for value in args:
            cursor = value
            for placeholder in allowed_placeholders:
                cursor = cursor.replace(placeholder, "")
            if "{" in cursor or "}" in cursor:
                failures.append(f"{tool_id}: placeholder non autorisé dans {value!r}")

    review_roles = {"architecte-solutions", "redacteur-technique", "auditeur-qualite"}
    for agent in review_roles:
        denied = set(tools.get("agents", {}).get(agent, {}).get("deny", []))
        _fail(
            failures,
            {"exec", "process"} <= denied,
            f"{agent}: exec/process doivent rester interdits malgré les nouveaux renderers",
        )

    _fail(failures, publication.get("enabled") is True, "publication documentaire doit être active")
    canonical = publication.get("canonical_source", {})
    _fail(
        failures,
        ".qmd" in set(canonical.get("extensions", [])),
        "publication: .qmd doit être une source canonique",
    )
    template = ROOT / str(canonical.get("template", ""))
    _fail(failures, template.is_file(), "publication: template QMD absent")
    required_formats = set(publication.get("outputs", {}).get("required", []))
    _fail(
        failures,
        required_formats == {"markdown", "html", "docx", "pdf"},
        "publication: Markdown/HTML/DOCX/PDF doivent être requis",
    )
    render = publication.get("render", {})
    _fail(failures, render.get("shell") is False, "publication: shell=false requis")
    formats = render.get("formats", {})
    for kind in required_formats:
        spec = formats.get(kind, {})
        if not isinstance(spec, dict) or not str(spec.get("quarto_format", "")).strip():
            failures.append(f"publication: renderer absent pour {kind}")
    _fail(
        failures,
        formats.get("pdf", {}).get("quarto_format") == "typst",
        "publication PDF: Typst doit rester le moteur nominal",
    )

    preferred = set(diagrams.get("preferred_formats", []))
    _fail(
        failures,
        {"mermaid", "graphviz"} <= preferred,
        "diagrammes: Mermaid et Graphviz doivent être supportés",
    )
    diagram_renderers = diagrams.get("renderers", {})
    _fail(
        failures,
        diagram_renderers.get("mermaid", {}).get("executable") == "mmdc",
        "diagrammes: mmdc attendu",
    )
    _fail(
        failures,
        diagram_renderers.get("graphviz", {}).get("executable") == "dot",
        "diagrammes: dot attendu",
    )

    toolchain = runtime.get("publication_toolchain", {})
    expected_versions = {
        "quarto": "1.10.18",
        "typst": "0.15.0",
        "mermaid_cli": "11.17.0",
        "graphviz": "16.1.0",
    }
    for key, version in expected_versions.items():
        actual = str(toolchain.get(key, {}).get("preferred", ""))
        if actual != version:
            failures.append(
                f"runtime_versions.json: {key} attendu {version}, "
                f"trouvé {actual or '<vide>'}"
            )

    docs = [
        ROOT / "docs" / "SPECIALIST_TOOLING.md",
        ROOT / "docs" / "PUBLICATION_TOOLCHAIN.md",
    ]
    for path in docs:
        _fail(failures, path.is_file(), f"documentation absente: {path.relative_to(ROOT)}")

    if failures:
        print("Specialist tooling gate: NON CONFORME")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Specialist tooling gate: CONFORME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
