#!/bin/bash
# Keeps Komodo's stack checkout fresh from the Mac Mini host.
# Works around OrbStack VirtFS not propagating new files/dirs to containers.
# Runs via LaunchAgent every 60 seconds.
set -euo pipefail

STACK_DIR="/etc/komodo/stacks/services"
DOCKER="$HOME/.orbstack/bin/docker"
LOG="/tmp/komodo-stack-sync.log"

# Skip if stack dir doesn't exist or isn't a git repo
[ -d "$STACK_DIR/.git" ] || exit 0

# Rotate log if over 100KB
[ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 102400 ] && : > "$LOG"

cd "$STACK_DIR"

# Capture directory listing before pull
DIRS_BEFORE=$(find . -type d | sort | /sbin/md5 -q)

# Fetch and reset to match remote (same as what Komodo periphery would do)
git fetch --quiet origin main 2>/dev/null || exit 0
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

# Nothing to do if already at HEAD
[ "$LOCAL" = "$REMOTE" ] && exit 0

# Files that will change (for targeted container restarts)
CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE" 2>/dev/null || true)

git reset --hard origin/main --quiet

# Capture directory listing after pull
DIRS_AFTER=$(find . -type d | sort | /sbin/md5 -q)

echo "$(date): synced $LOCAL -> $REMOTE" >> "$LOG"

# If new directories appeared, restart periphery to flush VirtFS cache
if [ "$DIRS_BEFORE" != "$DIRS_AFTER" ]; then
    echo "$(date): directory structure changed, restarting periphery" >> "$LOG"
    "$DOCKER" restart komodo-periphery-1 2>/dev/null || true
fi

# VirtFS often does not propagate new *files* or edits under existing dirs to
# bind mounts until the consumer container restarts. Only directory-level
# changes triggered a periphery restart before, so new dashboards (e.g.
# Apps/*.json) never appeared until a manual grafana restart.
if echo "$CHANGED" | grep -q '^monitoring/'; then
    echo "$(date): monitoring stack files changed, restarting grafana (and prometheus)" >> "$LOG"
    "$DOCKER" restart grafana 2>/dev/null || true
    "$DOCKER" restart prometheus 2>/dev/null || true
fi

# HA bind-mounts git-tracked YAML from the host; OrbStack VirtFS often keeps
# stale file contents inside the container until homeassistant restarts.
if echo "$CHANGED" | grep -q '^homeassistant/'; then
    echo "$(date): homeassistant config changed, restarting homeassistant" >> "$LOG"
    "$DOCKER" restart homeassistant 2>/dev/null || true
fi

# Z2M external extensions are bind-mounted; VirtFS can serve stale JS until restart.
if echo "$CHANGED" | grep -q '^zigbee2mqtt/'; then
    echo "$(date): zigbee2mqtt files changed, restarting zigbee2mqtt" >> "$LOG"
    "$DOCKER" restart zigbee2mqtt 2>/dev/null || true
fi
