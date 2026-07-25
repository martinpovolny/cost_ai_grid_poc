# Table Lifecycle — Cost Event Consumer

Each table that grows without bound needs a sustainable lifecycle: a clear
answer to what produces it, what reads it, when it can be aggregated, when
it can be pruned, and what the long-term archive is.

---

## Summary

| Table | Producer | Hot window | Roll-up | Archive | Prune trigger |
|-------|----------|-----------|---------|---------|---------------|
| `raw_events` | Event ingest | Until forwarded | — | Splunk / S3 | Archival confirmed |
| `metering_entries` | Sweep + ingest | 2 months | `monthly_usage_summary` | None | Month close + 1 |
| `cost_entries` | Rating sweep | 13 months | `monthly_cost_summary` | None | 13-month rolling |
| `wallet_ledger_entries` | Wallet deduction | 7 years | — | — | Never |
| `inventory_*` (deleted) | OSAC events | 90 days | — | — | 90 days after delete |
| `alerts` | Threshold eval | 90 days | — | — | 90 days |
| `rates`, `quotas` | Config/seed | Forever | — | — | Never |

---

## raw_events

**What it is:** Immutable audit log. Every CloudEvent stored verbatim before
any processing. Used for debugging ingestion failures, event replay, and
compliance.

**Producer:** `POST /api/v1/events` handler — every accepted event gets a row.

**Readers:**
- Splunk forwarder (reads unforwarded rows via cursor)
- Debug queries and incident investigation
- Nothing in the normal billing pipeline reads this after the event is classified

**Hot window:** Until the archival sink (Splunk HEC or equivalent) confirms
delivery. The `splunk_cursor` table tracks `last_forwarded_at` — rows before
that timestamp have been forwarded and may be pruned.

**Roll-up:** None — raw events are not aggregatable in a meaningful way.

**Archive:** Splunk HEC (already implemented). Future: S3/object store for
long-term cold storage.

**Prune trigger:** Only after archival confirmation. Safe DELETE query:

```sql
DELETE FROM raw_events
WHERE received_at < (SELECT last_forwarded_at FROM splunk_cursor LIMIT 1)
  AND id IN (
    SELECT id FROM raw_events
    WHERE received_at < (SELECT last_forwarded_at FROM splunk_cursor LIMIT 1)
    LIMIT 10000
  );
VACUUM ANALYZE raw_events;
```

**Steady-state size:** ~30 days of events (prune monthly after Splunk confirms).

---

## metering_entries

**What it is:** Time-series usage records at resource-meter granularity.
Produced at two points:
1. **Capacity sweep** (every 45s): 3 entries per live VM/cluster/bare-metal
2. **MaaS ingest** (inline): 2 entries per inference CloudEvent

**Readers:**
- Rating sweep (reads unrated rows, writes `rated_at`)
- Quota engine (`MeteringSum` for token/core quotas)
- `MeteringSumBefore` for cumulative tiered rate calculation (current period only)
- `analyze-sizing.sh` for queue depth monitoring

**Hot window: 2 months.** The rating sweep needs the current and prior month
for cumulative tier calculations. Quota calculations only span the current
billing period. Nothing reads metering_entries older than 2 months.

**Roll-up: `monthly_usage_summary`** (schema below). Created at billing period
close. Captures total consumption per tenant/resource/meter/month — sufficient
for historical quota reports and trend analysis.

**Roll-up schema:**

```sql
CREATE TABLE monthly_usage_summary (
  id              BIGSERIAL PRIMARY KEY,
  billing_month   DATE NOT NULL,           -- first day of month
  tenant_id       TEXT NOT NULL,
  project_id      TEXT,
  user_id         TEXT,
  resource_type   TEXT NOT NULL,
  meter_name      TEXT NOT NULL,
  total_value     NUMERIC(18,6) NOT NULL,
  entry_count     BIGINT NOT NULL,
  unit            TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (billing_month, tenant_id, resource_type, meter_name, project_id, user_id)
);
```

**Prune trigger:** After roll-up is confirmed for month M, delete entries where
`period_end < M - 1 month` (keep 2 rolling months):

```sql
-- Run after confirming monthly_usage_summary is complete for month M
DELETE FROM metering_entries
WHERE period_end < date_trunc('month', NOW()) - INTERVAL '1 month'
  AND rated_at IS NOT NULL
  AND id IN (
    SELECT id FROM metering_entries
    WHERE period_end < date_trunc('month', NOW()) - INTERVAL '1 month'
      AND rated_at IS NOT NULL
    LIMIT 10000
  );
VACUUM ANALYZE metering_entries;
```

**Storage at scale (2-month hot window):**

| OSAC size | MaaS rate | 2-month metering_entries |
|-----------|-----------|--------------------------|
| 10 VMs | 100 events/min | ~4 GB |
| 100 VMs | 1,000 events/min | ~34 GB |
| 1,000 VMs | 10,000 events/min | ~330 GB |

---

## cost_entries

