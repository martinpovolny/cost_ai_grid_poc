# OSAC-985 Remaining Gaps

Status of our implementation against the
[OSAC-985 metering design spec](https://github.com/osac-project/enhancement-proposals/tree/main/enhancements/OSAC-985-metering-and-usage-tracking/design.md).

Last reviewed: 2026-08-08.

## Completed

All items below are implemented and merged.

| Area | Details | PR |
|------|---------|-----|
| CloudEvent extensions | `osacresourceid`, `osacresourcetype`, `osactenant`, `osacproject`, `osactrace` on `cloudEventInternal` | #115, #120 |
| Structured content mode | v1 events decoded from JSON CloudEvent envelope | #118 |
| meteringData schema | All 12 fields: resource_id, resource_type, tenant_id, project_id, catalog_item_id, template_id, previous_state, current_state, transition_time, duration_seconds, billing_dimensions, schema_version | #118 |
| Kafka topics | `osac.metering.lifecycle`, `osac.metering.heartbeat`, `osac.metering.inference` — correct names, prefix configurable via `KAFKA_TOPIC_PREFIX` | #115 |
| Partition keys | lifecycle/heartbeat keyed on `resourceID`, inference keyed on `tenantID` | #115 |
| Event types — lifecycle | `created.v1`, `started.v1`, `updated.v1`, `suspended.v1`, `resumed.v1`, `deleted.v1` | #118, #120 |
| Event types — heartbeat | `osac.resource.heartbeat.v1` | #120 |
| Event types — inference | `osac.inference.usage.v1` + legacy `inference.tokens.used` | #120 |
| Consumer group naming | Default `osac-metering-cost-management` (spec: `osac-metering-<provider>`) | #120 |
| Extension validation | Reject v1 events with empty required extensions | #121 |
| VMaaS billing_dimensions | `instance_type`, `image_ref`, `boot_disk_size_gib` | #118 |
| CaaS billing_dimensions | `cluster_template`, `release_image`, `component`, `host_type`, `node_count` | #121 |
| MaaS billing_dimensions | `prompt_tokens`, `completion_tokens`, `model`, `provider`, `organization_id`, etc. mapped to `MaaSUsage` pipeline | #121 |
| Producer routing | All v1 event types routed to correct topics | #120 |
| End-to-end CI | OSAC fulfillment → metering-service → Kafka → cost-consumer, with Apache Kafka in KRaft mode | #118 |

## Gap 1: Corrections Topic (MEDIUM)

**Spec:** `osac.metering.corrections` topic with `osac.resource.correction.v1` events.

The metering-service's reconciler detects discrepancies between its state
projection and the fulfillment-service's actual state. When a mismatch is
found, it publishes a correction event.

**Correction reasons:**

| Reason | Meaning |
|--------|---------|
| `missed_creation` | Resource exists in fulfillment but not in the metering projection |
| `state_drift` | Resource state differs between projection and fulfillment |
| `billing_dimensions_drift` | Billing dimensions differ while state is unchanged |
| `missed_deletion` | Resource in projection but absent from fulfillment |

**Correction event additional fields:**

```json
{
  "reason": "state_drift",
  "description": "Human-readable explanation",
  "corrected_state": "RUNNING",
  "previous_state_in_projection": "STOPPED",
  "actual_state_from_source": "RUNNING",
  "affected_interval": {
    "from": "2026-08-01T00:00:00Z",
    "to": "2026-08-01T01:00:00Z",
    "overbilled_seconds": 3600
  },
  "original_event_id": "uuid-of-event-being-corrected"
}
```

**What we need to implement:**

1. Add `osac.metering.corrections` topic to `kafka/config.go`
2. Add `osac.resource.correction.v1` event type constant
3. Create `correctionEventData` struct matching the schema above
4. Implement `processOSACCorrection` handler that:
   - For `missed_creation`: upsert the resource into inventory
   - For `state_drift`: update the resource state
   - For `billing_dimensions_drift`: update billing dimensions
   - For `missed_deletion`: mark resource as deleted
   - For all: create adjustment metering entries based on `overbilled_seconds`
     (negative entries to cancel overbilled periods)
5. Consumer subscribes to the corrections topic

**Estimated effort:** ~2 days

## Gap 2: Dead Letter Queue (MEDIUM)

**Spec:** `osac.metering.dlq` topic with exponential retry policy.

Currently, when `ProcessKafkaEvent` returns an error, the consumer logs the
error, sends the record to a (non-existent) DLQ topic, and commits the offset.
In practice, failed records are lost.

**Spec requirements:**

- Exponential backoff: initial 1s, doubling each retry, max 5 minutes
- Maximum 10 retry attempts before moving to DLQ
- DLQ record contains:
  - `dlq.original-topic`: source topic
  - `dlq.original-offset`: source offset
  - `dlq.original-event`: complete original CloudEvent
  - `dlq.failure-reason`: error description
  - `dlq.failure-count`: retry count
  - `dlq.failed-at`: timestamp
- DLQ retention: 90 days
- Replay via `osac-metering-dlq-replay` CLI tool

**What we need to implement:**

1. Add `osac.metering.dlq` topic to `kafka/config.go`
2. Implement retry logic in `kafka/consumer.go`:
   - Track retry count per record (in-memory or via Kafka headers)
   - Apply exponential backoff before re-processing
   - After 10 failures, publish to DLQ topic with metadata headers
3. Create DLQ record producer that wraps the original event with
   failure metadata
4. (Optional) Create a replay script/CLI that reads DLQ records and
   re-publishes them to the original topic

**Estimated effort:** ~1-2 days

## Gap 3: Partition Count Configuration (LOW)

**Spec partition counts:**

| Topic | Partitions | Current |
|-------|-----------|---------|
| `osac.metering.lifecycle` | 24 | broker default |
| `osac.metering.heartbeat` | 24 | broker default |
| `osac.metering.inference` | 12 | broker default |
| `osac.metering.corrections` | 6 | not created |
| `osac.metering.dlq` | 6 | not created |

This only matters at production scale. For the PoC, broker defaults are fine.

**What we need:** Add partition count to topic creation in deployment manifests
or a setup script. Not a code change — operational configuration.

**Estimated effort:** ~1 hour

## Upstream Dependencies

| Issue | Impact | Resolution |
|-------|--------|------------|
| **Proto version mismatch** | The metering-service regenerated protos to v0.0.83 (typed references) but the fulfillment-service hasn't published a matching tag. Wire-format incompatibility causes Watch stream errors. | We pin the metering-service to our fork tag `metering-v0.0.82-compat`. Switch back when OSAC publishes v0.0.83+. |
| **Metering-service SASL/TLS** | The metering-service requires SASL credentials and TLS in production. For CI with plain Kafka, we patch out the validation at build time. | OSAC should make SASL/TLS optional for dev/test environments. |
