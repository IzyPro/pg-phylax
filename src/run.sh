#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

if [ -n "${SCHEDULE:-}" ]; then
  echo "[run] Starting scheduled backup service"
  echo "[run] Schedule: ${SCHEDULE}"
  echo "[run] Timezone: ${TZ}"

  # Write crontab
  mkdir -p /etc/cron.d
  printf '%s /bin/sh %s/backup.sh\n' "$SCHEDULE" "$SCRIPT_DIR" \
    > /etc/cron.d/pgbackup
  chmod 0644 /etc/cron.d/pgbackup

  # Run crond in foreground
  exec crond -f -l 2
else
  echo "[run] No SCHEDULE set - running backup once and exiting"
  exec /bin/sh "${SCRIPT_DIR}/backup.sh"
fi