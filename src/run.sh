#!/bin/sh
# run.sh - Schedule backups via go-cron or run once immediately
# Mirrors eeshugerman/postgres-backup-s3 run.sh approach

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load and validate env
. "${SCRIPT_DIR}/env.sh"

if [ -n "${SCHEDULE:-}" ]; then
  echo "[run] Starting scheduled backup service"
  echo "[run] Schedule: ${SCHEDULE}"
  echo "[run] Timezone: ${TZ}"
  # go-cron handles the scheduling loop
  # It correctly parses @daily, @weekly, @monthly and standard cron expressions
  exec go-cron "$SCHEDULE" /bin/sh "${SCRIPT_DIR}/backup.sh"
else
  echo "[run] No SCHEDULE set - running backup once and exiting"
  exec /bin/sh "${SCRIPT_DIR}/backup.sh"
fi
