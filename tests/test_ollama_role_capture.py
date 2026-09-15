from __future__ import annotations

import importlib.util
import pathlib
import types

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "54_capture_ollama_request_roles.py"
STRICT_MODEL = "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M"


def load_script() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("ollama_role_capture", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_request_shape_keeps_roles_and_drops_prompt_text() -> None:
    module = load_script()
    shape = module.request_shape(
        {
            "model": "example-model",
            "messages": [
                {"role": "system", "content": "secret-system-text"},
                {"role": "user", "content": "secret-user-text"},
                {"role": "user", "content": "second-secret-user-text"},
            ],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "ping",
                        "description": "secret-description",
                        "parameters": {"type": "object"},
                    },
                }
            ],
            "options": {"num_ctx": 16384, "num_predict": 256},
            "stream": True,
            "think": False,
            "truncate": False,
            "shift": False,
        }
    )

    assert shape["roles"] == ["system", "user", "user"]
    assert shape["duplicate_non_tool_roles"] == [
        {"previous_index": 1, "index": 2, "role": "user"}
    ]
    assert shape["tool_names"] == ["ping"]
    assert shape["num_ctx"] == 16384
    assert all("content" not in message for message in shape["messages"])
    serialized = repr(shape)
    assert "secret-system-text" not in serialized
    assert "secret-user-text" not in serialized
    assert "secret-description" not in serialized


def test_normalization_merges_adjacent_user_only_for_exact_model() -> None:
    module = load_script()
    payload = {
        "model": STRICT_MODEL,
        "messages": [
            {"role": "system", "content": "system"},
            {"role": "user", "content": "bootstrap"},
            {"role": "user", "content": "prompt"},
        ],
        "tools": [{"type": "function", "function": {"name": "ping"}}],
    }

    normalized, metadata = module.normalize_adjacent_user_messages(
        payload,
        {STRICT_MODEL},
    )

    assert metadata == {
        "eligible": True,
        "applied": True,
        "merged_user_messages": 1,
    }
    assert [message["role"] for message in normalized["messages"]] == [
        "system",
        "user",
    ]
    assert normalized["messages"][1]["content"] == "bootstrap\n\nprompt"
    assert normalized["tools"] == payload["tools"]
    assert [message["role"] for message in payload["messages"]] == [
        "system",
        "user",
        "user",
    ]


def test_normalization_is_noop_for_other_model() -> None:
    module = load_script()
    payload = {
        "model": "qwen3.5:9b-q4_K_M",
        "messages": [
            {"role": "system", "content": "system"},
            {"role": "user", "content": "first"},
            {"role": "user", "content": "second"},
        ],
    }

    normalized, metadata = module.normalize_adjacent_user_messages(
        payload,
        {STRICT_MODEL},
    )

    assert normalized is payload
    assert metadata == {
        "eligible": False,
        "applied": False,
        "merged_user_messages": 0,
    }


def test_normalization_fails_closed_on_conflicting_user_metadata() -> None:
    module = load_script()
    payload = {
        "model": STRICT_MODEL,
        "messages": [
            {"role": "user", "content": "first", "custom": "a"},
            {"role": "user", "content": "second", "custom": "b"},
        ],
    }

    with pytest.raises(ValueError, match="champ conflictuel custom"):
        module.normalize_adjacent_user_messages(payload, {STRICT_MODEL})


def test_response_content_type_is_reduced_to_safe_constants() -> None:
    module = load_script()

    assert (
        module.safe_response_content_type("application/json; charset=utf-8")
        == "application/json"
    )
    assert module.safe_response_content_type("application/x-ndjson") == "application/x-ndjson"
    assert (
        module.safe_response_content_type("text/event-stream; charset=utf-8")
        == "text/event-stream"
    )
    assert (
        module.safe_response_content_type("text/plain\r\nX-Injected: yes")
        == "application/octet-stream"
    )
    assert module.safe_response_content_type(None) == "application/octet-stream"
