#!/usr/bin/env bash
# downloads-report.sh — push download progress over WhatsApp. Run from cron
# every 10 minutes or so.
#
# This deliberately does not live in heartbeat.sh. Progress on a 30-minute
# cycle is too coarse to be useful, and bolting it onto the status summary made
# one message carry two unrelated things. Own message, own cadence.
#
# Silent when nothing is downloading — otherwise it would be 144 messages a day
# saying there is nothing to say. Also silent when qBittorrent is unreachable:
# alerts.sh is what tells you a service is down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/notify.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

DOWNLOADS_SH="$SCRIPT_DIR/downloads.sh"
LOG="$BASE_DIR/logs/downloads-report.log"

mkdir -p "$BASE_DIR/logs"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

DL_JSON=$("$DOWNLOADS_SH" 2>/dev/null) || { log "downloads.sh failed"; exit 0; }

if [[ "$(echo "$DL_JSON" | jq -r '.ok')" != "true" ]]; then
  log "qBittorrent unavailable: $(echo "$DL_JSON" | jq -r '.error // "no detail"')"
  exit 0
fi

COUNT=$(echo "$DL_JSON" | jq -r '.count_downloading')
if [[ "$COUNT" == "0" ]]; then
  log "nothing downloading — staying quiet"
  exit 0
fi

# Same shape as the bot's "queue" command, so the pushed message and the one you
# ask for look identical: two lines per torrent, blank line between blocks.
ENTRIES=()
while IFS=$'\t' read -r name pct speed eta cat; do
  [[ -z "$name" ]] && continue
  case "$cat" in
    tv)     emoji="📺" ;;
    movies) emoji="🎬" ;;
    books)  emoji="📚" ;;
    *)      emoji="📦" ;;
  esac
  ENTRIES+=("${emoji} ${name:0:38}"$'\n'"$(bar20 "$pct") ${pct}% · ${speed} · ETA ${eta}")
done < <(echo "$DL_JSON" | jq -r '
  .downloading[] | [.name, (.progress_pct|tostring), .speed, .eta, .category] | @tsv')

MSG="📥 *Downloading now* (${COUNT})"
for e in "${ENTRIES[@]}"; do MSG+=$'\n\n'"${e}"; done

log "reporting ${COUNT} download(s)"

if edgar_send "$MSG" 2>>"$LOG"; then
  log "sent"
else
  log "send failed"
  exit 1
fi
