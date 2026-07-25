# Table Sizing Reference — Cost Event Consumer

Row sizes are **measured** from a live load test (not estimated):
296k raw_events, 616k metering_entries, 618k cost_entries under sustained
~50 events/s MaaS + OSAC VM lifecycle traffic.

| Table | Data/row | Index/row | **Total/row** | Dominant driver |
|-------|----------|-----------|---------------|-----------------|
| `raw_events` | 869 B | 222 B | **1,146 B** | MaaS events + OSAC lifecycle |
| `metering_entries` | 213 B | 209 B | **442 B** | VM sweep (3/VM/45s) + MaaS (2/event) |
| `cost_entries` | 167 B | 107 B | **286 B** | Same rate as metering_entries |
| `wallet_ledger_entries` | ~200 B | ~100 B | **~300 B** | Cost entries with active wallets |

> Index overhead is significant — `metering_entries` carries indexes equal to
> its data size (partial index on `rated_at IS NULL` plus three covering indexes
> for the rating/quota/report query patterns).

---

## Growth drivers

Two independent dimensions scale the system:

**Dimension A — OSAC compute resources (capacity billing)**

Every 45 seconds the metering sweep writes 3 rows per live resource:

| Resource type | Meters | Rows/resource/hour |
|---------------|--------|-------------------|
| Compute instance (VM) | vm_uptime_seconds, vm_cpu_core_seconds, vm_memory_gib_seconds | 240 |
| Cluster | cluster_uptime_seconds, cluster_worker_node_seconds | 160 |
| Bare-metal instance | bm_uptime_seconds | 80 |

VM events (create/delete from OSAC watch stream) also produce 1 `raw_events`
row each, but this is negligible compared to MaaS volume unless VM churn is
very high.

**Dimension B — MaaS inference events (consumption billing)**

Each `POST /api/v1/events` produces:
- 1 `raw_events` row (~1,146 B)
- 2 `metering_entries` rows (tokens_in + tokens_out, ~884 B)
- 2 `cost_entries` rows (~572 B)
- Total per event: **~2,602 B** across all tables

---

## Scenario: OSAC-only (no MaaS)

Pure capacity billing — VMs, clusters, bare metal; no inference traffic.
All growth comes from the metering sweep.

### raw_events (OSAC lifecycle only)

Assuming modest VM churn: 10% of VMs created/deleted per day.

| Fleet size | Raw events/day | raw_events size/day | /month | /year |
|-----------|----------------|---------------------|--------|-------|
| 100 VMs | ~20 events | 23 KB | 690 KB | 8 MB |
| 1,000 VMs | ~200 events | 229 KB | 6.9 MB | 83 MB |
| 10,000 VMs | ~2,000 events | 2.3 MB | 69 MB | 830 MB |

> raw_events is negligible in OSAC-only deployments.

### metering_entries

3 entries × 80 sweeps/hour × 24 h × fleet size.

| Fleet size | Rows/day | metering_entries/day | /month | /year |
|-----------|----------|----------------------|--------|-------|
| 100 VMs | 576,000 | 255 MB | 7.6 GB | 91 GB |
| 1,000 VMs | 5,760,000 | 2.5 GB | 75 GB | 906 GB |
| 10,000 VMs | 57,600,000 | 25 GB | 750 GB | 9 TB |

### cost_entries

1 per metering entry (same row count, 286 B/row vs 442 B/row).

| Fleet size | cost_entries/day | /month | /year |
|-----------|------------------|--------|-------|
| 100 VMs | 165 MB | 4.9 GB | 59 GB |
| 1,000 VMs | 1.6 GB | 49 GB | 587 GB |
| 10,000 VMs | 16 GB | 485 GB | 5.8 TB |

### Combined (OSAC-only, 2 tables dominate)

| Fleet | /day | /month | /year |
|-------|------|--------|-------|
| 100 VMs | 420 MB | 12.5 GB | 150 GB |
| 1,000 VMs | 4.2 GB | 124 GB | 1.5 TB |
| 10,000 VMs | 42 GB | 1.24 TB | 14.9 TB |

**The metering sweep interval is the primary lever.** Changing from 45s to
5 minutes reduces all capacity-billing rows by **6.7×** with no change to
billing accuracy (cost is prorated regardless of granularity).

---

## Scenario: MaaS-only (no OSAC VMs)

Pure consumption billing — inference events, no VM fleet.

### MaaS event rates

| Usage tier | Events/hour | Events/day | Description |
|-----------|-------------|------------|-------------|
| Light | 1,000 | 24,000 | ~100 active users, 10 requests/hour each |
| Medium | 10,000 | 240,000 | ~1,000 users, 10 requests/hour |
| Heavy | 100,000 | 2,400,000 | ~10,000 users or batch workloads |
| Very heavy | 1,000,000 | 24,000,000 | Large-scale deployment |

### raw_events (MaaS — dominant driver)

