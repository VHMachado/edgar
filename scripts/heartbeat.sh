#!/usr/bin/env bash
# heartbeat.sh — push a full status summary over WhatsApp.
# Run from cron (every 30 min works well); the bot's "heartbeat" command
# triggers the same script on demand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/notify.sh"

MONITOR_JSON="$BASE_DIR/logs/latest.json"
LOG="$BASE_DIR/logs/heartbeat.log"

mkdir -p "$BASE_DIR/logs"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

log "collecting status"

# --- services ---
if [[ -f "$MONITOR_JSON" ]]; then
  MON_JSON=$(cat "$MONITOR_JSON")
  MON_OK=1
else
  MON_JSON='{}'
  MON_OK=0
  log "WARN: $MONITOR_JSON not found"
fi

# --- hardware ---
RES_JSON=$("$SCRIPT_DIR/resources.sh" 2>/dev/null) && RES_OK=1 || RES_OK=0

if [[ $MON_OK -eq 0 && $RES_OK -eq 0 ]]; then
  log "ERROR: both sources failed — nothing to report"
  exit 1
fi

ALL_OK=1
SVC_LINES=()

if [[ $MON_OK -eq 1 ]]; then
  while IFS= read -r line; do
    SVC_LINES+=("$line")
    [[ "$line" == *"🔴"* || "$line" == *"⚠️"* ]] && ALL_OK=0
  done < <(echo "$MON_JSON" | jq -r '
    .services[] |
    .name as $name |
    ({"pihole":"🛡️","syncthing":"🔄","tailscale":"🔒","samba":"📁","vaultwarden":"🔑"}[$name] // "⚙️") as $emoji |
    (if .status == "ok" then "✅" elif .status == "warn" then "⚠️" else "🔴" end)
    + " " + $emoji + " " + $name + " — " + (if .details != "" then .details else .status end)
  ')
else
  SVC_LINES=("❌ Monitor unavailable")
  ALL_OK=0
fi

HAS_RES_WARN=0
HW_LINES=()

if [[ $RES_OK -eq 1 ]]; then
  HAS_RES_WARN=$(echo "$RES_JSON" | jq -r 'if .has_resource_warnings then 1 else 0 end')

  HW_LINES+=("🖥️ CPU: $(echo "$RES_JSON" | jq -r '.cpu.load_per_cpu')/core ($(echo "$RES_JSON" | jq -r '(.cpu.load_per_cpu * 100 | floor)')%)")
  HW_LINES+=("🧠 RAM: $(echo "$RES_JSON" | jq -r '.memory.used_pct')% ($(echo "$RES_JSON" | jq -r '.memory.used_mb')MB/$(echo "$RES_JSON" | jq -r '.memory.total_mb')MB)")
  HW_LINES+=("🔄 Swap: $(echo "$RES_JSON" | jq -r '.swap.used_pct')%")

  while IFS= read -r disk_line; do
    HW_LINES+=("$disk_line")
  done < <(echo "$RES_JSON" | jq -r '
    .disks[] |
    select((.source | startswith("/dev/")) and (.total_gb > 1)) |
    "💿 " + .mount + ": " + (.used_pct | tostring) + "% (" + (.avail_gb | floor | tostring) + "GB free)"
  ')

  HW_LINES+=("⏱️ Uptime: $(echo "$RES_JSON" | jq -r '.uptime.human')")

  if [[ $HAS_RES_WARN -eq 1 ]]; then
    ALL_OK=0
    while IFS= read -r warn; do
      HW_LINES+=("⚠️ ${warn}")
    done < <(echo "$RES_JSON" | jq -r '.warnings[]')
  fi
else
  HW_LINES=("❌ Resources unavailable")
  ALL_OK=0
fi

if [[ $ALL_OK -eq 1 ]]; then
  HEADER="🟢 ALL OK"
else
  HEADER="🔴 NEEDS ATTENTION"
fi

MSG="${HEADER} — $(date '+%H:%M')"$'\n'
MSG+=$'\n'"📡 *Services*"$'\n'
for l in "${SVC_LINES[@]}"; do MSG+="${l}"$'\n'; done
MSG+=$'\n'"📊 *Hardware*"$'\n'
for l in "${HW_LINES[@]}"; do MSG+="${l}"$'\n'; done
MSG="${MSG%$'\n'}"

log "built heartbeat: $HEADER"

if edgar_send "$MSG" 2>>"$LOG"; then
  log "sent OK"
else
  log "send failed"
  exit 1
fi
