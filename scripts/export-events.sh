#!/usr/bin/env bash
# Export raw_events to JSONL for use with event-replayer.
#
# Each output line is the full CloudEvent JSON as originally received,
# ready to be shifted in time and re-sent by event-replayer.
#
# Usage:
#   ./scripts/export-events.sh                         > events-base.jsonl
#   ./scripts/export-events.sh --window 1h             > events-1h.jsonl
#   ./scripts/export-events.sh --start "2026-07-25 10:00" --end "2026-07-25 11:00"
#   ./scripts/export-events.sh --type inference.tokens.used  # MaaS only
#   ./scripts/export-events.sh --type osac.compute_instance.lifecycle  # OSAC only
#
# Output: one JSON object per line (JSONL). Each line is the stored CloudEvent
# envelope as sent to POST /api/v1/events.
#
# Requirements: psql

set -euo pipefail

DB="${COSTDB_URL:-postgres://user:pass@localhost:5434/costdb}"
WINDOW="1 hour"
START=""
END=""
TYPE=""
LIMIT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --window)  WINDOW="$2";  shift 2 ;;
    --start)   START="$2";   shift 2 ;;
    --end)     END="$2";     shift 2 ;;
    --type)    TYPE="$2";    shift 2 ;;
    --limit)   LIMIT="$2";   shift 2 ;;
    --db)      DB="$2";      shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Build WHERE clause
WHERE="1=1"

if [[ -n "$START" ]]; then
  WHERE="$WHERE AND received_at >= '$START'"
elif [[ -n "$WINDOW" ]]; then
  WHERE="$WHERE AND received_at >= (SELECT MIN(received_at) FROM raw_events)"
  WHERE="$WHERE AND received_at < (SELECT MIN(received_at) + INTERVAL '$WINDOW' FROM raw_events)"
fi

if [[ -n "$END" ]]; then
  WHERE="$WHERE AND received_at < '$END'"
fi

if [[ -n "$TYPE" ]]; then
  WHERE="$WHERE AND event_type = '$TYPE'"
fi

LIMIT_CLAUSE=""
if [[ -n "$LIMIT" ]]; then
  LIMIT_CLAUSE="LIMIT $LIMIT"
fi

# Export: reconstruct minimal CloudEvent from stored data column.
# The data column already contains the full envelope (specversion, type, source,
# id, time, subject, data) as stored by the ingest handler.
psql "$DB" --no-align --tuples-only -c "
SELECT data
FROM raw_events
WHERE $WHERE
ORDER BY received_at
$LIMIT_CLAUSE;" 2>/dev/null

>&2 echo "Export complete."