# Cost Calculation and Billing Specification

> **Status:** PoC draft  
> **Requirements:** REQ-3b, REQ-4, COST-6951, COST-7164  
> **Related:** [metering-spec-draft.md](../metering/metering-spec-draft.md) · [cost_model_metric_feasibility.md](../metering/cost_model_metric_feasibility.md) · [cost-reports-feasibility.md](../reporting/cost-reports-feasibility.md) · [event-types.md](../event-types.md)

---

## 1. Purpose

This spec defines how Cost Management converts metered quantities into billable costs for the AI Grid PoC. It is the companion to [metering-spec-draft.md](../metering/metering-spec-draft.md), which handles quantity measurement.

**Metering answers:** how much capacity was provisioned, for how long, and for whom?  
**This spec answers:** what does that cost?

The separation is intentional: meters are immutable facts; rates and tiers are policy that may change without re-metering.

---

## 2. Rate Types

### 2.1 Capacity-Based Rates (VMaaS / CaaS / BMaaS)

| Rate type | Example | Applies to meter |
|---|---|---|
| Flat hourly (VM) | `$0.10 / VM-hour` | `vm_uptime_seconds` |
| Per-core hourly | `$0.05 / core-hour` | `vm_cpu_core_seconds` |
| Per-GiB hourly | `$0.01 / GiB-hour` | `vm_memory_gib_seconds` |
| Flat monthly (node) | `$500 / node-month` | `cluster_worker_node_seconds` (amortized) |
| Cluster flat monthly | `$200 / cluster-month` | `cluster_uptime_seconds` (control plane) |
| Bare metal flat hourly | TBD | `bm_uptime_seconds` (pending BMaaS schema) |

### 2.2 MaaS Consumption-Based Rates (REQ-4 / COST-7164)

Model-as-a-Service charges per unit of inference consumed, not per provisioned capacity. Rate unit is per million tokens/requests.

| Dimension | Unit | Example rate |
|---|---|---|
| Tokens in (prompt) | per million tokens | `$0.50 / M tokens` |
| Tokens out (completion) | per million tokens | `$1.50 / M tokens` |
| Inference tokens | per million tokens | `$1.00 / M tokens` |
| Requests | per million requests | `$0.10 / M requests` |

> MaaS meters are sourced from OSAC/RHOAI CloudEvents. See [event-types.md](../event-types.md) for the expected payload fields. Open question: whether Cost or OSAC is responsible for collecting RHOAI metrics — see §7.

---

## 3. Rate Storage

Rates are stored in the `rates` table, keyed by `resource_type`, `meter_name`, and optionally `tenant_id` and `instance_type` for per-tenant and per-SKU pricing.

> **Actual implementation** (differs from the original spec below):
> - PK is `BIGSERIAL`, not UUID
> - `tenant_id` is `TEXT`, not UUID
> - `unit_divisor` was not implemented — `price_per_unit` is stored
>   pre-converted (e.g. `$0.01/hour / 3600 = $/second`)
> - Added: `instance_type TEXT` (per-SKU pricing), `koku_metric TEXT`,
>   `cost_type TEXT` (Infrastructure/Supplementary), `tiers JSONB`,
>   `description TEXT`
> - See [`internal/inventory/store.go`](../../../inventory-watcher/internal/inventory/store.go) for the actual schema

```
rates (actual)
  id              BIGSERIAL PK
  tenant_id       TEXT NULL    -- NULL/empty = default rate; non-NULL = tenant override
  resource_type   TEXT         -- 'compute_instance', 'cluster', 'bare_metal', 'model'
  instance_type   TEXT         -- empty = all instance types; non-empty = per-SKU rate
  meter_name      TEXT         -- e.g. 'vm_uptime_seconds', 'maas_tokens_in'
  koku_metric     TEXT         -- Koku metric mapping (optional)
  cost_type       TEXT         -- 'Infrastructure' or 'Supplementary'
  price_per_unit  DECIMAL      -- pre-converted to per-unit (seconds, tokens)
  currency        TEXT         -- 'USD'
  tiers           JSONB        -- tiered pricing bands (see §4)
  description     TEXT
  effective_from  TIMESTAMPTZ
  effective_to    TIMESTAMPTZ NULL
```

