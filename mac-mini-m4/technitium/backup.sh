#!/bin/sh
# Technitium DNS — tar.gz of /etc/dns → GCS (S3-compatible HMAC via s3cmd).
# Run daily via technitium-backup in core/compose.yaml. Retention: 7 archives.
#
# What is backed up: zones, auth, blocklists, apps, scopes, dns.config, etc.
# Excluded (regenerates at runtime): logs/, stats/, cache.bin — shrink upload; DNS config is preserved.
#
# Manual run on the Mac Mini (host has Docker):
#   docker run --rm \
#     -v services_technitium-data:/etc/dns:ro \
#     -v "$PWD/mac-mini-m4/technitium/backup.sh:/backup.sh:ro" \
#     -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e BACKUP_ENDPOINT \
#     -e BACKUP_BUCKET -e BACKUP_BUCKET_PATH \
#     alpine:3 sh -c 'apk add --no-cache s3cmd && sh /backup.sh'
#
# Restore (outline): stop technitium → empty or new volume → tar xzf into /etc/dns → start technitium.
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUCKET="${BACKUP_BUCKET:-amerenda-backups}"
BUCKET_PATH="${BACKUP_BUCKET_PATH:-us/mac-mini/dean}"
ENDPOINT="${BACKUP_ENDPOINT}"
SRC="${TECHNITIUM_DATA:-/etc/dns}"

if [ -z "$ENDPOINT" ]; then
  echo "ERROR: BACKUP_ENDPOINT must be set"
  exit 1
fi

if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC is not a directory"
  exit 1
fi
if [ ! -f "$SRC/dns.config" ] && [ ! -f "$SRC/auth.config" ]; then
  echo "ERROR: $SRC missing dns.config and auth.config — not a Technitium data dir?"
  exit 1
fi

HOST=$(echo "$ENDPOINT" | sed 's|https://||' | sed 's|http://||')
S3CMD="s3cmd --access_key=${AWS_ACCESS_KEY_ID} --secret_key=${AWS_SECRET_ACCESS_KEY} --host=${HOST} --host-bucket=%(bucket)s.${HOST} --ssl"

FILENAME="technitium_${TIMESTAMP}.tar.gz"
echo "[$(date)] Backing up Technitium from ${SRC}..."

tar czf "/tmp/${FILENAME}" \
  --exclude='logs' \
  --exclude='stats' \
  --exclude='cache.bin' \
  -C "$SRC" .

$S3CMD put "/tmp/${FILENAME}" "s3://${BUCKET}/${BUCKET_PATH}/${FILENAME}"
rm "/tmp/${FILENAME}"
echo "[$(date)] Done: ${FILENAME}"

$S3CMD ls "s3://${BUCKET}/${BUCKET_PATH}/" \
  | grep " technitium_" | sort | head -n -7 \
  | awk '{print $4}' \
  | while read -r KEY; do
      echo "[$(date)] Deleting old backup: $KEY"
      $S3CMD del "$KEY"
    done

echo "[$(date)] Technitium backup complete."
