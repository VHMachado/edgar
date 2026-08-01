#!/usr/bin/env bash
# =============================================================
# status.sh — read side of the monitor. Always prints JSON.
# This is the contract the bot's handlers.js parses.
#
# Modes:
#   all         → last full monitor run (default)
#   issues      → services not ok + cron jobs that failed in the last 24h
#   cron        → latest result per cron job
#   resources   → live CPU/memory/swap/disk/uptime (delegates to resources.sh)
#   <service>   → one service from the last monitor run
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

MODE="${1:-all}"

get_latest_monitor() {
    local latest="$BASE_DIR/logs/latest.json"
    if [ ! -f "$latest" ]; then
        jq -n '{error: "No monitor result yet. Run monitor.sh first.", timestamp: null}'
        return
    fi
    cat "$latest"
}

get_cron_failures_24h() {
    local cutoff
    cutoff=$(date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
             date -v-24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

    local cron_dir="$BASE_DIR/logs/cron"
    [ -d "$cron_dir" ] || { echo "[]"; return; }

    local failures="[]"
    while IFS= read -r -d '' f; do
        local entry
        entry=$(jq -e --arg cutoff "$cutoff" \
            'select(.status == "failure" and .timestamp >= $cutoff)' "$f" 2>/dev/null || true)
        [ -n "$entry" ] && failures=$(echo "$failures" | jq ". + [$entry]")
    done < <(find "$cron_dir" -name "*.json" -print0 2>/dev/null)

    echo "$failures"
}

get_latest_cron_results() {
    local cron_dir="$BASE_DIR/logs/cron"
    if [ ! -d "$cron_dir" ] || [ -z "$(ls -A "$cron_dir" 2>/dev/null)" ]; then
        jq -n '{cron_jobs: [], message: "No cron results recorded yet"}'
        return
    fi

    local all_results="[]"
    while IFS= read -r -d '' f; do
        local entry
        entry=$(jq -e '.' "$f" 2>/dev/null || true)
        [ -n "$entry" ] && all_results=$(echo "$all_results" | jq ". + [$entry]")
    done < <(find "$cron_dir" -name "*.json" -print0 2>/dev/null)

    # Newest run per job_name
    echo "$all_results" | jq 'group_by(.job_name) | map(sort_by(.timestamp) | last) | {cron_jobs: .}'
}

case "$MODE" in
    all)
        get_latest_monitor
        exit 0
        ;;

    issues)
        MONITOR_DATA=$(get_latest_monitor)
        CRON_FAILURES=$(get_cron_failures_24h)

        PROBLEM_SERVICES=$(echo "$MONITOR_DATA" | jq '[.services[] | select(.status != "ok")]' 2>/dev/null || echo "[]")
        MONITOR_TS=$(echo "$MONITOR_DATA" | jq -r '.timestamp // "unknown"' 2>/dev/null || echo "unknown")

        jq -n \
            --arg ts "$MONITOR_TS" \
            --argjson ps "$PROBLEM_SERVICES" \
            --argjson cf "$CRON_FAILURES" \
            '{
                queried_at: (now | todate),
                monitor_timestamp: $ts,
                has_service_issues: ($ps | length > 0),
                has_cron_failures: ($cf | length > 0),
                service_issues: $ps,
                cron_failures_24h: $cf
            }'
        exit 0
        ;;

    cron)
        get_latest_cron_results
        exit 0
        ;;

    resources)
        exec "$SCRIPT_DIR/resources.sh"
        ;;

    vaultwarden)
        # Live, unlike the other services — the container state is cheap to read
        # and this is the one people check right after a restart.
        CONTAINER=$(docker inspect vaultwarden --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
        HEALTH=$(docker inspect vaultwarden --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        STARTED=$(docker inspect vaultwarden --format '{{.State.StartedAt}}' 2>/dev/null || echo "")

        if [ "$CONTAINER" != "running" ]; then
            jq -n --arg c "$CONTAINER" \
                '{name:"vaultwarden", status:"error", details:"Container is not running", container:$c, health:"unknown"}'
            exit 0
        fi

        CURL_ARGS=(-sk --max-time 5)
        [ -n "${VAULTWARDEN_CA_CERT:-}" ] && CURL_ARGS+=(--cacert "$VAULTWARDEN_CA_CERT")
        HTTP=$(timeout 8 curl "${CURL_ARGS[@]}" "$VAULTWARDEN_URL/alive" 2>/dev/null | head -c 50 || true)

        if [ -n "$HTTP" ]; then
            jq -n --arg h "$HEALTH" --arg u "$STARTED" --arg url "$VAULTWARDEN_URL" \
                '{name:"vaultwarden", status:"ok", details:("Container running, HTTPS answering at " + $url), container:"running", health:$h, started_at:$u}'
        else
            jq -n --arg h "$HEALTH" --arg u "$STARTED" \
                '{name:"vaultwarden", status:"warn", details:"Container running but HTTPS did not answer", container:"running", health:$h, started_at:$u}'
        fi
        exit 0
        ;;
esac

# Any other mode: look the name up in the last monitor run.
MONITOR_DATA=$(get_latest_monitor)
SERVICE_DATA=$(echo "$MONITOR_DATA" | jq --arg name "$MODE" \
    '.services[]? | select(.name == $name)' 2>/dev/null || true)

if [ -n "$SERVICE_DATA" ]; then
    MONITOR_TS=$(echo "$MONITOR_DATA" | jq -r '.timestamp // "unknown"')
    echo "$SERVICE_DATA" | jq --arg ts "$MONITOR_TS" '. + {monitor_timestamp: $ts}'
    exit 0
fi

jq -n --arg m "$MODE" --argjson known "$(echo "$MONITOR_DATA" | jq '[.services[]?.name]')" \
    '{
        error: ("Unknown mode: \"" + $m + "\""),
        valid_modes: (["all","issues","cron","resources"] + $known)
    }'
exit 1
