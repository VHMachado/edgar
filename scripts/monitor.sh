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
# Unbound — the recursive resolver Pi-hole forwards to
# -----------------------------------------------------------
check_unbound() {
    if ! systemctl is-active --quiet unbound 2>/dev/null; then
        add_service "unbound" "error" "unbound is not active — Pi-hole has no upstream"
        return
    fi

    local port dns_result
    port="${UNBOUND_PORT:-5335}"
    dns_result=$(timeout "$SERVICE_TIMEOUT" dig @127.0.0.1 -p "$port" example.com +short 2>/dev/null | head -1 || true)

    if [ -n "$dns_result" ]; then
        add_service "unbound" "ok" "Recursion up on port $port (example.com -> $dns_result)"
    else
        add_service "unbound" "warn" "unbound up but did not answer on port $port within ${SERVICE_TIMEOUT}s"
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
# SearXNG — metasearch. Container up and the page answering.
# -----------------------------------------------------------
check_searxng() {
    local container_state code
    container_state=$(docker inspect searxng --format '{{.State.Status}}' 2>/dev/null)
    if [ "$container_state" != "running" ]; then
        add_service "searxng" "error" "Container not running (state: ${container_state:-missing})"
        return
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$SERVICE_TIMEOUT" \
        "$SEARXNG_URL/" 2>/dev/null)
    if [ "$code" != "200" ]; then
        add_service "searxng" "warn" "Container running but HTTP returned ${code:-nothing} at $SEARXNG_URL"
        return
    fi
    add_service "searxng" "ok" "Container running, search answering at $SEARXNG_URL"
}

# -----------------------------------------------------------
# Media stack — one aggregate entry, not one per container.
# Nine separate lines in a status message is noise; what matters
# is whether any of them is down.
# -----------------------------------------------------------
check_media() {
    local expected total=0 down="" n_down up

    if [ -z "${MEDIA_COMPOSE_FILE:-}" ]; then
        add_service "media" "error" "MEDIA_COMPOSE_FILE is not set in config.env"
        return
    fi

    # The list comes from the compose file, so swapping a service out of the
    # stack needs no edit here. A hardcoded list already broke once, the day
    # one download client replaced another.
    #
    # This works because every service in that stack uses
    # container_name == service name. Immich does not — see check_immich.
    expected=$(docker compose -f "$MEDIA_COMPOSE_FILE" config --services 2>/dev/null)
    if [ -z "$expected" ]; then
        add_service "media" "error" "Could not read $MEDIA_COMPOSE_FILE"
        return
    fi

    for c in $expected; do
        total=$((total + 1))
        if [ "$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)" != "running" ]; then
            down="$down $c"
        fi
    done

    n_down=$(echo $down | wc -w)
    up=$((total - n_down))

    if [ "$n_down" -eq "$total" ]; then
        add_service "media" "error" "Whole stack is down (0/$total)"
        return
    fi
    if [ "$n_down" -gt 0 ]; then
        add_service "media" "warn" "$up/$total containers running - down:$down"
        return
    fi

    add_service "media" "ok" "$up/$total containers running"
}

# -----------------------------------------------------------
# Immich — photo library. Whole compose project, plus the API.
# -----------------------------------------------------------
check_immich() {
    local expected running down n_down total code
    local -a compose=(docker compose)

    # Both files on purpose: the override is where a disabled machine-learning
    # service is parked behind a profile. With only the base file that service
    # counts again and the stack looks permanently one container short.
    compose+=(-f "$IMMICH_DIR/docker-compose.yml")
    [ -f "$IMMICH_DIR/docker-compose.override.yml" ] &&
        compose+=(-f "$IMMICH_DIR/docker-compose.override.yml")

    expected=$("${compose[@]}" config --services 2>/dev/null | sort)
    if [ -z "$expected" ]; then
        add_service "immich" "error" "Could not read the compose project in $IMMICH_DIR"
        return
    fi
    total=$(echo "$expected" | wc -l)

    # Service name != container_name here (immich-server -> immich_server), so
    # the down list comes from compose itself, not from docker inspect <name>.
    running=$("${compose[@]}" ps --status running --format '{{.Service}}' 2>/dev/null | sort)
    down=$(comm -23 <(echo "$expected") <(echo "$running") | tr '\n' ' ')
    n_down=$(echo $down | wc -w)

    if [ "$n_down" -eq "$total" ]; then
        add_service "immich" "error" "Whole stack is down (0/$total)"
        return
    fi
    if [ "$n_down" -gt 0 ]; then
        add_service "immich" "warn" "$((total - n_down))/$total containers running - down: $down"
        return
    fi

    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$SERVICE_TIMEOUT" \
        "$IMMICH_URL/api/server/ping" 2>/dev/null)
    if [ "$code" != "200" ]; then
        add_service "immich" "warn" "Containers up but HTTP returned ${code:-nothing} at $IMMICH_URL"
        return
    fi

    add_service "immich" "ok" "$total/$total containers running, API answering at $IMMICH_URL"
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
