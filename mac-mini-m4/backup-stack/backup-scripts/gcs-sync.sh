#!/bin/sh
# Unified GCS Sync for Backup Stack
#
# Single script that uploads ALL local backups to GCS with safety caps.
# This is the ONLY path that touches GCS — backup scripts themselves never
# upload directly, they only stage files locally.
#
# SAFETY: Dry-run by default. Must pass --force to actually upload anything.

set -eu

# ============================================================
# CONFIGURATION (override via environment or command line)
# ============================================================
BUCKET="${GCS_BUCKET:-amerenda-backups}"
ENDPOINT="${GCS_ENDPOINT:?ERROR: GCS_ENDPOINT must be set — from BWS .env BACKUP_ENDPOINT}"
ACCESS_KEY="${GCS_ACCESS_KEY:?ERROR: GCS_ACCESS_KEY must be set — from BWS .env BACKUP_ACCESS_KEY}"
SECRET_KEY="${GCS_SECRET_KEY:?ERROR: GCS_SECRET_KEY must be set — from BWS .env BACKUP_SECRET_KEY}"

# Local staging directory where all backup scripts write to
STAGING_DIR="${BACKUP_STAGING:-/backups-local/staging}"

# Remote prefix on GCS (change this per-environment for dev/staging/prod)
REMOTE_PREFIX="${GCS_REMOTE_PREFIX:-us/mac-mini/dean}"

# ============================================================
# SAFETY CAPS — prevents runaway costs
# ============================================================
MAX_TOTAL_SIZE_MB="${GCS_MAX_SIZE_MB:-1024}"             # Default: 1 GB total
MAX_FILES_PER_SERVICE="${GCS_MAX_FILES_PER_SVC:-30}"     # Default: 30 per service directory
DRY_RUN="${GCS_DRY_RUN:-true}"                           # Default: dry-run mode (no uploads)

# ============================================================
# PARSING --force flag
# ============================================================
FORCE=false
for arg in "$@"; do
  case $arg in
    --force) FORCE=true ;;
    --dry-run) DRY_RUN="true" ;;
    --help|-h)
      echo "Usage: gcs-sync.sh [--force]"
      echo ""
      echo "Safety features:"
      echo "  - Dry-run by default (no actual uploads)"
      echo "  - Max total size cap: ${MAX_TOTAL_SIZE_MB}MB"
      echo "  - Max files per service: ${MAX_FILES_PER_SERVICE}"
      echo ""
      echo "Environment variables:"
      echo "  GCS_ENDPOINT       - S3-compatible endpoint URL (required)"
      echo "  GCS_ACCESS_KEY     - HMAC access key (required)"
      echo "  GCS_SECRET_KEY     - HMAC secret key (required)"
      echo "  GCS_BUCKET         - Bucket name (default: amerenda-backups)"
      echo "  GCS_REMOTE_PREFIX  - Prefix path in bucket (default: us/mac-mini/dean)"
      echo "  GCS_MAX_SIZE_MB    - Max total upload size in MB (default: ${MAX_TOTAL_SIZE_MB})"
      echo "  GCS_MAX_FILES_PER_SVC - Max files per service directory (default: ${MAX_FILES_PER_SERVICE})"
      echo ""
      exit 0
      ;;
  esac
done

if [ "$DRY_RUN" = "true" ]; then
  if [ "$FORCE" != "true" ]; then
    DRY_RUN="true"  # --force not passed, stay in dry-run mode
  else
    echo "[INFO] --force flag detected — uploads WILL happen (not just dry-run)"
  fi
fi

HOST=$(echo "$ENDPOINT" | sed 's|https://||' | sed 's|http://||')
S3CMD="s3cmd --access_key=${ACCESS_KEY} --secret_key=${SECRET_KEY} --host=${HOST} --host-bucket=%(bucket)s.${HOST} --ssl"

echo "============================================"
echo "  GCS Backup Sync (DRY_RUN=$DRY_RUN)"
echo "============================================"
echo ""

# ============================================================
# STEP 1: Scan staging directory — what would be uploaded?
# ============================================================
echo "[1/4] Scanning local backups in $STAGING_DIR ..."

if [ ! -d "$STAGING_DIR" ]; then
  echo "  No staging directory found. Nothing to sync."
  exit 0
fi

TOTAL_SIZE_KB=0
FILE_COUNT=0
SERVICES_SCANNED=""

