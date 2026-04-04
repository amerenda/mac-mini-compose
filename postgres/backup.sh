#!/bin/sh
# pg_dump → gzip → GCS (S3-compatible HMAC via s3cmd)
# Runs daily via cron. Retention: 7 daily backups per database.
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Databases on unified postgres (add agent_kb, argo_workflows when migrated)
DATABASES="todo"
BUCKET="${BACKUP_BUCKET:-amerenda-backups}"
BUCKET_PATH="${BACKUP_BUCKET_PATH:-us/mac-mini/dean}"
ENDPOINT="${BACKUP_ENDPOINT}"

if [ -z "$ENDPOINT" ]; then
  echo "ERROR: BACKUP_ENDPOINT must be set"
  exit 1
fi

# Strip https:// for s3cmd --host
HOST=$(echo "$ENDPOINT" | sed 's|https://||' | sed 's|http://||')

S3CMD="s3cmd --access_key=${AWS_ACCESS_KEY_ID} --secret_key=${AWS_SECRET_ACCESS_KEY} --host=${HOST} --host-bucket=%(bucket)s.${HOST} --ssl"

for DB in $DATABASES; do
  FILENAME="${DB}_${TIMESTAMP}.sql.gz"
  echo "[$(date)] Backing up $DB..."
  pg_dump -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "$DB" \
    | gzip -9 > "/tmp/${FILENAME}"
  $S3CMD put "/tmp/${FILENAME}" "s3://${BUCKET}/${BUCKET_PATH}/${FILENAME}"
  rm "/tmp/${FILENAME}"
  echo "[$(date)] $DB done: ${FILENAME}"
done

# Retention: keep last 7 per database, delete older
for DB in $DATABASES; do
  $S3CMD ls "s3://${BUCKET}/${BUCKET_PATH}/" \
    | grep " ${DB}_" | sort | head -n -7 \
    | awk '{print $4}' \
    | while read -r KEY; do
        echo "[$(date)] Deleting old backup: $KEY"
        $S3CMD del "$KEY"
      done
done

echo "[$(date)] All backups complete."
