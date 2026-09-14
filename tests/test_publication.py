from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest

import clawlocal.publication as publication
from clawlocal.publication import inspect_rendered_file, validate_publication_manifest


def _project(tmp_path: Path) -> Path:
    project = tmp_path / "projects" / "demo"
    project.mkdir(parents=True)
    (project / "project.json").write_text(
        json.dumps({"project_id": "demo", "status": "IN_PROGRESS"}),
        encoding="utf-8",
    )
    return project


def _docx(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "<document/>")
        archive.writestr("word/styles.xml", "<styles/>")


def _publication_policy() -> dict[str, object]:
    return {
        "canonical_source": {"extensions": [".qmd"]},
        "default_output_directory": "rendered",
        "render": {
            "executable": "quarto",
            "timeout_seconds": 30,
            "max_timeout_seconds": 60,
            "formats": {
                "markdown": {"quarto_format": "gfm", "extension": ".md"},
                "html": {"quarto_format": "html", "extension": ".html"},
                "docx": {"quarto_format": "docx", "extension": ".docx"},
                "pdf": {"quarto_format": "typst", "extension": ".pdf"},
            },
        },
        "outputs": {"required": ["markdown", "html", "docx", "pdf"]},
    }


def _write_rendered(path: Path) -> None:
    if path.suffix == ".md":
        path.write_text(
            "# Guide\n\n" + ("Documentation technique exploitable et vérifiable. " * 4),
            encoding="utf-8",
        )
    elif path.suffix == ".html":
        path.write_text(
            "<html><head><title>Guide</title></head><body>ok</body></html>",
            encoding="utf-8",
        )
    elif path.suffix == ".docx":
        _docx(path)
    elif path.suffix == ".pdf":
        path.write_bytes(b"%PDF-1.7\n" + b"x" * 64)
    else:
        raise AssertionError(path)


def test_format_inspection_accepts_structurally_valid_outputs(tmp_path: Path) -> None:
    markdown = tmp_path / "guide.md"
    markdown.write_text(
        "# Guide\n\n" + ("Documentation technique exploitable et vérifiable. " * 4),
        encoding="utf-8",
    )
    html = tmp_path / "guide.html"
    html.write_text(
        "<html><head><title>Guide</title></head><body>ok</body></html>",
        encoding="utf-8",
    )
    docx = tmp_path / "guide.docx"
    _docx(docx)
    pdf = tmp_path / "guide.pdf"
    pdf.write_bytes(b"%PDF-1.7\n" + b"x" * 64)

    assert inspect_rendered_file(markdown, "markdown") == []
    assert inspect_rendered_file(html, "html") == []
    assert inspect_rendered_file(docx, "docx") == []
    assert inspect_rendered_file(pdf, "pdf") == []


def test_format_inspection_rejects_invalid_outputs(tmp_path: Path) -> None:
    missing = tmp_path / "missing.md"
    assert "fichier absent" in inspect_rendered_file(missing, "markdown")[0]

    tiny = tmp_path / "tiny.md"
    tiny.write_text("x", encoding="utf-8")
    assert "trop petit" in inspect_rendered_file(tiny, "markdown")[0]

    markdown = tmp_path / "bad.md"
    markdown.write_text("texte sans titre " * 10, encoding="utf-8")
    assert "markdown sans titre" in inspect_rendered_file(markdown, "markdown")

    html = tmp_path / "bad.html"
    html.write_text("x" * 40, encoding="utf-8")
    failures = inspect_rendered_file(html, "html")
    assert "html sans balise <html>" in failures
    assert "html sans <title>" in failures

    docx = tmp_path / "bad.docx"
    docx.write_bytes(b"not-a-zip" * 8)
    assert "conteneur ZIP illisible" in inspect_rendered_file(docx, "docx")[0]

    pdf = tmp_path / "bad.pdf"
    pdf.write_bytes(b"NOTPDF" + b"x" * 64)
    assert "signature %PDF absente" in inspect_rendered_file(pdf, "pdf")[0]
    assert "format de publication inconnu" in inspect_rendered_file(pdf, "epub")[0]


def test_render_publication_builds_all_outputs_and_manifest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _project(tmp_path)
    source = project / "deliverables" / "docs" / "guide.qmd"
    source.parent.mkdir(parents=True)
    source.write_text("# Guide\n\nSource canonique.\n", encoding="utf-8")

    monkeypatch.setattr(publication, "_policy", _publication_policy)
    monkeypatch.setattr(publication.shutil, "which", lambda _name: "/usr/bin/quarto")
    monkeypatch.setattr(publication, "_tool_version", lambda *_args, **_kwargs: "test-1.0")

    def fake_render(
        source_path: Path,
        *,
        quarto: str,
        quarto_format: str,
        expected_extension: str,
        timeout: int,
    ) -> tuple[list[str], Path, str, str, int]:
        assert quarto == "/usr/bin/quarto"
        assert quarto_format
        assert timeout == 30
        generated = source_path.with_suffix(expected_extension)
        _write_rendered(generated)
        return [quarto, "render", source_path.name], generated, "ok", "", 0

    monkeypatch.setattr(publication, "_render_format", fake_render)
    manifest = publication.render_publication(project, source)

    payload = json.loads(manifest.read_text(encoding="utf-8"))
    assert payload["render_engine"] == "quarto"
    assert {item["kind"] for item in payload["outputs"]} == {
        "markdown",
        "html",
        "docx",
        "pdf",
    }
    assert payload["quality"]["sha256_manifest"] is True
    assert validate_publication_manifest(project, manifest) == []
    assert publication.project_publication_failures(project) == []


