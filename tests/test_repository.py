from __future__ import annotations

import sys
from pathlib import Path

import clawlocal.config as config
from clawlocal.config import load_contract


def test_eight_roles_have_routes() -> None:
    roles = load_contract("role_matrix.yaml")["roles"]
    routes = load_contract("model_routing.yaml")["agents"]
    assert len(roles) == 8
    assert set(roles) == set(routes)


def test_architecture_v2_defaults_to_local_only() -> None:
    routing = load_contract("model_routing.yaml")
    catalog = load_contract("model_catalog.yaml")
    platform = load_contract("platform.yaml")
    escalation = load_contract("escalation_policy.yaml")
    web = load_contract("web_policy.yaml")

    assert routing["local_only"] is True
    assert catalog["policy"]["local_only"] is True
    assert catalog["policy"]["cloud_models_supported"] is False
    assert "cloud_models" not in catalog

    assert "cloud" not in platform
    assert platform["llm_cloud"] == {
        "supported": False,
        "providers": [],
        "escalation_supported": False,
        "automatic_fallback": False,
    }
    assert escalation["llm_cloud"]["supported"] is False
    assert escalation["llm_cloud"]["default"] == "deny"
    assert escalation["llm_cloud"]["providers"] == []
    assert escalation["llm_cloud"]["escalation_supported"] is False
    assert web["remote_source_escalation"]["llm_reasoning_must_remain_local"] is True
    assert web["remote_source_escalation"]["llm_cloud_escalation_forbidden"] is True
    assert "cloud_escalation" not in web


def test_active_operator_docs_use_windows_repository_identity() -> None:
    root = Path(__file__).resolve().parents[1]
    readme = (root / "README.md").read_text(encoding="utf-8")
    install = (root / "docs" / "INSTALLATION_WINDOWS_11.md").read_text(encoding="utf-8")
    expected = "https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL_WINDOWS.git"
    assert expected in readme
    assert expected in install
    assert "git clone https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL.git" not in readme
    assert "git clone https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL.git" not in install


def test_finops_doc_does_not_advertise_cloud_llm_execution() -> None:
    root = Path(__file__).resolve().parents[1]
    text = (root / "docs" / "FINOPS.md").read_text(encoding="utf-8")
    assert "LLM cloud                  : NON SUPPORTÉ" in text
    assert "OPENROUTER_API_KEY" not in text
    assert "ajouter `--execute`" not in text


def test_local_provider_is_loopback() -> None:
    platform = load_contract("platform.yaml")
    assert platform["local_provider"]["base_url"].startswith("http://127.0.0.1:")


def test_repository_root_uses_explicit_runtime_contract(monkeypatch, tmp_path: Path) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    fake_module = tmp_path / "venv" / "Lib" / "site-packages" / "clawlocal" / "config.py"
    fake_module.parent.mkdir(parents=True)
    fake_module.write_text("# installed package placeholder\n", encoding="utf-8")

    monkeypatch.setattr(config, "__file__", str(fake_module))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["python"])
    monkeypatch.setenv("OPENCLAW_LOCAL_REPO_ROOT", str(repo_root))

    assert config.repository_root() == repo_root


def test_repository_root_recovers_from_repo_script_when_package_is_installed(
    monkeypatch, tmp_path: Path
) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    fake_module = tmp_path / "venv" / "Lib" / "site-packages" / "clawlocal" / "config.py"
    fake_module.parent.mkdir(parents=True)
    fake_module.write_text("# installed package placeholder\n", encoding="utf-8")

    monkeypatch.delenv("OPENCLAW_LOCAL_REPO_ROOT", raising=False)
    monkeypatch.setattr(config, "__file__", str(fake_module))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [str(repo_root / "scripts" / "20_list_models.py")])

    assert config.repository_root() == repo_root
    assert load_contract("model_catalog.yaml")["models"]
