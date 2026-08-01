#!/usr/bin/env bash
# alerts.sh — notice problems and message you about them. Run from cron every
# 10 minutes or so.
#
# Every alert is deduplicated: the payload is hashed (ignoring timestamps) and
# stored in last-alert-state.json, so a service that stays broken produces one
# message, not one every ten minutes. The hash is cleared when it recovers, so
# the next occurrence alerts again.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/notify.sh"

STATUS_SH="$SCRIPT_DIR/status.sh"
FIX_SYNCTHING="$SCRIPT_DIR/fix-syncthing-markers.sh"
LOG="$BASE_DIR/logs/alerts.log"
STATE_FILE="$BASE_DIR/last-alert-state.json"

mkdir -p "$BASE_DIR/logs"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

send_msg() {
  if edgar_send "$1" 2>>"$LOG"; then
    log "  message sent"
  else
    log "  send failed"
  fi
}

hash_json() {
  echo "$1" | jq -c 'del(.queried_at, .monitor_timestamp, .checked_at, .timestamp)' | sha256sum | cut -d' ' -f1
}

# ---- state ----

ISSUES_HASH=""
RESOURCES_HASH=""
SYNCTHING_HASH=""
declare -A CRON_LAST_SEEN=()
STATE_CHANGED=0

if [[ -f "$STATE_FILE" ]]; then
  ISSUES_HASH=$(jq -r '.issues_hash // ""' "$STATE_FILE" 2>/dev/null || echo "")
  RESOURCES_HASH=$(jq -r '.resources_hash // ""' "$STATE_FILE" 2>/dev/null || echo "")
  SYNCTHING_HASH=$(jq -r '.syncthing_hash // ""' "$STATE_FILE" 2>/dev/null || echo "")
  while IFS="=" read -r key val; do
    [[ -n "$key" ]] && CRON_LAST_SEEN["$key"]="$val"
  done < <(jq -r '.cron_last_seen // {} | to_entries[] | .key + "=" + .value' "$STATE_FILE" 2>/dev/null || true)
fi

save_state() {
  local cron_json="{}"
  for k in "${!CRON_LAST_SEEN[@]}"; do
    cron_json=$(echo "$cron_json" | jq --arg k "$k" --arg v "${CRON_LAST_SEEN[$k]}" '. + {($k): $v}')
  done
  jq -n \
    --arg ih "$ISSUES_HASH" \
    --arg rh "$RESOURCES_HASH" \
    --arg sh "$SYNCTHING_HASH" \
    --argjson cl "$cron_json" \
    --arg ts "$(date -Iseconds)" \
    '{issues_hash: $ih, resources_hash: $rh, syncthing_hash: $sh, cron_last_seen: $cl, updated_at: $ts}' \
    > "$STATE_FILE"
}

# ---- services and failed jobs ----

