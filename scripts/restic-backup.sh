#!/usr/bin/env bash
# restic-backup.sh — back up BACKUP_PATHS to a Backblaze B2 bucket with restic,
# and message you when it starts and finishes.
#
# Prints a JSON summary on stdout; the human-readable log lives in
# logs/restic-backup.log, which is what the bot's "backup" command reads.
#
# First run needs the repository to exist:
#   source restic.env
#   B2_ACCOUNT_ID="$B2_ACCOUNT_ID" B2_ACCOUNT_KEY="$B2_ACCOUNT_KEY" \
#     RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "b2:$B2_BUCKET" init

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/notify.sh"

RESTIC="${RESTIC_BIN:-restic}"
EXCLUDES_FILE="$SCRIPT_DIR/restic-excludes.txt"
LOG_FILE="$BASE_DIR/logs/restic-backup.log"
LOCK_FILE="$BASE_DIR/restic-backup.lock"

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# One run at a time — a slow backup must not stack up behind the next cron tick.
exec 200>"$LOCK_FILE"
flock -n 200 || { log "WARN: a backup is already running. Exiting."; exit 0; }

# shellcheck source=/dev/null
source "$SCRIPT_DIR/restic.env"

REPO="b2:${B2_BUCKET}"
read -ra PATHS <<< "$BACKUP_PATHS"

log "=== Backup started ==="
log "Repo: $REPO"
log "Paths: ${#PATHS[@]}"

START_EPOCH=$(date +%s)
START_TS=$(date -Iseconds)
STARTED_AT=$(date '+%d %b %H:%M')

edgar_send "⏳ Backup starting
📅 $STARTED_AT
Destination: Backblaze B2" 2>>"$LOG_FILE" || true

SUCCESS=false
SNAP_ID=""
FILES_NEW=0
FILES_CHANGED=0
FILES_UNMODIFIED=0
DATA_ADDED=0
ERROR_MSG=""

BACKUP_OUT=$(B2_ACCOUNT_ID="$B2_ACCOUNT_ID" B2_ACCOUNT_KEY="$B2_ACCOUNT_KEY" \
    RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    "$RESTIC" -r "$REPO" backup \
    "${PATHS[@]}" \
    --exclude-file="$EXCLUDES_FILE" \
    --compression auto \
    --tag "nas-backup" \
    --json 2>>"$LOG_FILE") && RC=0 || RC=$?

# rc 3 means "some files could not be read" — the snapshot is still valid.
if [ "$RC" -eq 0 ] || [ "$RC" -eq 3 ]; then
    SUMMARY=$(echo "$BACKUP_OUT" | jq -c 'select(.message_type == "summary")' 2>/dev/null | tail -1)
    if [ -n "$SUMMARY" ]; then
        SNAP_ID=$(echo "$SUMMARY" | jq -r '.snapshot_id // ""')
        FILES_NEW=$(echo "$SUMMARY" | jq -r '.files_new // 0')
        FILES_CHANGED=$(echo "$SUMMARY" | jq -r '.files_changed // 0')
        FILES_UNMODIFIED=$(echo "$SUMMARY" | jq -r '.files_unmodified // 0')
        DATA_ADDED=$(echo "$SUMMARY" | jq -r '.data_added // 0')
        SUCCESS=true
        log "OK: snapshot=$SNAP_ID files_new=$FILES_NEW data_added=${DATA_ADDED}B"

        B2_ACCOUNT_ID="$B2_ACCOUNT_ID" B2_ACCOUNT_KEY="$B2_ACCOUNT_KEY" \
            RESTIC_PASSWORD="$RESTIC_PASSWORD" \
            "$RESTIC" -r "$REPO" forget --prune \
            --keep-daily 7 --keep-weekly 4 --keep-monthly 12 \
            --json 2>>"$LOG_FILE" >/dev/null || log "WARN: forget/prune failed"
    else
        ERROR_MSG="restic returned no summary"
        log "FAILED: $ERROR_MSG"
    fi
else
    ERROR_MSG=$(echo "$BACKUP_OUT" | grep -v '"message_type":"status"' | head -2 | tr '\n' ' ' | cut -c1-200)
    log "FAILED (rc=$RC): $ERROR_MSG"
fi

TOTAL_DUR=$(( $(date +%s) - START_EPOCH ))
DUR_STR="$((TOTAL_DUR/60))min $((TOTAL_DUR%60))s"
log "=== Backup finished in ${TOTAL_DUR}s ==="

if [ "$SUCCESS" = true ]; then
    MSG="✅ Backup finished
📅 $STARTED_AT — $DUR_STR

📦 Snapshot: ${SNAP_ID:0:8}
📦 New: $FILES_NEW  Changed: $FILES_CHANGED"
    if [ "$DATA_ADDED" -gt 0 ]; then
        ADDED_STR=$(awk -v b="$DATA_ADDED" 'BEGIN{
            mb = b/1024/1024
            if (mb > 1024) printf "%.2f GB", mb/1024; else printf "%.1f MB", mb
        }')
        MSG+="
💾 New data: $ADDED_STR"
    fi
else
    MSG="⚠️ Backup FAILED
📅 $STARTED_AT — $DUR_STR

${ERROR_MSG:-unknown error}"
fi
edgar_send "$MSG" 2>>"$LOG_FILE" || true

jq -n \
    --arg started "$START_TS" \
    --arg finished "$(date -Iseconds)" \
    --argjson dur "$TOTAL_DUR" \
    --argjson ok "$SUCCESS" \
    --arg snap "$SNAP_ID" \
    --argjson fn "$FILES_NEW" \
    --argjson fc "$FILES_CHANGED" \
    --argjson fu "$FILES_UNMODIFIED" \
    --argjson da "$DATA_ADDED" \
    --arg err "$ERROR_MSG" \
    '{
        started_at: $started,
        finished_at: $finished,
        duration_seconds: $dur,
        success: $ok,
        snapshot_id: (if $snap == "" then null else $snap end),
        files_new: $fn,
        files_changed: $fc,
        files_unmodified: $fu,
        data_added_bytes: $da,
        error: (if $err == "" then null else $err end)
    }'
