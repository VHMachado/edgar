#!/usr/bin/env bash
# notify.sh — shared "send me a WhatsApp message" helper.
# Source it, then call: edgar_send "text"
#
# Reads the bot's own .env so the token and recipient live in exactly one place.
# Sourced by heartbeat.sh, alerts.sh and restic-backup.sh.

EDGAR_ENV="${EDGAR_ENV:-/opt/edgar-bot/.env}"

# shellcheck source=/dev/null
source "$EDGAR_ENV" 2>/dev/null || true

EDGAR_SEND_URL="http://${EDGAR_HTTP_HOST:-127.0.0.1}:${EDGAR_HTTP_PORT:-18790}/send"
EDGAR_TO="${EDGAR_DEFAULT_TO:-}"

# edgar_send <text> — returns 0 on delivery, 1 otherwise. Never fatal by itself;
# the caller decides whether a failed notification is worth exiting over.
edgar_send() {
    if [[ -z "${EDGAR_TOKEN:-}" ]]; then
        echo "edgar_send: EDGAR_TOKEN not set in $EDGAR_ENV" >&2
        return 1
    fi
    if [[ -z "$EDGAR_TO" ]]; then
        echo "edgar_send: EDGAR_DEFAULT_TO not set in $EDGAR_ENV" >&2
        return 1
    fi

    local payload response status
    payload=$(jq -cn --arg to "$EDGAR_TO" --arg text "$1" '{to: $to, text: $text}')
    response=$(mktemp)
    status=$(curl -s -o "$response" -w "%{http_code}" \
        -X POST "$EDGAR_SEND_URL" \
        -H "Content-Type: application/json" \
        -H "X-Edgar-Token: $EDGAR_TOKEN" \
        -d "$payload")

    if [[ "$status" == "200" ]]; then
        rm -f "$response"
        return 0
    fi
    echo "edgar_send: HTTP $status — $(cat "$response" 2>/dev/null)" >&2
    rm -f "$response"
    return 1
}