Rate lookup uses a 4-way fallback: tenant+instance_type > instance_type > tenant > global. See [rate configuration guide](../../rate-configuration-guide.md).

---

## 4. Cost Tiers (COST-6951)

### 4.1 Overview

Tiered pricing allows the first N units to be charged at one rate (or free), with subsequent bands priced differently. Required for both capacity-based and MaaS consumption-based rates.

**Example:** Storage or token volume tiers  
- First 20 GiB: free  
- Next 100 GiB: `$0.08 / GiB-month`  
- Next 1,000 GiB: `$0.07 / GiB-month`  
- Above 1,120 GiB: `$0.06 / GiB-month`

### 4.2 Tier Schema

> **Actual implementation:** Tiers are stored as a JSONB column `tiers`
> on the `rates` table, not as a separate `rate_tiers` table. Each
> entry is `{"up_to": N, "price_per_unit": P}` where `up_to: null`
> means unbounded (final tier). The original spec below was not built.

```
rates.tiers (JSONB array — actual implementation)
  [
    {"up_to": 100,  "price_per_unit": 0.10},
    {"up_to": 500,  "price_per_unit": 0.05},
    {"up_to": null, "price_per_unit": 0.01}   -- unbounded final tier
  ]
```

### 4.3 Tier Evaluation

For a given billing period, accumulated consumption is split across tiers in order:

```
remaining = total_consumed_units
cost = 0

for tier in rate_tiers ordered by tier_order:
    band = min(remaining, tier.up_to_quantity ?? remaining)
    cost += band × tier.price_per_unit
    remaining -= band
    if remaining == 0: break
```

### 4.4 PoC Scope

For the PoC, flat rates (no tiers) are sufficient. The tier schema is defined to avoid a breaking migration later. Tier evaluation logic is implemented and active — flat-rate seeds have no tiers, so the tiered path is exercised only when rates with multiple tier rows are present.

---

## 5. Cost Formula

### 5.1 Basic Formula

```
cost_amount = metered_value × price_per_unit
```

All meters store raw SI units (seconds, core-seconds, GiB-seconds, tokens). `price_per_unit` is stored pre-converted to match the meter unit — e.g. `$0.01/hour` is stored as `$0.01 / 3600 = $0.00000278/second`. If tiers are present on the rate, `applyTieredRate` (graduated/waterfall) is used instead.

### 5.2 Sub-Monthly Amortization (Monthly Rates)

For monthly flat rates applied to sub-monthly metering windows:

```
daily_cost = (monthly_rate / days_in_month) × (metered_seconds / 86400)
```

### 5.3 MaaS Formula

```
cost_amount = token_count × (price_per_million / 1_000_000)
```

Each token dimension (in/out/inference) is rated independently and summed.

---

## 6. Cost Entry Schema

Each row in `cost_entries` represents the cost for one metering entry at the time of rate application:

| Field | Source |
|---|---|
| `metering_entry_id` | FK → `metering_entries.id` |
| `tenant_id` | From metering entry |
| `resource_type` | From metering entry |
| `resource_id` | From metering entry |
| `meter_name` | From metering entry |
| `metered_value` | Quantity from metering entry |
| `rate_id` | FK → `rates.id` (rate applied) |
| `cost_amount` | Calculated cost |
| `currency` | From rate |
| `period_start` | From metering entry |
| `period_end` | From metering entry |
| `calculated_at` | Timestamp of cost calculation run |

---

## 7. Koku Metric Mapping

The full meter → Koku cost model metric mapping is in [cost_model_metric_feasibility.md](../metering/cost_model_metric_feasibility.md). Summary of feasibility:

