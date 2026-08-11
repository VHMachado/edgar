#!/usr/bin/env bash
# Exercises every branch of check_immich() with docker and curl stubbed out.
# Touches no container and needs no config.env. Run: bash test-check-immich.sh
#
# Stopping a real container to test the unhappy path is not free here: Immich
# queues its jobs in Redis, so killing it mid-import loses the queue.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/monitor.sh"

# Pull out just the function — monitor.sh runs every check when sourced.
FUNC=$(sed -n '/^check_immich() {/,/^}/p' "$SRC")
[ -n "$FUNC" ] || { echo "FAIL: check_immich() not found in $SRC"; exit 1; }

SERVICE_TIMEOUT=5
IMMICH_DIR=/opt/immich
IMMICH_URL=http://127.0.0.1:2283
FAILED=0

run_case() {
    # The t_ prefix is load-bearing. Bash scoping is dynamic, and check_immich
    # declares its own `local running`. Without the prefix the docker stub
    # reads that variable — empty at call time — instead of the case's value,
    # and every case reports the whole stack down.
    local name="$1" t_services="$2" t_running="$3" t_http="$4" want_status="$5" want_substr="$6"
    local out status details

    out=$(
        SERVICES_JSON=""
        add_service() { printf '%s\t%s\t%s' "$2" "$1" "$3"; }
        docker() {
            case "$*" in
                *"config --services"*)   printf '%s' "$t_services" ;;
                *"ps --status running"*) printf '%s' "$t_running" ;;
            esac
        }
        curl() { printf '%s' "$t_http"; }
        eval "$FUNC"
        check_immich
    )
    status=$(cut -f1 <<<"$out")
    details=$(cut -f3 <<<"$out")

    if [ "$status" = "$want_status" ] && [[ "$details" == *"$want_substr"* ]]; then
        echo "  ok    $name -> $status: $details"
    else
        echo "  FAIL  $name"
        echo "        wanted: $want_status containing '$want_substr'"
        echo "        got:    $status: $details"
        FAILED=1
    fi
}

THREE=$'database\nredis\nimmich-server'

echo "check_immich:"
run_case "all up"          "$THREE" "$THREE"            "200" "ok"    "3/3 containers"
run_case "one down"        "$THREE" $'database\nredis' "200" "warn"  "immich-server"
run_case "whole stack down" "$THREE" ""                 "000" "error" "0/3"
run_case "API not answering" "$THREE" "$THREE"          "502" "warn"  "502"
run_case "compose unreadable" ""     ""                 "200" "error" "compose project"

if [ "$FAILED" -eq 0 ]; then echo "all cases ok"; else echo "FAILURES"; fi
exit "$FAILED"
