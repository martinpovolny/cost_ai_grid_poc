#!/usr/bin/env bash
# analyze-sizing.sh — DB growth observation and capacity planning for cost-event-consumer
#
# Usage:
#   COSTDB_URL=postgres://user:pass@localhost:5434/costdb ./scripts/analyze-sizing.sh
#
# The script tries to connect to the DB directly. If the connection fails it
# attempts to start a kubectl port-forward from cost-db:5432 → localhost:5434
# and retries. Kill the port-forward with Ctrl-C or it will be cleaned up when
# the script exits.

set -euo pipefail

# ── colour codes ──────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
RESET='\033[0m'

COSTDB_URL="${COSTDB_URL:-postgres://user:pass@localhost:5434/costdb}"
OBSERVE_SECS=60
PF_PID=""

# ── helpers ───────────────────────────────────────────────────────────────────
die() { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }

fmt_bytes() {
  local b=$1
  if   (( b >= 1099511627776 )); then printf "%.1f TB" "$(echo "scale=1; $b/1099511627776" | bc)"
  elif (( b >= 1073741824    )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824"    | bc)"
  elif (( b >= 1048576       )); then printf "%.1f MB" "$(echo "scale=1; $b/1048576"       | bc)"
  elif (( b >= 1024          )); then printf "%.1f KB" "$(echo "scale=1; $b/1024"          | bc)"
  else printf "%d B" "$b"
  fi
}

fmt_rows() {
  # Format with thousands separator
  printf "%d" "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

psql_q() {
  psql "$COSTDB_URL" --no-align --tuples-only --quiet -c "$1" 2>/dev/null
}

cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── table size query ──────────────────────────────────────────────────────────
TABLE_QUERY="
SELECT
  relname AS table_name,
  n_live_tup AS row_count,
  pg_relation_size(relid) AS table_bytes,
  pg_total_relation_size(relid) AS total_bytes
FROM pg_stat_user_tables
WHERE relname IN ('raw_events','metering_entries','cost_entries','wallet_ledger_entries')
ORDER BY table_bytes DESC;"

QUEUE_DEPTH_QUERY="SELECT count(*) FROM metering_entries WHERE rated_at IS NULL;"

LAG_QUERY="
SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(period_start))), 0)::bigint
FROM metering_entries WHERE rated_at IS NULL;"

# ── DB connection ─────────────────────────────────────────────────────────────
attempt_connect() {
  psql "$COSTDB_URL" --no-align --tuples-only --quiet -c "SELECT 1;" >/dev/null 2>&1
}

ensure_db_connection() {
  if attempt_connect; then
    return 0
  fi

  printf "${YELLOW}Direct DB connection failed — trying kubectl port-forward...${RESET}\n"
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found and direct DB connection failed. Set COSTDB_URL to a reachable address."
  fi

  # Kill any existing port-forward on 5434
  fuser -k 5434/tcp 2>/dev/null || true

  kubectl port-forward -n cost-mgmt svc/cost-db 5434:5432 &>/tmp/pf-cost-db.log &
  PF_PID=$!

  printf "  Waiting for port-forward (pid %d)..." "$PF_PID"
  local tries=0
  while ! attempt_connect; do
    sleep 1
    (( tries++ ))
    if (( tries >= 15 )); then
      printf "\n"
      cat /tmp/pf-cost-db.log >&2
      die "Port-forward failed after ${tries}s. Check kubectl context and cost-db pod health."
    fi
    printf "."
  done
  printf " ${GREEN}connected${RESET}\n\n"
}

# ── Prometheus event rate (optional) ─────────────────────────────────────────
fetch_prometheus_rate() {
  local prom_url="http://localhost:9090"
  local query='rate(cost_consumer_events_total[1m])*60'
  local result
  result=$(curl -sf "${prom_url}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data',{}).get('result',[])
if results:
    print(results[0]['value'][1])
else:
    print('')
" 2>/dev/null) || result=""
  echo "$result"
}

# ── snapshot helper ───────────────────────────────────────────────────────────
# Prints: table_name|row_count|table_bytes|total_bytes  (one row per table)
snapshot_tables() {
  psql_q "$TABLE_QUERY" | tr '|' ' '
}

# ── main ──────────────────────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${CYAN}║   Cost Event Consumer — DB Sizing Analysis               ║${RESET}\n"
printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}\n\n"

ensure_db_connection

