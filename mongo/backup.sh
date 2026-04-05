#!/bin/sh
# mongodump → gzip → GCS (S3-compatible HMAC via s3cmd)
# Runs daily via cron. Retention: 7 daily backups.
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUCKET="${BACKUP_BUCKET:-amerenda-backups}"
BUCKET_PATH="${BACKUP_BUCKET_PATH:-us/mac-mini/dean}"
ENDPOINT="${BACKUP_ENDPOINT}"

if [ -z "$ENDPOINT" ]; then
  echo "ERROR: BACKUP_ENDPOINT must be set"
  exit 1
fi

HOST=$(echo "$ENDPOINT" | sed 's|https://||' | sed 's|http://||')
S3CMD="s3cmd --access_key=${AWS_ACCESS_KEY_ID} --secret_key=${AWS_SECRET_ACCESS_KEY} --host=${HOST} --host-bucket=%(bucket)s.${HOST} --ssl"

FILENAME="mongo_${TIMESTAMP}.archive.gz"
echo "[$(date)] Backing up MongoDB..."
mongodump \
  --host "${MONGO_HOST:-mongo}" \
  --port "${MONGO_PORT:-27017}" \
  --username "${MONGO_USER}" \
  --password "${MONGO_PASSWORD}" \
  --authenticationDatabase admin \
  --archive \
  | gzip -9 > "/tmp/${FILENAME}"

$S3CMD put "/tmp/${FILENAME}" "s3://${BUCKET}/${BUCKET_PATH}/${FILENAME}"
rm "/tmp/${FILENAME}"
echo "[$(date)] Done: ${FILENAME}"

# Retention: keep last 7, delete older
$S3CMD ls "s3://${BUCKET}/${BUCKET_PATH}/" \
  | grep " mongo_" | sort | head -n -7 \
  | awk '{print $4}' \
  | while read -r KEY; do
      echo "[$(date)] Deleting old backup: $KEY"
      $S3CMD del "$KEY"
    done

echo "[$(date)] MongoDB backup complete."
