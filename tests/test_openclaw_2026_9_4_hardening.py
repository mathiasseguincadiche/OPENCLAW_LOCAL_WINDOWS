from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARALLEL_SRI = (
    "sha512-/6XIzmiF1iJtXzKYZxO+v92xTzOvTnSQJh89tTQfpZkyk5SxsaQtBAeBwFT7sv3blGIYhGEVhs3+"
    "hf4rKVIqtA=="
)
NODE_WIN_X64_SHA256 = (
    "089a02c4c687451c9f0b7f1bfd252dae"
    "85a7ba27df0295a14096bdcc956fdc92"
)


def _runtime_lock() -> dict[str, object]:
    return json.loads(
        (ROOT / "config" / "v1" / "runtime_versions.json").read_text(
            encoding="utf-8"
        )
    )


def test_parallel_plugin_has_exact_published_sri() -> None:
    runtime = _runtime_lock()
    parallel = runtime["openclaw"]["plugins"]["parallel"]  # type: ignore[index]
    assert parallel["package"] == "@openclaw/parallel-plugin"
    assert parallel["preferred"] == "2026.9.4"
    assert parallel["integrity"] == PARALLEL_SRI


def test_node_26_floor_matches_openclaw_engine_contract() -> None:
    runtime = _runtime_lock()
    node = runtime["node"]  # type: ignore[index]
    assert node["preferred"] == "26.1.0"
    assert node["sha256_win_x64_zip"] == NODE_WIN_X64_SHA256
    node26 = [item for item in node["supported"] if item["major"] == 26]
    assert node26 == [{"major": 26, "minimum": "26.1.0"}]


def test_ci_and_release_share_the_npm_integrity_verifier() -> None:
    ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )
    marker = "python scripts/50_verify_npm_integrities.py"
    assert marker in ci
    assert marker in release
    assert "--artifact-dir artifacts/npm-smoke" in ci
    assert 'node-version: "26.1.0"' in ci
    assert 'node-version: "26.1.0"' in release
    assert release.index(marker) < release.index("python -m build")


def test_readonly_write_window_is_fail_closed() -> None:
    guard = (
        ROOT / "scripts" / "windows" / "lib" / "openclaw_readonly.ps1"
    ).read_text(encoding="utf-8")
    install = (ROOT / "scripts" / "windows" / "11_install_full.ps1").read_text(
        encoding="utf-8"
    )
    menu = (ROOT / "menu.ps1").read_text(encoding="utf-8")

    assert "$env:OPENCLAW_CONFIG_READONLY = '0'" in guard
    assert "finally" in guard
    assert "Set-OpenClawReadOnlySteadyState" in guard
    assert "Assert-OpenClawReadOnlySteadyState" in guard
    assert "Invoke-OpenClawConfigWriteWindow" in install
    assert install.count("Assert-OpenClawReadOnlySteadyState") >= 3
    assert "08_configure_openclaw_guarded.ps1" in menu
