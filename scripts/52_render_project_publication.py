from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _activate_repository_sources() -> None:
    root = Path(__file__).resolve().parents[1]
    src = str(root / "src")
    if src not in sys.path:
        sys.path.insert(0, src)


def main() -> int:
    _activate_repository_sources()
    from clawlocal.publication import render_publication, validate_publication_manifest

    parser = argparse.ArgumentParser(
        description="Rend une source QMD en Markdown, HTML, DOCX et PDF puis vérifie le manifest."
    )
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir")
    parser.add_argument("--timeout", type=int)
    args = parser.parse_args()

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
    raise SystemExit(main())
