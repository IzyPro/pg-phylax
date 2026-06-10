#!/bin/sh
# backup.sh - PostgreSQL backup to Cloudflare R2
# Adapted from:
#   - eeshugerman/postgres-backup-s3 (S3 upload via aws CLI)
#   - prodrigestivill/docker-postgres-backup-local (retention logic)
#
# Backup structure in R2:
#   s3://bucket/prefix/<dbname>/daily/   - one per day,   kept BACKUP_KEEP_DAYS days
#   s3://bucket/prefix/<dbname>/weekly/  - one per week,  kept BACKUP_KEEP_WEEKS weeks
#   s3://bucket/prefix/<dbname>/monthly/ - one per month, kept BACKUP_KEEP_MONTHS months

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load env defaults and validation
. "${SCRIPT_DIR}/env.sh"

# ---------- Helpers ------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# S3 wrapper - all aws s3 calls go through here
s3() {
  aws s3 $AWS_ARGS "$@"
}

# S3 API wrapper for object operations
s3api() {
  aws s3api $AWS_ARGS "$@"
}

# ---------- Failure trap -------------------------------------
# Called automatically on any command failure due to set -e
BACKUP_START_TIME=""
on_exit() {
  exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Backup script failed with exit code ${exit_code}"
    # Notify Telegram - failure message
    sh "${SCRIPT_DIR}/notify.sh" "failure" "Script exited with code ${exit_code}"
  fi
}
trap 'on_exit' EXIT

# ---------- Date helpers for retention -----------------------
TIMESTAMP="$(date '+%Y-%m-%dT%H-%M-%SZ')"
DAY_OF_WEEK="$(date '+%u')"    # 1=Monday ... 7=Sunday
DAY_OF_MONTH="$(date '+%d')"   # 01-31

# ---------- Upload file to R2 --------------------------------
upload_to_r2() {
  local_file="$1"
  r2_key="$2"

  log "Uploading to R2: s3://${S3_BUCKET}/${r2_key}"
  s3 cp "$local_file" "s3://${S3_BUCKET}/${r2_key}" \
    --no-progress \
    --storage-class STANDARD
  log "Upload complete: ${r2_key}"
}

# ---------- Apply retention to an R2 prefix ------------------
# Deletes objects older than max_age_secs under the given prefix
apply_r2_retention() {
  prefix="$1"
  max_age_days="$2"

  # Skip if max_age_days is 0
  if [ "$max_age_days" -eq 0 ]; then
    log "Retention disabled for ${prefix}, skipping"
    return 0
  fi

  log "Applying retention to s3://${S3_BUCKET}/${prefix} (max age: ${max_age_days} days)"

# Calculate cutoff date using standard Epoch math
  CURRENT_EPOCH=$(date +%s)
  OFFSET_SECONDS=$((max_age_days * 86400))
  CUTOFF_EPOCH=$((CURRENT_EPOCH - OFFSET_SECONDS))
  
  # Support both BusyBox (Linux) and BSD (macOS) epoch formatting safely
  CUTOFF_DATE="$(date -d "@${CUTOFF_EPOCH}" '+%Y-%m-%d' 2>/dev/null || \
                 date -r "${CUTOFF_EPOCH}" '+%Y-%m-%d' 2>/dev/null || true)"

  # Safety check so set -e doesn't silently kill the script if it still fails
  if [ -z "$CUTOFF_DATE" ]; then
    log "ERROR: Failed to calculate retention date. Incompatible date utility."
    exit 1
  fi

  log "Cutoff date: ${CUTOFF_DATE}"

  # List objects and filter by LastModified date prefix comparison
  # R2 returns LastModified as: 2024-01-15T02:00:00.000Z
  # We extract YYYY-MM-DD and compare as strings (lexicographic = chronological)
  s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "$prefix" \
    --query 'Contents[].{Key:Key,LastModified:LastModified}' \
    --output text 2>/dev/null | while IFS=$'\t' read -r key last_modified; do

    [ -z "$key" ] && continue
    [ "$key" = "None" ] && continue

    # Extract just the date portion YYYY-MM-DD from LastModified
    obj_date="$(echo "$last_modified" | cut -c1-10)"

    # String comparison works correctly for ISO dates
    if [ -n "$obj_date" ] && [ "$obj_date" \< "$CUTOFF_DATE" ]; then
      log "Deleting expired backup: ${key} (date: ${obj_date}, cutoff: ${CUTOFF_DATE})"
      s3api delete-object \
        --bucket "$S3_BUCKET" \
        --key "$key"
    fi
  done
}

