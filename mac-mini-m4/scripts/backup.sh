#!/bin/bash
# Backup Mac Mini services data
# Run via cron: 0 3 * * * /Users/alex/komodo-dean-gitops/mac-mini-m4/scripts/backup.sh

set -e

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${COMPOSE_DIR}/backups/$(date +%Y-%m-%d)"
RETAIN_DAYS=7

mkdir -p "${BACKUP_DIR}"

echo "Backing up to ${BACKUP_DIR}..."

# BIND9 zone files (the cache dir has the live zone data with dynamic updates)
echo "  BIND9 zones..."
docker cp bind9:/var/cache/bind "${BACKUP_DIR}/bind9-zones" 2>/dev/null || echo "  WARN: bind9 not running"

# Pihole teleporter backup
echo "  Pihole config..."
docker exec pihole pihole -a -t 2>/dev/null && \
  docker cp pihole:/var/pihole/pi-hole-teleporter.tar.gz "${BACKUP_DIR}/pihole-teleporter.tar.gz" || \
  echo "  WARN: pihole backup failed"

# Home Assistant — volume-only state (scenes, custom scene packs, helper values)
# Skips read-only git-mounted config files; only backs up what can't be recovered from the repo.
echo "  Home Assistant data..."
bash "${COMPOSE_DIR}/homeassistant/backup.sh" "${BACKUP_DIR}/ha-config"

# Cleanup old backups
echo "  Cleaning backups older than ${RETAIN_DAYS} days..."
find "${COMPOSE_DIR}/backups" -maxdepth 1 -type d -mtime "+${RETAIN_DAYS}" -exec rm -rf {} \;

echo "Backup complete: ${BACKUP_DIR}"
