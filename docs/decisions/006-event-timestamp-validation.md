# ADR-006 — Event Timestamp Validation at Ingest

**Status:** Accepted  
**Date:** 2026-07-25

---

## Context

The `POST /api/v1/events` ingest endpoint accepts a `time` field in the
CloudEvent payload. This field is written directly to `raw_events.event_time`
and is used as `period_start`/`period_end` in metering and cost entries —
driving billing period attribution, quota sums, and cumulative tier
calculations.

There was no server-side validation of this timestamp, meaning any authenticated
client could submit events with arbitrary past or future timestamps.

## Problem: What Backdated Events Can Do

Even events a few minutes old can have real billing consequences depending on
where they land relative to billing-period boundaries and sweep state.

### 1. Cumulative tier waterfall corruption

`MeteringSumBefore()` aggregates all metering entries for a tenant/meter up
to a given point in time to determine which price tier applies. A backdated
event inserts a metering entry into an already-computed window, shifting the
tenant's position in the tier waterfall for subsequent entries in that period.

**Example:** A tenant has 900,000 tokens this month, nearly at the 1M free
tier threshold. A backdated event adds 200,000 tokens at 09:00 (past). All
subsequent real events at 11:00 onward are now rated in the paid tier instead
of the free tier — even though the backdated entry was injected after those
ratings already ran.

The rating sweep processes entries in arrival order (by `metering_entries.id`),
not in timestamp order. A backdated entry created today gets rated today, but
its `period_start` points to this morning — corrupting the cumulative sum for
any later entries within that billing period.

### 2. Quota sum manipulation

`MeteringSum()` aggregates metering entries by `period_start`/`period_end`.
Injecting a backdated metering entry into a past billing window inflates the
tenant's consumption for that period, potentially triggering quota alerts or
blocking future requests via the balance check endpoint.

### 3. Cost report tampering

`cost_entries` are keyed by `period_start`. A backdated cost entry shows up
in historical reports, alters tenant totals for past periods, and could
affect chargeback calculations.

### 4. Wallet ledger inconsistency

If a backdated cost entry falls in a period that has already been settled
against a wallet, the wallet balance is understated until the next
reconciliation. If there is no reconciliation for closed periods, the
discrepancy persists.

### 5. Billing period boundary attacks

A client controlling the `time` field can place events in the last second of
a billing period to maximise consumption in that period while being charged
at the rates of a different one, or to push cumulative usage past a threshold
in a period the operator considers closed.

---

## Decision

Validate `event_time` at ingest and reject events outside a configurable
tolerance window:

| Condition | Response |
|-----------|----------|
| `now - event_time > MAX_EVENT_AGE` | 400 — event time is too old |
| `event_time - now > MAX_EVENT_FUTURE` | 400 — event time is too far in the future |
| `event_time` is zero (not set by client) | Accept — `received_at` is used |

**Default window (committed):**
- `MAX_EVENT_AGE = 2 hours`
- `MAX_EVENT_FUTURE = 5 minutes`

This is an improvement over no validation, but does **not fully eliminate** the
consistency risks described above. Within a 2-hour window:

- Cumulative tier sums can still be corrupted for events in the same billing
  period: a 1h58m-old event lands in this month's quota window and shifts the
  tier waterfall for all entries rated since then.
- The rating sweep runs every 20s; a 2-hour-old entry is rated after all
  entries from the past 2 hours, potentially in the wrong tier position.

The window was chosen as a pragmatic balance:
- Covers legitimate clock skew between OSAC metering collectors and the
  consumer (typically < 30 seconds, occasionally up to a few minutes)
- Covers brief network outages where collectors buffer and replay events
- Rejects obvious backdating (yesterday's events, last month's events)

## Remaining Risk

The following attack remains possible within the 2-hour window:

> A client injects an event with `time = now - 1h59m` into the current billing
> period. The metering entry is created with `period_end = now - 1h59m`.
> The rating sweep rates it immediately. Any subsequent real entries in the same
> billing period with cumulative tiered meters now have incorrect prior-usage
> sums.

**Mitigations not yet implemented:**

1. **Rate-limiting by tenant** — cap how many events a single tenant can submit
   per minute. A burst of backdated events is more suspicious than a single one.

2. **Immutable billing period close** — once a billing period is closed and
   billed, reject any events for that period regardless of timestamp.
   Requires a `billing_periods` table with a `closed_at` timestamp.

3. **Re-rate on insert** — after inserting a backdated metering entry, trigger
   re-rating of all subsequent entries for the same tenant/meter in the same
   billing period. Expensive but correct. Requires idempotent rating.

4. **`received_at` for billing, `event_time` for display only** — use the
   server-set `received_at` as the canonical timestamp for all billing
   calculations, relegating `event_time` to a display/audit field. This
   eliminates the attack surface entirely but changes the billing semantics
   (a VM that was running at 09:00 but whose event arrived at 11:00 would
   be billed from 11:00, not 09:00).

## Observability

Two new Prometheus metrics:

| Metric | Labels | When incremented |
|--------|--------|-----------------|
| `cost_consumer_events_rejected_total` | `reason=timestamp_too_old` | Event `time` > 2h in the past — rejected with 400 |
| `cost_consumer_events_rejected_total` | `reason=timestamp_too_future` | Event `time` > 5m in the future — rejected with 400 |
| `cost_consumer_events_timestamp_drift_total` | `direction=past` | Accepted, but `time` > 30s in the past |
| `cost_consumer_events_timestamp_drift_total` | `direction=future` | Accepted, but `time` > 30s in the future |

Rejected events are also logged at WARN with `event_id`, `event_type`,
`event_time`, and the measured drift. Drifted-but-accepted events are logged
at INFO.

**Recommended alerts:**
- `rate(cost_consumer_events_rejected_total{reason="timestamp_too_old"}[5m]) > 0`
  — a source is replaying stale events; investigate buffering behaviour
- `rate(cost_consumer_events_timestamp_drift_total[5m]) > 1`
  — sustained clock drift detected; misconfigured source clock

## Consequences

- Events from sources with misconfigured clocks (> 2h drift) will be rejected.
  The error message includes the drift so operators can diagnose.
- The event replayer (`cmd/event-replayer`) and test tools that inject historical
  data must connect directly to the DB (`scripts/replicate-data.sh`) rather
  than through the ingest endpoint. This is the correct approach for testing.
- The 2-hour window is a constant in `handler.go` (`maxEventAge`). If the OSAC
  metering collector's buffering window exceeds 2 hours (e.g., during an
  extended network partition), those buffered events will be rejected on replay.
  The drift warning (30s threshold, `warnEventDrift`) will surface the problem
  before the collector's buffer fills to the rejection threshold.

## Related

- [ADR-004](004-raw-events-no-unique-index.md) — deduplication by `event_id`
- `docs/operations/table-sizing.md` — storage projections
- `docs/operations/table-lifecycle.md` — billing period close strategy
