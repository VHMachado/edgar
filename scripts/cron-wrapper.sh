#!/usr/bin/env bash
# =============================================================
# cron-wrapper.sh — run a command, record how it went as JSON.
# Wrap your cron jobs in this and they show up under the bot's
# "cron" command, and failures reach you through alerts.sh.
#
# Usage: cron-wrapper.sh "job-name" command [args...]
# Exits with the wrapped command's exit code.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 \"job-name\" command [args...]" >&2
    exit 1
fi

JOB_NAME="$1"
shift
COMMAND=("$@")

TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
SAFE_NAME=$(echo "$JOB_NAME" | tr ' /' '_-' | tr -dc '[:alnum:]_-')
LOG_FILE="$BASE_DIR/logs/cron/${SAFE_NAME}_$(date '+%Y%m%d_%H%M%S').json"

mkdir -p "$BASE_DIR/logs/cron"

TMP_STDOUT=$(mktemp)
TMP_STDERR=$(mktemp)
trap 'rm -f "$TMP_STDOUT" "$TMP_STDERR"' EXIT

EXIT_CODE=0
"${COMMAND[@]}" >"$TMP_STDOUT" 2>"$TMP_STDERR" || EXIT_CODE=$?

# Cap at 10 KB each so one chatty job cannot produce a huge JSON file
STDOUT_CONTENT=$(head -c 10240 "$TMP_STDOUT" || true)
STDERR_CONTENT=$(head -c 10240 "$TMP_STDERR" || true)

if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="success"
else
    STATUS="failure"
fi

jq -n \
    --arg jn "$JOB_NAME" \
    --arg ts "$TIMESTAMP" \
    --argjson ec "$EXIT_CODE" \
    --arg out "$STDOUT_CONTENT" \
    --arg err "$STDERR_CONTENT" \
    --arg st "$STATUS" \
    --arg cmd "${COMMAND[*]}" \
    '{
        job_name: $jn,
        timestamp: $ts,
        exit_code: $ec,
        status: $st,
        command: $cmd,
        stdout: $out,
        stderr: $err
    }' > "$LOG_FILE"

# Same exit code as the wrapped command — cron needs to see failures
exit "$EXIT_CODE"
