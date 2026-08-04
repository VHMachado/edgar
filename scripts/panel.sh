#!/usr/bin/env bash
# panel.sh — detailed per-service panels, pre-formatted for WhatsApp.
# Usage: panel.sh <pihole|syncthing|tailscale>
# Prints the panel on stdout, or "ERROR: <message>" and exits non-zero.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

SERVICE="${1:-}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

fmt_num() {
    python3 -c "n=int(float('$1')); print(f'{n:,}')"
}

# Syncthing hands back folder labels as UTF-8 bytes decoded as Latin-1, so
# "Vídeos" arrives as "VÃ­deos". Re-encode to undo it.
fix_encoding() {
    python3 -c "
import sys
s = sys.stdin.read().rstrip('\n')
try:
    print(s.encode('latin-1').decode('utf-8'), end='')
except Exception:
    print(s, end='')
"
}

fmt_sync_time() {
    python3 - "$1" <<'PYEOF'
import sys, re
from datetime import datetime
s = sys.argv[1] if len(sys.argv) > 1 else ''
if not s or s == 'null':
    sys.exit(0)
try:
    # -07:00 -> -0700 so strptime accepts it
    s_clean = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', s[:25])
    d = datetime.strptime(s_clean, '%Y-%m-%dT%H:%M:%S%z').astimezone()
    print(d.strftime('%d %b %H:%M'), end='')
except Exception:
    pass
PYEOF
}

# ─── pihole ───────────────────────────────────────────
if [ "$SERVICE" = "pihole" ]; then
    if [ -z "${PIHOLE_PASSWORD:-}" ]; then
        echo "ERROR: PIHOLE_PASSWORD is not set in config.env"
        exit 1
    fi

    AUTH=$(curl -s -X POST "$PIHOLE_URL/api/auth" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"$PIHOLE_PASSWORD\"}")
    SID=$(echo "$AUTH" | jq -r '.session.sid // empty')

    if [ -z "$SID" ]; then
        echo "ERROR: authentication failed: $(echo "$AUTH" | jq -r '.session.message // "wrong password"')"
        exit 1
    fi

    SUMMARY=$(curl -s "$PIHOLE_URL/api/stats/summary?sid=$SID")
    TOP_BLOCKED=$(curl -s "$PIHOLE_URL/api/stats/top_domains?count=1&blocked=true&sid=$SID")
    TOP_ALLOWED=$(curl -s "$PIHOLE_URL/api/stats/top_domains?count=1&blocked=false&sid=$SID")
    TOP_CLIENTS=$(curl -s "$PIHOLE_URL/api/stats/top_clients?count=1&sid=$SID")
    RECENT=$(curl -s "$PIHOLE_URL/api/queries?blocked=true&count=1&sid=$SID")

    curl -s -X DELETE "$PIHOLE_URL/api/auth/$SID" > /dev/null 2>&1

    PCT=$(echo "$SUMMARY" | jq '.queries.percent_blocked // 0')

    printf '📊 *Pi-hole*\n'
    printf '\n'
    printf 'Blocked: [%s] %.1f%%\n' "$(bar20 "$PCT")" "$PCT"
    printf '%s of %s queries\n' \
        "$(fmt_num "$(echo "$SUMMARY" | jq '.queries.blocked // 0')")" \
        "$(fmt_num "$(echo "$SUMMARY" | jq '.queries.total // 0')")"
    printf '\n'
    printf '🚫 Domains on blocklists: %s\n' "$(fmt_num "$(echo "$SUMMARY" | jq '.gravity.domains_being_blocked // 0')")"
    printf '🌐 Top allowed domain: %s\n'   "$(echo "$TOP_ALLOWED" | jq -r '.domains[0].domain // "N/A"')"
    printf '📈 Top blocked domain: %s\n'   "$(echo "$TOP_BLOCKED" | jq -r '.domains[0].domain // "N/A"')"
    printf '🔒 Last block: %s\n'           "$(echo "$RECENT" | jq -r '.queries[0].domain // "N/A"')"
    printf '👥 Active clients: %s\n'       "$(echo "$SUMMARY" | jq '.clients.active // 0')"
    printf '👤 Noisiest client: %s\n'      "$(echo "$TOP_CLIENTS" | jq -r \
        'if .clients[0] == null then "N/A" elif .clients[0].name != "" then .clients[0].name else .clients[0].ip end')"
    exit 0
fi