| MaaS rate | /day | /month | /year |
|-----------|------|--------|-------|
| 1k events/h | 27 MB | 826 MB | 9.9 GB |
| 10k events/h | 275 MB | 8.3 GB | 99 GB |
| 100k events/h | 2.7 GB | 83 GB | 993 GB |
| 1M events/h | 27 GB | 825 GB | 9.9 TB |

### metering_entries + cost_entries (MaaS)

2 metering + 2 cost entries per event (442 B + 286 B = 728 B per event pair).

| MaaS rate | Combined/day | /month | /year |
|-----------|-------------|--------|-------|
| 1k events/h | 35 MB | 1.0 GB | 12 GB |
| 10k events/h | 350 MB | 10.5 GB | 125 GB |
| 100k events/h | 3.5 GB | 104 GB | 1.25 TB |
| 1M events/h | 35 GB | 1 TB | 12.5 TB |

### Combined (MaaS-only)

| MaaS rate | /day | /month | /year |
|-----------|------|--------|-------|
| 1k events/h | 62 MB | 1.9 GB | 22 GB |
| 10k events/h | 625 MB | 18.8 GB | 224 GB |
| 100k events/h | 6.2 GB | 187 GB | 2.2 TB |
| 1M events/h | 62 GB | 1.9 TB | 22 TB |

> `raw_events` dominates in MaaS-only deployments (~44% of total size).
> Rolling up `raw_events` is not practical (the full payload is needed for
> debugging and replay), so archiving to Splunk/S3 before pruning is
> essential — see [table-lifecycle.md](table-lifecycle.md).

---

## Combined scenario: OSAC + MaaS

Most realistic production deployment.

### Storage per day (all tables combined)

|  | **100 VMs** | **1,000 VMs** | **10,000 VMs** |
|--|-------------|---------------|----------------|
| **1k MaaS events/h** | 482 MB/day | 4.3 GB/day | 42 GB/day |
| **10k MaaS events/h** | 1.0 GB/day | 4.9 GB/day | 43 GB/day |
| **100k MaaS events/h** | 6.6 GB/day | 10.8 GB/day | 49 GB/day |
| **1M MaaS events/h** | 62 GB/day | 66 GB/day | 104 GB/day |

### Storage per year (all tables, no pruning)

|  | **100 VMs** | **1,000 VMs** | **10,000 VMs** |
|--|-------------|---------------|----------------|
| **1k MaaS events/h** | 172 GB | 1.5 TB | 15 TB |
| **10k MaaS events/h** | 378 GB | 1.8 TB | 16 TB |
| **100k MaaS events/h** | 2.4 TB | 3.9 TB | 18 TB |
| **1M MaaS events/h** | 22 TB | 24 TB | 38 TB |

---

## With lifecycle management (hot windows)

Applying the policy from [table-lifecycle.md](table-lifecycle.md):
- `raw_events`: ~30-day steady-state (archive-gated)
- `metering_entries`: 2-month hot window → `monthly_usage_summary`
- `cost_entries`: 13-month hot window → `monthly_cost_summary` (7yr)

### Steady-state DB size (PostgreSQL only, post-archival)

|  | **100 VMs** | **1,000 VMs** | **10,000 VMs** |
|--|-------------|---------------|----------------|
| **1k MaaS events/h** | 28 GB | 261 GB | 2.6 TB |
| **10k MaaS events/h** | 31 GB | 267 GB | 2.6 TB |
| **100k MaaS events/h** | 56 GB | 291 GB | 2.7 TB |
| **1M MaaS events/h** | 289 GB | 524 GB | 4.9 TB |

> The 2-month metering window at 1,000 VMs costs ~150 GB regardless of
> MaaS volume. MaaS at 1M events/h adds ~265 GB. The VM fleet is the
> dominant factor below ~100k events/h.

---

## Key tuning levers

| Lever | Effect | Trade-off |
|-------|--------|-----------|
| **Metering sweep interval** (default 45s) | Linear — 2× interval = 2× fewer rows | Coarser billing granularity; minimum viable is 1 min |
| **MaaS archival** (Splunk/S3) | Removes raw_events from PostgreSQL | Requires Splunk in prod |
| **monthly_usage_summary rollup** | Reduces metering_entries hot window to 2 months | Loses per-event metering detail after 2 months |
| **Partition metering_entries by month** | DROP PARTITION instead of DELETE | Schema change; recommended above 50M rows |
| **RATING_BATCH_SIZE** | Controls rating sweep throughput | Higher = more DB memory during sweep |

---

## Metering interval sensitivity

At 1,000 VMs, changing the metering sweep interval:

| Interval | metering_entries/year | Size/year |
|----------|----------------------|-----------|
| 45s (default) | 2.1 B rows | 906 GB |
| 5 min | 315 M rows | 135 GB |
| 15 min | 105 M rows | 45 GB |
| 1 hour | 26 M rows | 11 GB |

Monthly billing does not require 45s granularity. A 5-minute interval
reduces storage 6.7× with identical billing accuracy for flat-rate meters.
Cumulative tiered meters would see slightly different waterfall calculations
but the difference is sub-cent per billing period.
