#!/usr/bin/env bash
# =============================================================
# cleanup.sh — delete monitor/cron/alert JSON older than
# LOG_RETENTION_DAYS. Run daily from cron.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

REMOVED=0

prune() {
    local dir="$1" pattern="$2" depth="$3"
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' f; do
        rm -f "$f"
        REMOVED=$((REMOVED + 1))
    done < <(find "$dir" $depth -name "$pattern" -mtime +"$LOG_RETENTION_DAYS" -print0 2>/dev/null)
}

prune "$BASE_DIR/logs"      "monitor_*.json" "-maxdepth 1"
prune "$BASE_DIR/logs/cron" "*.json"         ""
prune "$BASE_DIR/alerts"    "*.json"         ""

echo "[$(date '+%Y-%m-%dT%H:%M:%S')] cleanup.sh: removed $REMOVED file(s) (retention: ${LOG_RETENTION_DAYS}d)"