# Count files and size per service subdirectory
for SVC_DIR in "${STAGING_DIR}"/*/; do
  if [ ! -d "$SVC_DIR" ]; then continue; fi
  
  SERVICE_NAME=$(basename "$SVC_DIR")
  SERVICES_SCANNED="$SERVICES_SCANNED $SERVICE_NAME"
  
  FILE_COUNT=$(find "$SVC_DIR" -type f | wc -l)
  SVC_SIZE_KB=$(du -sk "$SVC_DIR" 2>/dev/null | awk '{print $1}')
  TOTAL_SIZE_KB=$((TOTAL_SIZE_KB + SVC_SIZE_KB))
  
  echo "  ${SERVICE_NAME}: $FILE_COUNT files, ${SVC_SIZE_KB}KB"
done

echo ""
TOTAL_SIZE_MB=$((TOTAL_SIZE_KB / 1024))

# ============================================================
# STEP 2: Check safety caps — FAIL before uploading if exceeded
# ============================================================
echo "[2/4] Checking safety caps ..."

CAPS_PASSED=true

if [ "$TOTAL_SIZE_MB" -gt "$MAX_TOTAL_SIZE_MB" ]; then
  echo "  ❌ CAP EXCEEDED: Local backups total ${TOTAL_SIZE_MB}MB > cap of ${MAX_TOTAL_SIZE_MB}MB"
  echo "     Reduce local backup retention or increase GCS_MAX_SIZE_MB to override."
  CAPS_PASSED=false
fi

# Check per-service file counts
for SVC_DIR in "${STAGING_DIR}"/*/; do
  if [ ! -d "$SVC_DIR" ]; then continue; fi
  
  SERVICE_NAME=$(basename "$SVC_DIR")
  FILE_COUNT=$(find "$SVC_DIR" -type f | wc -l)
  
  if [ "$FILE_COUNT" -gt "$MAX_FILES_PER_SERVICE" ]; then
    echo "  ❌ CAP EXCEEDED: ${SERVICE_NAME} has $FILE_COUNT files > cap of ${MAX_FILES_PER_SERVICE}"
    CAPS_PASSED=false
  fi
done

if [ "$CAPS_PASSED" != "true" ]; then
  echo ""
  echo "Sync ABORTED — safety caps exceeded. Fix retention in backup scripts or bump caps."
  exit 1
fi

echo "  ✓ Total size: ${TOTAL_SIZE_MB}MB (cap: ${MAX_TOTAL_SIZE_MB}MB)"
echo "  ✓ Per-service file count within limits"
echo ""

# ============================================================
# STEP 3: Upload to GCS
# ============================================================
echo "[3/4] Uploading to GCS ..."

if [ "$DRY_RUN" = "true" ]; then
  echo "  (dry-run) Would upload the following:"
  
  for SVC_DIR in "${STAGING_DIR}"/*/; do
    if [ ! -d "$SVC_DIR" ]; then continue; fi
    
    SERVICE_NAME=$(basename "$SVC_DIR")
    
    for FILE in "$SVC_DIR"*; do
      if [ ! -f "$FILE" ]; then continue; fi
      
      FILENAME=$(basename "$FILE")
      FSIZE_KB=$(du -sk "$FILE" | awk '{print $1}')
      
      echo "  → ${REMOTE_PREFIX}/${SERVICE_NAME}/${FILENAME} (${FSIZE_KB}KB)"
    done
  
  done
else
  # Actual upload — iterate each service directory and upload all files
  UPLOAD_ERRORS=0
  
  for SVC_DIR in "${STAGING_DIR}"/*/; do
    if [ ! -d "$SVC_DIR" ]; then continue; fi
    
    SERVICE_NAME=$(basename "$SVC_DIR")
    
    echo "  Syncing ${SERVICE_NAME}/ ..."
    
    for FILE in "$SVC_DIR"*; do
      if [ ! -f "$FILE" ]; then continue; fi
      
      FNAME=$(basename "$FILE")
      
      # Skip files already uploaded (check GCS listing first to avoid duplicates)
      REMOTE_KEY="${REMOTE_PREFIX}/${SERVICE_NAME}/${FNAME}"
      $S3CMD get "s3://${BUCKET}/${REMOTE_KEY}" /dev/null 2>/dev/null && \
        echo "    SKIP (exists): ${FNAME}" || \
        ($S3CMD put "$FILE" "s3://${BUCKET}/${REMOTE_KEY}" && echo "    UPLOADED: ${FNAME}") || {
          echo "    ERROR: Failed to upload ${FNAME} — retrying..."
          sleep 2
          $S3CMD put "$FILE" "s3://${BUCKET}/${REMOTE_KEY}" && \
            echo "    RETRY OK: ${FNAME}" || UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
        }
    done
  done
  
  if [ "$UPLOAD_ERRORS" -gt 0 ]; then
    echo ""
    echo "  WARNING: $UPLOAD_ERRORS upload errors occurred. Check logs."
  fi
fi

echo ""

# ============================================================
# STEP 4: Cleanup local staging (optional — controlled by env)
# ============================================================
if [ "$DRY_RUN" = "true" ]; then
  echo "[4/4] (dry-run) Would skip cleanup of $STAGING_DIR"
else
  CLEANUP="${GCS_CLEANUP_AFTER_SYNC:-false}"
  
  if [ "$CLEANUP" = "true" ]; then
    echo "[4/4] Cleaning up local staging files (sync successful) ..."
    rm -rf "${STAGING_DIR:?}/"*
    echo "  Done."
  else
    echo "[4/4] Keeping local copies in $STAGING_DIR (set GCS_CLEANUP_AFTER_SYNC=true to auto-delete)"
  fi
fi

echo ""
echo "============================================"
if [ "$DRY_RUN" = "true" ]; then
  echo "  DRY RUN COMPLETE — no data uploaded."
else
  if [ "$CAPS_PASSED" != "true" ] || [ "$UPLOAD_ERRORS" -gt 0 ]; then
    echo "  SYNC COMPLETED WITH ISSUES (see errors above)"
  else
    echo "  SYNC COMPLETE — all backups synced to GCS"
  fi
fi
echo "============================================"
