# Requirement 11: Cost Tiers — Gap Analysis

> **Requirement:** Tiered pricing support for both capacity-based and MaaS
> consumption-based rates. Examples: 
- first 20 GiB free, next 100 GiB at $0.08/GiB-month, next 1000 GiB at $0.07/GiB-month
- first 1M tokens free every 5 hours and next 1M tokens at $10 USD/Mtoken
- first 1,000 requests free every 24 hours and next 1,000 request at $10 USD/Krequest

All of these rates, tiers and time ranges should be configurable by OSAC Cloud/Tenant Admin roles and/or Cost Management Administrators (depending on which one is the source of truth for the tiers). It should be possible to configure tiers for different tenants and meters separately.

>
> **Source:** [poc_requirements_overview.md#req-11](https://github.com/myersCody/cost_ai_grid_poc/blob/main/docs/requirements/poc_requirements_overview.md#req-11-cost-tiers)
>
> **Related:** [REQ-9 Quota/Budget](req9-quota-budget-gap-analysis.md) — dimensional/monetary *ceilings* and status API (not pricing)
>
> **Depends on:** REQ-2 (Near-Real-Time Cost Calculation) — **Done**,
> REQ-2a (MaaS token metering) — **In Progress**

## Boundary with REQ-9 (Quotas / Budgets)

REQ-11 answers **what rate applies**. REQ-9 answers **how much is allowed**.

The same windowed pattern (e.g. “1M tokens every 5 hours”) can be configured
either way by the OSAC or Cost Management administrator:

| Admin configures… | Behavior after the free/included band | Home |
|-------------------|----------------------------------------|------|
| Free → **charge** next band | Keep serving; apply next price | **REQ-11** (this doc) |
| Allow → **deny** / throttle | Hard ceiling; OSAC enforces using status | **[REQ-9](req9-quota-budget-gap-analysis.md)** |
| Monetary spend ceiling | Status + thresholds; enforcement OUT | **REQ-9** |

Both may use the same meters and clocks; they are different APIs and semantics.
Which mode applies is a **per-rate / per-quota configuration choice**, not a
fixed product rule for all MaaS traffic.

## TL;DR

Tiered pricing is implemented for **per-event** graduated bands (works within a single MaaS event). That is not enough for the requirement as stated: capacity meters need **period-cumulative** tiers (GiB-month), and the MaaS examples need **time-windowed** tiers that reset (every 5h / 24h). Neither accumulation model exists today — configuring those tiers on current code would silently undercharge. Prices/costs still use `float64` in Go (**Gap** — money needs decimal or integer minor units). Per-tenant rate records already exist; configurable time ranges and admin-role ownership still need sign-off.

## What We Have

The rating engine already implements tiered pricing. `ApplyRate` checks for
tiers before falling back to flat-rate pricing. **Target types** (money must
not use IEEE floats):

```go
import "github.com/shopspring/decimal"

// Target shape — decimal money. Go has no stdlib currency type;
// shopspring/decimal is the usual choice (exact decimal arithmetic).
// Alternative: store minor units as int64 (cents / micros) and scale for display.
func ApplyRate(value decimal.Decimal, rate inventory.RateRecord) decimal.Decimal {
    if len(rate.Tiers) > 0 {
        return applyTieredRate(value, rate.Tiers)
    }
    return value.Mul(rate.PricePerUnit)
}

type Tier struct {
    UpTo         *decimal.Decimal `json:"up_to"` // nil = unbounded final tier
    PricePerUnit decimal.Decimal  `json:"price_per_unit"`
}
```

**Current code** still uses `float64` for `ApplyRate`, `Tier.PricePerUnit`,
`RateRecord.PricePerUnit`, and cost amounts — acceptable for demos, **not**
acceptable for billing-grade money (rounding / representation error). Postgres
`NUMERIC` on cost columns is fine; the Go layer is the gap. See Coverage and
Gap Details below.

`applyTieredRate` uses a waterfall loop — `prev`/`remaining` tracking — that
correctly implements **graduated pricing**: only the marginal units in each
band are priced at that band's rate. The whole quantity is not repriced when
a boundary is crossed.

A `nil` `UpTo` means the tier is unbounded — it absorbs all remaining
quantity. This correctly handles the "above N units at $X" final band.

Tier *band* configuration requires no code changes once stored: tiers are
JSONB in the `rates` table and loaded at rating time (`POST /api/v1/rates`
or SQL). Switching price fields from `float64` → decimal (or minor-unit
integers) **does** require a code + migration change.

## Rate-to-Tier-Semantics Map

Every meter currently in `SeedDefaultRates` falls into one of three tier semantics. This table should be the authoritative reference for implementation decisions and demo scripting.

| Meter | Resource Type | Unit | Tier Semantics | Reason |
|---|---|---|---|---|
| `vm_uptime_seconds` | `compute_instance` | seconds | **Cumulative (billing period)** | Capacity reservation; 60s sweeps are tiny fractions of monthly usage |
| `vm_cpu_core_seconds` | `compute_instance` | core_seconds | **Cumulative (billing period)** | Capacity reservation; same accumulation model as GiB-month |
| `vm_memory_gib_seconds` | `compute_instance` | gib_seconds | **Cumulative (billing period)** | Exactly the GiB-month pattern cited in the spec |
| `cluster_uptime_seconds` | `cluster` | seconds | **Cumulative (billing period)** | Capacity reservation; cluster-hours accumulate over the billing period |
| `cluster_worker_node_seconds` | `cluster` | node_seconds | **Cumulative (billing period)** | Node-hour accumulation; tiers represent volume discounts on sustained usage |
| `bm_uptime_seconds` | `bare_metal` | seconds | **Cumulative (billing period)** | Capacity reservation; bare metal is leased, not consumed per-request |
| `maas_tokens_in` | `model` | tokens | **Per-Event** *and/or* **Windowed** | Per-event waterfall works within one request; spec also requires windowed free bands (e.g. first 1M free every 5h) |
| `maas_tokens_out` | `model` | tokens | **Per-Event** *and/or* **Windowed** | Same as `maas_tokens_in` |
| `maas_tokens_cached` | `model` | tokens | **Per-Event** *and/or* **Windowed** | Rate seeded but not currently metered — no entries produced |
| `maas_tokens_reasoning` | `model` | tokens | **Per-Event** *and/or* **Windowed** | Rate seeded but not currently metered — no entries produced |
| `maas_requests` | `model` | requests | **Per-Event** *and/or* **Windowed** | Spec example: first 1K requests free every 24h |

**Summary:** Capacity meters need billing-period cumulative tiers (**Gap**). MaaS per-event graduated pricing is **Done**; MaaS time-windowed free/paid bands from the requirement examples are a separate **Gap**.

## Coverage vs Gaps

| Capability | Required | Status | Notes |
|---|---|---|---|
| Multiple tiers per rate record | Yes | **Done** | `[]Tier` in `RateRecord` |
| Graduated pricing (marginal units only) | Yes | **Done** | `applyTieredRate` waterfall |
| Unbounded final tier (`up_to: null`) | Yes | **Done** | `nil` pointer check |
| Free tier (`price_per_unit: 0`) | Yes | **Done** | Zero price is valid; no special case needed |
| Exact decimal money (no `float64` for prices/costs) | Yes | **Gap** | Prefer `shopspring/decimal` + Postgres `NUMERIC`. int64 minor units: OK at cents/micros for $M balances, but MaaS per-token rates need sub-micro precision and then int64 max shrinks (~$9.2M at nanos) |
| MaaS per-event tiers (within a single event) | Yes | **Done** | Within-event graduated waterfall; does **not** cover the windowed MaaS examples below |
| Time-windowed MaaS free/paid bands (tokens, requests) | Yes | **Gap** | e.g. first 1M tokens free every 5h **then charge**; accumulation + window reset. Hard stop after allowance → [REQ-9](req9-quota-budget-gap-analysis.md) |
| Configurable time ranges / billing windows on tiers | Yes | **Gap** | Requirement: “rates, tiers and time ranges should be configurable”; `Tier` has no window/period field today |
| Capacity cumulative tiers (GiB-month, core-hours) | Yes | **Gap** | Spec example implies monthly accumulation; per-event is incorrect — see "Tier Semantics" below |
| Per-tenant (and per-meter) tier configuration | Yes | **Partial** | `RateRecord.TenantID` + per-meter rates already supported; need to confirm seeded/demo tiers cover tenant overrides |
| Config by OSAC Cloud/Tenant Admin and/or Cost admins | Yes | **Partial** | Depends on source of truth; API/SQL exists for Cost-side config; OSAC admin path = ownership/sync |
| Tier config without code changes | Yes | **Done** | DB-stored JSONB; manageable via API or SQL (bands only — not time windows) |
| Tier management UI or sync API | Out of scope | Not started | Manual config acceptable for PoC |
| OSAC → Cost tier sync | Post-PoC | Not started | Ownership unresolved; deferred |

## Gap Details

### 0. Money must not be `float64`

IEEE floating point cannot represent most decimal fractions exactly (e.g.
`0.1`, `0.01`). For rates and costs that is a billing correctness issue, not
a style preference.

Go’s standard library has **no** decimal or currency type. Common options:

| Approach | Package / pattern | Performance | Notes |
|----------|-------------------|-------------|--------|
| Decimal | [`github.com/shopspring/decimal`](https://github.com/shopspring/decimal) | Slower than int64 (big-int under the hood); fine for normal rating sweeps | Exact decimal math; pairs well with Postgres `NUMERIC`; no practical $ cap |
| Minor units | `int64` (cents / micros / nanos) | Fastest | Exact only at a **fixed scale**; scale vs max-dollar tradeoff (below) |

**`int64` is enough for “tens of millions of dollars” only if the scale is coarse enough:**

| Scale | 1 unit means | Approx max dollars | Tens of millions OK? |
|-------|--------------|--------------------|----------------------|
| Cents (`×100`) | $0.01 | ~$9×10¹⁶ | Yes |
| Micros (`×10⁶`) | $0.000001 | ~$9.2 billion | Yes |
| Nanos (`×10⁹`) | $0.000000001 | ~$9.2 **million** | Tight / no for large tenants or lifetime totals |
| Finer than nano | — | drops quickly | No |

The PoC’s MaaS rates (e.g. **$0.50 / 1M tokens** = **$0.0000005 per token**) need **sub-micro** resolution. Micros cannot represent that exactly; nanos can, but then a single balance/cost field tops out near **~$9.2M** — awkward for large customers or rolled-up fleets.

**Recommendation:** use `shopspring/decimal` (or `NUMERIC` + decimal in Go) for **prices and costs**. Keep meter *quantities* (seconds, tokens) in types suited to usage. Prefer int64 minor units only for coarse settlement/display (e.g. cents) if ever needed — not as the sole type for per-token rate math.

### 1. Tier Semantics: Three Billing Models, Not One

The requirement applies tiers to capacity and MaaS workloads and includes
**time-windowed** MaaS examples. These are not the same problem.

#### MaaS — Per-Event Graduated Pricing Is Done (Narrow Case)

For a **single** MaaS event, **per-event graduated pricing is correct** and
already implemented. Cloud AI providers often price per API call at a fixed
rate per token; if one request is large enough to cross a tier boundary
(e.g. a batch job sending 2M tokens), the waterfall applies within that event.

That does **not** satisfy the requirement examples that reset on a clock
**and then charge** the next band:

> "first 1M tokens free every 5 hours and next 1M tokens at $10 USD/Mtoken"  
> "first 1,000 requests free every 24 hours and next 1,000 request at $10 USD/Krequest"

Those need **windowed accumulation for pricing**: sum usage in the active
window, apply graduated *rates* to the running total, reset when the window
rolls. Today every small request re-enters the free band independently —
same undercharge class of bug as capacity per-event tiers.

If the administrator instead configures “allowance then **deny**,” that is a
**quota** — see [REQ-9](req9-quota-budget-gap-analysis.md), not this doc.
The same numeric window can back either mode depending on configuration.

#### MaaS — Time-Windowed *Pricing* Tiers Are a Gap

No `window` / `period` / `reset_every` field exists on `Tier`. The rating
sweep does not query usage within a rolling or calendar window before
applying MaaS tiers. Until that exists, the intro’s 5h/24h **free→paid**
examples cannot be configured correctly. (Windowed **ceilings** that block
are REQ-9’s problem — and also unimplemented for non-monthly periods.)

#### Capacity (GiB-month, core-hours) — Per-Event Is Wrong

The capacity example in the requirement is:

> "first 20 GiB free, next 100 GiB at $0.08/**GiB-month**"

The `/month` suffix is unambiguous — this is a billing period aggregate.
Usage accumulates across all 60-second sweeps in the month and tiers fire
as the running total crosses thresholds. No individual sweep produces 20 GiB
of delta; per-event tiering means the free tier never exhausts and the tenant
pays $0 all month regardless of total consumption.

**Per-event example** — tenant accumulates 200 GiB over a month via sweeps
of ~0.07 GiB each. Tier: first 20 GiB free, above 20 GiB at $0.08/GiB-month.

```
Sweep 1:   ApplyRate(0.07 GiB) → within free tier → $0.00
Sweep 2:   ApplyRate(0.07 GiB) → within free tier → $0.00
...
Sweep N:   ApplyRate(0.07 GiB) → within free tier → $0.00
Total billed: $0.00   ← free tier never exhausts; tenant is undercharged by $14.40
```

**Cumulative example** — same 200 GiB accumulated over the month:

```
First 20 GiB  → $0.00 (free)
Next 100 GiB  → $8.00 (100 × $0.08)
Next 80 GiB   → $5.60 (80 × $0.07)
Total billed: $13.60   ← correct
```

This is a real gap. A per-event tier system that works within a large MaaS
request is still silently incorrect for capacity rates *and* for windowed
MaaS **free→paid** pricing bands.


### 2. Unresolved Ownership: Where Do Tiers Live?

The requirements list this as an open question: "Where do cost tiers live:
OSAC, Cost, or both synced?"

This is unresolved in the architectural decisions table. For the PoC, a practical answer is needed to unblock demo setup.

**Options:**

| Option | PoC complexity | Production complexity | Notes |
|---|---|---|---|
| Cost owns tiers (manual DB setup) | Trivial | Medium | No sync needed; tiers seeded via `SeedDefaultRates` or API |
| OSAC owns tiers, Cost reads them | Small | Medium | Requires OSAC to expose a tiers endpoint Cost can poll |
| Both synced | Medium | High | Bilateral sync; conflict resolution needed |

## Implementation Options for PoC

### Option A: Per-Event Only — Narrow MaaS Demo

Keep the current implementation. Demo REQ-11 only through **within-event**
MaaS graduated bands (large single requests that cross tier boundaries). Do
**not** demo capacity GiB-month tiers or the windowed “every 5h / 24h” MaaS
examples; call those out as gaps / post-PoC.

**Effort:** None — already implemented for within-event MaaS.
**Constraint:** Does not satisfy the requirement’s windowed MaaS or capacity
cumulative examples. MaaS simulator should fire batches of ≥1M tokens per
event so within-event boundaries visibly fire.

### Option B: Cumulative Tiers for Capacity

Before calling `ApplyRate` for capacity meters, query `MeteringSum` for the
tenant/meter/billing period to get the accumulated total. Determine which
tier band the current sweep's delta falls into given the accumulated
position, and price only the marginal contribution.

This requires careful delta accounting to avoid double-counting: the cost
entry records the marginal cost of this sweep's units at the correct tier
position, not the cost of the full accumulated total.

**Effort:** Medium — new accumulated-usage query, delta cost logic in the
rating sweep, updated cost entry attribution.
**Benefit:** Correct behavior for the GiB-month spec example.

### Option C: Time-Windowed Tiers for MaaS

Extend the tier model with a configurable window (e.g. `reset_every: 5h` /
`24h`). Before rating a MaaS event, sum meter usage in the active window for
that tenant/meter, apply graduated tiers to the running total, and attribute
only the marginal cost of this event. Same delta-accounting care as Option B,
but with a rolling or calendar window instead of a billing month.

**Effort:** Medium — overlaps with Option B’s accumulation machinery; adds
window definition on `Tier` / rate config and window-bounded queries.
**Benefit:** Satisfies the “every 5 hours” / “every 24 hours” requirement examples.

## Open Questions

### 1. Tier ownership for PoC

Cost or OSAC (Cloud/Tenant Admin vs Cost Management Administrators)? Needs
sign-off — see Coverage row on admin configurability.

### 2. Demo scope: per-event only, capacity cumulative, and/or windowed MaaS?

- Option A alone demos only within-event MaaS bands.
- Capacity GiB-month needs Option B.
- Windowed free allowances (5h / 24h) need Option C.
This decision drives the implementation path.

### 3. Decimal vs integer minor units for money — **lean decimal (Jul 20)**

Product requirement: exact money (no floats). **`shopspring/decimal`** for
rates/costs given MaaS sub-micro unit prices; int64 minor units hit a
scale-vs-range wall (nanos ≈ $9.2M max). See Gap Details §0. Remaining
engineering choice is only whether any *display/settlement* path uses cents
as int64 — not whether rating uses floats or nanos-as-int64.

### 4. MaaS simulator event size

What token batch size does the MaaS simulator emit per event today? If
batches are already ≥1M tokens, within-event tier boundaries fire under
Option A. If batches are small (thousands of tokens), either the simulator
needs adjustment, tier boundaries must be set below the typical event value,
or demo relies on Option C windowed accumulation instead.

### 5. Seeded tiered rate example

`SeedDefaultRates` currently seeds only flat rates. At least one MaaS rate
(e.g., `maas_tokens_in`) should be seeded with a tiered structure so the
feature is visible in a default deployment without manual DB setup. Without
this, tier support exists in code but is invisible at demo time. Prefer a
seed that matches the chosen demo scope (per-event bands vs windowed).
