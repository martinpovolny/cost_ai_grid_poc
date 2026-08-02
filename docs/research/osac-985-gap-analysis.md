# OSAC-985 Metering Proposal — Gap Analysis

Comparison of our Kafka implementation against the
[OSAC-985 metering and usage tracking design](https://github.com/masayag/enhancement-proposals/blob/c32291379b50933c8f9e5c2e1229dd8190d9a0ed/enhancements/OSAC-985-metering-and-usage-tracking/design.md).

## Status

| # | Gap | Priority | Status |
|---|---|---|---|
| 1 | CloudEvent extension attributes | HIGH | **Done** — osacresourceid, osacresourcetype, osactenant injected (structured mode) |
| 2 | Event type naming (proposal v1 names) | HIGH | **Done** — producer route() accepts both internal and v1 names |
| 3 | Base schema with billing_dimensions | MEDIUM | Not started |
| 4 | Corrections topic | LOW | Deferred (PoC) |
| 5 | Dead-letter queue (DLQ) topic | LOW | **Done** — failed records published to osac.metering.dlq |
| 6 | Provider adapter interface | MEDIUM | Not started |
| 7 | Dedup cache (in-memory TTL) | OK | Our DB dedup is stronger |
| 8 | VMaaS/CaaS state machine | LOW | Deferred (PoC) |
| 9 | CaaS per-component records | LOW | Deferred (PoC) |
| 10 | Separate heartbeat schema | MEDIUM | Not started |
| 11 | Topic partitioning | LOW | Config only |
| 12 | W3C trace context | LOW | Deferred |

## Plan

### Phase 1: Event type naming + DLQ (gaps 2, 5)

**Gap 2 — Event type naming:**

The proposal defines versioned event types:
- `osac.resource.created.v1`
- `osac.resource.started.v1`
- `osac.resource.updated.v1`
- `osac.resource.suspended.v1`
- `osac.resource.resumed.v1`
- `osac.resource.deleted.v1`
- `osac.resource.heartbeat.v1`
- `osac.resource.correction.v1`
- `osac.inference.usage.v1`

We currently use:
- `EVENT_TYPE_OBJECT_CREATED` (from OSAC Watch stream)
- `osac.compute_instance.lifecycle` (from CloudEvent ingest)
- `inference.tokens.used` (from IPP plugin)

Plan: Update the producer's `route()` function to map our internal event
types to the proposal's topic routing. The event type in the CloudEvent
`type` field should match the proposal naming. The consumer should accept
both old and new names for backward compatibility.

**Gap 5 — DLQ topic:**

Add `osac.metering.dlq` topic. When the consumer's `ProcessKafkaEvent`
returns an error, publish the failed record to the DLQ with the original
topic name embedded. No retry from DLQ for PoC — just durable storage
for debugging.

Files to modify:
- `internal/kafka/config.go` — add `TopicDLQ()` method
- `internal/kafka/producer.go` — update `route()` for proposal event types
- `internal/kafka/consumer.go` — publish to DLQ on processing error
- `internal/api/handler.go` — map event types in `PublishEvent` call

### Phase 2: CloudEvent extensions + base schema (gaps 1, 3)

**Gap 1 — Extension attributes:**

Add `osacresourceid`, `osacresourcetype`, `osactenant`, `osacproject` as
Kafka record headers (CloudEvents binary content mode) or as top-level
fields in the JSON envelope (structured content mode). Use structured
mode (JSON) since that's what we already produce.

**Gap 3 — Base schema with billing_dimensions:**

Restructure event data to wrap resource-specific fields in
`billing_dimensions` and add `previous_state`, `current_state`,
`transition_time`, `schema_version` at the top level. The consumer
must be updated to unwrap `billing_dimensions` before processing.

### Phase 3: Adapter interface + heartbeat separation (gaps 6, 10)

**Gap 6 — Provider adapter interface:**

Refactor `ProcessKafkaEvent` to implement the `ProviderAdapter` interface
(`Submit`, `Flush`, `HealthCheck`, `Close`). The consumer framework calls
`Submit` per event and `Flush` periodically (every 10s). Kafka offsets
commit only after successful `Flush`.

**Gap 10 — Separate heartbeat schema:**

Heartbeat events should not carry `previous_state`, `duration_seconds`,
or `transition_time`. Split the schema so heartbeat events only have
`current_state` and `billing_dimensions`.

### Phase 4: Deferred (post-PoC)

- Gap 4: Corrections topic
- Gap 8: Full VMaaS/CaaS state machine
- Gap 9: CaaS per-component records
- Gap 11: Topic partitioning (24/24/12/6/6)
- Gap 12: W3C trace context (`osactrace`)
