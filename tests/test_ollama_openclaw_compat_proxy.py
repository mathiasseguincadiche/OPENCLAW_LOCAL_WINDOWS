from __future__ import annotations

import importlib.util
import pathlib
import types

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "55_ollama_openclaw_compat_proxy.py"
STRICT_MODEL = "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M"


def load_script() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("ollama_openclaw_compat_proxy", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_ministral_adjacent_user_messages_are_merged_without_mutating_input() -> None:
    module = load_script()
    payload = {
        "model": STRICT_MODEL,
        "messages": [
            {"role": "system", "content": "system-secret"},
            {"role": "user", "content": "bootstrap-secret"},
            {"role": "user", "content": "prompt-secret"},
        ],
        "tools": [{"type": "function", "function": {"name": "ping"}}],
        "options": {"num_ctx": 16384},
    }

    normalized, merged = module.normalize_ministral_messages(payload)

    assert merged == 1
    assert module.role_sequence(payload) == ["system", "user", "user"]
    assert module.role_sequence(normalized) == ["system", "user"]
    assert normalized["messages"][1]["content"] == "bootstrap-secret\n\nprompt-secret"
    assert normalized["tools"] == payload["tools"]
    assert normalized["options"] == payload["options"]


def test_other_models_are_forwarded_unchanged() -> None:
    module = load_script()
    payload = {
        "model": "qwen3.5:9b-q4_K_M",
        "messages": [
            {"role": "system", "content": "system"},
            {"role": "user", "content": "first"},
            {"role": "user", "content": "second"},
        ],
    }

    normalized, merged = module.normalize_ministral_messages(payload)

    assert normalized is payload
    assert merged == 0


def test_conflicting_user_metadata_fails_closed() -> None:
    module = load_script()
    payload = {
        "model": STRICT_MODEL,
        "messages": [
            {"role": "user", "content": "first", "custom": "a"},
            {"role": "user", "content": "second", "custom": "b"},
        ],
    }

    with pytest.raises(ValueError, match="métadonnée user conflictuelle"):
        module.normalize_ministral_messages(payload)


def test_non_text_user_content_fails_closed() -> None:
    module = load_script()
    payload = {
        "model": STRICT_MODEL,
        "messages": [
            {"role": "user", "content": "first"},
            {"role": "user", "content": [{"type": "text", "text": "second"}]},
        ],
    }

    with pytest.raises(ValueError, match="content user non textuel"):
        module.normalize_ministral_messages(payload)


def test_upstream_health_probe_requires_successful_local_ollama(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = load_script()
    observed: dict[str, object] = {}

    class FakeResponse:
        status = 200

    class FakeConnection:
        def __init__(self, host: str, port: int, timeout: int) -> None:
            observed["host"] = host
            observed["port"] = port
            observed["timeout"] = timeout

        def request(
            self,
            method: str,
            path: str,
            headers: dict[str, str],
        ) -> None:
            observed["method"] = method
            observed["path"] = path
            observed["headers"] = headers

        def getresponse(self) -> FakeResponse:
            return FakeResponse()

        def close(self) -> None:
            observed["closed"] = True

    monkeypatch.setattr(module.http.client, "HTTPConnection", FakeConnection)

    assert module.probe_upstream_ready() is True
    assert observed["host"] == "127.0.0.1"
    assert observed["port"] == 11434
    assert observed["path"] == "/api/tags"
    assert observed["closed"] is True


def test_upstream_health_probe_fails_closed_on_connection_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = load_script()

    class FailingConnection:
        def __init__(self, host: str, port: int, timeout: int) -> None:
            del host, port, timeout

        def request(
            self,
            method: str,
            path: str,
            headers: dict[str, str],
        ) -> None:
            del method, path, headers
            raise ConnectionRefusedError("local Ollama unavailable")

        def close(self) -> None:
            return

    monkeypatch.setattr(module.http.client, "HTTPConnection", FailingConnection)

    assert module.probe_upstream_ready() is False


def test_proxy_contract_is_loopback_and_prompt_text_is_not_part_of_health() -> None:
    module = load_script()

    assert module.LISTEN_HOST == "127.0.0.1"
    assert module.DEFAULT_LISTEN_PORT == 11436
    assert module.UPSTREAM_URL == "http://127.0.0.1:11434"
    assert module.HEALTH_PATH == "/__openclaw_compat_health"
    assert module.STRICT_MODEL == STRICT_MODEL
    assert (
        module.safe_response_content_type("application/json; charset=utf-8")
        == "application/json"
    )
    assert (
        module.safe_response_content_type("application/x-ndjson")
        == "application/x-ndjson"
    )
    assert (
        module.safe_response_content_type("text/plain\r\nInjected: yes")
        == "application/octet-stream"
    )