**What it is:** Monetary cost attributed to each metering entry under the
applicable rate. The billing record — one row per metering_entry × rate.

**Producer:** Rating sweep — reads unrated `metering_entries`, applies rates,
writes `cost_entries` and sets `metering_entries.rated_at`.

**Readers:**
- Cost report API (`/api/v1/reports/costs`) — primary source for all financial reports
- Budget quota engine (`CostSum` for USD-denominated quotas)
- Wallet deduction (`UnappliedCostEntries` — needs `wallet_applied` column)
- CSV export and chargeback reports

**Hot window: 13 months.** Covers a full calendar billing year plus one month
overlap for month-boundary reconciliation and customer dispute window. Wallet
deductions must be settled before pruning.

**Roll-up: `monthly_cost_summary`** (schema below). Created at billing period
close. Sufficient for the 7-year financial retention obligation — the summary
is the general ledger; the raw rows are the sub-ledger.

**Roll-up schema:**

```sql
CREATE TABLE monthly_cost_summary (
  id              BIGSERIAL PRIMARY KEY,
  billing_month   DATE NOT NULL,
  tenant_id       TEXT NOT NULL,
  project_id      TEXT,
  user_id         TEXT,
  resource_type   TEXT NOT NULL,
  meter_name      TEXT NOT NULL,
  cost_type       TEXT NOT NULL,      -- Infrastructure / Supplementary
  total_cost      NUMERIC(18,10) NOT NULL,
  total_metered   NUMERIC(18,6),
  entry_count     BIGINT NOT NULL,
  currency        TEXT NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (billing_month, tenant_id, resource_type, meter_name, cost_type, project_id, user_id)
);
```

Keep `monthly_cost_summary` for **7 years** — this satisfies the financial
retention obligation without keeping billions of raw rows.

**Prune trigger:** After roll-up is confirmed and all wallets settled for the
period:

```sql
-- Only delete rows where wallet deductions are fully applied
DELETE FROM cost_entries
WHERE period_end < NOW() - INTERVAL '13 months'
  AND (wallet_applied IS NULL OR wallet_applied >= cost_amount)
  AND id IN (
    SELECT id FROM cost_entries
    WHERE period_end < NOW() - INTERVAL '13 months'
      AND (wallet_applied IS NULL OR wallet_applied >= cost_amount)
    LIMIT 10000
  );
VACUUM ANALYZE cost_entries;
```

---

## wallet_ledger_entries

**What it is:** Double-entry ledger — every credit (top-up) and debit (cost
settlement) against a tenant wallet. This IS the financial record; it cannot
be rolled up without losing the audit trail.

**Producer:** Wallet top-up API and rating sweep (DeductWallets).

**Readers:**
- Wallet balance queries
- Dispute resolution and financial audit

**Hot window:** 7 years — no pruning. Financial records must be kept in full.

**Roll-up:** None. The ledger entries are the roll-up.

---

## inventory_* tables (deleted records)

`inventory_compute_instance`, `inventory_cluster`, `inventory_bare_metal_instance`,
`inventory_model`, `inventory_project`, `inventory_tenant` all use soft-delete
(`deleted_at`). Deleted records accumulate.

**Prune trigger:** 90 days after `deleted_at`. Cost and metering records survive
in `cost_entries` and `monthly_cost_summary` regardless of inventory pruning.

```sql
DELETE FROM inventory_compute_instance
WHERE deleted_at IS NOT NULL
  AND deleted_at < NOW() - INTERVAL '90 days'
LIMIT 10000;
```

---

## alerts

**What it is:** Threshold breach notifications — one row per tenant/meter/
threshold/period. Idempotent by design (not re-inserted for the same period).

**Readers:** Alert API, notification consumers. Not needed after the billing
period closes.

**Prune trigger:** 90 days.

```sql
DELETE FROM alerts WHERE created_at < NOW() - INTERVAL '90 days' LIMIT 10000;
```

---

## rates, quotas

**What they are:** Configuration tables. Rates define prices; quotas define
limits. Both are soft-deleted with `effective_from`/`effective_to` timestamps.

**Lifecycle:** Never prune. Small tables (hundreds of rows), essential for
re-rating and historical quota lookups.

---

## Implementation Roadmap

| Step | What | When |
|------|------|------|
| 1 | Schema: add `monthly_usage_summary`, `monthly_cost_summary` | Before first month close |
| 2 | CronJob: month-close rollup (last day of month) | Before first month close |
| 3 | CronJob: prune `metering_entries` (2-month window) | After rollup confirmed |
| 4 | CronJob: prune `cost_entries` (13-month window) | After rollup confirmed |
| 5 | CronJob: prune `raw_events` (Splunk cursor gated) | After Splunk in prod |
| 6 | CronJob: prune `inventory_*` deleted rows (90 days) | Any time |
| 7 | CronJob: prune `alerts` (90 days) | Any time |

All CronJobs should run during off-peak hours, use bounded DELETE batches
(10,000 rows), and emit Prometheus metrics on rows pruned and duration.
