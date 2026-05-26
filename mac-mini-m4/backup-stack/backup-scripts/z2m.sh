#!/bin/sh
# Backup Zigbee2MQTT coordinator state and device database.
# Writes to local staging directory — NOT GCS directly.
# Run gcs-sync.sh separately to upload staged backups to cloud storage.

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING_DIR="${BACKUP_STAGING:-/tmp/backups-local/staging/z2m}"

mkdir -p "$STAGING_DIR"

COORDINATOR_FILE="/app/data/coordinator_backup.json"
DATABASE_FILE="/app/data/database.db"

echo "[$(date)] Starting Z2M coordinator backup..."

if [ ! -f "$COORDINATOR_FILE" ]; then
  echo "[$(date)] WARN: $COORDINATOR_FILE not found — skipping coordinator backup"
else
  COORD_NAME="coordinator_backup_${TIMESTAMP}.json"
  cp "$COORDINATOR_FILE" "${STAGING_DIR}/${COORD_NAME}"
  SIZE=$(stat -c%s "${STAGING_DIR}/${COORD_NAME}" 2>/dev/null || stat -f%z "${STAGING_DIR}/${COORD_NAME}")
  echo "[$(date)] Staged: ${COORD_NAME} (${SIZE}B)"
fi

if [ ! -f "$DATABASE_FILE" ]; then
  echo "[$(date)] WARN: $DATABASE_FILE not found — skipping device database backup"
else
  DB_NAME="database_${TIMESTAMP}.db"
  cp "$DATABASE_FILE" "${STAGING_DIR}/${DB_NAME}"
  SIZE=$(stat -c%s "${STAGING_DIR}/${DB_NAME}" 2>/dev/null || stat -f%z "${STAGING_DIR}/${DB_NAME}")
  echo "[$(date)] Staged: ${DB_NAME} (${SIZE}B)"
fi

# Local retention: keep last 7 backups per service
echo "[$(date)] Cleaning local backups (keeping latest 7)..."
find "$STAGING_DIR" -type f | sort | head -n -7 | while read -r OLD_FILE; do
  echo "[$(date)] Deleting old backup: $(basename $OLD_FILE)"
  rm "$OLD_FILE"
done

echo "[$(date)] Z2M coordinator backup complete."
