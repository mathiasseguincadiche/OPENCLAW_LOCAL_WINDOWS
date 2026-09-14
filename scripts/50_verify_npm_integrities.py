from __future__ import annotations

import argparse
import base64
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "config" / "v1" / "runtime_versions.json"


def _run(*args: str, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        list(args),
        cwd=cwd,
        check=False,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"commande en échec: {' '.join(args)}\n{detail}")
    return completed.stdout.strip()


def _sha512_sri(path: Path) -> str:
    digest = hashlib.sha512()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha512-" + base64.b64encode(digest.digest()).decode("ascii")


def _verify_package(
    package: str,
    version: str,
    expected: str,
    artifact_dir: Path | None,
) -> None:
    if not expected.startswith("sha512-"):
        raise RuntimeError(f"{package}@{version}: SRI sha512 absent du runtime lock")

    spec = f"{package}@{version}"
    registry = _run("npm", "view", spec, "dist.integrity").strip()
    if registry != expected:
        raise RuntimeError(
            f"{spec}: dist.integrity npm différent du lock\n"
            f"lock={expected}\nregistry={registry}"
        )

    with tempfile.TemporaryDirectory(prefix="openclaw-npm-") as tmp:
        temp_dir = Path(tmp)
        raw = _run("npm", "pack", spec, "--ignore-scripts", "--json", cwd=temp_dir)
        payload = json.loads(raw)
        if not isinstance(payload, list) or len(payload) != 1:
            raise RuntimeError(f"{spec}: sortie npm pack JSON inattendue")
        filename = payload[0].get("filename")
        if not isinstance(filename, str) or not filename:
            raise RuntimeError(f"{spec}: npm pack n'a pas retourné de tarball")
        tarball = temp_dir / filename
        if not tarball.is_file():
            raise RuntimeError(f"{spec}: tarball npm introuvable: {tarball}")

        computed = _sha512_sri(tarball)
        if computed != expected:
            raise RuntimeError(
                f"{spec}: SHA-512 du tarball différent du lock\n"
                f"lock={expected}\ntarball={computed}"
            )

        npm_pack_integrity = payload[0].get("integrity")
        if npm_pack_integrity and npm_pack_integrity != expected:
            raise RuntimeError(
                f"{spec}: intégrité déclarée par npm pack différente du lock"
            )

        if artifact_dir is not None:
            artifact_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(tarball, artifact_dir / filename)

    print(f"OK  {spec}: lock == registre npm == tarball ({expected})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path)
    args = parser.parse_args()

    runtime = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    openclaw = runtime["openclaw"]
    parallel = openclaw["plugins"]["parallel"]

    _verify_package(
        str(openclaw["package"]),
        str(openclaw["preferred"]),
        str(openclaw["integrity"]),
        args.artifact_dir,
    )
    _verify_package(
        str(parallel["package"]),
        str(parallel["preferred"]),
        str(parallel["integrity"]),
        args.artifact_dir,
    )
    print("NPM integrity gate: CONFORME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
