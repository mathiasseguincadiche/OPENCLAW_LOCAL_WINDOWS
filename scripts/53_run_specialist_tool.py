from __future__ import annotations

import sys
from pathlib import Path


def _activate_repository_sources() -> None:
    root = Path(__file__).resolve().parents[1]
    src = str(root / "src")
    if src not in sys.path:
        sys.path.insert(0, src)


def main() -> int:
    _activate_repository_sources()
    from clawlocal.specialist_tools import _cli

    return _cli()


if __name__ == "__main__":
    raise SystemExit(main())
