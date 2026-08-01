#!/usr/bin/env bash
# =============================================================
# resources.sh — CPU/memory/swap/disk/uptime snapshot as JSON.
# Called by "status.sh resources", or directly.
#
# Sets has_resource_warnings when a threshold is crossed; alerts.sh keys off
# that. Thresholds are the three awk lines near the bottom — tune them there.
# =============================================================

set -u

# -- CPU / load ----------------------------------------------
CPU_COUNT=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
LOAD_PER_CPU=$(awk -v l="$LOAD1" -v c="$CPU_COUNT" 'BEGIN{ printf "%.2f", l/c }')

# -- Memory / swap (kB from /proc/meminfo) -------------------
MEM_TOTAL_KB=$(awk '/^MemTotal:/     {print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
MEM_FREE_KB=$(awk  '/^MemFree:/      {print $2}' /proc/meminfo)
SWAP_TOTAL_KB=$(awk '/^SwapTotal:/   {print $2}' /proc/meminfo)
SWAP_FREE_KB=$(awk  '/^SwapFree:/    {print $2}' /proc/meminfo)

MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))

MEM_USED_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{ if(t>0) printf "%.1f", (u*100)/t; else print "0" }')
SWAP_USED_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" 'BEGIN{ if(t>0) printf "%.1f", (u*100)/t; else print "0" }')

kb_to_mb() { awk -v v="$1" 'BEGIN{ printf "%.0f", v/1024 }'; }

MEM_TOTAL_MB=$(kb_to_mb "$MEM_TOTAL_KB")
MEM_USED_MB=$(kb_to_mb "$MEM_USED_KB")
MEM_AVAIL_MB=$(kb_to_mb "$MEM_AVAIL_KB")
MEM_FREE_MB=$(kb_to_mb "$MEM_FREE_KB")
SWAP_TOTAL_MB=$(kb_to_mb "$SWAP_TOTAL_KB")
SWAP_USED_MB=$(kb_to_mb "$SWAP_USED_KB")

# -- Disks: real filesystems only (no tmpfs/overlay/loop/snap) --
DISKS_JSON=$(df -P -B1 2>/dev/null | awk 'NR>1 {print $1" "$2" "$3" "$4" "$5" "$6}' | \
while read -r src total used avail pct mount; do
    case "$src" in
        tmpfs|devtmpfs|overlay|/dev/loop*|none) continue ;;
    esac
    case "$mount" in
        /snap/*|/run/*|/dev/*|/sys/*|/proc/*|/boot/efi) continue ;;
    esac
    # Skip anything under 1 GB — those are helper mounts, not storage
    awk -v v="$total" 'BEGIN{ exit !(v < 1073741824) }' && continue
    pct_num=${pct%\%}
    total_gb=$(awk -v v="$total" 'BEGIN{ printf "%.1f", v/1024/1024/1024 }')
    used_gb=$(awk  -v v="$used"  'BEGIN{ printf "%.1f", v/1024/1024/1024 }')
    avail_gb=$(awk -v v="$avail" 'BEGIN{ printf "%.1f", v/1024/1024/1024 }')
    jq -n \
        --arg mount "$mount" \
        --arg src "$src" \
        --argjson total_gb "$total_gb" \
        --argjson used_gb "$used_gb" \
        --argjson avail_gb "$avail_gb" \
        --argjson used_pct "$pct_num" \
        '{mount:$mount, source:$src, total_gb:$total_gb, used_gb:$used_gb, avail_gb:$avail_gb, used_pct:$used_pct}'
done | jq -s '.')

# -- Uptime ---------------------------------------------------
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
UPTIME_HUMAN=$(awk -v s="$UPTIME_SEC" 'BEGIN{
    d=int(s/86400); s%=86400;
    h=int(s/3600);  s%=3600;
    m=int(s/60);
    if(d>0) printf "%dd %dh %dm", d, h, m;
    else if(h>0) printf "%dh %dm", h, m;
    else printf "%dm", m;
}')

# -- Thresholds ----------------------------------------------
HAS_WARN=false
WARNINGS="[]"
add_warn() {
    WARNINGS=$(echo "$WARNINGS" | jq --arg w "$1" '. + [$w]')
    HAS_WARN=true
}

awk -v v="$MEM_USED_PCT"  'BEGIN{ exit !(v>85) }'  && add_warn "memory above 85% ($MEM_USED_PCT%)"
awk -v v="$SWAP_USED_PCT" 'BEGIN{ exit !(v>50) }'  && add_warn "swap above 50% ($SWAP_USED_PCT%)"
awk -v v="$LOAD_PER_CPU"  'BEGIN{ exit !(v>1.5) }' && add_warn "load per CPU high ($LOAD_PER_CPU)"

DISK_WARN=$(echo "$DISKS_JSON" | jq -r '[.[] | select(.used_pct > 90) | .mount + " (" + (.used_pct|tostring) + "%)"] | join(", ")')
[ -n "$DISK_WARN" ] && add_warn "disk above 90%: $DISK_WARN"

# -- Output ---------------------------------------------------
jq -n \
    --arg queried_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cpu_count "$CPU_COUNT" \
    --argjson load1 "$LOAD1" \
    --argjson load5 "$LOAD5" \
    --argjson load15 "$LOAD15" \
    --argjson load_per_cpu "$LOAD_PER_CPU" \
    --argjson mem_total_mb "$MEM_TOTAL_MB" \
    --argjson mem_used_mb "$MEM_USED_MB" \
    --argjson mem_avail_mb "$MEM_AVAIL_MB" \
    --argjson mem_free_mb "$MEM_FREE_MB" \
    --argjson mem_used_pct "$MEM_USED_PCT" \
    --argjson swap_total_mb "$SWAP_TOTAL_MB" \
    --argjson swap_used_mb "$SWAP_USED_MB" \
    --argjson swap_used_pct "$SWAP_USED_PCT" \
    --argjson disks "$DISKS_JSON" \
    --argjson uptime_sec "$UPTIME_SEC" \
    --arg uptime_human "$UPTIME_HUMAN" \
    --argjson warnings "$WARNINGS" \
    --argjson has_warn "$HAS_WARN" \
    '{
        queried_at: $queried_at,
        cpu: {
            cores: $cpu_count,
            load1: $load1,
            load5: $load5,
            load15: $load15,
            load_per_cpu: $load_per_cpu
        },
        memory: {
            total_mb: $mem_total_mb,
            used_mb: $mem_used_mb,
            available_mb: $mem_avail_mb,
            free_mb: $mem_free_mb,
            used_pct: $mem_used_pct
        },
        swap: {
            total_mb: $swap_total_mb,
            used_mb: $swap_used_mb,
            used_pct: $swap_used_pct
        },
        disks: $disks,
        uptime: {
            seconds: $uptime_sec,
            human: $uptime_human
        },
        has_resource_warnings: $has_warn,
        warnings: $warnings
    }'