# ---------- Backup a single database -------------------------
backup_database() {
  DB="$1"
  log "========================================"
  log "Starting backup: ${DB}"
  log "========================================"

  BACKUP_SUFFIX=".sql.gz"
  DAILY_KEY="${S3_PREFIX}/${DB}/daily/${DB}_${TIMESTAMP}${BACKUP_SUFFIX}"
  WEEKLY_KEY="${S3_PREFIX}/${DB}/weekly/${DB}_${TIMESTAMP}${BACKUP_SUFFIX}"
  MONTHLY_KEY="${S3_PREFIX}/${DB}/monthly/${DB}_${TIMESTAMP}${BACKUP_SUFFIX}"

  # Create temp file securely
  TEMP_FILE="$(mktemp /tmp/pgbackup_XXXXXX)"
  # Ensure temp file is always cleaned up
  trap 'rm -f "$TEMP_FILE"' EXIT

  # Run pg_dump and compress
  log "Running pg_dump for database: ${DB}"

  pg_dump \
  -h "$POSTGRES_HOST" \
  -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" \
  -F c \
  --compress="$COMPRESSION_METHOD:level=$COMPRESSION_LEVEL" \
  $POSTGRES_EXTRA_OPTS \
  -f "$TEMP_FILE.dump" \
  "$DB"

  # Verify the dump is not empty
  DUMP_SIZE="$(wc -c < "$TEMP_FILE")"
  if [ "$DUMP_SIZE" -lt 100 ]; then
    log "ERROR: Backup file is suspiciously small (${DUMP_SIZE} bytes) - possible pg_dump failure"
    rm -f "$TEMP_FILE"
    exit 1
  fi

  DUMP_SIZE_HR="$(du -sh "$TEMP_FILE" | cut -f1)"
  log "Dump complete: ${DUMP_SIZE_HR}"

  # Always upload to daily
  upload_to_r2 "$TEMP_FILE" "$DAILY_KEY"

  # Upload to weekly on Sundays (DAY_OF_WEEK=7)
  if [ "$DAY_OF_WEEK" = "7" ]; then
    log "Weekly backup day - uploading to weekly prefix"
    upload_to_r2 "$TEMP_FILE" "$WEEKLY_KEY"
  fi

  # Upload to monthly on 1st of the month
  if [ "$DAY_OF_MONTH" = "01" ]; then
    log "Monthly backup day - uploading to monthly prefix"
    upload_to_r2 "$TEMP_FILE" "$MONTHLY_KEY"
  fi

  # Clean up temp file
  rm -f "$TEMP_FILE"
  trap - EXIT
  log "Temp file cleaned up"

  # Apply retention policies
  apply_r2_retention "${S3_PREFIX}/${DB}/daily/"   "$BACKUP_KEEP_DAYS"
  apply_r2_retention "${S3_PREFIX}/${DB}/weekly/"  "$((BACKUP_KEEP_WEEKS * 7))"
  apply_r2_retention "${S3_PREFIX}/${DB}/monthly/" "$((BACKUP_KEEP_MONTHS * 31))"

  log "Backup complete: ${DB} (${DUMP_SIZE_HR})"
}

# ---------- Main ---------------------------------------------
BACKUP_START_TIME="$(date '+%s')"
log "========================================"
log "PostgreSQL Backup Service"
log "Server:    ${SERVER_NAME}"
log "Host:      ${POSTGRES_HOST}:${POSTGRES_PORT}"
log "Database:  ${POSTGRES_DB}"
log "R2 Bucket: ${S3_BUCKET}/${S3_PREFIX}"
log "Retention: ${BACKUP_KEEP_DAYS}d daily / ${BACKUP_KEEP_WEEKS}w weekly / ${BACKUP_KEEP_MONTHS}m monthly"
log "========================================"

# Send start notification
sh "${SCRIPT_DIR}/notify.sh" "started"

# Loop over comma or space separated database list
# Mirrors prodrigestivill approach
POSTGRES_DBS="$(echo "$POSTGRES_DB" | tr ',' ' ')"
for DB in $POSTGRES_DBS; do
  DB="$(echo "$DB" | tr -d '[:space:]')"
  [ -z "$DB" ] && continue
  backup_database "$DB"
done

# Calculate total duration
BACKUP_END_TIME="$(date '+%s')"
DURATION="$((BACKUP_END_TIME - BACKUP_START_TIME))"

log "========================================"
log "All backups completed in ${DURATION}s"
log "========================================"

# Send success notification
sh "${SCRIPT_DIR}/notify.sh" "success" "$DURATION"
