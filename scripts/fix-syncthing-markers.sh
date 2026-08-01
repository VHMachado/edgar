#!/usr/bin/env bash
# fix-syncthing-markers.sh
# Syncthing stops a folder when its .stfolder marker disappears — which happens
# whenever an external drive gets remounted empty. This finds those folders,
# recreates the marker and triggers a rescan.
#
# Normal mode: {fixed, already_ok, fixed_folders[], failed[]}
# --check    : {error_count, errors[], out_of_sync_count, out_of_sync[]}
#              read-only; alerts.sh calls this first.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ -z "${SYNCTHING_API_KEY:-}" ]; then
    echo '{"error": "SYNCTHING_API_KEY not set in config.env"}' >&2; exit 1
fi

if ! curl -sf -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_URL/rest/system/ping" > /dev/null 2>&1; then
    echo '{"error": "Syncthing API not reachable"}' >&2; exit 1
fi

FOLDERS=$(curl -sf -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_URL/rest/config/folders" 2>/dev/null)
if [ -z "$FOLDERS" ]; then
    echo '{"error": "could not list Syncthing folders"}' >&2; exit 1
fi

FIXED=0
ALREADY_OK=0
FAILED_LIST="[]"
FIXED_LIST="[]"
ERROR_COUNT=0
ERROR_LIST="[]"
OOS_COUNT=0
OOS_LIST="[]"

append() {   # append <json-array> <json-object>
    echo "$1" | jq -c --argjson e "$2" '. + [$e]'
}

while IFS=$'\t' read -r folder_id folder_path marker_name ignore_delete; do
    STATUS=$(curl -sf -G -H "X-API-Key: $SYNCTHING_API_KEY" \
        --data-urlencode "folder=$folder_id" \
        "$SYNCTHING_URL/rest/db/status" 2>/dev/null)

    STATE=$(echo "$STATUS" | jq -r '.state // ""' 2>/dev/null)
    NEED_BYTES=$(echo "$STATUS" | jq -r '.needBytes // 0' 2>/dev/null)
    MARKER_PATH="${folder_path%/}/$marker_name"

    if [ "$STATE" = "error" ] || [ "$STATE" = "stopped" ]; then
        if [ "$CHECK_ONLY" = "1" ]; then
            ERROR_COUNT=$((ERROR_COUNT + 1))
            MARKER_MISSING=false
            [ ! -e "$MARKER_PATH" ] && MARKER_MISSING=true
            ERROR_LIST=$(append "$ERROR_LIST" "$(jq -n \
                --arg id "$folder_id" --arg p "$folder_path" --arg s "$STATE" \
                --argjson mm "$MARKER_MISSING" \
                '{id:$id, path:$p, state:$s, marker_missing:$mm}')")
        elif [ ! -e "$MARKER_PATH" ]; then
            # A file, not a directory — Syncthing accepts either, but a file is
            # what it creates itself.
            if touch "$MARKER_PATH" 2>/dev/null; then
                curl -sf -X POST -G -H "X-API-Key: $SYNCTHING_API_KEY" \
                    --data-urlencode "folder=$folder_id" \
                    "$SYNCTHING_URL/rest/db/scan" > /dev/null 2>&1
                FIXED=$((FIXED + 1))
                FIXED_LIST=$(append "$FIXED_LIST" "$(jq -n \
                    --arg id "$folder_id" --arg p "$folder_path" --arg m "$MARKER_PATH" \
                    '{id:$id, path:$p, marker:$m}')")
            else
                FAILED_LIST=$(append "$FAILED_LIST" "$(jq -n \
                    --arg id "$folder_id" --arg p "$folder_path" \
                    '{id:$id, path:$p, reason:"touch failed"}')")
            fi
        else
            # Marker is there but the folder is still stopped — a rescan usually
            # clears it.
            curl -sf -X POST -G -H "X-API-Key: $SYNCTHING_API_KEY" \
                --data-urlencode "folder=$folder_id" \
                "$SYNCTHING_URL/rest/db/scan" > /dev/null 2>&1
            ALREADY_OK=$((ALREADY_OK + 1))
        fi

    elif [ "${NEED_BYTES:-0}" -gt 0 ] && [ "$ignore_delete" = "true" ]; then
        # Out of sync but the folder has Ignore Delete on — expected, not a fault.
        if [ "$CHECK_ONLY" = "1" ]; then
            OOS_COUNT=$((OOS_COUNT + 1))
            OOS_LIST=$(append "$OOS_LIST" "$(jq -n \
                --arg id "$folder_id" --arg p "$folder_path" --argjson nb "$NEED_BYTES" \
                '{id:$id, path:$p, need_bytes:$nb, ignore_delete:true}')")
        fi
    else
        [ "$CHECK_ONLY" = "0" ] && ALREADY_OK=$((ALREADY_OK + 1))
    fi

done < <(echo "$FOLDERS" | jq -r '.[] | [.id, .path, (.markerName // ".stfolder"), (.ignoreDelete // false | tostring)] | @tsv')

if [ "$CHECK_ONLY" = "1" ]; then
    jq -n --argjson ec "$ERROR_COUNT" --argjson e "$ERROR_LIST" \
          --argjson oc "$OOS_COUNT" --argjson o "$OOS_LIST" \
          '{error_count:$ec, errors:$e, out_of_sync_count:$oc, out_of_sync:$o}'
else
    jq -n --argjson f "$FIXED" --argjson a "$ALREADY_OK" \
          --argjson ff "$FIXED_LIST" --argjson fl "$FAILED_LIST" \
          '{fixed:$f, already_ok:$a, fixed_folders:$ff, failed:$fl}'
fi
