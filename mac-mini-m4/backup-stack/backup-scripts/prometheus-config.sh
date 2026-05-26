#!/bin/sh
# Backup Prometheus configuration file.
# Writes to local staging directory — NOT GCS directly.
# Run gcs-sync.sh separately to upload staged backups to cloud storage.
# NOTE: Only config files are backed up (not time-series data).

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING_DIR="${BACKUP_STAGING:-/tmp/backups-local/staging/prometheus}"
mkdir -p "$STAGING_DIR"

PROMETHEUS_DATA="/prometheus/data/prometheus"  # Standard prometheus-data volume mount path

echo "[$(date)] Starting Prometheus config backup..."

CONFIG_FILE=$(find "$PROMETHEUS_DATA" -name "prometheus.yml" -o -name "*.yml" | grep -E "(prometheus\.yml|\.yml$)" | head -1 2>/dev/null || echo "")

if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="/etc/prometheus/prometheus.yml"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[$(date)] WARN: Prometheus config file not found at $PROMETHEUS_DATA or /etc/prometheus/"
else
  CONFIG_NAME="prometheus_config_${TIMESTAMP}.yml"
  cp "$CONFIG_FILE" "${STAGING_DIR}/${CONFIG_NAME}"
  
  SIZE=$(stat -c%s "${STAGING_DIR}/${CONFIG_NAME}" 2>/dev/null || stat -f%z "${STAGING_DIR}/${CONFIG_NAME}")
  echo "[$(date)] Staged: ${CONFIG_NAME} (${SIZE}B)"
fi

# Local retention: keep last 7 backups
echo "[$(date)] Cleaning local backups (keeping latest 7)..."
find "$STAGING_DIR" -type f | sort | head -n -7 | while read -r OLD_FILE; do
  echo "[$(date)] Deleting old backup: $(basename $OLD_FILE)"
  rm "$OLD_FILE"
done

echo "[$(date)] Prometheus config backup complete."
