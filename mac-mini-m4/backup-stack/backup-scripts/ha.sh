#!/bin/sh
# Backup Home Assistant volume-only state (non-GitOps files).
# Writes to local staging directory — NOT GCS directly.
# Run gcs-sync.sh separately to upload staged backups to cloud storage.
#
# Backed up: scenes.yaml, sl_custom_scenes.json, .storage/ directory

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING_DIR="${BACKUP_STAGING:-/tmp/backups-local/staging/homeassistant}"
mkdir -p "$STAGING_DIR"

CONFIG_DIR="/config"

echo "[$(date)] Starting Home Assistant volume backup..."

# 1. scenes.yaml
SCENES_FILE="${CONFIG_DIR}/scenes.yaml"
if [ -f "$SCENES_FILE" ]; then
  cp "$SCENES_FILE" "${STAGING_DIR}/scenes_${TIMESTAMP}.yaml"
  SIZE=$(stat -c%s "${STAGING_DIR}/scenes_${TIMESTAMP}.yaml" 2>/dev/null || stat -f%z "${STAGING_DIR}/scenes_${TIMESTAMP}.yaml")
  echo "[$(date)] Staged: scenes.yaml (${SIZE}B)"
else
  echo "[$(date)] WARN: scenes.yaml not found (HA may not have started yet)"
fi

# 2. sl_custom_scenes.json (optional)
CUSTOM_SCENES_FILE="${CONFIG_DIR}/sl_custom_scenes.json"
if [ -f "$CUSTOM_SCENES_FILE" ]; then
  cp "$CUSTOM_SCENES_FILE" "${STAGING_DIR}/custom_scenes_${TIMESTAMP}.json"
  SIZE=$(stat -c%s "${STAGING_DIR}/custom_scenes_${TIMESTAMP}.json" 2>/dev/null || stat -f%z "${STAGING_DIR}/custom_scenes_${TIMESTAMP}.json")
  echo "[$(date)] Staged: custom_scenes.json (${SIZE}B)"
else
  echo "[$(date)] INFO: sl_custom_scenes.json not found — no custom scene packs saved (OK)"
fi

# 3. .storage/ directory (tar.gz)
STORAGE_DIR="${CONFIG_DIR}/.storage"
if [ -d "$STORAGE_DIR" ]; then
  (cd "${CONFIG_DIR}" && tar czf "/tmp/.storage_${TIMESTAMP}.tar.gz" ".storage/")
  mv "/tmp/.storage_${TIMESTAMP}.tar.gz" "${STAGING_DIR}/.storage_${TIMESTAMP}.tar.gz"
  SIZE=$(stat -c%s "${STAGING_DIR}/.storage_${TIMESTAMP}.tar.gz" 2>/dev/null || stat -f%z "${STAGING_DIR}/.storage_${TIMESTAMP}.tar.gz")
  echo "[$(date)] Staged: .storage/ (${SIZE}B)"
else
  echo "[$(date)] WARN: .storage/ directory not found (HA may not have started yet)"
fi

# Local retention: keep last 7 backups
echo "[$(date)] Cleaning local backups (keeping latest 7)..."
find "$STAGING_DIR" -type f | sort | head -n -7 | while read -r OLD_FILE; do
  echo "[$(date)] Deleting old backup: $(basename $OLD_FILE)"
  rm "$OLD_FILE"
done

echo "[$(date)] Home Assistant volume backup complete."