def test_render_publication_rejects_protected_source_and_invalid_configuration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _project(tmp_path)
    protected = project / "intake" / "guide.qmd"
    protected.parent.mkdir()
    protected.write_text("# Guide\n", encoding="utf-8")
    monkeypatch.setattr(publication, "_policy", _publication_policy)

    with pytest.raises(PermissionError, match="copier d'abord"):
        publication.render_publication(project, protected)

    source = project / "deliverables" / "guide.txt"
    source.parent.mkdir(exist_ok=True)
    source.write_text("texte", encoding="utf-8")
    with pytest.raises(ValueError, match="source .txt interdite"):
        publication.render_publication(project, source)

    qmd = source.with_suffix(".qmd")
    qmd.write_text("# Guide\n", encoding="utf-8")
    monkeypatch.setattr(publication.shutil, "which", lambda _name: None)
    with pytest.raises(FileNotFoundError, match="quarto introuvable"):
        publication.render_publication(project, qmd)

    monkeypatch.setattr(publication.shutil, "which", lambda _name: "/usr/bin/quarto")
    with pytest.raises(ValueError, match="timeout hors limites"):
        publication.render_publication(project, qmd, timeout=999)


def test_publication_manifest_detects_hash_drift(tmp_path: Path) -> None:
    project = _project(tmp_path)
    source = project / "deliverables" / "docs" / "guide.qmd"
    source.parent.mkdir(parents=True)
    source.write_text("# Guide\n\nSource canonique.\n", encoding="utf-8")
    rendered = source.parent / "rendered"
    rendered.mkdir()

    markdown = rendered / "guide.md"
    _write_rendered(markdown)
    html = rendered / "guide.html"
    _write_rendered(html)
    docx = rendered / "guide.docx"
    _write_rendered(docx)
    pdf = rendered / "guide.pdf"
    _write_rendered(pdf)

    import hashlib

    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    manifest = rendered / "publication_manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "source": {
                    "path": source.relative_to(project).as_posix(),
                    "sha256": digest(source),
                },
                "outputs": [
                    {
                        "kind": "markdown",
                        "path": markdown.relative_to(project).as_posix(),
                        "sha256": digest(markdown),
                    },
                    {
                        "kind": "html",
                        "path": html.relative_to(project).as_posix(),
                        "sha256": digest(html),
                    },
                    {
                        "kind": "docx",
                        "path": docx.relative_to(project).as_posix(),
                        "sha256": digest(docx),
                    },
                    {
                        "kind": "pdf",
                        "path": pdf.relative_to(project).as_posix(),
                        "sha256": digest(pdf),
                    },
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    assert validate_publication_manifest(project, manifest) == []
    pdf.write_bytes(b"%PDF-1.7\nchanged" + b"x" * 64)
    failures = validate_publication_manifest(project, manifest)
    assert any("SHA-256 divergent" in failure for failure in failures)


def test_publication_manifest_reports_missing_source_outputs_and_formats(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _project(tmp_path)
    monkeypatch.setattr(publication, "_policy", _publication_policy)
    manifest = project / "deliverables" / "publication_manifest.json"
    manifest.parent.mkdir()
    manifest.write_text(
        json.dumps(
            {
                "source": {"path": "missing.qmd", "sha256": "bad"},
                "outputs": [{"kind": "markdown", "path": "missing.md", "sha256": "bad"}],
            }
        ),
        encoding="utf-8",
    )
    failures = validate_publication_manifest(project, manifest)
    assert "manifest: source absente" in failures
    assert "markdown: sortie absente" in failures
    assert any("formats requis absents" in value for value in failures)


def test_render_task_diagrams_and_postprocess_use_bounded_helpers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _project(tmp_path)
    diagrams = project / "diagrams" / "task-doc"
    diagrams.mkdir(parents=True)
    (diagrams / "flow.mmd").write_text("flowchart TD\nA-->B\n", encoding="utf-8")
    (diagrams / "network.dot").write_text("digraph G { A -> B }", encoding="utf-8")

    calls: list[str] = []

    class Result:
        returncode = 0
        output_path = "diagrams/task-doc/generated.svg"

    def fake_tool(*_args: object, **kwargs: object) -> Result:
        calls.append(str(kwargs["tool_id"]))
        return Result()

    monkeypatch.setattr(publication, "run_specialist_tool", fake_tool)
    generated = publication.render_task_diagrams(
        project, task_id="task-doc", agent="architecte-solutions"
    )
    assert calls == ["mermaid_render_svg", "graphviz_render_svg"]
    assert generated

    deliverable = project / "deliverables" / "task-doc"
    deliverable.mkdir(parents=True)
    (deliverable / "guide.qmd").write_text("# Guide\n", encoding="utf-8")
    rendered = deliverable / "rendered"
    rendered.mkdir()
    manifest = rendered / "publication_manifest.json"
    output = rendered / "guide.pdf"
    output.write_bytes(b"%PDF-1.7\n" + b"x" * 64)
    manifest.write_text(
        json.dumps({"outputs": [{"kind": "pdf", "path": output.relative_to(project).as_posix()}]}),
        encoding="utf-8",
    )
    monkeypatch.setattr(publication, "render_task_diagrams", lambda *_a, **_k: ["diagram.svg"])
    monkeypatch.setattr(publication, "render_publication", lambda *_a, **_k: manifest)
    result = publication.postprocess_task_outputs(
        project, task_id="task-doc", agent="redacteur-technique"
    )
    assert "diagram.svg" in result
    assert manifest.relative_to(project).as_posix() in result
    assert output.relative_to(project).as_posix() in result
