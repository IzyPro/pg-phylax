#!/bin/sh
# notify.sh - Send Telegram notifications
# Usage: notify.sh <type> [message]
# Types: started | success | failure
#
# Sourced variables expected: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SERVER_NAME

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
NOTIFY_TYPE="${1:-}"
EXTRA_MSG="${2:-}"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---------- Escape text for Telegram MarkdownV2 -------------
# MarkdownV2 requires escaping: _ * [ ] ( ) ~ ` > # + - = | { } . !
escape_md() {
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/_/\\_/g' \
    -e 's/\*/\\*/g' \
    -e 's/\[/\\[/g' \
    -e 's/\]/\\]/g' \
    -e 's/(/\\(/g' \
    -e 's/)/\\)/g' \
    -e 's/~/\\~/g' \
    -e 's/`/\\`/g' \
    -e 's/>/\\>/g' \
    -e 's/#/\\#/g' \
    -e 's/+/\\+/g' \
    -e 's/-/\\-/g' \
    -e 's/=/\\=/g' \
    -e 's/|/\\|/g' \
    -e 's/{/\\{/g' \
    -e 's/}/\\}/g' \
    -e 's/\./\\./g' \
    -e 's/!/\\!/g'
}

send_message() {
  message="$1"
  # Send silently (no notification sound) for non-failure alerts
  silent="${2:-false}"

  response=$(curl \
    --silent \
    --max-time 15 \
    --retry 3 \
    --retry-delay 5 \
    --retry-connrefused \
    -X POST "$TELEGRAM_API" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="MarkdownV2" \
    -d disable_notification="${silent}" \
    --data-urlencode "text=${message}" \
    2>&1)

  # Check if Telegram returned ok:true
  if ! echo "$response" | grep -q '"ok":true'; then
    echo "[notify] WARNING: Telegram API returned unexpected response: $response" >&2
  fi
}

# ---------- Escape dynamic values ----------------------------
SAFE_SERVER="$(escape_md "$SERVER_NAME")"
SAFE_TIME="$(escape_md "$TIMESTAMP")"
SAFE_DBS="$(escape_md "$POSTGRES_DB")"
SAFE_EXTRA="$(escape_md "$EXTRA_MSG")"

# ---------- Build and send message by type -------------------
case "$NOTIFY_TYPE" in
  started)
    MESSAGE="$(printf '🔄 *BACKUP STARTED*\n━━━━━━━━━━━━━━━━━━━\n*Server:* %s\n*Database\\(s\\):* %s\n*Time:* %s\n━━━━━━━━━━━━━━━━━━━' \
      "$SAFE_SERVER" "$SAFE_DBS" "$SAFE_TIME")"
    send_message "$MESSAGE" "true"  # silent - no need to wake anyone up
    ;;

  success)
    SAFE_DAYS="$(escape_md "$BACKUP_KEEP_DAYS")"
    SAFE_WEEKS="$(escape_md "$BACKUP_KEEP_WEEKS")"
    SAFE_MONTHS="$(escape_md "$BACKUP_KEEP_MONTHS")"
    SAFE_BUCKET="$(escape_md "$S3_BUCKET")"
    SAFE_DURATION="$(escape_md "$EXTRA_MSG")"  # EXTRA_MSG is duration in seconds here
    MESSAGE="$(printf '✅ *BACKUP SUCCESSFUL*\n━━━━━━━━━━━━━━━━━━━\n*Server:* %s\n*Database\\(s\\):* %s\n*Time:* %s\n*Duration:* %ss\n*Retention:*\n  • Daily: %s days\n  • Weekly: %s weeks\n  • Monthly: %s months\n*Storage:* R2 › %s\n━━━━━━━━━━━━━━━━━━━' \
      "$SAFE_SERVER" "$SAFE_DBS" "$SAFE_TIME" "$SAFE_DURATION" \
      "$SAFE_DAYS" "$SAFE_WEEKS" "$SAFE_MONTHS" "$SAFE_BUCKET")"
    send_message "$MESSAGE" "true"  # silent on success
    ;;

  failure)
    MESSAGE="$(printf '🔴 *BACKUP FAILED*\n━━━━━━━━━━━━━━━━━━━\n*Server:* %s\n*Database\\(s\\):* %s\n*Time:* %s\n*Error:* %s\n━━━━━━━━━━━━━━━━━━━\n⚠️ _Immediate attention required_' \
      "$SAFE_SERVER" "$SAFE_DBS" "$SAFE_TIME" "$SAFE_EXTRA")"
    send_message "$MESSAGE" "false"  # NOT silent - alert the group
    ;;

  *)
    echo "[notify] ERROR: Unknown notification type: $NOTIFY_TYPE" >&2
    exit 1
    ;;
esac
