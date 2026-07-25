#!/usr/bin/env bash
# Replicate a base window of data by copying it with shifted timestamps.
#
# This compresses time: generate 1 hour of real traffic, then use this script
# to manufacture a day / week / month of data for lifecycle testing, quota
# roll-up testing, or retention policy validation.
#
# What gets replicated:
#   raw_events          — event_id suffixed with _rN to avoid duplicates
#   metering_entries    — timestamps shifted; raw_event_id carried over (tracing only)
#   cost_entries        — timestamps shifted; metering_entry_id carried over (tracing only)
#
# Usage:
#   ./scripts/replicate-data.sh --copies 24            # 1 hour → 1 day
#   ./scripts/replicate-data.sh --copies 168           # 1 hour → 1 week
#   ./scripts/replicate-data.sh --copies 720           # 1 hour → 30 days
#   ./scripts/replicate-data.sh --copies 24 --shift 1h # explicit shift interval
#   ./scripts/replicate-data.sh --window 2h --copies 12 # use 2h base window
#
# The base window is auto-detected as the first N minutes of data in raw_events
# (where N = shift interval). Override with --base-start and --base-end.
#
# Requirements: psql, COSTDB_URL or default postgres://user:pass@localhost:5434/costdb

set -euo pipefail

DB="${COSTDB_URL:-postgres://user:pass@localhost:5434/costdb}"
COPIES=24
SHIFT="1 hour"
BASE_START=""
BASE_END=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --copies)  COPIES="$2"; shift 2 ;;
    --shift)   SHIFT="$2"; shift 2 ;;
    --base-start) BASE_START="$2"; shift 2 ;;
    --base-end)   BASE_END="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --db)      DB="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

q() { psql "$DB" -t -A -c "$1" 2>/dev/null; }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Cost Event Consumer — Data Replication                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Auto-detect base window if not specified
if [[ -z "$BASE_START" ]]; then
  BASE_START=$(q "SELECT MIN(received_at) FROM raw_events")
fi
if [[ -z "$BASE_END" ]]; then
  BASE_END=$(q "SELECT MIN(received_at) + INTERVAL '${SHIFT}' FROM raw_events")
fi

BASE_ROWS=$(q "SELECT count(*) FROM raw_events WHERE received_at >= '${BASE_START}' AND received_at < '${BASE_END}'")
BASE_METERING=$(q "SELECT count(*) FROM metering_entries WHERE period_start >= '${BASE_START}' AND period_start < '${BASE_END}'")
BASE_COST=$(q "SELECT count(*) FROM cost_entries WHERE period_start >= '${BASE_START}' AND period_start < '${BASE_END}'")

echo "Base window : ${BASE_START} → ${BASE_END}"
echo "Shift       : ${SHIFT} per copy"
echo "Copies      : ${COPIES}"
echo "Time span   : base + ${COPIES} × ${SHIFT}"
echo ""
echo "Base data   : ${BASE_ROWS} raw_events, ${BASE_METERING} metering_entries, ${BASE_COST} cost_entries"
echo "After copy  : ~$((BASE_ROWS * (COPIES + 1))) raw_events, ~$((BASE_METERING * (COPIES + 1))) metering_entries"
echo ""

if $DRY_RUN; then
  echo "[dry-run] No changes made."
  exit 0
fi

read -p "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
START_TIME=$(date +%s)

for i in $(seq 1 "$COPIES"); do
  OFFSET="${i} * INTERVAL '${SHIFT}'"

  # raw_events — suffix event_id with _rN to avoid unique constraint
  RAW=$(psql "$DB" -t -A -c "
    INSERT INTO raw_events
      (event_id, event_type, event_source, event_time,
       tenant_id, resource_type, resource_id, data, received_at)
    SELECT
      event_id || '_r${i}',
      event_type, event_source,
      event_time   + ${OFFSET},
      tenant_id, resource_type, resource_id, data,
      received_at  + ${OFFSET}
    FROM raw_events
    WHERE received_at >= '${BASE_START}'
      AND received_at  < '${BASE_END}'
    RETURNING 1;" 2>/dev/null | wc -l | tr -d ' ')

  # metering_entries — carry raw_event_id for tracing (not a hard FK)
  ME=$(psql "$DB" -t -A -c "
    INSERT INTO metering_entries
      (raw_event_id, resource_type, resource_id, tenant_id,
       project_id, user_id, instance_type,
       meter_name, value, unit, period_start, period_end, rated_at)
    SELECT
      raw_event_id, resource_type, resource_id, tenant_id,
      project_id, user_id, instance_type,
      meter_name, value, unit,
      period_start + ${OFFSET},
      period_end   + ${OFFSET},
      CASE WHEN rated_at IS NOT NULL THEN rated_at + ${OFFSET} ELSE NULL END
    FROM metering_entries
    WHERE period_start >= '${BASE_START}'
      AND period_start  < '${BASE_END}'
    RETURNING 1;" 2>/dev/null | wc -l | tr -d ' ')

  # cost_entries — carry metering_entry_id for tracing (not a hard FK)
  CE=$(psql "$DB" -t -A -c "
    INSERT INTO cost_entries
      (metering_entry_id, rate_id, tenant_id, project_id, user_id,
       resource_type, resource_id, meter_name, metered_value,
       cost_amount, currency, period_start, period_end)
    SELECT
      me_new.id,
      ce.rate_id, ce.tenant_id, ce.project_id, ce.user_id,
      ce.resource_type, ce.resource_id, ce.meter_name, ce.metered_value,
      ce.cost_amount, ce.currency,
      ce.period_start + ${OFFSET},
      ce.period_end   + ${OFFSET}
    FROM cost_entries ce
    JOIN metering_entries me_orig ON ce.metering_entry_id = me_orig.id
    JOIN metering_entries me_new
      ON me_new.resource_id   = me_orig.resource_id
     AND me_new.meter_name    = me_orig.meter_name
     AND me_new.tenant_id     = me_orig.tenant_id
     AND me_new.period_start  = me_orig.period_start + ${OFFSET}
    WHERE ce.period_start >= '${BASE_START}'
      AND ce.period_start  < '${BASE_END}'
    RETURNING 1;" 2>/dev/null | wc -l | tr -d ' ')

  ELAPSED=$(( $(date +%s) - START_TIME ))
  printf "  copy %3d/%d  raw=%-6s  metering=%-6s  cost=%-6s  [%ds]\n" \
    "$i" "$COPIES" "$RAW" "$ME" "$CE" "$ELAPSED"
done

echo ""
echo "Done in $(( $(date +%s) - START_TIME ))s"
echo ""
echo "=== Final table sizes ==="
psql "$DB" -c "
SELECT relname AS table_name,
       to_char(n_live_tup, '999,999,999') AS rows,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname IN ('raw_events','metering_entries','cost_entries')
ORDER BY pg_total_relation_size(relid) DESC;" 2>/dev/null
