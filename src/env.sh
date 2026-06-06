#!/bin/sh
# env.sh - Load defaults and validate required environment variables
# Sourced by backup.sh and run.sh

# ---------- Postgres defaults --------------------------------
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_EXTRA_OPTS="${POSTGRES_EXTRA_OPTS:--Z1 --no-owner --no-acl}"

# ---------- S3/R2 defaults -----------------------------------
S3_REGION="${S3_REGION:-auto}"
S3_PREFIX="${S3_PREFIX:-postgres-backups}"
S3_S3V4="${S3_S3V4:-yes}"

# ---------- Retention defaults -------------------------------
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
BACKUP_KEEP_WEEKS="${BACKUP_KEEP_WEEKS:-4}"
BACKUP_KEEP_MONTHS="${BACKUP_KEEP_MONTHS:-12}"

# ---------- General defaults ---------------------------------
SERVER_NAME="${SERVER_NAME:-postgres-backup}"
TZ="${TZ:-UTC}"

# ---------- Validate required variables ----------------------
assert_set() {
  var_name="$1"
  var_value="$2"
  if [ -z "$var_value" ]; then
    echo "[env] ERROR: Required environment variable $var_name is not set" >&2
    exit 1
  fi
}

assert_set "POSTGRES_HOST"     "$POSTGRES_HOST"
assert_set "POSTGRES_DB"       "$POSTGRES_DB"
assert_set "POSTGRES_USER"     "$POSTGRES_USER"
assert_set "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
assert_set "S3_ENDPOINT"       "$S3_ENDPOINT"
assert_set "S3_BUCKET"         "$S3_BUCKET"
assert_set "S3_ACCESS_KEY_ID"  "$S3_ACCESS_KEY_ID"
assert_set "S3_SECRET_ACCESS_KEY" "$S3_SECRET_ACCESS_KEY"
assert_set "TELEGRAM_BOT_TOKEN"   "$TELEGRAM_BOT_TOKEN"
assert_set "TELEGRAM_CHAT_ID"     "$TELEGRAM_CHAT_ID"

# ---------- Configure AWS CLI for R2 -------------------------
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

# Use path-style addressing required by R2
AWS_ARGS="--endpoint-url $S3_ENDPOINT"
if [ "$S3_S3V4" = "yes" ]; then
  aws configure set default.s3.signature_version s3v4 2>/dev/null || true
fi