# ─── syncthing ────────────────────────────────────────
if [ "$SERVICE" = "syncthing" ]; then
    FOLDERS=$(curl -s "$SYNCTHING_URL/rest/config/folders" \
        -H "X-API-Key: $SYNCTHING_API_KEY" 2>/dev/null)

    if [ -z "$FOLDERS" ] || echo "$FOLDERS" | grep -q '"error"'; then
        echo "ERROR: could not reach Syncthing"
        exit 1
    fi

    printf '📊 *Syncthing*\n'
    printf '\n'

    while IFS= read -r FOLDER_ID; do
        LABEL=$(echo "$FOLDERS" | jq -r --arg id "$FOLDER_ID" '.[] | select(.id == $id) | .label' | fix_encoding)
        PAUSED=$(echo "$FOLDERS" | jq -r --arg id "$FOLDER_ID" '.[] | select(.id == $id) | .paused')

        if [ "$PAUSED" = "true" ]; then
            printf '📁 %s — ⏸️ paused\n' "$LABEL"
            continue
        fi

        DB=$(curl -s -G "$SYNCTHING_URL/rest/db/status" \
            --data-urlencode "folder=$FOLDER_ID" \
            -H "X-API-Key: $SYNCTHING_API_KEY" 2>/dev/null)
        STATE=$(echo "$DB" | jq -r '.state // "unknown"')
        ERR=$(echo "$DB"   | jq -r '.error // ""')
        NEED=$(echo "$DB"  | jq '.needTotalItems // 0')
        SYNC_TIME=$(fmt_sync_time "$(echo "$DB" | jq -r '.stateChanged // ""')")

        case "$STATE" in
            idle)
                if [ "$NEED" -eq 0 ]; then
                    STATUS="✅ in sync${SYNC_TIME:+ · $SYNC_TIME}"
                else
                    STATUS="🔄 waiting ($NEED items)"
                fi ;;
            scanning) STATUS="🔄 scanning" ;;
            syncing)  STATUS="🔄 syncing" ;;
            error)    STATUS="❌ error${ERR:+: $ERR}" ;;
            paused)   STATUS="⏸️ paused" ;;
            *)        STATUS="❓ unknown" ;;
        esac

        printf '📁 %s — %s\n' "$LABEL" "$STATUS"
    done < <(echo "$FOLDERS" | jq -r '.[].id')

    exit 0
fi

# ─── tailscale ────────────────────────────────────────
if [ "$SERVICE" = "tailscale" ]; then
    TS_JSON=$(tailscale status --json 2>/dev/null)
    if [ -z "$TS_JSON" ]; then
        echo "ERROR: could not read Tailscale status"
        exit 1
    fi

    fmt_date() {
        python3 - "$1" <<'PYEOF'
import sys
from datetime import datetime
try:
    print(datetime.strptime(sys.argv[1][:19], '%Y-%m-%dT%H:%M:%S').strftime('%d %b'))
except Exception:
    print('?')
PYEOF
    }

    printf '📊 *Tailscale*\n'
    printf '\n'

    # This machine first
    printf '🟢 %s — %s — %s\n' \
        "$(hostname)" \
        "$(echo "$TS_JSON" | jq -r '.Self.TailscaleIPs[0]')" \
        "$(echo "$TS_JSON" | jq -r '.Self.OS')"

    while IFS=$'\t' read -r NAME OS IP; do
        printf '🟢 %s — %s — %s\n' "$NAME" "$IP" "$OS"
    done < <(echo "$TS_JSON" | jq -r '
        .Peer[] | select(.Online == true) | [
            (if .HostName == "localhost" then (.DNSName | split(".")[0]) else .HostName end),
            .OS,
            .TailscaleIPs[0]
        ] | @tsv')

    while IFS=$'\t' read -r NAME OS IP LAST_SEEN; do
        printf '🔴 %s — %s — %s (last seen %s)\n' "$NAME" "$IP" "$OS" "$(fmt_date "$LAST_SEEN")"
    done < <(echo "$TS_JSON" | jq -r '
        .Peer[] | select(.Online == false) | [
            (if .HostName == "localhost" then (.DNSName | split(".")[0]) else .HostName end),
            .OS,
            .TailscaleIPs[0],
            .LastSeen
        ] | @tsv')

    exit 0
fi

echo "ERROR: unknown service \"$SERVICE\". Valid: pihole, syncthing, tailscale"
exit 1
