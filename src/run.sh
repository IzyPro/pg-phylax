#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

if [ -n "${SCHEDULE:-}" ]; then
  echo "[run] Starting scheduled backup service"
  echo "[run] Schedule: ${SCHEDULE}"
  echo "[run] Timezone: ${TZ}"

  # Write crontab for busybox crond
  mkdir -p /var/spool/cron/crontabs
  printf '%s /bin/sh %s/backup.sh >> /var/log/pgbackup/cron.log 2>&1\n' \
    "$SCHEDULE" "$SCRIPT_DIR" \
    > /var/spool/cron/crontabs/root
  chmod 0600 /var/spool/cron/crontabs/root

  # busybox crond - -f foreground, -d 8 log level
  exec busybox crond -f -d 8
else
  echo "[run] No SCHEDULE set - running backup once and exiting"
  exec /bin/sh "${SCRIPT_DIR}/backup.sh"
fi