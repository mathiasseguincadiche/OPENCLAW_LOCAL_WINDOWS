from __future__ import annotations

import importlib.util
import pathlib
import types

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "54_capture_ollama_request_roles.py"


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
