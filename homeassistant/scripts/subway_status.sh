#!/bin/sh
# Fetches NYC subway status for N, Q, 4, 5 lines
# Returns JSON: {"state": "All Clear"|"Delays", "details": [...], "lines": {...}}
curl -sf https://api.subwaynow.app/routes 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    lines = {}
    for k in ["N", "Q", "4", "5"]:
        lines[k] = d.get(k, {})
    bad = []
    for k, v in lines.items():
        status = v.get("status", "Unknown")
        if status != "Good Service":
            bad.append(k + " train: " + status)
    result = {
        "state": "Delays" if bad else "All Clear",
        "details": bad,
        "lines": {k: v.get("status", "Unknown") for k, v in lines.items()}
    }
    print(json.dumps(result))
except Exception:
    print(json.dumps({"state": "Error", "details": [], "lines": {}}))
'
