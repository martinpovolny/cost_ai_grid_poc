---
marp: true
theme: default
paginate: true
style: |
  section {
    font-size: 1.4rem;
    padding-top: 30px !important;
  }
  h1, h2 {
    margin-top: 0 !important;
    margin-bottom: 0.4em !important;
  }
  section.lead h1 {
    font-size: 2.4rem;
  }
  section.lead h2 {
    font-size: 1.4rem;
    color: #555;
  }
  h1 { color: #1a3a5c; }
  h2 { color: #2c6fad; border-bottom: 2px solid #2c6fad; padding-bottom: 4px; }
  code { background: #f0f4f8; padding: 2px 6px; border-radius: 3px; }
  pre { background: #f0f4f8; }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  table { font-size: 1.1rem; }
  blockquote { border-left: 4px solid #2c6fad; color: #444; }
  .done { color: #16a34a; font-weight: bold; }
  .partial { color: #d97706; font-weight: bold; }
  .metric { font-family: monospace; background: #e0f2fe; padding: 2px 8px; border-radius: 4px; }
---

<!-- _class: lead -->

# Cost Event Consumer
## Demo 4 — Observability, Custom Metrics & Tooling

Martin Povolny — 2026-07-03

---

## What's New Since Demo 3

| Area | Status |
|---|---|
| **REQ-13** Custom metric extraction | <span class="done">Done</span> — config-driven, zero code changes |
| **Observability** P1+P2 | <span class="done">Done</span> — Prometheus, probes, logging, shutdown |
| **CI pipeline** | <span class="done">Done</span> — 4 jobs: lint, build, test, container |
| **CRC deployment** | <span class="partial">Partial</span> — consumer running, OSAC pending |
| **Adversarial review** | v3 — 41 findings, 19 fixed |
| **Tooling** | Bruno collection + Grafana stack |

**Score: 13 done / 3 partial / 0 not started** (of 16 requirements)

---

## REQ-13: Custom Metrics — The Problem

OSAC will emit new CloudEvent types over time:
- GPU workloads, storage volumes, network traffic, ...
- Each with different fields to meter

Without REQ-13: **every new metric = code change + PR + deploy**

With REQ-13: **drop a JSON config, restart**

---

## REQ-13: How It Works

```json
{
  "custom_metrics": [{
    "event_type": "osac.gpu.lifecycle",
    "resource_type": "gpu_instance",
    "resource_id_field": "instance_id",
    "tenant_id_field": "tenant_id",
    "meters": [
      { "meter_name": "gpu_memory_gib_seconds",
        "value_field": "gpu_memory_gib_seconds",
        "unit": "gib_seconds" },
      { "meter_name": "gpu_compute_seconds",
        "value_field": "gpu_compute_seconds",
        "unit": "seconds" }
    ]
  }]
}
```

Rating, reporting, quotas — all work automatically.

---

## REQ-13: Live Demo

<!-- Screenshot: Bruno firing a custom GPU CloudEvent -->

1. Show config file → `CUSTOM_METRICS_CONFIG=deploy/custom-metrics-example.json`
2. Open **Bruno** → click "Custom GPU Metric" → Send
3. Query metering entries → GPU meters appear
4. Wait 30s → cost entries created with dollar amounts
5. **No code was changed. No recompile. No redeploy.**

---

## REQ-13: What Flows Through

```
CloudEvent (osac.gpu.lifecycle)
  → handleEvent default branch
    → custommetrics.ProcessEvent
      → extractField("instance_id") → resource ID
      → extractField("gpu_memory_gib_seconds") → metering entry
      → extractField("gpu_compute_seconds") → metering entry
        → rating sweep (30s) → cost entries
          → report API → JSON/CSV
```

Same pipeline as VMs and MaaS — zero special handling.

---

## Observability: Prometheus Metrics

Separate `:9000` port (no auth), following RHT pattern.

| Metric | Type | What |
|---|---|---|
| `events_processed_total` | Counter | Events by type + status |
| `metering_entries_created_total` | Counter | Meters by resource + name |
| `cost_entries_created_total` | Counter | Costs by type |
| `metering_sweep_duration_seconds` | Histogram | 60s sweep latency |
| `rating_sweep_duration_seconds` | Histogram | 30s sweep latency |
| `live_compute_instances` | Gauge | Active VMs |
| `live_clusters` | Gauge | Active clusters |
| `http_requests_total` | Counter | API traffic |
| `http_request_duration_seconds` | Histogram | API latency |

---

## Observability: Grafana Dashboard

<!-- Screenshot: Grafana dashboard with live data -->

`docker compose up -d` → `http://localhost:3000`

Pre-built dashboard with 10 panels:
- Event throughput, HTTP request rate
- Live resource gauges (VMs, clusters, models)
- Sweep duration percentiles (p99)
- Cost + metering entry creation rates
- Reconcile drift, alerts fired
- Go runtime (goroutines, RSS)

---

## Observability: Structured Logging

```json
{"time":"...","level":"INFO","msg":"http request",
 "method":"POST","path":"/api/v1/events",
 "status":202,"duration_ms":3,"request_id":"a1b2c3d4"}
```

- `LOG_FORMAT=json` for OpenShift log aggregation
- `LOG_LEVEL` controls verbosity (was hardcoded to debug)
- Probe requests logged at DEBUG (no noise)
- Request ID on every request for correlation

---

## Observability: K8s Probes & Shutdown

| Endpoint | What | Auth |
|---|---|---|
| `/healthz` | Liveness — process alive | Exempt |
| `/readyz` | Readiness — pings PostgreSQL | Exempt |

- `/readyz` returns **503** when DB is unreachable
- Graceful shutdown: `srv.Shutdown()` with 30s drain
- Panic recovery on all goroutines + HTTP handlers
- Dead goroutine → error propagated → pod restarts

---

## CI Pipeline

<!-- Screenshot: GitHub Actions green wall -->

4 parallel jobs on every PR and push to main:

| Job | What |
|---|---|
| **Lint** | `go vet ./...` |
| **Build** | Both binaries (consumer + simulator) |
| **Test** | `go test -race` with PostgreSQL service |
| **Container** | UBI10 image via Buildx |

All green. Tests run against a real database.

---

## CRC / OpenShift Deployment

<!-- Screenshot: oc get pods -n cost-mgmt -->

- Multi-stage UBI10 container (164 MB)
- K8s manifests: namespace, PostgreSQL, consumer Deployment
- Health probes configured and passing
- JSON structured logging flowing
- **Next:** Deploy OSAC fulfillment-service alongside

---

## Bruno: Clickable CloudEvent Catalog

<!-- Screenshot: Bruno with collection open -->

Committed to the repo — no cloud sync, no accounts.

<div class="columns">

**CloudEvents**
- VM Create
- Cluster Create
- MaaS Token Usage
- IPP Inference Tokens
- Custom GPU Metric
- Custom Storage Metric

**Queries & Probes**
- Cost Report (JSON / CSV)
- Quota Status
- Balance Check (IPP)
- Pipeline Summary
- Liveness / Readiness / Metrics

</div>

---

## Adversarial Review Process

| Version | Scope | Total | Fixed | Accepted |
|---|---|---|---|---|
| v1 | Full codebase | 17 | 9 | 4 |
| v2 | Observability | +16 = 33 | +10 = 19 | +0 = 4 |
| v3 | Custom metrics | +8 = 41 | +3 = 22 | +4 = 8 |

Key fixes: JWT auth, input validation, panic recovery,
NaN/Inf rejection, cardinality protection, graceful shutdown.

---

## What's Next

| Item | Status | Next step |
|---|---|---|
| REQ-5 Chargeback export | Partial | Scheduled export (API done) |
| REQ-1a Cluster orders | Partial | Verify with OSAC team |
| POC-ENV | Partial | Deploy OSAC on CRC |
| Noy's dogfood | Blocked | Get access, test real IPP events |
| Observability PR #9 | Ready | Merge into upstream |

---

<!-- _class: lead -->

# Questions?

`github.com/myersCody/cost_ai_grid_poc`
