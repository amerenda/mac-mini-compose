#!/bin/bash
# Back up Home Assistant volume-only state.
#
# Three things in /config are NOT in git and cannot be recovered from the repo:
#   scenes.yaml          — scenes created/edited in the HA UI
#   sl_custom_scenes.json — Smart Lighting "All Rooms" custom scene packs
#   .storage/            — all HA persistent state (helper values in
#                          core.restore_state, auth, Lovelace storage, etc.)
#
# Everything else under /config is a read-only bind-mount from git and is
# omitted here — it's already in the repo.
#
# Usage: backup.sh <BACKUP_DIR>
#   BACKUP_DIR is created if it doesn't exist.
#   Called by scripts/backup.sh; can also be run standalone.

set -euo pipefail

BACKUP_DIR="${1:?Usage: backup.sh <BACKUP_DIR>}"
CONTAINER="homeassistant"

mkdir -p "${BACKUP_DIR}"

if ! docker inspect "${CONTAINER}" &>/dev/null; then
  echo "  WARN: ${CONTAINER} container not found — skipping HA backup"
  exit 0
fi

if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" != "true" ]; then
  echo "  WARN: ${CONTAINER} is not running — skipping HA backup"
  exit 0
fi

echo "  Home Assistant: scenes.yaml..."
docker cp "${CONTAINER}:/config/scenes.yaml" "${BACKUP_DIR}/scenes.yaml" \
  2>/dev/null || echo "    WARN: scenes.yaml not found (HA never started?)"

echo "  Home Assistant: sl_custom_scenes.json..."
docker cp "${CONTAINER}:/config/sl_custom_scenes.json" "${BACKUP_DIR}/sl_custom_scenes.json" \
  2>/dev/null || echo "    INFO: sl_custom_scenes.json absent (no custom packs saved yet — OK)"

echo "  Home Assistant: .storage/ (helper state, auth, Lovelace)..."
docker cp "${CONTAINER}:/config/.storage" "${BACKUP_DIR}/.storage" \
  2>/dev/null || echo "    WARN: .storage not found"

echo "  Home Assistant backup written to ${BACKUP_DIR}"