printf "${BOLD}Observation window:${RESET} %ds\n" "$OBSERVE_SECS"
# Redact password from display URL
DISPLAY_URL=$(echo "$COSTDB_URL" | sed 's|://[^:]*:[^@]*@|://***:***@|')
printf "${BOLD}DB:${RESET} %s\n\n" "$DISPLAY_URL"

# T=0 snapshot
printf "${DIM}Capturing T=0 snapshot...${RESET}\n"
declare -A t0_rows t0_tbytes t0_totbytes
while IFS=' ' read -r tname rcount tbytes totbytes; do
  [[ -z "$tname" ]] && continue
  t0_rows["$tname"]="$rcount"
  t0_tbytes["$tname"]="$tbytes"
  t0_totbytes["$tname"]="$totbytes"
done < <(snapshot_tables)

# Queue depth at T=0
UNRATED_T0=$(psql_q "$QUEUE_DEPTH_QUERY" | tr -d ' ')
LAG_T0=$(psql_q "$LAG_QUERY" | tr -d ' ')
UNRATED_T0="${UNRATED_T0:-0}"
LAG_T0="${LAG_T0:-0}"

printf "${DIM}Waiting %ds for T=60 snapshot...${RESET}\n" "$OBSERVE_SECS"
sleep "$OBSERVE_SECS"

# T=60 snapshot
declare -A t60_rows t60_tbytes t60_totbytes
while IFS=' ' read -r tname rcount tbytes totbytes; do
  [[ -z "$tname" ]] && continue
  t60_rows["$tname"]="$rcount"
  t60_tbytes["$tname"]="$tbytes"
  t60_totbytes["$tname"]="$totbytes"
done < <(snapshot_tables)

UNRATED_T60=$(psql_q "$QUEUE_DEPTH_QUERY" | tr -d ' ')
LAG_T60=$(psql_q "$LAG_QUERY" | tr -d ' ')
UNRATED_T60="${UNRATED_T60:-0}"
LAG_T60="${LAG_T60:-0}"

# ── compute growth per minute ─────────────────────────────────────────────────
declare -A grow_rows grow_bytes
TABLES=(raw_events metering_entries cost_entries wallet_ledger_entries)

for tbl in "${TABLES[@]}"; do
  r0="${t0_rows[$tbl]:-0}"
  r60="${t60_rows[$tbl]:-0}"
  b0="${t0_tbytes[$tbl]:-0}"
  b60="${t60_tbytes[$tbl]:-0}"
  grow_rows["$tbl"]=$(( (r60 - r0) ))
  grow_bytes["$tbl"]=$(( (b60 - b0) ))
done

# ── table output ──────────────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}%-24s %-14s %-14s %-14s %-12s %-14s${RESET}\n" \
  "Table" "T=0 rows" "T=60 rows" "Growth/min" "T=0 size" "Growth/min"
printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────"

for tbl in "${TABLES[@]}"; do
  r0="${t0_rows[$tbl]:-0}"
  r60="${t60_rows[$tbl]:-0}"
  b0="${t0_tbytes[$tbl]:-0}"
  gr="${grow_rows[$tbl]:-0}"
  gb="${grow_bytes[$tbl]:-0}"

  # growth/min = growth over 60s × 1 (already per minute)
  grow_per_min_r=$gr
  grow_per_min_b=$gb

  printf "%-24s %-14s %-14s %-14s %-12s %-14s\n" \
    "$tbl" \
    "$(fmt_rows "$r0")" \
    "$(fmt_rows "$r60")" \
    "$(fmt_rows "$grow_per_min_r") rows" \
    "$(fmt_bytes "$b0")" \
    "$(fmt_bytes "$grow_per_min_b")"
done

# ── pipeline health ───────────────────────────────────────────────────────────
printf "\n${BOLD}Pipeline health:${RESET}\n"

if (( UNRATED_T60 == 0 )); then
  printf "  Unrated queue depth : %-12s ${GREEN}✓ healthy${RESET}\n" "0 entries"
elif (( UNRATED_T60 < 1000 )); then
  printf "  Unrated queue depth : %-12s ${YELLOW}⚠ accumulating${RESET}\n" "$(fmt_rows "$UNRATED_T60") entries"
else
  printf "  Unrated queue depth : %-12s ${RED}✗ backlog${RESET}\n" "$(fmt_rows "$UNRATED_T60") entries"
