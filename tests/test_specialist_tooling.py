from __future__ import annotations

import json
from pathlib import Path

import pytest

from clawlocal.specialist_tools import available_tools_for, build_specialist_command


def _project(tmp_path: Path) -> Path:
    project = tmp_path / "projects" / "demo"
    project.mkdir(parents=True)
    (project / "project.json").write_text(
        json.dumps({"project_id": "demo", "status": "IN_PROGRESS"}),
        encoding="utf-8",
    )
    return project


def test_specialist_policy_exposes_role_scoped_tools() -> None:
    assert "terraform_validate" in available_tools_for("ingenieur-devops")
    assert "gitleaks_scan" in available_tools_for("ingenieur-securite")
    assert "mermaid_render_svg" in available_tools_for("architecte-solutions")
    assert "quarto_render" not in available_tools_for("redacteur-technique")


def test_specialist_tool_denies_cross_role_access(tmp_path: Path) -> None:
    project = _project(tmp_path)
    target = project / "infra"
    target.mkdir()

    with pytest.raises(PermissionError):
        build_specialist_command(
            project,
            agent="auditeur-qualite",
            tool_id="terraform_validate",
            target=target,
        )


def test_specialist_tool_rejects_target_outside_project(tmp_path: Path) -> None:
    project = _project(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()

    with pytest.raises(PermissionError):
        build_specialist_command(
            project,
            agent="ingenieur-devops",
            tool_id="terraform_validate",
            target=outside,
        )


def test_mermaid_command_is_fixed_and_shell_free(tmp_path: Path) -> None:
    project = _project(tmp_path)
    source = project / "diagrams" / "flow.mmd"
    source.parent.mkdir(parents=True)
    source.write_text("flowchart TD\nA-->B\n", encoding="utf-8")
    output = source.with_suffix(".svg")

    command, target, rendered = build_specialist_command(
        project,
        agent="architecte-solutions",
        tool_id="mermaid_render_svg",
        target=source,
        output=output,
    )

    assert Path(command[0]).name.lower() in {"mmdc", "mmdc.cmd"}
    assert command[1:] == [
        "-i",
        str(source.resolve()),
        "-o",
        str(output.resolve()),
        "-b",
        "transparent",
    ]
    assert target == source.resolve()
    assert rendered == output.resolve()


def test_specialist_tool_rejects_wrong_extension(tmp_path: Path) -> None:
    project = _project(tmp_path)
    source = project / "diagrams" / "flow.txt"
    source.parent.mkdir(parents=True)
    source.write_text("not mermaid", encoding="utf-8")

    with pytest.raises(ValueError, match="extension"):
        build_specialist_command(
            project,
            agent="architecte-solutions",
            tool_id="mermaid_render_svg",
            target=source,
            output=source.with_suffix(".svg"),
        )


def test_specialist_tool_rejects_output_in_protected_exchange(tmp_path: Path) -> None:
    project = _project(tmp_path)
    source = project / "diagrams" / "flow.mmd"
    source.parent.mkdir(parents=True)
    source.write_text("flowchart TD\nA-->B\n", encoding="utf-8")
    protected = project / "context" / "exchange" / "flow.svg"
    protected.parent.mkdir(parents=True)

    with pytest.raises(PermissionError, match="entrée protégée"):
        build_specialist_command(
            project,
            agent="architecte-solutions",
            tool_id="mermaid_render_svg",
            target=source,
            output=protected,
        )
