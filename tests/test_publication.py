from __future__ import annotations

import json
import zipfile
from pathlib import Path

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


def test_publication_manifest_detects_hash_drift(tmp_path: Path) -> None:
    project = _project(tmp_path)
    source = project / "deliverables" / "docs" / "guide.qmd"
    source.parent.mkdir(parents=True)
    source.write_text("# Guide\n\nSource canonique.\n", encoding="utf-8")
    rendered = source.parent / "rendered"
    rendered.mkdir()

    markdown = rendered / "guide.md"
    markdown.write_text(
        "# Guide\n\n" + ("Documentation technique exploitable et vérifiable. " * 4),
        encoding="utf-8",
    )
    html = rendered / "guide.html"
    html.write_text(
        "<html><head><title>Guide</title></head><body>ok</body></html>",
        encoding="utf-8",
    )
    docx = rendered / "guide.docx"
    _docx(docx)
    pdf = rendered / "guide.pdf"
    pdf.write_bytes(b"%PDF-1.7\n" + b"x" * 64)

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
