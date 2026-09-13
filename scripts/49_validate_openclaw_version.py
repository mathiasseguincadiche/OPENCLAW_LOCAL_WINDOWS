from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_LOCK = ROOT / "config" / "v1" / "runtime_versions.json"

EXPECTED_OPENCLAW_VERSION = "2026.9.4"
EXPECTED_OPENCLAW_RELEASE_SHA = "3a9d69db306cd7f081e06254cb89c4bcc14a7107"
EXPECTED_OPENCLAW_INTEGRITY = (
    "sha512-lTQpEEe1Xm3u2PCHaPEr+vP8paGk1vLdHuzdItsNToaLI6hAqRVvgJYg+GxukJhETJp4tPy/"
    "S1Gftl4KuB8n7A=="
)
EXPECTED_PARALLEL_PACKAGE = "@openclaw/parallel-plugin"
EXPECTED_PARALLEL_INTEGRITY = (
    "sha512-/6XIzmiF1iJtXzKYZxO+v92xTzOvTnSQJh89tTQfpZkyk5SxsaQtBAeBwFT7sv3blGIYhGEVhs3+"
    "hf4rKVIqtA=="
)

ACTIVE_ROOTS = (ROOT / "config", ROOT / "src", ROOT / "scripts", ROOT / "tests", ROOT / "docs")
ACTIVE_TOP_LEVEL = (ROOT / "README.md", ROOT / "STATUS.md", ROOT / "menu.ps1", ROOT / "START_MENU.cmd")
TEXT_SUFFIXES = {".json", ".yaml", ".yml", ".py", ".ps1", ".md", ".toml", ".cmd"}
HISTORICAL_PARTS = {"adr", "adrs", "architecture_decisions"}


def _load_runtime_lock() -> dict[str, object]:
    data = json.loads(RUNTIME_LOCK.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("runtime_versions.json: racine JSON invalide")
    return data


def _iter_active_text_files() -> list[Path]:
    files: set[Path] = set()
    for root in ACTIVE_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
                continue
            relative_parts = {part.lower() for part in path.relative_to(ROOT).parts}
            if relative_parts & HISTORICAL_PARTS:
                continue
            files.add(path)
    for path in ACTIVE_TOP_LEVEL:
        if path.is_file():
            files.add(path)
    return sorted(files)


def main() -> int:
    failures: list[str] = []
    runtime = _load_runtime_lock()
    openclaw = runtime.get("openclaw")
    if not isinstance(openclaw, dict):
        failures.append("runtime_versions.json: section openclaw absente ou invalide")
        openclaw = {}

    if openclaw.get("package") != "openclaw":
        failures.append("OpenClaw: package npm canonique attendu=openclaw")
    if openclaw.get("preferred") != EXPECTED_OPENCLAW_VERSION:
        failures.append(f"OpenClaw: version verrouillée attendue={EXPECTED_OPENCLAW_VERSION}, reçue={openclaw.get('preferred')}")
    if openclaw.get("release_sha") != EXPECTED_OPENCLAW_RELEASE_SHA:
        failures.append("OpenClaw: release_sha ne correspond pas à 2026.9.4")
    if openclaw.get("integrity") != EXPECTED_OPENCLAW_INTEGRITY:
        failures.append("OpenClaw: npm SRI ne correspond pas à l'artefact 2026.9.4 verrouillé")

    plugins = openclaw.get("plugins")
    if not isinstance(plugins, dict):
        failures.append("OpenClaw: section plugins absente ou invalide")
        plugins = {}
    parallel = plugins.get("parallel")
    if not isinstance(parallel, dict):
        failures.append("OpenClaw: contrat plugin Parallel absent ou invalide")
        parallel = {}
    if parallel.get("package") != EXPECTED_PARALLEL_PACKAGE:
        failures.append("OpenClaw: package Parallel officiel inattendu")
    if parallel.get("preferred") != EXPECTED_OPENCLAW_VERSION:
        failures.append(f"OpenClaw: Parallel doit être aligné exactement sur {EXPECTED_OPENCLAW_VERSION}")
    if parallel.get("integrity") != EXPECTED_PARALLEL_INTEGRITY:
        failures.append("OpenClaw: SRI exact de @openclaw/parallel-plugin@2026.9.4 absent ou inattendu")

    verifier = ROOT / "scripts" / "50_verify_npm_integrities.py"
    if not verifier.is_file():
        failures.append("scripts/50_verify_npm_integrities.py absent")

    stale_version = "2026.9." + "2"
    for path in _iter_active_text_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        if stale_version in text:
            failures.append(f"version OpenClaw obsolète interdite dans surface active: {path.relative_to(ROOT)}")

    operator_contracts = {
        "scripts/windows/00_bootstrap.ps1": "Lock.openclaw.preferred",
        "scripts/windows/08_configure_openclaw.ps1": "RuntimeLock.openclaw.preferred",
        "scripts/windows/10_test_openclaw_e2e.ps1": "RuntimeLock.openclaw.preferred",
    }
    for relative, marker in operator_contracts.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"contrat opérateur OpenClaw absent: {relative}")
            continue
        if marker not in path.read_text(encoding="utf-8"):
            failures.append(f"{relative}: doit dériver la version OpenClaw du runtime lock canonique")

    integration_doc = ROOT / "docs" / "OPENCLAW_INTEGRATION.md"
    if not integration_doc.is_file():
        failures.append("docs/OPENCLAW_INTEGRATION.md absent")
    elif EXPECTED_OPENCLAW_VERSION not in integration_doc.read_text(encoding="utf-8"):
        failures.append("docs/OPENCLAW_INTEGRATION.md doit annoncer explicitement OpenClaw 2026.9.4")

    if failures:
        for failure in failures:
            print(f"KO  {failure}")
        print(f"\nVerdict: KO ({len(failures)} anomalie(s))")
        return 2

    print("OpenClaw Version Gate: CONFORME")
    print(f"- OpenClaw verrouillé exactement: {EXPECTED_OPENCLAW_VERSION}")
    print(f"- release SHA: {EXPECTED_OPENCLAW_RELEASE_SHA}")
    print("- npm SRI OpenClaw exact validé")
    print(f"- Parallel aligné exactement: {EXPECTED_OPENCLAW_VERSION}")
    print("- npm SRI Parallel exact validé")
    print("- aucune référence active à la version OpenClaw obsolète détectée")
    print("- bootstrap/configuration/E2E dérivent tous du runtime lock canonique")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
