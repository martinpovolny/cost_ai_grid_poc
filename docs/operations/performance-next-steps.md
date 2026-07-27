# Performance — Remaining Next Steps

Findings from load testing at ~50 events/s on CRC (July 2026).
See `docs/operations/table-sizing.md` for the full scale analysis.

## Already fixed

| Fix | Commit |
|-----|--------|
| Rating sweep loop-until-empty (was capped at 25 entries/s) | `7e5516f` |
| `RATING_BATCH_SIZE` env var (default 2000, was hardcoded 500) | `7e5516f` |
| `PipelineSummary` count(*) → n_live_tup (O(1) vs O(n)) | `8503dd5` |
| `idx_me_unrated` — added `period_start` leading column | `8503dd5` |
| `idx_ce_period_tenant` — cross-tenant report seq scan | `8503dd5` |
| `idx_ce_tenant_meter_period` — budget quota missing meter | `8503dd5` |
| `idx_ce_unapplied` — wallet sweep partial index | `8503dd5` |
| `idx_me_tenant_project_meter` — MeteringSumByProject heap filter | `e3f0545` |
| DeductWallets N+1 — wallet_applied now in UnappliedCostEntries SELECT | `e3f0545` |
| Autovacuum tuning — 1% threshold for metering_entries and raw_events | `79e4762` |
| Ingest timestamp validation — reject events >2h old or >5m future | (other session) |

---

## Next steps

### 1. Missing index: MeteringSumByProject

**File:** `internal/inventory/store.go` → `schemaEvolutions`

`MeteringSumByProject` filters `project_id` as a heap predicate after
an index scan on `(tenant_id, meter_name)`. At scale this scans all
tenant+meter entries and filters project in the heap.

```sql
CREATE INDEX IF NOT EXISTS idx_me_tenant_project_meter
  ON metering_entries (tenant_id, project_id, meter_name, period_start, period_end);
```

---

### 2. N+1 in DeductWallets

**File:** `internal/rating/rating.go`, `internal/inventory/store.go`

`DeductWallets` calls `UnappliedCostEntries` to fetch entries, then for
each entry does a second `SELECT wallet_applied WHERE id=$1`. The column
is already available — just add it to the SELECT in `UnappliedCostEntries`:

```go
// store.go — add wallet_applied to the SELECT
SELECT id, metering_entry_id, ..., wallet_applied   -- add this
FROM cost_entries
WHERE tenant_id = $1 AND wallet_applied < cost_amount
```

Then remove the redundant per-entry PK lookup in `rating.go:196`.

---

### 3. MeteringSumBefore — cumulative tier cache

**File:** `internal/rating/rating.go`, `internal/inventory/store.go`

`MeteringSumBefore` computes `SUM(value) WHERE id < $N` to find prior
usage for cumulative tiered rates. The per-batch cache (`priorUsageCache`)
avoids repeat calls within one sweep, but on cold start or after a large
backlog the query runs O(prior_entries) for every distinct
`(tenant, meter, period)` tuple.

**Fix:** materialize cumulative usage into a `billing_accumulators` table
updated atomically as entries are rated:

```sql
CREATE TABLE billing_accumulators (
  tenant_id    TEXT NOT NULL,
  meter_name   TEXT NOT NULL,
  billing_period DATE NOT NULL,     -- date_trunc('month', period_end)
  total_value  NUMERIC(18,6) NOT NULL DEFAULT 0,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, meter_name, billing_period)
);
```

Rating sweep: `INSERT ... ON CONFLICT DO UPDATE SET total_value = total_value + $delta`
alongside the `cost_entries` insert. `MeteringSumBefore` becomes an O(1)
point lookup instead of a range aggregation.

This is the most architecturally significant remaining change — affects
billing correctness for cumulative tiers at high volume.

---

### 4. Autovacuum tuning for high-churn tables

**File:** `internal/inventory/store.go` → `schemaEvolutions`

**Why:** PostgreSQL's default autovacuum thresholds (20% of rows dead)
are designed for OLTP workloads with small tables. At 9M rows, 20% =
1.8M dead tuples before vacuum fires. Our tables accumulate dead tuples
quickly:

- `metering_entries`: every rating sweep UPDATEs thousands of rows
  (`SET rated_at = NOW()`). In PostgreSQL, UPDATE = delete old version +
  insert new. At 300 rated entries/s → 300 dead tuples/s → default
  threshold hit after ~100 minutes.
- `raw_events`: bulk DELETE during pruning leaves large dead tuple swaths.

Without aggressive autovacuum:
- Index bloat accumulates (including `idx_me_unrated` partial index)
- Table physically grows beyond live row count
- Query planner statistics go stale → wrong cardinality estimates

**Fix — add to schemaEvolutions:**

```sql
-- Tighten autovacuum for high-churn tables.
-- Triggers at 1% dead (not 20%) — fires every ~5 min at 300 updates/s
-- instead of every ~100 min. Settings survive restarts, no reload needed.
ALTER TABLE metering_entries SET (
  autovacuum_vacuum_scale_factor  = 0.01,
  autovacuum_analyze_scale_factor = 0.005
);

ALTER TABLE raw_events SET (
  autovacuum_vacuum_scale_factor  = 0.01,
  autovacuum_analyze_scale_factor = 0.005
);
```

---

## Future / architectural (not yet scoped)

### 5. Table partitioning

At 50M+ rows on any of the three large tables, batch DELETE becomes
expensive (WAL amplification, table bloat, lock contention). Switch to
monthly range partitioning with `pg_partman` — `DROP PARTITION` is an
O(1) catalog operation.

Recommended partition granularity:
- `metering_entries`: monthly
- `cost_entries`: monthly
- `raw_events`: monthly (if not archived to Splunk/S3 fast enough)

**Trigger:** any single table exceeds 50M rows.
Track in `docs/decisions/` if a partition migration ADR is opened.

### 6. Monthly roll-up tables

Implement `monthly_usage_summary` and `monthly_cost_summary` per the
schemas in `docs/operations/table-lifecycle.md`. Required before the
2-month metering and 13-month cost hot windows can be enforced.

Implementation: k8s CronJob running on the last day of each month.

### 7. Data pruning CronJobs

Per `docs/operations/table-lifecycle.md`:
- `raw_events`: prune after Splunk cursor confirms forwarding
- `metering_entries`: prune after 2-month hot window + roll-up confirmed
- `cost_entries`: prune after 13-month hot window + roll-up confirmed
- `inventory_*` deleted rows: 90-day prune
- `alerts`: 90-day prune

All prune jobs should use bounded DELETE batches (10k rows), emit
Prometheus metrics on rows pruned and duration, and run during
off-peak hours (nightly, 02:00 UTC).
