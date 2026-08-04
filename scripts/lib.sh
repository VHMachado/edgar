#!/usr/bin/env bash
# lib.sh — formatting helpers shared between the scripts.
# Nothing here executes: source it.
#
# Sending lives in notify.sh, not here. This file is only about turning numbers
# into something readable on a phone.

# 20-char progress bar. Takes a percentage (0-100).
#   bar20 42  ->  ████████░░░░░░░░░░░░
bar20() {
    local pct=$1 filled empty b=""
    filled=$(awk -v p="$pct" 'BEGIN{printf "%d", (p/100)*20 + 0.5}')
    [ "$filled" -gt 20 ] && filled=20
    [ "$filled" -lt 0 ]  && filled=0
    empty=$((20 - filled))
    for ((i=0;i<filled;i++)); do b+=$'\xe2\x96\x88'; done
    for ((i=0;i<empty;i++)); do b+=$'\xe2\x96\x91'; done
    echo "$b"
}
