#!/usr/bin/env bash
# =============================================================
# monitor.sh — check every service and write the result as JSON
# Run from cron every 5 minutes. status.sh reads what this writes.
#
# Which checks run is set by CHECKS in config.env.
# To add a service: write a check_<name> function and add <name> to CHECKS.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
LOG_FILE="$BASE_DIR/logs/monitor_$(date '+%Y%m%d_%H%M%S').json"

mkdir -p "$BASE_DIR/logs"

SERVICES_JSON=""

# add_service <name> <ok|warn|error> <details>
add_service() {
    local entry
    entry=$(jq -n --arg n "$1" --arg s "$2" --arg d "$3" \
        '{name: $n, status: $s, details: $d}')
    if [ -z "$SERVICES_JSON" ]; then
        SERVICES_JSON="$entry"
    else
        SERVICES_JSON="$SERVICES_JSON,$entry"
    fi
}

# -----------------------------------------------------------
# Pi-hole — FTL running, and DNS actually resolving
# -----------------------------------------------------------
check_pihole() {
    if ! systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        add_service "pihole" "error" "pihole-FTL is not active"
        return
    fi

    local dns_result
    dns_result=$(timeout "$SERVICE_TIMEOUT" dig @127.0.0.1 example.com +short 2>/dev/null | head -1 || true)

    if [ -n "$dns_result" ]; then
        add_service "pihole" "ok" "FTL up, DNS resolving (example.com -> $dns_result)"
    else
        add_service "pihole" "warn" "FTL up but DNS did not answer within ${SERVICE_TIMEOUT}s"
    fi
}

# -----------------------------------------------------------
# Syncthing — unit active, API reachable, no folder in error
# -----------------------------------------------------------
check_syncthing() {
    if ! systemctl is-active --quiet "$SYNCTHING_SERVICE" 2>/dev/null; then
        add_service "syncthing" "error" "$SYNCTHING_SERVICE is not active"
        return
    fi

    local folders
    folders=$(timeout "$SERVICE_TIMEOUT" curl -s \
        -H "X-API-Key: $SYNCTHING_API_KEY" \
        "$SYNCTHING_URL/rest/config/folders" 2>/dev/null || true)

    if [ -z "$folders" ] || ! echo "$folders" | jq -e '.' >/dev/null 2>&1; then
        add_service "syncthing" "error" "REST API did not answer within ${SERVICE_TIMEOUT}s"
        return
    fi

    local error_folders=()
    while IFS= read -r folder_id; do
        local fstatus ferror fstate
        fstatus=$(timeout "$SERVICE_TIMEOUT" curl -s -G \
            -H "X-API-Key: $SYNCTHING_API_KEY" \
            --data-urlencode "folder=$folder_id" \
            "$SYNCTHING_URL/rest/db/status" 2>/dev/null || true)
        [ -z "$fstatus" ] && continue
        ferror=$(echo "$fstatus" | jq -r '.errors // 0' 2>/dev/null || echo "0")
        fstate=$(echo "$fstatus" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
        if { [ "$ferror" != "0" ] && [ "$ferror" != "null" ]; } || [ "$fstate" = "error" ]; then
            error_folders+=("$folder_id (errors: $ferror, state: $fstate)")
        fi
    done < <(echo "$folders" | jq -r '.[].id' 2>/dev/null || true)

    if [ ${#error_folders[@]} -eq 0 ]; then
        add_service "syncthing" "ok" "Unit active, API answering, all folders healthy"
    else
        local err_list
        err_list=$(printf '%s; ' "${error_folders[@]}")
        add_service "syncthing" "warn" "Folders with problems: ${err_list%; }"
    fi
}

# -----------------------------------------------------------
# Tailscale — logged in and connected
# -----------------------------------------------------------
check_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        add_service "tailscale" "error" "tailscale binary not found"
        return
    fi

    local ts_status
    ts_status=$(timeout "$SERVICE_TIMEOUT" tailscale status 2>/dev/null || true)

    if [ -z "$ts_status" ]; then
        add_service "tailscale" "error" "tailscale did not answer within ${SERVICE_TIMEOUT}s"
        return
    fi

    if echo "$ts_status" | grep -q "Logged out\|not logged in\|stopped"; then
        add_service "tailscale" "error" "Disconnected: $(echo "$ts_status" | head -1)"
        return
    fi

    local active_peers my_ip
    active_peers=$(echo "$ts_status" | grep -v "^$" | grep -c "active\|direct" || true)
    my_ip=$(timeout "$SERVICE_TIMEOUT" tailscale ip -4 2>/dev/null | head -1 || echo "unknown")

    add_service "tailscale" "ok" "Connected, IP $my_ip, $active_peers active peer(s)"
}

# -----------------------------------------------------------
# Samba — smbd and nmbd
# -----------------------------------------------------------
check_samba() {
    local smbd_ok=false nmbd_ok=false
    systemctl is-active --quiet smbd 2>/dev/null && smbd_ok=true
    systemctl is-active --quiet nmbd 2>/dev/null && nmbd_ok=true

    if $smbd_ok && $nmbd_ok; then
        local share_count
        share_count=$(testparm -s 2>/dev/null | grep '^\[' \
            | grep -v '\[global\]\|\[printers\]\|\[print\$\]' | wc -l || true)
        add_service "samba" "ok" "smbd and nmbd up, $share_count share(s) configured"
    elif $smbd_ok; then
        add_service "samba" "warn" "smbd up but nmbd is inactive"
    else
        add_service "samba" "error" "smbd is not active"
    fi
}

# -----------------------------------------------------------
# Vaultwarden — container running and HTTPS answering
# -----------------------------------------------------------
check_vaultwarden() {
    local container_state
    container_state=$(docker inspect vaultwarden --format '{{.State.Status}}' 2>/dev/null)
    if [ "$container_state" != "running" ]; then
        add_service "vaultwarden" "error" "Container not running (state: ${container_state:-missing})"
        return
    fi
    if [ -z "$(curl -sk --max-time "$SERVICE_TIMEOUT" "$VAULTWARDEN_URL/alive" 2>/dev/null)" ]; then
        add_service "vaultwarden" "warn" "Container running but HTTPS did not answer within ${SERVICE_TIMEOUT}s"
        return
    fi
    add_service "vaultwarden" "ok" "Container running, HTTPS answering at $VAULTWARDEN_URL"
}

# -----------------------------------------------------------
# Run the configured checks
# -----------------------------------------------------------
for check in $CHECKS; do
    if declare -F "check_$check" >/dev/null; then
        "check_$check"
    else
        add_service "$check" "error" "No check_$check function in monitor.sh"
    fi
done

HAS_ISSUES=$(echo "[$SERVICES_JSON]" | jq '[.[] | select(.status != "ok")] | length > 0')

jq -n \
    --arg ts "$TIMESTAMP" \
    --argjson hi "$HAS_ISSUES" \
    --argjson svcs "[$SERVICES_JSON]" \
    '{timestamp: $ts, has_issues: $hi, services: $svcs}' > "$LOG_FILE"

ln -sf "$LOG_FILE" "$BASE_DIR/logs/latest.json"

echo "$LOG_FILE"
