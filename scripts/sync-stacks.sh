#!/bin/bash
# Keeps Komodo's stack checkouts fresh from the Mac Mini host.
# Works around OrbStack VirtFS not propagating new files/dirs to containers.
# Runs via LaunchAgent every 60 seconds.
set -euo pipefail

# Both are clones of mac-mini-compose; Docker bind mounts use .../automation/...
# on this host, while Komodo may update .../services/... — sync both or HA stays stale.
STACK_SERVICES="/etc/komodo/stacks/services"
STACK_AUTOMATION="/etc/komodo/stacks/automation"
DOCKER="$HOME/.orbstack/bin/docker"
LOG="/tmp/komodo-stack-sync.log"

[ -d "$STACK_SERVICES/.git" ] || [ -d "$STACK_AUTOMATION/.git" ] || exit 0

# Rotate log if over 100KB
[ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 102400 ] && : > "$LOG"

CHANGED=""
DIRS_BEFORE=""
DIRS_AFTER=""
SYNCED=false

sync_one() {
    local dir="$1"
    [ -d "$dir/.git" ] || return 0
    cd "$dir" || return 0

    git fetch --quiet origin main 2>/dev/null || return 0
    local local_h remote_h
    local_h=$(git rev-parse HEAD)
    remote_h=$(git rev-parse origin/main)
    [ "$local_h" = "$remote_h" ] && return 0

    local c
    c=$(git diff --name-only "$local_h" "$remote_h" 2>/dev/null || true)
    git reset --hard origin/main --quiet
    echo "$(date): synced $(basename "$dir") $local_h -> $remote_h" >> "$LOG"
    CHANGED="$CHANGED"$'\n'"$c"
    SYNCED=true
}

# Directory hash only for services (periphery cache); same as before
if [ -d "$STACK_SERVICES/.git" ]; then
    cd "$STACK_SERVICES"
    DIRS_BEFORE=$(find . -type d | sort | /sbin/md5 -q)
fi

sync_one "$STACK_SERVICES"
sync_one "$STACK_AUTOMATION"

if [ "$SYNCED" != true ]; then
    exit 0
fi

if [ -d "$STACK_SERVICES/.git" ]; then
    cd "$STACK_SERVICES"
    DIRS_AFTER=$(find . -type d | sort | /sbin/md5 -q)
    if [ -n "$DIRS_BEFORE" ] && [ "$DIRS_BEFORE" != "$DIRS_AFTER" ]; then
        echo "$(date): directory structure changed, restarting periphery" >> "$LOG"
        "$DOCKER" restart komodo-periphery-1 2>/dev/null || true
    fi
fi

if echo "$CHANGED" | grep -q '^monitoring/'; then
    echo "$(date): monitoring stack files changed, restarting grafana (and prometheus)" >> "$LOG"
    "$DOCKER" restart grafana 2>/dev/null || true
    "$DOCKER" restart prometheus 2>/dev/null || true
fi

if echo "$CHANGED" | grep -q '^homeassistant/'; then
    echo "$(date): homeassistant config changed, restarting homeassistant" >> "$LOG"
    "$DOCKER" restart homeassistant 2>/dev/null || true
fi

if echo "$CHANGED" | grep -q '^zigbee2mqtt/'; then
    echo "$(date): zigbee2mqtt files changed, restarting zigbee2mqtt" >> "$LOG"
    "$DOCKER" restart zigbee2mqtt 2>/dev/null || true
fi
