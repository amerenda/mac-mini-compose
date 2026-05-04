#!/bin/sh
# Fetches NYC subway status for N, Q, 4, 5 lines
# Outputs JSON to stdout: {"state": "...", "title": "...", "message": "..."}
curl -sf https://api.subwaynow.app/routes 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    routes = d.get("routes", d)
    my_lines = ["N", "Q", "4", "5"]
    bad = []
    good = []
    for k in my_lines:
        route = routes.get(k, {})
        status = route.get("status", "Unknown")
        if status == "Good Service":
            good.append(k)
        else:
            bad.append(k + " train: " + status)
    if bad:
        title = "\U0001f687 Commute Alert"
        msg = "\n".join(bad)
        if good:
            msg += "\n" + ", ".join(good) + ": Good Service"
        state = "Delays"
    else:
        title = "\U0001f687 Commute"
        msg = "N, Q, 4, 5 \u2014 all running normally"
        state = "All Clear"
    print(json.dumps({"state": state, "title": title, "message": msg}))
except Exception:
    print(json.dumps({"state": "Error", "title": "\U0001f687 Commute", "message": "Could not check subway status"}))
'
