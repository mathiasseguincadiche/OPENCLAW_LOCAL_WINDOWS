from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def _render_patch(tmp_path: Path, backend: str = "ollama-vulkan") -> dict[str, object]:
    result = subprocess.run(
        [
            sys.executable,
            "scripts/26_render_openclaw_config.py",
            "--platform-root",
            str(tmp_path),
            "--backend",
            backend,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    assert isinstance(payload, dict)
    return payload


def test_renderer_explicitly_disables_unbounded_skill_cards(tmp_path: Path) -> None:
    patch = _render_patch(tmp_path)

    skills = patch["skills"]
    assert isinstance(skills, dict)
    assert skills == {"limits": {"maxSkillsPromptChars": 0}}

    agents = patch["agents"]
    assert isinstance(agents, dict)

    defaults = agents["defaults"]
    assert isinstance(defaults, dict)
    assert defaults.get("skills") == []

    roster = agents["list"]
    assert isinstance(roster, list)
    assert len(roster) == 8
    assert all(isinstance(entry, dict) and entry.get("skills") == [] for entry in roster)


def test_prompt_budget_fix_preserves_local_models_and_tool_policy(tmp_path: Path) -> None:
    patch = _render_patch(tmp_path)

    models_section = patch["models"]
    assert isinstance(models_section, dict)
    provider_map = models_section["providers"]
    assert isinstance(provider_map, dict)
    assert set(provider_map) == {"ollama", "ollama-ministral"}

    all_models: list[dict[str, object]] = []
    for provider_id in ("ollama", "ollama-ministral"):
        provider = provider_map[provider_id]
        assert isinstance(provider, dict)
        models = provider["models"]
        assert isinstance(models, list)
        assert all(isinstance(model, dict) for model in models)
        all_models.extend(models)

    assert len(all_models) == 3
    assert all(
        model.get("contextWindow") == 16384
        and model.get("contextTokens") == 16384
        for model in all_models
    )

    tools = patch["tools"]
    assert isinstance(tools, dict)
    assert tools["profile"] == "minimal"
    tool_search = tools["toolSearch"]
    assert isinstance(tool_search, dict)
    assert tool_search["enabled"] is True
    assert tool_search["mode"] == "tools"

    assert "openrouter/" not in json.dumps(patch)