check_issues() {
  log "checking: issues"
  local raw
  raw=$("$STATUS_SH" issues 2>/dev/null) || { log "  status.sh issues failed"; return; }

  local has_svc has_cron
  has_svc=$(echo "$raw" | jq -r '.has_service_issues // false')
  has_cron=$(echo "$raw" | jq -r '.has_cron_failures // false')

  if [[ "$has_svc" != "true" && "$has_cron" != "true" ]]; then
    log "  clear"
    if [[ -n "$ISSUES_HASH" ]]; then
      ISSUES_HASH=""
      STATE_CHANGED=1
      log "  dedup reset (recovered)"
    fi
    return
  fi

  local h
  h=$(hash_json "$raw")
  if [[ "$h" == "$ISSUES_HASH" ]]; then
    log "  unchanged (${h:0:12}) — staying quiet"
    return
  fi

  ISSUES_HASH="$h"
  STATE_CHANGED=1
  log "  new alert (${h:0:12})"

  local msg="🚨 *SERVICE ALERT*"

  if [[ "$has_svc" == "true" ]]; then
    local svc_issues
    svc_issues=$(echo "$raw" | jq -r '
      (.service_issues // [])[] |
      "🔴 " + .name + ": " + .status + (if .details != "" then " — " + .details else "" end)')
    [[ -n "$svc_issues" ]] && msg+=$'\n'"$svc_issues"
  fi

  if [[ "$has_cron" == "true" ]]; then
    local cron_fails
    cron_fails=$(echo "$raw" | jq -r '
      (.cron_failures_24h // [])[] |
      "🟡 job " + (.job_name // "unknown") + " failed (exit " + (.exit_code | tostring) + ")"')
    [[ -n "$cron_fails" ]] && msg+=$'\n'"$cron_fails"
  fi

  send_msg "$msg"
}

# ---- hardware thresholds ----

check_resources() {
  log "checking: resources"
  local raw
  raw=$("$STATUS_SH" resources 2>/dev/null) || { log "  status.sh resources failed"; return; }

  if [[ "$(echo "$raw" | jq -r '.has_resource_warnings // false')" != "true" ]]; then
    log "  clear"
    if [[ -n "$RESOURCES_HASH" ]]; then
      RESOURCES_HASH=""
      STATE_CHANGED=1
      log "  dedup reset (recovered)"
    fi
    return
  fi

  local h
  h=$(hash_json "$raw")
  if [[ "$h" == "$RESOURCES_HASH" ]]; then
    log "  unchanged (${h:0:12}) — staying quiet"
    return
  fi

  RESOURCES_HASH="$h"
  STATE_CHANGED=1
  log "  new alert (${h:0:12})"

  send_msg "⚠️ *HARDWARE ALERT*"$'\n\n'"$(echo "$raw" | jq -r '.warnings[]' | sed 's/^/⚠️ /')"
}

# ---- syncthing self-heal ----

check_syncthing_autofix() {
  log "checking: syncthing markers"
  local check_raw
  check_raw=$("$FIX_SYNCTHING" --check 2>/dev/null) || { log "  check failed"; return; }

  local err_count
  err_count=$(echo "$check_raw" | jq -r '.error_count // 0')

  if [[ "$err_count" == "0" ]]; then
    log "  clear"
    if [[ -n "$SYNCTHING_HASH" ]]; then
      SYNCTHING_HASH=""
      STATE_CHANGED=1
      log "  dedup reset (recovered)"
    fi
    return
  fi

  local h
  h=$(echo "$check_raw" | sha256sum | cut -d' ' -f1)
  if [[ "$h" == "$SYNCTHING_HASH" ]]; then
    log "  unchanged (${h:0:12}) — staying quiet"
    return
  fi

  SYNCTHING_HASH="$h"
  STATE_CHANGED=1
  log "  $err_count folder(s) in error — attempting fix"

  send_msg "🔴 *SYNCTHING ERROR*"$'\n'"${err_count} folder(s) missing their marker. Fixing automatically."

  local fix_raw
  if fix_raw=$("$FIX_SYNCTHING" 2>/dev/null); then
    local summary
    summary="fixed=$(echo "$fix_raw" | jq -r '.fixed // 0')"
    summary+=" already_ok=$(echo "$fix_raw" | jq -r '.already_ok // 0')"
    summary+=" failed=$(echo "$fix_raw" | jq -r '.failed | length')"
    log "  fix result: $summary"
    send_msg "🔧 *SYNCTHING FIX*"$'\n'"$summary"
  else
    log "  fix failed"
    send_msg "🔧 *SYNCTHING FIX*"$'\n'"Automatic fix failed."
  fi
}

# ---- job completion ----

check_cron_completion() {
  log "checking: job completions"
  local raw
  raw=$("$STATUS_SH" cron 2>/dev/null) || { log "  status.sh cron failed"; return; }

  if [[ "$(echo "$raw" | jq '.cron_jobs | length')" == "0" ]]; then
    log "  no jobs recorded"
    return
  fi

  while IFS= read -r job_json; do
    local job_name ts status exit_code stdout_preview prev_ts
    job_name=$(echo "$job_json" | jq -r '.job_name // "unknown"')
    ts=$(echo "$job_json" | jq -r '.timestamp // ""')
    status=$(echo "$job_json" | jq -r '.status // "unknown"')
    exit_code=$(echo "$job_json" | jq -r '.exit_code // "?"')
    # First non-empty stdout line — the summary, not the whole output
    stdout_preview=$(echo "$job_json" | jq -r '.stdout // ""' \
      | grep -m1 '[^[:space:]]' | sed 's/===//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-120 || true)

    prev_ts="${CRON_LAST_SEEN[$job_name]:-}"
    if [[ "$prev_ts" == "$ts" ]]; then
      log "  '$job_name' unchanged ($ts)"
      continue
    fi

    CRON_LAST_SEEN["$job_name"]="$ts"
    STATE_CHANGED=1
    log "  '$job_name' new result: $status ($ts)"

    local msg
    if [[ "$status" == "success" ]]; then
      msg="✅ *${job_name}*"
    else
      msg="🔴 *${job_name}*"
    fi
    msg+=$'\n'"🕐 ${ts}"
    [[ "$status" != "success" ]] && msg+=$'\n'"Status: ${status} (exit ${exit_code})"
    [[ -n "$stdout_preview" ]] && msg+=$'\n'"${stdout_preview}"
    send_msg "$msg"
  done < <(echo "$raw" | jq -c '.cron_jobs[]')
}

# ---- main ----

check_issues
check_resources
[[ -x "$FIX_SYNCTHING" ]] && check_syncthing_autofix || true
check_cron_completion

if [[ $STATE_CHANGED -eq 1 ]]; then
  save_state
  log "state saved"
fi

log "cycle done"
