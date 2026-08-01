#!/usr/bin/env bash
# vaultwarden.sh — read/delete vault entries through the Bitwarden CLI.
# Always prints JSON. handlers.js parses these exact field names.
#
#   vaultwarden.sh list                  — every login entry (name + username)
#   vaultwarden.sh get "<query>"         — matching entries, with passwords
#   vaultwarden.sh search "<query>"      — like get, plus ids, no passwords
#   vaultwarden.sh delete "<id1,id2>"    — move entries to the vault trash
#
# The CLI syncs and does a TLS handshake on every call — 40s is normal.
# Callers must allow at least 90s.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

MODE="${1:-}"
QUERY="${2:-}"

BW="${BW_BIN:-bw}"
[ -n "${VAULTWARDEN_CA_CERT:-}" ] && export NODE_EXTRA_CA_CERTS="$VAULTWARDEN_CA_CERT"

if [ ! -f "$BW_MASTER_PWD_FILE" ]; then
    echo "{\"error\":\"master password file not found at $BW_MASTER_PWD_FILE\"}"
    exit 1
fi

export BW_PASSWORD
BW_PASSWORD=$(cat "$BW_MASTER_PWD_FILE")

SESSION=$($BW unlock --passwordenv BW_PASSWORD --raw 2>/dev/null)
if [ -z "$SESSION" ]; then
    echo '{"error":"could not unlock the vault — check that bw is logged in and the master password is right"}'
    exit 1
fi

# Always relock, even if jq or the CLI blows up midway.
trap '$BW lock --session "$SESSION" > /dev/null 2>&1' EXIT

$BW sync --session "$SESSION" > /dev/null 2>&1

case "$MODE" in
    list)
        RESULT=$($BW list items --session "$SESSION" 2>/dev/null)
        if [ -z "$RESULT" ] || [ "$RESULT" = "[]" ]; then
            echo '{"items":[],"count":0}'
        else
            echo "$RESULT" | jq '{
                count: ([.[] | select(.login != null)] | length),
                items: [.[] | select(.login != null) | {name: .name, username: .login.username}]
            }'
        fi
        ;;

    get)
        MATCHES=$($BW list items --search "$QUERY" --session "$SESSION" 2>/dev/null \
            | jq '[.[] | select(.login != null)]' 2>/dev/null)
        if [ -z "$MATCHES" ] || [ "$(echo "$MATCHES" | jq 'length')" = "0" ]; then
            jq -n --arg q "$QUERY" '{error: ("no entry found for: " + $q)}'
        else
            echo "$MATCHES" | jq '{
                count: length,
                items: [.[] | {name: .name, username: .login.username, password: .login.password}]
            }'
        fi
        ;;

    search)
        # Same as get but returns ids and no passwords — drives the delete flow.
        MATCHES=$($BW list items --search "$QUERY" --session "$SESSION" 2>/dev/null \
            | jq '[.[] | select(.login != null)]' 2>/dev/null)
        if [ -z "$MATCHES" ] || [ "$(echo "$MATCHES" | jq 'length')" = "0" ]; then
            echo '{"count":0,"items":[]}'
        else
            echo "$MATCHES" | jq '{
                count: length,
                items: [.[] | {id: .id, name: .name, username: .login.username}]
            }'
        fi
        ;;

    delete)
        # QUERY is a comma-separated id list. Items go to the trash, recoverable.
        DELETED=0
        ERRORS=0
        IFS=',' read -ra IDS <<< "$QUERY"
        for ID in "${IDS[@]}"; do
            if $BW delete item "$ID" --session "$SESSION" > /dev/null 2>&1; then
                DELETED=$((DELETED + 1))
            else
                ERRORS=$((ERRORS + 1))
            fi
        done
        $BW sync --session "$SESSION" > /dev/null 2>&1
        echo "{\"deleted\": $DELETED, \"errors\": $ERRORS}"
        ;;

    *)
        echo '{"error":"invalid mode. Use: list | get <query> | search <query> | delete <id1,id2,...>"}'
        exit 1
        ;;
esac