fi

if (( LAG_T60 == 0 )); then
  printf "  Pipeline lag        : %-12s ${GREEN}✓ healthy${RESET}\n" "0.0s"
elif (( LAG_T60 < 300 )); then
  printf "  Pipeline lag        : %-12s ${YELLOW}⚠ lagging${RESET}\n" "${LAG_T60}s"
else
  printf "  Pipeline lag        : %-12s ${RED}✗ critical${RESET}\n" "${LAG_T60}s"
fi

# ── Prometheus event rate ─────────────────────────────────────────────────────
PROM_RATE=$(fetch_prometheus_rate)
if [[ -n "$PROM_RATE" && "$PROM_RATE" != "0" ]]; then
  printf "  Observed event rate : ${GREEN}%.0f events/min${RESET} (from Prometheus)\n" "$PROM_RATE"
else
  # Fall back: derive from raw_events growth
  OBS_RATE="${grow_rows[raw_events]:-0}"
  if (( OBS_RATE > 0 )); then
    printf "  Observed event rate : ${YELLOW}%s events/min${RESET} (estimated from DB delta)\n" \
      "$(fmt_rows "$OBS_RATE")"
  else
    printf "  Observed event rate : ${DIM}unknown (no traffic detected)${RESET}\n"
  fi
fi

# ── projections ───────────────────────────────────────────────────────────────
# Bytes per event across three growing tables:
#   raw_events      : 500 B/row, 1 row/event
#   metering_entries: 220 B/row, 3 rows/event → 660 B/event
#   cost_entries    : 270 B/row, 3 rows/event → 810 B/event
#   wallet_ledger   : ~150 B/row, ~3 rows/event → 450 B/event (included in total)
BYTES_PER_EVENT=1970   # 500 + 660 + 810

printf "\n"
printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${CYAN}  DB Size Projections${RESET}\n"
printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}\n\n"

printf "${BOLD}%-22s %-14s %-14s %-14s %-14s${RESET}\n" \
  "Rate tier" "1 day" "1 week" "1 month" "1 year"
printf "%s\n" "─────────────────────────────────────────────────────────────────────────────"

for rate_per_min in 100 1000 10000; do
  per_day=$(( rate_per_min * 60 * 24 * BYTES_PER_EVENT ))
  per_week=$(( per_day * 7 ))
  per_month=$(( per_day * 30 ))
  per_year=$(( per_day * 365 ))

  label="${rate_per_min} events/min"
  printf "%-22s %-14s %-14s %-14s %-14s\n" \
    "$label" \
    "$(fmt_bytes "$per_day")" \
    "$(fmt_bytes "$per_week")" \
    "$(fmt_bytes "$per_month")" \
    "$(fmt_bytes "$per_year")"
done

printf "\n${DIM}(projections include raw_events + metering_entries + cost_entries combined)${RESET}\n"
printf "\n${BOLD}Assumptions:${RESET}\n"
printf "  raw_events      : ~500 bytes/row\n"
printf "  metering        : ~220 bytes/row, 3 entries per event\n"
printf "  cost_entries    : ~270 bytes/row, 3 entries per event\n"

# ── retention recommendations ──────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${CYAN}  Retention Recommendations${RESET}\n"
printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}\n\n"

# At 1,000 events/min for 1 year
RATE_1K=1000
YEAR_BYTES=$(( RATE_1K * 60 * 24 * 365 * BYTES_PER_EVENT ))
# Savings if raw_events (500B/event) pruned at 90 days vs kept for 1 year
RAW_YEAR=$(( RATE_1K * 60 * 24 * 365 * 500 ))
RAW_90D=$(( RATE_1K * 60 * 24 * 90  * 500 ))
RAW_SAVED=$(( RAW_YEAR - RAW_90D ))
if (( YEAR_BYTES > 0 )); then
  SAVINGS_PCT=$(( RAW_SAVED * 100 / YEAR_BYTES ))
else
  SAVINGS_PCT=0
fi

printf "At 1,000 events/min sustained for 1 year:\n"
printf "  Total DB growth  : %s\n" "$(fmt_bytes "$YEAR_BYTES")"
printf "  Recommendation   : Archive raw_events after 90 days → saves ~%d%%\n" "$SAVINGS_PCT"
printf "  See ${BOLD}docs/operations/data-retention.md${RESET} for full policy\n\n"
