#!/bin/sh
# Export Grafana dashboards and data sources via REST API.
# Writes to local staging directory — NOT GCS directly.
# Run gcs-sync.sh separately to upload staged backups to cloud storage.

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING_DIR="${BACKUP_STAGING:-/backups-local/staging/grafana}"
mkdir -p "${STAGING_DIR}/dashboards" "${STAGING_DIR}/datasources"

GRAFANA_URL="${GRAFANA_URL:-http://grafana:3000}"
GRAFANA_API_TOKEN="${GRAFANA_API_TOKEN:?ERROR: GRAFANA_API_TOKEN must be set (from .env)}"

echo "[$(date)] Starting Grafana backup..."

# 1. Fetch all dashboards via API
DASHBOARDS_URL="${GRAFANA_URL}/api/search?folderIds=&limit=1000&type=dash-db"
echo "[$(date)] Fetching dashboard list from $DASHBOARDS_URL..."

DASHBOARD_LIST=$(curl -sf -H "Authorization: Bearer ${GRAFANA_API_TOKEN}" "$DASHBOARDS_URL" 2>/dev/null || echo "")

if [ -z "$DASHBOARD_LIST" ] || [ "$(echo $DASHBOARD_LIST | jq 'length')" = "0" ]; then
  echo "[$(date)] INFO: No dashboards found (or API call failed — Grafana may not be set up yet)"
else
  DASH_PATHS=$(echo "$DASHBOARD_LIST" | jq -r '.[].uid' 2>/dev/null || echo "")
  
  for UID in $DASH_PATHS; do
    SAFE_NAME=$(echo "$UID" | sed 's|/|-|g' | sed 's|[^\x00-\x7F]||g')
    
    DASHBOARD_JSON=$(curl -sf "${GRAFANA_URL}/api/dashboards/uid/${UID}" -H "Authorization: Bearer ${GRAFANA_API_TOKEN}" 2>/dev/null || echo "")
    
    if [ -n "$DASHBOARD_JSON" ]; then
      echo "$DASHBOARD_JSON" > "${STAGING_DIR}/dashboards/${SAFE_NAME}_${TIMESTAMP}.json"
      SIZE=$(stat -c%s "${STAGING_DIR}/dashboards/${SAFE_NAME}_${TIMESTAMP}.json" 2>/dev/null || stat -f%z "${STAGING_DIR}/dashboards/${SAFE_NAME}_${TIMESTAMP}.json")
      echo "[$(date)] Staged: ${SAFE_NAME}.json (${SIZE}B)"
    else
      echo "[$(date)] WARN: Could not fetch dashboard $UID"
    fi
  done
  
  # Local retention for dashboards (keep last N per dashboard)
  find "${STAGING_DIR}/dashboards/" -type f | sort | head -n -5 | while read -r OLD_FILE; do
    echo "[$(date)] Deleting old backup: $(basename $OLD_FILE)"
    rm "$OLD_FILE"
  done
else
  echo "[$(date)] No dashboards found to stage."
fi

# 2. Export data source configurations
echo "[$(date)] Fetching data sources..."
DATASOURCES_JSON=$(curl -sf "${GRAFANA_URL}/api/datasources" -H "Authorization: Bearer ${GRAFANA_API_TOKEN}" 2>/dev/null || echo "")

if [ -n "$DATASOURCES_JSON" ] && [ "$(echo $DATASOURCES_JSON | jq 'length')" != "0" ]; then
  echo "$DATASOURCES_JSON" > "${STAGING_DIR}/datasources/datasources_${TIMESTAMP}.json"
  SIZE=$(stat -c%s "${STAGING_DIR}/datasources/datasources_${TIMESTAMP}.json" 2>/dev/null || stat -f%z "${STAGING_DIR}/datasources/datasources_${TIMESTAMP}.json")
  echo "[$(date)] Staged: datasources.json (${SIZE}B)"
else
  echo "[$(date)] INFO: No data sources configured (or API call failed)"
fi

echo "[$(date)] Grafana backup complete."
