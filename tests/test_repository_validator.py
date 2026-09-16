from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "scripts" / "21_validate_repository.py"


def load_validator() -> ModuleType:
    spec = importlib.util.spec_from_file_location("repository_validator", VALIDATOR_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(root: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def test_forbidden_scan_ignores_untracked_venv_files(tmp_path: Path) -> None:
    validator = load_validator()
    git(tmp_path, "init")

    (tmp_path / ".gitignore").write_text(".venv/\n", encoding="utf-8")
    (tmp_path / "safe.txt").write_text("safe\n", encoding="utf-8")
    certificate = tmp_path / ".venv" / "Lib" / "site-packages" / "certifi" / "cacert.pem"
    certificate.parent.mkdir(parents=True)
    certificate.write_text("ignored certificate\n", encoding="utf-8")

    git(tmp_path, "add", ".gitignore", "safe.txt")

    tracked = {
        path.relative_to(tmp_path).as_posix()
        for path in validator.get_tracked_files(tmp_path)
    }
    assert tracked == {".gitignore", "safe.txt"}
    assert validator.find_forbidden_tracked_files(tmp_path) == []


def test_forbidden_scan_flags_forbidden_file_in_git_index(tmp_path: Path) -> None:
    validator = load_validator()
    git(tmp_path, "init")

    forbidden = tmp_path / "tracked-secret.pem"
    forbidden.write_text("tracked secret\n", encoding="utf-8")
    git(tmp_path, "add", "tracked-secret.pem")

    detected = [
        path.relative_to(tmp_path).as_posix()
        for path in validator.find_forbidden_tracked_files(tmp_path)
    ]
    assert detected == ["tracked-secret.pem"]
