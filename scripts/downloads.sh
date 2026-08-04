#!/usr/bin/env bash
# downloads.sh — qBittorrent's current state, as JSON. Prints and exits.
#
# On auth: if qBittorrent runs in Docker with the host publishing its port,
# requests from the host arrive with the bridge gateway as their source address.
# Put that subnet in qBittorrent's AuthSubnetWhitelist and this script needs no
# credentials. Otherwise set QB_URL to a URL carrying them.
#
# The output is always valid JSON, even when qBittorrent is down (ok:false).
# Callers decide whether an unreachable client is worth mentioning — for a
# 10-minute cron that is noise, so downloads-report.sh stays quiet.

set -euo pipefail

QB=${QB_URL:-http://127.0.0.1:8080}
TS=$(date -Iseconds)

fail() {
    jq -n --arg ts "$TS" --arg err "$1" \
        '{queried_at:$ts, ok:false, error:$err,
          downloading:[], completed:[],
          count_downloading:0, count_completed:0}'
    exit 0
}

RAW=$(curl -s -m 15 "$QB/api/v2/torrents/info" 2>/dev/null) || fail "qBittorrent unreachable"
[[ -n "$RAW" ]] || fail "empty response"
echo "$RAW" | jq -e 'type == "array"' >/dev/null 2>&1 || fail "response is not a torrent list"

echo "$RAW" | jq --arg ts "$TS" '
  def hsize:
    if . == null or . <= 0 then "?"
    elif . >= 1073741824 then ((. / 1073741824 * 10 | round) / 10 | tostring) + " GB"
    else (. / 1048576 | round | tostring) + " MB"
    end;

  def hspeed:
    if . == null or . <= 0 then "0 KB/s"
    elif . >= 1048576 then ((. / 1048576 * 10 | round) / 10 | tostring) + " MB/s"
    else (. / 1024 | round | tostring) + " KB/s"
    end;

  # 8640000 is qBittorrent stand-in for infinity: it shows up whenever there is
  # no download speed to extrapolate from.
  def heta:
    if . == null or . <= 0 or . >= 8640000 then "?"
    elif . >= 3600 then ((. / 3600) | floor | tostring) + "h "
                       + (((. % 3600) / 60) | floor | tostring) + "m"
    elif . >= 60 then ((. / 60) | floor | tostring) + "m"
    else (tostring) + "s"
    end;

  {
    queried_at: $ts,
    ok: true,
    downloading: [ .[] | select(.progress < 1) | {
      hash, name, category, state,
      progress_pct: ((.progress * 1000 | round) / 10),
      size:  (.size    | hsize),
      speed: (.dlspeed | hspeed),
      eta:   (.eta     | heta),
      seeds: .num_seeds
    } ],
    completed: [ .[] | select(.progress >= 1) | {
      hash, name, category,
      size: (.size | hsize)
    } ]
  }
  | .count_downloading = (.downloading | length)
  | .count_completed   = (.completed   | length)
'
