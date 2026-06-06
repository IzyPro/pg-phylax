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
on_error() {
  exit_code=$?
  line="$1"
  log "ERROR: Backup failed at line ${line} with exit code ${exit_code}"
  # Notify Telegram - failure message
  sh "${SCRIPT_DIR}/notify.sh" "failure" "Script exited with code ${exit_code} at line ${line}"
  exit $exit_code
}
trap 'on_error $LINENO' ERR

# ---------- Date helpers for retention -----------------------
TIMESTAMP="$(date '+%Y-%m-%dT%H-%M-%SZ')"
DAY_OF_WEEK="$(date '+%u')"    # 1=Monday ... 7=Sunday
DAY_OF_MONTH="$(date '+%d')"   # 01-31

# Compute cutoff timestamps for retention
# Using days as the common unit (weeks * 7, months * 31)
KEEP_DAYS_SECS="$((BACKUP_KEEP_DAYS * 86400))"
KEEP_WEEKS_SECS="$((BACKUP_KEEP_WEEKS * 7 * 86400))"
KEEP_MONTHS_SECS="$((BACKUP_KEEP_MONTHS * 31 * 86400))"
NOW_SECS="$(date '+%s')"

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
  max_age_secs="$2"

  log "Applying retention to s3://${S3_BUCKET}/${prefix} (max age: $((max_age_secs / 86400)) days)"

  # List all objects under prefix and check their LastModified
  s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "$prefix" \
    --query 'Contents[].{Key:Key,LastModified:LastModified}' \
    --output text 2>/dev/null | while IFS=$'\t' read -r key last_modified; do
    [ -z "$key" ] && continue

    # Parse LastModified to epoch seconds
    # LastModified format from AWS: 2024-01-15T02:00:00+00:00
    obj_secs="$(date -d "$last_modified" '+%s' 2>/dev/null || \
                date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "$last_modified" | cut -c1-19)" '+%s' 2>/dev/null || \
                echo 0)"

    age_secs="$((NOW_SECS - obj_secs))"

    if [ "$age_secs" -gt "$max_age_secs" ]; then
      log "Deleting expired backup: ${key} (age: $((age_secs / 86400)) days)"
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
  TEMP_FILE="$(mktemp /tmp/pgbackup_XXXXXX.sql.gz)"
  # Ensure temp file is always cleaned up
  trap 'rm -f "$TEMP_FILE"' EXIT

  # Run pg_dump and compress
  log "Running pg_dump for database: ${DB}"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
    --host="$POSTGRES_HOST" \
    --port="$POSTGRES_PORT" \
    --username="$POSTGRES_USER" \
    --no-password \
    $POSTGRES_EXTRA_OPTS \
    "$DB" | gzip > "$TEMP_FILE"

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
  apply_r2_retention "${S3_PREFIX}/${DB}/daily/"   "$KEEP_DAYS_SECS"
  apply_r2_retention "${S3_PREFIX}/${DB}/weekly/"  "$KEEP_WEEKS_SECS"
  apply_r2_retention "${S3_PREFIX}/${DB}/monthly/" "$KEEP_MONTHS_SECS"

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