| Feasible (allocation-based) | Not feasible (usage-based) |
|---|---|
| `vm_cost_per_hour`, `vm_cost_per_month` | `cpu_core_usage_per_hour` |
| `vm_core_cost_per_hour`, `vm_core_cost_per_month` | `cpu_core_effective_usage_per_hour` |
| `cpu_core_request_per_hour`, `memory_gb_request_per_hour` | `memory_gb_usage_per_hour` |
| `cluster_cost_per_hour`, `cluster_cost_per_month` | `storage_gb_usage_per_month` |
| `node_cost_per_hour`, `node_core_cost_per_hour` | `gpu_cost_per_month` |
| `project_per_month` | |

---

## 8. Report Outputs

Report shapes and Koku response format compatibility are documented in [cost-reports-feasibility.md](../reporting/cost-reports-feasibility.md). PoC priority:

| Phase | Report | Key metrics |
|---|---|---|
| **1** | Compute cost by tenant/project | `cpu_core_hours`, `memory_gb_hours`, `cost_total` |
| **2** | Cluster cost, instance type breakdown | `node_count`, `total_cores`, `cost_total` |
| **3** | Network resource billing, cost distribution | `network_cost_total`, `distributed_cost` |

Response format follows Koku's hierarchical JSON structure (`meta` / `data` / `total`).

---

## 9. SLA

| Stage | Target | Requirement |
|---|---|---|
| Cost calculation after metering | ≤ 60s | REQ-2 |
| End-to-end (OSAC emit → cost available) | ≤ 90s | REQ-2 |

Cost calculation runs as an independent 30s sweep (Rater worker): it processes all unrated `metering_entries` in batches of 500 using cached rates. This is asynchronous from the metering sweep — any entry written by the 60s Meter sweep will be rated within the next Rater tick (~30s), satisfying the 90s E2E SLA.

---

## 10. PoC Phasing

| Phase | Deliverable | Status |
|---|---|---|
| **2** | Cost calculation (`metering_entries` → `cost_entries`) | **Implemented** — `rating.go` Rater worker runs on a 30s sweep; processes up to 500 unrated entries per sweep; writes `cost_entries` |
| **3** | Cost reports API (tenant/project drill-down) | Planned |
| **MaaS** | MaaS CloudEvent ingestion + token-based cost | **Partial** — `POST /api/v1/events` handles `osac.model.lifecycle`; `maas_tokens_in`, `maas_tokens_out`, `maas_requests` meters written and rated; OSAC/RHOAI event schema TBD |
| **Tiers** | Tiered rate evaluation for capacity + MaaS | **Implemented** — `applyTieredRate` in `rating.go` is active; flat rates used for PoC seeds |

---

## 11. Open Questions

| # | Question | Owner | Impact |
|---|---|---|---|
| 1 | Where do rates live — OSAC catalog sync vs manual seed? | Cost | REQ-3b — manual acceptable for PoC |
| 2 | Where do cost tiers live: OSAC, Cost, or both synced? (COST-6951) | Cost + OSAC | Shapes rate engine and sync complexity |
| 3 | Who collects RHOAI MaaS metrics — Cost or OSAC? | OSAC + Cost | Defines integration boundary for REQ-4 |
| 4 | What fields will OSAC MaaS CloudEvents contain? | OSAC | Required to implement token-based rating |
| 5 | MaaS transport: HTTP, Kafka, other? | OSAC + Cost | REQ-1b / COST-7164 |
| 6 | HostType catalog join for `cores_per_node` on clusters? | OSAC + Cost | Needed for `node_core_cost_per_*` metrics |
| 7 | Pre-aggregated summary tables for report query performance? | Cost | Dashboard SLA |

---

## 12. References

- [Metering spec](../metering/metering-spec-draft.md) — quantity measurement (the input to this spec)
- [ADR-001: Metering sweep interval](../../decisions/001-metering-sweep-interval.md)
- [Cost model metric feasibility](../metering/cost_model_metric_feasibility.md)
- [Cost reports feasibility](../reporting/cost-reports-feasibility.md)
- [POC requirements overview](../../requirements/poc_requirements_overview.md)
- [Koku cost model constants](https://github.com/project-koku/koku/blob/main/koku/api/metrics/constants.py)
- COST-6951 — Cost tiers
- COST-7164 — MaaS costing
