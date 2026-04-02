#!/bin/bash
# Keeps Komodo's stack checkout fresh from the Mac Mini host.
# Works around OrbStack VirtFS not propagating new directories to containers.
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

git reset --hard origin/main --quiet

# Capture directory listing after pull
DIRS_AFTER=$(find . -type d | sort | /sbin/md5 -q)

echo "$(date): synced $LOCAL -> $REMOTE" >> "$LOG"

# If new directories appeared, restart periphery to flush VirtFS cache
if [ "$DIRS_BEFORE" != "$DIRS_AFTER" ]; then
    echo "$(date): directory structure changed, restarting periphery" >> "$LOG"
    "$DOCKER" restart komodo-periphery-1 2>/dev/null || true
fi
