from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from clawlocal.project_orchestrator import project_path
from clawlocal.telemetry import append_telemetry, summarize_telemetry


def default_root() -> Path:
    configured = os.environ.get("OPENCLAW_LOCAL_ROOT")
    if configured:
        return Path(configured)
    if Path("E:/").exists():
        return Path("E:/AI/OpenClawLocal")
    return Path(os.environ.get("LOCALAPPDATA", ".")) / "OpenClawLocal"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Enregistre des métriques observées sans prompts ni contenus privés."
    )
    parser.add_argument("--project", required=True)
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--summary", action="store_true")
    parser.add_argument("--agent")
    parser.add_argument("--model")
    parser.add_argument("--backend")
    parser.add_argument("--route-kind")
    parser.add_argument("--duration-ms", type=float)
    parser.add_argument("--ttft-ms", type=float)
    parser.add_argument("--tokens-per-second", type=float)
    parser.add_argument("--prompt-tokens", type=int)
    parser.add_argument("--generated-tokens", type=int)
    parser.add_argument("--vram-mb", type=float)
    parser.add_argument("--ram-mb", type=float)
    parser.add_argument("--tool-calls", type=int)
    parser.add_argument("--retries", type=int)
    parser.add_argument("--local-to-deep-transition", action="store_true")
    parser.add_argument("--success", action="store_true")
    parser.add_argument("--error-class")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project = project_path(args.root, args.project)
    if args.summary:
        print(json.dumps(summarize_telemetry(project), indent=2))
        return 0

    required = {
        "agent": args.agent,
        "model": args.model,
        "backend": args.backend,
        "route_kind": args.route_kind,
        "duration_ms": args.duration_ms,
    }
    missing = [key for key, value in required.items() if value is None]
    if missing:
        raise ValueError("arguments requis absents: " + ", ".join(missing))

    payload = {
        "project_id": args.project,
        **required,
        "ttft_ms": args.ttft_ms,
        "tokens_per_second": args.tokens_per_second,
        "prompt_tokens": args.prompt_tokens,
        "generated_tokens": args.generated_tokens,
        "vram_mb": args.vram_mb,
        "ram_mb": args.ram_mb,
        "tool_calls": args.tool_calls,
        "retries": args.retries,
        "local_to_deep_transition": args.local_to_deep_transition,
        "success": args.success,
        "error_class": args.error_class,
    }
    cleaned = {key: value for key, value in payload.items() if value is not None}
    path = append_telemetry(project, cleaned)
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
