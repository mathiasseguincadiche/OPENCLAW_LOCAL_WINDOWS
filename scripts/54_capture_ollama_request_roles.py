from __future__ import annotations

import argparse
import datetime
import http.client
import http.server
import json
import pathlib
import threading
import typing
import urllib.parse


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Proxy Ollama local de diagnostic. Il journalise uniquement la forme "
            "des requêtes /api/chat (rôles, tailles, outils), jamais le texte des prompts."
        )
    )
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=11435)
    parser.add_argument("--upstream", default="http://127.0.0.1:11434")
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def utc_now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def safe_len(value: typing.Any) -> int:
    if isinstance(value, str):
        return len(value)
    if value is None:
        return 0
    try:
        return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    except (TypeError, ValueError):
        return 0


def request_shape(payload: typing.Any) -> dict[str, typing.Any]:
    if not isinstance(payload, dict):
        return {"json_object": False}

    raw_messages = payload.get("messages")
    messages = raw_messages if isinstance(raw_messages, list) else []
    shapes: list[dict[str, typing.Any]] = []
    roles: list[str] = []
    for index, message in enumerate(messages):
        if not isinstance(message, dict):
            roles.append("<non-object>")
            shapes.append({"index": index, "role": "<non-object>"})
            continue
        role = str(message.get("role", "<missing>"))
        roles.append(role)
        tool_calls = message.get("tool_calls")
        tool_call_count = len(tool_calls) if isinstance(tool_calls, list) else 0
        shapes.append(
            {
                "index": index,
                "role": role,
                "content_chars": safe_len(message.get("content")),
                "thinking_chars": safe_len(message.get("thinking")),
                "image_count": len(message.get("images"))
                if isinstance(message.get("images"), list)
                else 0,
                "tool_call_count": tool_call_count,
                "has_tool_name": bool(message.get("tool_name")),
                "has_tool_call_id": bool(message.get("tool_call_id")),
            }
        )

    tools = payload.get("tools")
    tool_names: list[str] = []
    if isinstance(tools, list):
        for tool in tools:
            if not isinstance(tool, dict):
                continue
            function = tool.get("function")
            if isinstance(function, dict) and isinstance(function.get("name"), str):
                tool_names.append(function["name"])

    duplicate_non_tool_roles: list[dict[str, typing.Any]] = []
    for index in range(1, len(roles)):
        current = roles[index]
        previous = roles[index - 1]
        if current == previous and current in {"user", "assistant"}:
            duplicate_non_tool_roles.append(
                {"previous_index": index - 1, "index": index, "role": current}
            )

    options = payload.get("options") if isinstance(payload.get("options"), dict) else {}
    return {
        "json_object": True,
        "model": payload.get("model"),
        "stream": payload.get("stream"),
        "think": payload.get("think"),
        "truncate": payload.get("truncate"),
        "shift": payload.get("shift"),
        "message_count": len(messages),
        "roles": roles,
        "messages": shapes,
        "duplicate_non_tool_roles": duplicate_non_tool_roles,
        "tool_count": len(tools) if isinstance(tools, list) else 0,
        "tool_names": tool_names,
        "num_ctx": options.get("num_ctx"),
        "num_predict": options.get("num_predict"),
    }


class ShapeProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = urllib.parse.urlsplit("http://127.0.0.1:11434")
    output_path = pathlib.Path("ollama-role-capture.jsonl")
    output_lock = threading.Lock()

    def log_message(self, _format: str, *_args: typing.Any) -> None:
        return

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length > 0 else b""

    def _append_record(self, record: dict[str, typing.Any]) -> None:
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self.output_lock:
            self.output_path.parent.mkdir(parents=True, exist_ok=True)
            with self.output_path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")

    def _proxy(self) -> None:
        request_body = self._read_body()
        record: dict[str, typing.Any] | None = None
        if self.path.startswith("/api/chat"):
            try:
                payload = json.loads(request_body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload = None
            record = {
                "timestamp_utc": utc_now(),
                "method": self.command,
                "path": self.path,
                "request": request_shape(payload),
            }

        target_path = self.path
        if self.upstream.path and self.upstream.path != "/":
            target_path = self.upstream.path.rstrip("/") + "/" + self.path.lstrip("/")

        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS
            and key.lower() not in {"host", "content-length"}
        }
        if request_body:
            headers["Content-Length"] = str(len(request_body))

        if self.upstream.scheme == "https":
            connection_class = http.client.HTTPSConnection
        else:
            connection_class = http.client.HTTPConnection
        connection = connection_class(
            self.upstream.hostname,
            self.upstream.port,
            timeout=600,
        )

        try:
            connection.request(self.command, target_path, body=request_body, headers=headers)
            response = connection.getresponse()
            response_body = response.read()
            if record is not None:
                record["response_status"] = response.status
                if response.status >= 400:
                    error_text = response_body.decode("utf-8", errors="replace")
                    record["response_error"] = error_text[:4000]
                self._append_record(record)

            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                lowered = key.lower()
                if lowered in HOP_BY_HOP_HEADERS or lowered == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if response_body:
                self.wfile.write(response_body)
            self.close_connection = True
        except Exception as exc:
            if record is not None:
                record["proxy_error"] = f"{type(exc).__name__}: {exc}"
                self._append_record(record)
            error_payload = {"error": f"diagnostic proxy failure: {exc}"}
            error_body = json.dumps(error_payload).encode("utf-8")
            self.send_response(502, "Bad Gateway")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(error_body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(error_body)
            self.close_connection = True
        finally:
            connection.close()

    do_GET = _proxy
    do_POST = _proxy
    do_HEAD = _proxy


def main() -> int:
    args = parse_args()
    upstream = urllib.parse.urlsplit(args.upstream)
    if upstream.scheme not in {"http", "https"} or not upstream.hostname:
        raise SystemExit(f"Upstream invalide: {args.upstream}")

    ShapeProxyHandler.upstream = upstream
    ShapeProxyHandler.output_path = pathlib.Path(args.output)
    server = http.server.ThreadingHTTPServer(
        (args.listen_host, args.listen_port),
        ShapeProxyHandler,
    )
    print(
        f"ROLE_CAPTURE_READY=http://{args.listen_host}:{args.listen_port} "
        f"upstream={args.upstream} output={args.output}",
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
