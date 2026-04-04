#!/bin/sh
# pg_dump → gzip → GCS (S3-compatible HMAC)
# Runs daily via cron. Retention: 7 daily backups per database.
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATABASES="todo agent_kb argo_workflows"
BUCKET="${BACKUP_BUCKET}"
ENDPOINT="${BACKUP_ENDPOINT}"

if [ -z "$BUCKET" ] || [ -z "$ENDPOINT" ]; then
  echo "ERROR: BACKUP_BUCKET and BACKUP_ENDPOINT must be set"
  exit 1
fi

# GCS S3-compat requires path-style addressing
aws configure set default.s3.addressing_style path

for DB in $DATABASES; do
  FILENAME="${DB}_${TIMESTAMP}.sql.gz"
  echo "[$(date)] Backing up $DB..."
  pg_dump -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "$DB" \
    | gzip -9 > "/tmp/${FILENAME}"
  aws s3 cp "/tmp/${FILENAME}" "s3://${BUCKET}/postgres/${FILENAME}" \
    --endpoint-url "${ENDPOINT}"
  rm "/tmp/${FILENAME}"
  echo "[$(date)] $DB done: ${FILENAME}"
done

# Retention: keep last 7 per database, delete older
for DB in $DATABASES; do
  aws s3 ls "s3://${BUCKET}/postgres/" --endpoint-url "${ENDPOINT}" \
    | grep " ${DB}_" | sort | head -n -7 \
    | awk '{print $4}' \
    | while read -r KEY; do
        echo "[$(date)] Deleting old backup: $KEY"
        aws s3 rm "s3://${BUCKET}/postgres/${KEY}" --endpoint-url "${ENDPOINT}"
      done
done

echo "[$(date)] All backups complete."
