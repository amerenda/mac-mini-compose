#!/usr/bin/env python3
"""Remove literal uid=prometheus from dashboard JSON so panels use the default Prometheus datasource (type-only)."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def strip(obj: object) -> None:
    if isinstance(obj, dict):
        if obj.get("type") == "prometheus" and obj.get("uid") == "prometheus":
            del obj["uid"]
        for v in obj.values():
            strip(v)
    elif isinstance(obj, list):
        for item in obj:
            strip(item)


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "monitoring" / "grafana" / "dashboards"
    if not root.is_dir():
        print(f"Missing {root}", file=sys.stderr)
        sys.exit(1)
    changed = 0
    for path in sorted(root.rglob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        before = json.dumps(data)
        strip(data)
        after = json.dumps(data)
        if before != after:
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            changed += 1
            print(path)
    print(f"# Updated {changed} files", file=sys.stderr)


if __name__ == "__main__":
    main()
