#!/usr/bin/env bash
# Replicate a base time window of data by copying rows with shifted timestamps.
#
# Purpose: time-compressed lifecycle testing. Generate 1 hour of real traffic,
# then run this script to manufacture a day / week / month of data in seconds
# for testing retention policies, monthly roll-ups, quota calculations, and
# reporting across billing periods — without running generators for days.
#
# What gets replicated (direct DB INSERT — no HTTP, no pipeline):
#   raw_events        — event_id suffixed _rN, all timestamps shifted
#   metering_entries  — timestamps shifted; rated_at preserved (already rated)
#   cost_entries      — timestamps shifted; metering_entry_id carried as-is
#                       (tracing only — not a hard FK, fine for testing)
#
# Usage:
#   ./scripts/replicate-data.sh --copies 24               # base hour → 1 day
#   ./scripts/replicate-data.sh --copies 168              # base hour → 1 week
#   ./scripts/replicate-data.sh --copies 720              # base hour → 30 days
#   ./scripts/replicate-data.sh --copies 24 --shift 1h --yes   # no prompt
#   ./scripts/replicate-data.sh --base-start "2026-07-25 10:00" \
#                               --base-end   "2026-07-25 11:00" \
#                               --copies 720 --shift 1h --yes
#
# Requirements: psql
# DB connection: COSTDB_URL env var or default postgres://user:pass@localhost:5434/costdb

set -euo pipefail

DB="${COSTDB_URL:-postgres://user:pass@localhost:5434/costdb}"
COPIES=24
SHIFT="1 hour"
BASE_START=""
BASE_END=""
YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --copies)     COPIES="$2";     shift 2 ;;
    --shift)      SHIFT="$2";      shift 2 ;;
    --base-start) BASE_START="$2"; shift 2 ;;
    --base-end)   BASE_END="$2";   shift 2 ;;
    --yes|-y)     YES=true;        shift ;;
    --dry-run)    DRY_RUN=true;    shift ;;
    --db)         DB="$2";         shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

q() { psql "$DB" -t -A -c "$1" 2>/dev/null; }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Cost Event Consumer — DB Data Replication              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Auto-detect base window from the earliest data in the DB
if [[ -z "$BASE_START" ]]; then
  BASE_START=$(q "SELECT MIN(received_at) FROM raw_events")
fi
if [[ -z "$BASE_END" ]]; then
  BASE_END=$(q "SELECT MIN(received_at) + INTERVAL '${SHIFT}' FROM raw_events")
fi

if [[ -z "$BASE_START" || "$BASE_START" == "" ]]; then
  echo "ERROR: raw_events is empty. Generate some data first." >&2
  exit 1
fi

BASE_RAW=$(q "SELECT count(*) FROM raw_events       WHERE received_at  >= '${BASE_START}' AND received_at  < '${BASE_END}'")
BASE_ME=$(q  "SELECT count(*) FROM metering_entries WHERE period_start >= '${BASE_START}' AND period_start < '${BASE_END}'")
BASE_CE=$(q  "SELECT count(*) FROM cost_entries     WHERE period_start >= '${BASE_START}' AND period_start < '${BASE_END}'")

SPAN_END=$(q "SELECT ('${BASE_START}'::timestamptz + ${COPIES} * INTERVAL '${SHIFT}')::text")

printf "Base window  : %s → %s\n" "$BASE_START" "$BASE_END"
printf "Shift        : %s per copy\n" "$SHIFT"
printf "Copies       : %d\n" "$COPIES"
printf "Simulated to : %s\n" "$SPAN_END"
echo ""
printf "Base rows    : %s raw_events  %s metering_entries  %s cost_entries\n" "$BASE_RAW" "$BASE_ME" "$BASE_CE"
printf "Total after  : ~%d raw_events  ~%d metering_entries  ~%d cost_entries\n" \
  $((BASE_RAW * (COPIES + 1))) $((BASE_ME * (COPIES + 1))) $((BASE_CE * (COPIES + 1)))
echo ""

if $DRY_RUN; then
  echo "[dry-run] No changes made."
  exit 0
fi

if ! $YES; then
  read -r -p "Proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  echo ""
fi

START_TIME=$(date +%s)

