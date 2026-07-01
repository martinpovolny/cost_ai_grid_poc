# GoRules/Zen Integration Assessment

> Practical assessment of integrating GoRules/Zen engine into the
> cost-event-consumer for REQ-13 (custom rate dimensions).
> Date: 2026-06-29

## Go SDK

Package: `github.com/gorules/zen-go`

The Zen engine core is Rust. The Go SDK ships precompiled static libraries
for darwin/amd64, darwin/arm64, linux/amd64, linux/arm64 — linked via CGO.
No Rust toolchain required.

```bash
go get github.com/gorules/zen-go
```

## Integration Effort

~80 lines of new Go code + ~80 lines of JDM JSON:

**New files:**
- `internal/rating/gorules.go` — engine init, loader, evaluation wrapper
- `rules/pricing.json` — JDM decision table with rate rules

**Changes to existing:**
- `cmd/consumer/main.go` — initialize engine, pass to Rater (~5 lines)
- `internal/rating/rating.go` — swap `ApplyRate()` call site (~10 lines)
- `go.mod` — add dependency

## How It Works

The SDK uses a Loader pattern — a function that resolves rule files by key:

```go
engine := zen.NewEngine(zen.EngineConfig{
    Loader: func(key string) ([]byte, error) {
        return os.ReadFile(filepath.Join("./rules", key))
    },
})
defer engine.Dispose()

result, err := engine.Evaluate("pricing.json", map[string]any{
    "value":         1500.0,
    "resource_type": "compute_instance",
    "meter_name":    "vm_uptime_seconds",
    "tenant_id":     "tenant-acme",
})
// result: {"cost": 0.00416, "currency": "USD"}
```

## JDM Decision Table Example

A decision table for tiered pricing looks like:

```json
{
  "nodes": [
    {"id": "input", "type": "inputNode", "name": "MeteringInput"},
    {
      "id": "rates",
      "type": "decisionTableNode",
      "name": "RateLookup",
      "content": {
        "hitPolicy": "first",
        "inputs": [
          {"field": "resource_type"},
          {"field": "meter_name"},
          {"field": "value"}
        ],
        "outputs": [
          {"field": "cost"},
          {"field": "currency"}
        ],
        "rules": [
          {
            "resource_type": "== 'compute_instance'",
            "meter_name": "== 'vm_uptime_seconds'",
            "value": "<= 3600",
            "cost": "value * 0.01 / 3600",
            "currency": "'USD'"
          },
          {
            "resource_type": "== 'compute_instance'",
            "meter_name": "== 'vm_uptime_seconds'",
            "value": "> 3600",
            "cost": "3600 * 0.01/3600 + (value - 3600) * 0.008/3600",
            "currency": "'USD'"
          }
        ]
      }
    },
    {"id": "output", "type": "outputNode", "name": "CostResult"}
  ],
  "edges": [
    {"sourceId": "input", "targetId": "rates"},
    {"sourceId": "rates", "targetId": "output"}
  ]
}
```

## JDM Editor

Available as:
- **Standalone Docker:** `docker run -p 8080:8080 gorules/editor`
- **React component:** `npm i @gorules/jdm-editor` — embeddable `<DecisionGraph />`
- **Live demo:** https://gorules.github.io/jdm-editor/

## Performance

| Mode | Latency | Throughput |
|------|---------|------------|
| Embedded SDK (our path) | <1ms | 10-100K evals/sec |
| HTTP Agent | 10-20ms | 1-10K req/s |

Our 500-entry rating batch would process in <50ms. No concern.

## Constraints

- **CGO_ENABLED=1** required — no pure-Go option
- **No Alpine/musl** — needs glibc (use `golang:1.22-bookworm`)
- **`Dispose()` calls** — Rust memory is outside Go's GC
- Expression language compiles to bytecode (stack VM), not AST traversal

## Rule Storage Options

| Storage | Mechanism | Hot reload |
|---------|-----------|------------|
| File system | Load `.json` from disk, version in git | Manual restart |
| Database | `rules` JSONB table, loader queries DB | On next eval |
| Object storage | ZIP bundles, agent polls with etag | Atomic swap |

## Recommendation

**PoC (July 31): Don't integrate yet.** Our `ApplyRate()` is 36 lines of
clear Go handling flat + tiered pricing. GoRules adds a CGO dependency
and JDM learning curve with no functionality gain for current requirements.

**Post-PoC (REQ-13): Integrate.** When business users need custom rate
formulas (different rates by GPU model, region, tenant, label values)
without recompiling Go, GoRules with the visual editor is the right tool.
The Loader pattern supports per-tenant rules from the database.

**Migration path:** Keep `ApplyRate()` as fallback. GoRules evaluation
wraps it — if a rule file exists for the resource type, use GoRules;
otherwise fall back to the SQL-based rate lookup. This makes the
transition incremental and safe.
