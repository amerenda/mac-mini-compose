#!/bin/bash
# z2m-backup.sh — Backs up the Zigbee2MQTT device database.
# Runs every 4h via com.local.z2m-backup LaunchDaemon.
# Manual trigger: bash /Users/alex/komodo-dean-gitops/mac-mini-m4/scripts/z2m-backup.sh

set -euo pipefail

DB_SRC="/Users/alex/komodo/stacks/automation/mac-mini-m4/zigbee2mqtt/z2m-data/database.db"
BACKUP_DIR="/Users/alex/backups/z2m"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_DIR/database.db.$TIMESTAMP"
GOLDEN="$BACKUP_DIR/database.db.golden"
LATEST="$BACKUP_DIR/database.db.latest"

mkdir -p "$BACKUP_DIR"

if [ ! -f "$DB_SRC" ]; then
    echo "$(date): ERROR: Z2M database not found at $DB_SRC" >&2
    exit 1
fi

cp "$DB_SRC" "$DEST"

# Relative symlink so it works regardless of mount path
ln -sf "database.db.$TIMESTAMP" "$LATEST"

# Initialize golden on first run — never overwritten automatically
if [ ! -f "$GOLDEN" ]; then
    cp "$DEST" "$GOLDEN"
    echo "$(date): Golden backup initialized: $GOLDEN"
fi

# Prune timestamped backups older than 14 days (golden and latest are excluded by name pattern)
find "$BACKUP_DIR" -maxdepth 1 -name 'database.db.2*' -mtime +14 -delete

echo "$(date): Backup complete: $DEST ($(stat -f%z "$DEST") bytes)"
