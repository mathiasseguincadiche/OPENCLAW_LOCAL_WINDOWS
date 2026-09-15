from __future__ import annotations

import argparse
import copy
import http.client
import http.server
import json
import sys
import typing
import urllib.parse

LISTEN_HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 11436
UPSTREAM_URL = "http://127.0.0.1:11434"
STRICT_MODEL = "hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M"
HEALTH_PATH = "/__openclaw_compat_health"
READ_CHUNK_BYTES = 64 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Proxy local OpenClaw -> Ollama dédié à la compatibilité du template "
            "Ministral strict. Il ne journalise jamais le texte des prompts."
        )
    )
    parser.add_argument(
        "--listen-port",
        type=int,
        default=DEFAULT_LISTEN_PORT,
        choices=range(1025, 65536),
        metavar="PORT",
    )
    return parser.parse_args()


def safe_response_content_type(value: str | None) -> str:
    normalized = (value or "").strip().lower()
    if normalized.startswith("application/x-ndjson"):
        return "application/x-ndjson"
    if normalized.startswith("application/json"):
        return "application/json"
    if normalized.startswith("text/event-stream"):
        return "text/event-stream"
    return "application/octet-stream"


def role_sequence(payload: typing.Any) -> list[str]:
    if not isinstance(payload, dict):
        return []
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return []
    roles: list[str] = []
    for message in messages:
        if isinstance(message, dict):
            roles.append(str(message.get("role", "<missing>")))
        else:
            roles.append("<non-object>")
    return roles


def _merge_user_message(target: dict[str, typing.Any], source: dict[str, typing.Any]) -> None:
    target_content = target.get("content", "")
    source_content = source.get("content", "")
    if not isinstance(target_content, str) or not isinstance(source_content, str):
        raise ValueError("content user non textuel")

    for key in ("tool_calls", "tool_name", "tool_call_id"):
        if target.get(key) or source.get(key):
            raise ValueError(f"champ outil inattendu sur message user: {key}")

    if target_content and source_content:
        target["content"] = target_content + "\n\n" + source_content
    else:
        target["content"] = target_content + source_content

    source_images = source.get("images")
    if source_images is not None:
        if not isinstance(source_images, list):
            raise ValueError("images user doit être une liste")
        target_images = target.get("images")
        if target_images is None:
            target["images"] = list(source_images)
        elif isinstance(target_images, list):
            target["images"] = list(target_images) + list(source_images)
        else:
            raise ValueError("images user cible doit être une liste")

    ignored_keys = {"role", "content", "images"}
    for key, value in source.items():
        if key in ignored_keys:
            continue
        if key not in target:
            target[key] = copy.deepcopy(value)
            continue
        if target[key] == value or value in (None, "", [], {}):
            continue
        if target[key] in (None, "", [], {}):
            target[key] = copy.deepcopy(value)
            continue
        raise ValueError(f"métadonnée user conflictuelle: {key}")


def normalize_ministral_messages(
    payload: typing.Any,
) -> tuple[typing.Any, int]:
    if not isinstance(payload, dict):
        return payload, 0
    if payload.get("model") != STRICT_MODEL:
        return payload, 0

    raw_messages = payload.get("messages")
    if not isinstance(raw_messages, list):
        raise ValueError("messages absent ou non liste pour Ministral")

    normalized = copy.deepcopy(payload)
    normalized_messages = normalized.get("messages")
    if not isinstance(normalized_messages, list):
        raise ValueError("messages normalisés non liste")

    output: list[typing.Any] = []
    merged = 0
    for message in normalized_messages:
        if (
            isinstance(message, dict)
            and message.get("role") == "user"
            and output
            and isinstance(output[-1], dict)
            and output[-1].get("role") == "user"
        ):
            _merge_user_message(output[-1], message)
            merged += 1
            continue
        output.append(message)

    normalized["messages"] = output
    return normalized, merged


class CompatProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = urllib.parse.urlsplit(UPSTREAM_URL)

    def log_message(self, _format: str, *_args: typing.Any) -> None:
        return

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length > 0 else b""

    def _send_json(self, status: int, payload: dict[str, typing.Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _health(self) -> None:
        self._send_json(
            200,
            {
                "ok": True,
                "mode": "ministral-adjacent-user-normalization",
                "model": STRICT_MODEL,
                "upstream": UPSTREAM_URL,
            },
        )

    def _proxy(self) -> None:
        if self.path == HEALTH_PATH:
            self._health()
            return

        request_body = self._read_body()
        if self.path.startswith("/api/chat") and request_body:
            try:
                payload = json.loads(request_body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._send_json(400, {"error": "invalid /api/chat JSON"})
                return

            if isinstance(payload, dict) and payload.get("model") == STRICT_MODEL:
                before = role_sequence(payload)
                try:
                    normalized, merged = normalize_ministral_messages(payload)
                except ValueError as exc:
                    print(
                        f"OLLAMA_COMPAT_REJECT model={STRICT_MODEL} reason={exc}",
                        file=sys.stderr,
                        flush=True,
                    )
                    self._send_json(
                        422,
                        {"error": "Ministral role normalization rejected request"},
                    )
                    return
                if merged > 0:
                    after = role_sequence(normalized)
                    request_body = json.dumps(
                        normalized,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ).encode("utf-8")
                    print(
                        "OLLAMA_COMPAT_NORMALIZED "
                        f"model={STRICT_MODEL} merged={merged} "
                        f"roles_before={'>'.join(before)} roles_after={'>'.join(after)}",
                        flush=True,
                    )

        target_path = self.path
        headers = {"Accept": "application/json, application/x-ndjson"}
        if request_body:
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(request_body))

        connection = http.client.HTTPConnection(
            self.upstream.hostname,
            self.upstream.port,
            timeout=600,
        )
        try:
            connection.request(self.command, target_path, body=request_body, headers=headers)
            response = connection.getresponse()
            self.send_response(response.status)
            self.send_header(
                "Content-Type",
                safe_response_content_type(response.getheader("Content-Type")),
            )
            self.send_header("Connection", "close")
            self.end_headers()

            if self.command != "HEAD":
                while True:
                    chunk = response.read(READ_CHUNK_BYTES)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            self.close_connection = True
        except Exception as exc:
            print(
                f"OLLAMA_COMPAT_PROXY_ERROR type={type(exc).__name__} detail={exc}",
                file=sys.stderr,
                flush=True,
            )
            if not self.wfile.closed:
                try:
                    self._send_json(502, {"error": "local Ollama compatibility proxy failure"})
                except OSError:
                    pass
        finally:
            connection.close()

    do_GET = _proxy
    do_POST = _proxy
    do_HEAD = _proxy


def main() -> int:
    args = parse_args()
    server = http.server.ThreadingHTTPServer(
        (LISTEN_HOST, args.listen_port),
        CompatProxyHandler,
    )
    print(
        f"OLLAMA_COMPAT_READY=http://{LISTEN_HOST}:{args.listen_port} "
        f"upstream={UPSTREAM_URL} model={STRICT_MODEL}",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