for i in $(seq 1 "$COPIES"); do
  # Precompute the interval string for this copy
  INTERVAL="${i} * INTERVAL '${SHIFT}'"

  # All three inserts in a single transaction per copy for consistency.
  # cost_entries carries original metering_entry_id — acceptable for testing
  # since there is no FK constraint enforced in the schema.
  RESULT=$(psql "$DB" -t -A 2>/dev/null <<SQL
BEGIN;

-- raw_events: suffix event_id to avoid the non-unique index on event_id
WITH ins AS (
  INSERT INTO raw_events
    (event_id, event_type, event_source, event_time,
     tenant_id, resource_type, resource_id, data, received_at)
  SELECT
    event_id || '_r${i}',
    event_type, event_source,
    event_time  + ${INTERVAL},
    tenant_id, resource_type, resource_id, data,
    received_at + ${INTERVAL}
  FROM raw_events
  WHERE received_at >= '${BASE_START}'
    AND received_at  < '${BASE_END}'
  RETURNING 1
)
SELECT 'raw=' || count(*) FROM ins;

-- metering_entries: shift timestamps; rated_at preserved (entries already rated)
WITH ins AS (
  INSERT INTO metering_entries
    (raw_event_id, resource_type, resource_id, tenant_id,
     project_id, user_id, instance_type,
     meter_name, value, unit, period_start, period_end, rated_at)
  SELECT
    raw_event_id, resource_type, resource_id, tenant_id,
    project_id, user_id, instance_type,
    meter_name, value, unit,
    period_start + ${INTERVAL},
    period_end   + ${INTERVAL},
    CASE WHEN rated_at IS NOT NULL THEN rated_at + ${INTERVAL} END
  FROM metering_entries
  WHERE period_start >= '${BASE_START}'
    AND period_start  < '${BASE_END}'
  RETURNING 1
)
SELECT 'me=' || count(*) FROM ins;

-- cost_entries: shift timestamps; metering_entry_id is tracing-only (no FK)
WITH ins AS (
  INSERT INTO cost_entries
    (metering_entry_id, rate_id, tenant_id, project_id, user_id,
     resource_type, resource_id, meter_name, metered_value,
     cost_amount, currency, period_start, period_end)
  SELECT
    metering_entry_id, rate_id, tenant_id, project_id, user_id,
    resource_type, resource_id, meter_name, metered_value,
    cost_amount, currency,
    period_start + ${INTERVAL},
    period_end   + ${INTERVAL}
  FROM cost_entries
  WHERE period_start >= '${BASE_START}'
    AND period_start  < '${BASE_END}'
  RETURNING 1
)
SELECT 'ce=' || count(*) FROM ins;

COMMIT;
SQL
)

  RAW=$(echo "$RESULT" | grep "^raw=" | cut -d= -f2)
  ME=$(echo  "$RESULT" | grep "^me="  | cut -d= -f2)
  CE=$(echo  "$RESULT" | grep "^ce="  | cut -d= -f2)
  ELAPSED=$(( $(date +%s) - START_TIME ))

  printf "  copy %4d/%d  raw=%-7s me=%-7s ce=%-7s  [%ds]\n" \
    "$i" "$COPIES" "${RAW:-0}" "${ME:-0}" "${CE:-0}" "$ELAPSED"
done

TOTAL=$(( $(date +%s) - START_TIME ))
echo ""
printf "Done in %ds (%.0f rows/s avg)\n" \
  "$TOTAL" \
  "$(echo "scale=0; ($((BASE_RAW + BASE_ME + BASE_CE)) * $COPIES) / $TOTAL" | bc 2>/dev/null || echo '?')"
echo ""
echo "=== Final table sizes ==="
psql "$DB" 2>/dev/null -c "
SELECT
  relname                                           AS table_name,
  to_char(n_live_tup, 'FM999,999,999')             AS rows,
  pg_size_pretty(pg_relation_size(relid))           AS data_size,
  pg_size_pretty(pg_indexes_size(relid))            AS index_size,
  pg_size_pretty(pg_total_relation_size(relid))     AS total_size
FROM pg_stat_user_tables
WHERE relname IN ('raw_events','metering_entries','cost_entries')
ORDER BY pg_total_relation_size(relid) DESC;"
