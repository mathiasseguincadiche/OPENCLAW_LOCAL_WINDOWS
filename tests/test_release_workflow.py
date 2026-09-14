from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


def test_release_workflow_requires_validated_commit_on_main() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    fetch_main = "git fetch --no-tags origin main:refs/remotes/origin/main"
    ancestry = "git merge-base --is-ancestor HEAD origin/main"
    hardening = "python scripts/47_validate_pre_v1_hardening.py"
    readiness = 'python scripts/24_validate_release.py --tag "${RELEASE_TAG}"'
    build = "python -m build"

    assert fetch_main in text
    assert ancestry in text
    assert "github.actor == github.repository_owner" in text
    assert '[[ "${ISSUE_TITLE}" == "Release ${expected_tag}" ]]' in text
    assert 'target_sha="$(git rev-parse refs/remotes/origin/main)"' in text
    assert text.index(ancestry) < text.index(hardening) < text.index(readiness)
    assert text.index(readiness) < text.index(build)


def test_release_publish_depends_on_authorization_and_validations() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "needs: [authorize, validate-python, validate-windows]" in text
    assert "if: needs.authorize.outputs.request_mode == 'issue'" in text
    assert '-f ref="refs/tags/${RELEASE_TAG}"' in text
    assert '-f sha="${RELEASE_SHA}"' in text
    assert 'gh release create "${RELEASE_TAG}"' in text


def test_release_actions_are_pinned_to_full_commit_sha() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    uses_lines = [line.strip() for line in text.splitlines() if "uses:" in line]
    assert uses_lines
    for line in uses_lines:
        match = re.search(r"uses:\s+[^@\s]+@([0-9a-f]{40})(?:\s|$)", line)
        assert match is not None, f"GitHub Action non pinée sur SHA 40 hex: {line}"
