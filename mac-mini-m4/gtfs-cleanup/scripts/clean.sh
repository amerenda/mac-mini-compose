#!/bin/sh
# GTFS realtime storage cleanup — keeps only the 10 newest .zip files (~200MB)
# Runs on a dedicated container, mounted to HA's docker volume directly.
# Independent of Home Assistant health status.

DATA_DIR="/data/.storage/gtfs_realtime"
KEEP_COUNT=10

if [ ! -d "$DATA_DIR" ]; then
  mkdir -p "$DATA_DIR"
fi

TOTAL=$(ls -1 "$DATA_DIR"/*.zip 2>/dev/null | wc -l)
if [ "$TOTAL" -gt "$KEEP_COUNT" ]; then
  rm_count=$((TOTAL - KEEP_COUNT))
  ls -t "$DATA_DIR"/*.zip | tail -n +$((KEEP_COUNT + 1)) | xargs rm -f --
  echo "$(date): Cleaned $rm_count GTFS realtime files (removed $rm_count old .zip at ~20MB each)" >> /var/log/gtfs-cleanup.log
fi

# Also clean old HA backups — keep only the last 1
# The volume is mounted at /data here (not /config like inside HA).
# HA auto-backups are ~4.8GB each; keep only the most recent to avoid filling the volume.
BACKUP_DIR="/data/backups"
if [ -d "$BACKUP_DIR" ]; then
  TOTAL=$(ls -1 "$BACKUP_DIR"/*.tar 2>/dev/null | wc -l)
  if [ "$TOTAL" -gt 1 ]; then
    rm_count=$((TOTAL - 1))
    ls -t "$BACKUP_DIR"/*.tar | tail -n +2 | xargs rm -f --
    echo "$(date): Cleaned $rm_count HA backup files (kept 1)" >> /var/log/gtfs-cleanup.log
  fi
fi
