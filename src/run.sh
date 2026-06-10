#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/env.sh"

if [ -n "${SCHEDULE:-}" ]; then
  echo "[run] Starting scheduled backup service"
  echo "[run] Schedule: ${SCHEDULE}"
  echo "[run] Timezone: ${TZ}"

  # Write crontab file for supercronic
  printf '%s /bin/sh %s/backup.sh\n' "$SCHEDULE" "$SCRIPT_DIR" \
    > /etc/supercronic-crontab

  echo "[run] Crontab written:"
  cat /etc/supercronic-crontab

  # busybox crond - -f foreground, -d 8 log level
  exec supercronic -passthrough-logs /etc/supercronic-crontab
else
  echo "[run] No SCHEDULE set - running backup once and exiting"
  exec /bin/sh "${SCRIPT_DIR}/backup.sh"
fi