# Computed Custom Metrics: Design Options

> **Context:** The current custom metrics feature (REQ-13) only does field
> extraction — it pulls a pre-computed value from a CloudEvent field. It
> cannot compute a meter value from multiple fields (e.g. `cores × duration`).
> This document evaluates three approaches to add computed metrics.
>
> **Related:**
> - [req13-custom-metrics-design.md](req13-custom-metrics-design.md) — current implementation
> - [rating-engine-options.md](rating-engine-options.md) — GoRules/Zen evaluation
> - [GoRules spike PR #45](https://github.com/myersCody/cost_ai_grid_poc/pull/45) — working prototype

## The Problem

The built-in metering for VMs computes derived values:

```go
// internal/metering/metering.go:455
MeterName: "vm_cpu_core_seconds",
Value:     float64(cores) * durationSeconds,
```

But custom metrics can only extract a single field:

```json
{
  "meter_name": "gpu_compute_seconds",
  "value_field": "gpu_compute_seconds"
}
```

If the CloudEvent source doesn't pre-compute `gpu_compute_seconds`, you're
stuck — you can't define `gpu_cores × duration_seconds` in config. Every
new computed metric requires a Go code change.

## Three Approaches

### Option A: Expressions at Metering Time

Add an `expression` field to the custom metrics config. When present, it
replaces `value_field` — instead of extracting one field, it evaluates a
math expression over event data fields.

#### Config format

```json
{
  "custom_metrics": [{
    "event_type": "osac.gpu.lifecycle",
    "resource_type": "gpu_instance",
    "resource_id_field": "instance_id",
    "tenant_id_field": "tenant_id",
    "meters": [
      {
        "meter_name": "gpu_core_seconds",
        "expression": "gpu_cores * duration_seconds",
        "unit": "core_seconds"
      },
      {
        "meter_name": "gpu_memory_gib_hours",
        "expression": "gpu_memory_gib * duration_seconds / 3600",
        "unit": "gib_hours"
      },
      {
        "meter_name": "gpu_compute_seconds",
        "value_field": "gpu_compute_seconds",
        "unit": "seconds"
      }
    ]
  }]
}
```

`value_field` and `expression` are mutually exclusive per meter definition.
Variables in expressions refer to fields in the CloudEvent `data` object.

#### What it can do

- Arithmetic on event fields: `+`, `-`, `*`, `/`
- Multiple fields in one expression: `cores * memory_gib * duration`
- Produce meaningful usage units (core_seconds, gib_hours)
- Co-exist with simple field extraction (`value_field` still works)
- Matches exactly how the built-in `computeInstanceMeters` works

#### What it cannot do

- Conditional logic: "if model == A100 use formula X, else use Y"
- Cross-reference external data (rate tables, tenant tiers, catalog items)
- String operations or comparisons
- Accumulation across events (running totals, period-based aggregation)
- Complex math (trigonometry, statistical functions)

#### Real-world examples

**Example 1: GPU instance metering**

CloudEvent:
```json
{
  "type": "osac.gpu.lifecycle",
  "data": {
    "instance_id": "gpu-i-abc123",
    "gpu_cores": 8,
    "gpu_memory_gib": 80,
    "duration_seconds": 3600,
    "state": "RUNNING"
  }
}
```

Config:
```json
{
  "meter_name": "gpu_core_seconds",
  "expression": "gpu_cores * duration_seconds",
  "unit": "core_seconds"
}
```

Result: metering entry with value `28800` (8 × 3600) core_seconds.
Rating: `28800 × $0.00001/core_second = $0.288`.

**Example 2: Network traffic billing**

CloudEvent:
```json
{
  "type": "osac.network.usage",
  "data": {
    "interface_id": "nic-001",
    "bytes_in": 1073741824,
    "bytes_out": 5368709120,
    "duration_seconds": 3600
  }
}
```

Config:
```json
[
  {
    "meter_name": "egress_gib",
    "expression": "bytes_out / 1073741824",
    "unit": "gib"
  },
  {
    "meter_name": "total_bandwidth_mbps",
    "expression": "(bytes_in + bytes_out) * 8 / duration_seconds / 1000000",
    "unit": "mbps"
  }
]
```

**Example 3: Storage cost with overhead factor**

```json
{
  "meter_name": "storage_effective_gib_hours",
  "expression": "disk_size_gib * replication_factor * duration_seconds / 3600",
  "unit": "gib_hours"
}
```

#### Implementation

- **Expression engine:** Use [expr-lang/expr](https://github.com/expr-lang/expr)
  (Go, MIT, ~2MB, no CGo) or a minimal hand-rolled parser for basic arithmetic.
  `expr` supports `+`, `-`, `*`, `/`, `%`, parentheses, variable references,
  comparisons, and ternary — more than enough.
- **Integration point:** `custommetrics.ProcessEvent` — where `value_field`
  is currently extracted, add a branch: if `expression` is set, evaluate it
  with event data fields as variables.
- **Validation:** At config load time, parse all expressions and verify they
  reference valid syntax. At event time, return an error if a referenced
  variable is missing from event data.

#### Complexity

| Dimension | Assessment |
|---|---|
| New dependencies | 1 (expr-lang/expr) or 0 (hand-rolled) |
| Lines of code | ~50-100 in custommetrics.go |
| Config change | Additive (new `expression` field, `value_field` still works) |
| Testing | Unit tests with expression evaluation, existing integration tests unchanged |
| Operability | Metering entries show computed values — easy to audit |
| Performance | Sub-microsecond per expression (compiled at load time) |

---

### Option B: GoRules at Rating Time

Instead of computing meter values, extract raw fields as separate metering
entries and let GoRules combine them during the rating sweep to produce cost.

#### Config format

Custom metrics config extracts raw fields (no change from today):

```json
{
  "custom_metrics": [{
    "event_type": "osac.gpu.lifecycle",
    "resource_type": "gpu_instance",
    "resource_id_field": "instance_id",
    "tenant_id_field": "tenant_id",
    "meters": [
      { "meter_name": "gpu_cores", "value_field": "gpu_cores", "unit": "cores" },
      { "meter_name": "duration_seconds", "value_field": "duration_seconds", "unit": "seconds" },
      { "meter_name": "gpu_memory_gib", "value_field": "gpu_memory_gib", "unit": "gib" }
    ]
  }]
}
```

GoRules JDM file handles the math at rating time:

```json
{
  "nodes": [
    {
      "id": "input-1",
      "type": "inputNode",
      "name": "Metering Entry"
    },
    {
      "id": "gpu-cost-calc",
      "type": "expressionNode",
      "name": "GPU Cost Calculation",
      "content": {
        "expressions": [
          {
            "key": "cost_amount",
            "value": "gpu_cores * duration_seconds * 0.00001 + gpu_memory_gib * duration_seconds / 3600 * 0.005"
          },
          {
            "key": "currency",
            "value": "'USD'"
          },
          {
            "key": "description",
            "value": "'GPU compute + memory cost'"
          }
        ]
      }
    },
    {
      "id": "output-1",
      "type": "outputNode",
      "name": "Cost Entry"
    }
  ],
  "edges": [
    { "id": "e1", "sourceId": "input-1", "targetId": "gpu-cost-calc" },
    { "id": "e2", "sourceId": "gpu-cost-calc", "targetId": "output-1" }
  ]
}
```

#### The problem: metering entries are per-meter, not per-event

The rating sweep processes one metering entry at a time:

```
metering_entries:
  gpu_cores       = 8       (for resource gpu-i-abc123, period 09:00-10:00)
  duration_seconds = 3600   (for resource gpu-i-abc123, period 09:00-10:00)
  gpu_memory_gib  = 80      (for resource gpu-i-abc123, period 09:00-10:00)
```

To compute `gpu_cores × duration_seconds`, the rating engine needs to
**join** multiple metering entries for the same resource and period. The
current rating sweep does `SELECT ... WHERE rated = false` row by row.

This means either:
1. **Change the rating sweep** to group metering entries by
   `(resource_id, resource_type, period_start, period_end)` and pass all
   related entries to GoRules as one input — significant refactor.
2. **Store all raw fields on a single metering entry** in a JSONB column —
   schema change, breaks the metering model.
3. **Accept that each raw field is rated independently** — which defeats
   the purpose (you can't compute `cores × duration` if they're separate rows).

#### What it can do

- Multi-variable pricing decisions: "if instance_type == A100 AND tenant_tier == gold, apply 20% discount"
- Committed-use discounts based on running VM count
- Sustained-use discounts based on monthly utilization percentage
- Visual rule design via JDM Editor (React UI)
- Complex conditional logic with decision tables

#### What it cannot do

- Compute derived usage metrics (core_seconds, gib_hours) — metering entries
  hold raw field values, not computed usage
- Report on computed usage ("total core-seconds this month") without replaying
  the rules
- Work without the cross-entry join problem being solved first
- Simple "value × rate" auditing — you need to replay the rule to explain a cost

#### Real-world examples where Option B shines

**Example: Instance-type-based pricing with tenant tier discounts**

This is what the GoRules spike (PR #45) already implements:

```
Input: { instance_type: "standard-4-16", tenant_tier: "gold", value: 3600 }

Decision table (compute-pricing.json):
  standard-4-16 + gold → $0.20/hr, 20% discount
  standard-4-16 + *    → $0.20/hr, 0% discount
  *             + *    → $0.10/hr, 0% discount (default)

Expression node:
  cost_amount = (value / 3600) * price_per_hour * (1 - discount_pct / 100)

Output: { cost_amount: 0.16, currency: "USD" }
```

**Example: Committed-use pricing with sustained-use fallback**

```
Input: {
  tenant_id: "tenant-acme",
  instance_type: "standard-4-16",
  value: 3600,
  running_vms: 8,
  base_price_per_hour: 0.20,
  monthly_utilization_pct: 80
}

Decision table determines:
  - tenant-acme has CUD for 5 VMs → 40% discount
  - running_vms (8) > commitment (5) → over commitment
  - Over commitment + utilization 80% → sustained-use 20% discount

Output: { cost_amount: 0.16, within_commitment: false }
```

These are **pricing decisions**, not meter computations. GoRules excels here.

#### Complexity

| Dimension | Assessment |
|---|---|
| New dependencies | zen-go (CGo, Rust binary via WASM) — already in spike |
| Lines of code | ~200 in rating.go + cross-entry grouping |
| Config change | GoRules JDM files replace or augment rates table |
| Testing | Requires GoRules test fixtures, CGo build |
| Operability | Hard to audit — must replay rule to explain cost |
| Performance | Fast execution (~μs), but cross-entry grouping adds DB queries |
| Refactor risk | Rating sweep needs significant changes for multi-entry input |

---

### Option C: Both Layers

Expressions at metering time for computing derived usage values.
GoRules at rating time for complex pricing decisions.

#### Config format

Custom metrics config with expressions (same as Option A):

```json
{
  "custom_metrics": [{
    "event_type": "osac.gpu.lifecycle",
    "resource_type": "gpu_instance",
    "resource_id_field": "instance_id",
    "tenant_id_field": "tenant_id",
    "meters": [
      {
        "meter_name": "gpu_core_seconds",
        "expression": "gpu_cores * duration_seconds",
        "unit": "core_seconds"
      },
      {
        "meter_name": "gpu_memory_gib_hours",
        "expression": "gpu_memory_gib * duration_seconds / 3600",
        "unit": "gib_hours"
      }
    ]
  }]
}
```

GoRules JDM file for pricing (similar to spike, but consumes computed meters):

```json
{
  "nodes": [
    { "id": "input-1", "type": "inputNode", "name": "Metering Entry" },
    {
      "id": "gpu-rate",
      "type": "decisionTableNode",
      "name": "GPU Rate Lookup",
      "content": {
        "hitPolicy": "first",
        "inputs": [
          { "field": "meter_name", "id": "c1", "name": "Meter" },
          { "field": "tenant_tier", "id": "c2", "name": "Tier" }
        ],
        "outputs": [
          { "field": "rate", "id": "c3", "name": "Rate" },
          { "field": "discount_pct", "id": "c4", "name": "Discount %" }
        ],
        "rules": [
          { "_id": "r1", "c1": "\"gpu_core_seconds\"", "c2": "\"gold\"",
            "c3": "0.00001", "c4": "20" },
          { "_id": "r2", "c1": "\"gpu_core_seconds\"", "c2": "",
            "c3": "0.00001", "c4": "0" },
          { "_id": "r3", "c1": "\"gpu_memory_gib_hours\"", "c2": "\"gold\"",
            "c3": "0.005", "c4": "20" },
          { "_id": "r4", "c1": "\"gpu_memory_gib_hours\"", "c2": "",
            "c3": "0.005", "c4": "0" }
        ]
      }
    },
    {
      "id": "calc-cost",
      "type": "expressionNode",
      "name": "Calculate Cost",
      "content": {
        "expressions": [
          { "key": "cost_amount", "value": "value * rate * (1 - discount_pct / 100)" },
          { "key": "currency", "value": "'USD'" }
        ]
      }
    },
    { "id": "output-1", "type": "outputNode", "name": "Cost Entry" }
  ],
  "edges": [
    { "id": "e1", "sourceId": "input-1", "targetId": "gpu-rate" },
    { "id": "e2", "sourceId": "gpu-rate", "targetId": "calc-cost" },
    { "id": "e3", "sourceId": "calc-cost", "targetId": "output-1" }
  ]
}
```

#### Data flow

```
CloudEvent { gpu_cores: 8, gpu_memory_gib: 80, duration: 3600 }
    │
    ▼ Expression (metering time)
MeteringEntry { meter: "gpu_core_seconds", value: 28800 }
MeteringEntry { meter: "gpu_memory_gib_hours", value: 80 }
    │
    ▼ GoRules (rating time)
CostEntry { cost: $0.288, description: "GPU compute" }
CostEntry { cost: $0.400, description: "GPU memory" }
```

Each layer does what it's good at:
- **Expressions** answer "what was used?" → meaningful metering entries
- **GoRules** answers "what does it cost?" → complex pricing decisions

#### What it can do

- Everything from Option A (computed usage values)
- Everything from Option B (complex pricing decisions)
- No cross-entry join problem — each metering entry has a self-contained value
- Metering entries are auditable ("28,800 core_seconds")
- Pricing is auditable via GoRules trace
- Can fall back to simple `value × rate` when GoRules is overkill

#### What it cannot do

- Two config systems to learn (expressions + JDM files)
- Must decide which layer handles each concern
- GoRules is optional — falls back to `rates` table if no rule file matches

#### Real-world examples

**Example 1: GPU compute with tier discounts**

Metering expression: `gpu_core_seconds = gpu_cores * duration_seconds`
GoRules: decision table maps `(meter_name, tenant_tier)` → `(rate, discount)`
Cost: `28800 × 0.00001 × (1 - 20%) = $0.2304`

**Example 2: MaaS tokens with committed-use pricing**

Metering: `value_field: "tokens_in"` (simple extraction — no expression needed)
GoRules: decision table checks monthly token volume against committed tier:
- < 1M tokens/month → $0.50/M (on-demand)
- 1-10M committed → $0.35/M (30% off)
- \> 10M committed → $0.25/M (50% off)

**Example 3: Network billing with peak/off-peak rates**

Metering expression: `egress_gib = bytes_out / 1073741824`
GoRules: function node checks time-of-day from `period_start`:
- 08:00-20:00 → $0.12/GiB (peak)
- 20:00-08:00 → $0.05/GiB (off-peak)

#### Complexity

| Dimension | Assessment |
|---|---|
| New dependencies | expr-lang/expr + zen-go (CGo) |
| Lines of code | ~50-100 in custommetrics.go (expressions) + ~200 in rating.go (GoRules) |
| Config change | `expression` field in custom metrics + JDM files for pricing |
| Testing | Two test surfaces, but each is well-isolated |
| Operability | Best of both — metering entries show usage, GoRules trace shows pricing |
| Performance | Sub-microsecond expressions + sub-microsecond GoRules |
| Refactor risk | Low — expressions are additive to custommetrics, GoRules replaces ApplyRate |

---

## Comparison Matrix

| Criterion | A: Expressions | B: GoRules only | C: Both |
|---|---|---|---|
| Compute `cores × duration` | Yes | Requires cross-entry join | Yes |
| Conditional pricing (tier discounts) | No | Yes | Yes |
| Multi-variable pricing | No | Yes | Yes |
| Metering entries meaningful? | Yes | No (raw field dumps) | Yes |
| Usage reporting works? | Yes | No (need to replay rules) | Yes |
| "Why was I charged $X?" | Easy (value × rate) | Hard (replay rule) | Medium (check both) |
| New dependencies | 1 small (expr) | 1 large (zen-go/CGo) | Both |
| Implementation effort | Small (~100 LOC) | Large (~500+ LOC, refactor) | Medium (~300 LOC) |
| Cross-entry join needed? | No | Yes (unsolved) | No |
| Visual rule editor? | No | Yes (JDM Editor) | Yes (for pricing) |
| Rating sweep changes? | None | Significant | Moderate (swap ApplyRate) |
| Falls back to simple rates? | Yes (rates table) | No (all-in on GoRules) | Yes |

## Recommendation

**Option C (both layers)**, implemented in two phases:

1. **Phase 1: Expressions at metering time** — small, self-contained change
   to `custommetrics.go`. Unblocks the "custom metrics that compute values"
   use case immediately. No new large dependencies (hand-rolled arithmetic
   or expr-lang/expr). Can ship independently.

2. **Phase 2: GoRules at rating time** — the existing spike (PR #45) is
   90% done. Wire it in as an alternative to `ApplyRate`. Falls back to
   the `rates` table when no GoRules rule matches. Can ship independently.

The two phases are **fully independent** — each delivers value alone, and
they compose naturally because metering entries are the interface boundary.

### Why not Option A alone?

Covers the immediate gap but leaves complex pricing (tier discounts,
committed-use, time-of-day rates) as hardcoded Go logic forever.

### Why not Option B alone?

The cross-entry join problem is real and unsolved. The rating sweep processes
one metering entry at a time. Making it group entries by resource+period is
a significant refactor that affects the entire rating pipeline, including
the existing VM/cluster/MaaS meters. And even if solved, metering entries
become meaningless raw field dumps — "8 cores" and "3600 seconds" instead
of "28,800 core_seconds".

### Why Option C works

Each layer stays in its lane:
- Expressions answer **"what was consumed?"** — a metering concern
- GoRules answers **"what does consumption cost?"** — a pricing concern

This matches how the built-in pipeline already works:
`computeInstanceMeters` (expression) → `metering_entries` → `ApplyRate`
(pricing). We're just making both sides configurable.

## Expression Engine Options

For Phase 1, two options for the expression evaluator:

### expr-lang/expr (recommended)

- [github.com/expr-lang/expr](https://github.com/expr-lang/expr)
- Pure Go, no CGo, MIT license
- ~2MB added to binary
- Compiles expressions at config load time, sub-μs evaluation
- Supports: arithmetic, comparisons, ternary (`a > 0 ? a : 0`),
  function calls (`max(a, b)`), field access
- Used by: Grafana, Kubernetes, GitLab

### Hand-rolled arithmetic parser

- Zero dependencies
- Supports only: `+`, `-`, `*`, `/`, `()`, variable references
- ~100 lines of Go (Pratt parser or shunting-yard)
- No ternary, no functions, no comparisons
- Sufficient for the immediate use cases but limited growth path

### Recommendation

Use `expr-lang/expr`. The ternary and `max()`/`min()` support will be needed
quickly (e.g. `max(actual_duration, minimum_billing_period)`), and it's
battle-tested in production at Grafana's scale.

## Testing Strategy

### Expressions (Phase 1)

- **Unit tests in custommetrics_test.go:**
  - Parse valid/invalid expressions at load time
  - Evaluate arithmetic: `a * b`, `a + b / c`, `(a + b) * c`
  - Missing variables → error with field name
  - Division by zero → error (not NaN/Inf)
  - Negative results → skip (value <= 0)
  - Expression + value_field mutual exclusivity validation

- **Integration test:**
  - POST CloudEvent with raw fields, custom metrics config with expression
  - Verify computed metering entry value in DB

### GoRules (Phase 2)

- **Unit tests in ruleengine_test.go:** (already exist in spike)
  - Decision table matching
  - Expression node computation
  - Default/fallback rules

- **Integration test:**
  - End-to-end: CloudEvent → expression → metering → GoRules → cost entry
  - Verify cost amount matches expected rule output

## Migration Path

### From current state → Phase 1

1. Add `expression` field to `MeterDef` struct
2. Add expression compilation at config load time
3. In `ProcessEvent`, branch on `expression` vs `value_field`
4. Existing configs with `value_field` continue working unchanged

### From current state → Phase 2

1. Merge GoRules spike (PR #45) — already wired into rating sweep
2. Add fallback: if no GoRules rule matches, fall back to `rates` table
3. Existing rates continue working unchanged

### Both phases combined

No interaction between the two. Expressions produce metering entries.
GoRules (or the rates table) prices them. The interface boundary is
`metering_entries` — unchanged.
