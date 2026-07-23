# Prepaid Wallets — Technical Spec (Draft)

> **Status:** PoC draft — for Cost + OSAC review
> **Requirements:** REQ-14 ([COST-7939](https://redhat.atlassian.net/browse/COST-7939)); product feature [COST-7938](https://redhat.atlassian.net/browse/COST-7938)
> **Source:** AI Grid MB-005 (prepaid / hybrid consumption models)
> **Related:** [alerting-osac-integration.md](alerting-osac-integration.md) · [alerting-spec-draft.md](alerting-spec-draft.md) · [cost-calculation-spec-draft.md](../pricing/cost-calculation-spec-draft.md) · [ai-grid-reporting-api.md](../reporting/ai-grid-reporting-api.md) · [REQ-14 overview](../../requirements/poc_requirements_overview.md#req-14-wallets-prepaid-balance)

Do not treat wire formats or schema details here as an agreed contract. This draft proposes ownership, ledger shape, APIs, and deduction mechanics so the team can decide PoC scope before implementation.

---

## 1. Purpose

This spec defines how Cost Management supports **prepaid wallets** for AI Grid / Sovereign Cloud providers.

**Wallets answer:** how much prepaid balance remains, after top-ups and metered spend deductions?

| Concern | Spec |
|---|---|
| How much capacity / tokens were used? | [metering-spec-draft.md](../metering/metering-spec-draft.md) |
| What does that cost? | [cost-calculation-spec-draft.md](../pricing/cost-calculation-spec-draft.md) |
| Am I within a spend/usage *ceiling*? | [alerting-osac-integration.md](alerting-osac-integration.md) (REQ-9) |
| How much *prepaid cash* remains? | **This spec (REQ-14)** |

Settlement happens at **top-up** (money already collected). Metered usage then **draws down** that balance. That is commercially distinct from a budget (a ceiling on usage that will still be billed).

**PoC priority (PM acceptance):** RHCM can create, top up, and query wallet balances **scoped to tenant** (and optionally project). Tenant-scoped wallets are the must-have; project-scoped wallets are a stretch goal.

**Hybrid funding (MB-005):** product direction is that a single enterprise can track **postpaid monthly corporate invoices** alongside **dedicated prepaid wallets for experimental teams**. That implies selective, scope-aware deduction. For the PoC, **tenant wallet + tenant-wide deduction** satisfies the acceptance criteria; project-scoped wallets (and hybrid selective routing) are stretch / post-PoC unless schedule allows.

---

## 2. Scope

### In Scope (PoC) — must-have

| Item | Notes |
|---|---|
| Wallet ledger | Create wallet, top up, adjust, query balance |
| Tenant-scoped wallets | One prepaid balance per tenant (`project_id` null); matches PM AC |
| Tenant spend deduction | Rated `cost_entries` for that tenant deduct from the tenant wallet |
| Status API | Remaining balance, % remaining, threshold flags (REQ-9 latency class) |
| Low-balance alerts | Reuse REQ-10 alert lifecycle / push-or-pull pattern |
| Audit trail | Immutable ledger entries for top-ups, deductions, adjustments (= Cost audit for PoC) |
| Coexistence with budgets | Tenant may have wallet *and* budget/quota |

### Stretch (nice-to-have if schedule allows)

| Item | Notes |
|---|---|
| Project-scoped wallets | Optional `project_id` on create; “experimental team” prepaid |
| Selective / hybrid deduction | Only spend matching a wallet scope is drawn down; unmatched stays postpaid |
| Status filter by project | `?project_id=` on status pull; project-aware OSAC gates |
| Hybrid demo | Postpaid project (no wallet) + prepaid experimental project concurrently |

### Out of Scope (PoC)

| Item | Owner / reason |
|---|---|
| Payment gateway / card capture | External billing (Lago, Zuora, etc.) or OSAC UX |
| Postpaid corporate invoice generation | Billing system — Cost still rates `cost_entries` for reporting |
| Hard stop on zero balance | OSAC enforcement (OPA / check-balance), same as REQ-9 |
| Reserved allocations / billing multipliers | Customer billing system per MB-005 |
| Cost UI for wallet management | Post-PoC unless needed for demo |
| Multi-currency FX | Single currency per wallet for PoC (`USD`) |
| Overdraft / credit lines | Balance floors at zero unless explicitly decided |

---

## 3. Concepts

### 3.1 Wallet vs budget vs quota

| Concept | Question | Settlement | Period | Home |
|---|---|---|---|---|
| **Quota** | How much am I *allowed* to use? | N/A (usage units) | Rolling / calendar | REQ-9 |
| **Budget** | How much am I *allowed* to spend ($)? | Post-paid (bill later) | Typically period-bound | REQ-9 |
| **Wallet** | How much prepaid balance remains? | Pre-paid (settled at top-up) | No spend-by date; balance carries | **REQ-14** |

Both wallet and budget may exist for the same tenant:

- Budget: “do not spend more than $5,000 this month” (ceiling; unused amount is not cash)
- Wallet: “$1,000 was prepaid; deduct until balance hits zero / floor”

**PoC (tenant-first):** enterprise tops up a tenant wallet → all that tenant’s metered cost draws down the prepaid balance. Budget/quota ceilings (REQ-9) still evaluate independently.

**Stretch — hybrid funding (same enterprise / tenant):**

- Corporate projects: no project wallet → metered cost accrues for **postpaid monthly invoice** (or falls through to a tenant wallet if one exists)
- Experimental team project: dedicated project wallet → that project’s metered cost **draws down** prepaid balance
- Enterprise may still have a tenant-level budget/quota ceiling evaluated independently (REQ-9)

### 3.2 Why not “budget with no time limit”?

Reusing budgets for wallets is tempting (a shrinking monetary number) but is a poor product fit:

1. **Wrong admin model.** OSAC / tenant admins should think in top-up / remaining balance / low-balance alerts — not “a budget with no spend-by date.”
2. **Wrong settlement model.** Top-up money is already in the provider’s coffers. Treating draw-down as “budget consumption” implies spend still needs to be billed.

Shared machinery under the hood (threshold evaluator, alert table, pull status API) is fine; the **user-facing concept and ledger** must remain explicit prepaid balance.

### 3.3 Key terms

| Term | Meaning |
|---|---|
| **Wallet** | Prepaid balance account. PoC: tenant-scoped (`project_id` null). Stretch: optional project scope |
| **Experimental team wallet** | Stretch: project-scoped wallet for a team under an enterprise tenant (MB-005 hybrid) |
| **Top-up** | Credit that increases available balance (settlement external) |
| **Deduction** | Debit equal to newly rated `cost_entries` that match wallet scope |
| **Postpaid path** | Cost with no matching wallet — remains in `cost_entries` for invoicing; no ledger debit (stretch / hybrid) |
| **Adjustment** | Manual credit/debit for disputes, corrections, promotions |
| **Available balance** | `balance` after deductions; never below configured floor (default `0`) |
| **Reference balance** | Amount used as denominator for “% remaining” (see §6.3) |
| **Low-balance threshold** | Configurable % of reference (or absolute amount) that fires alerts |

---

## 4. Ownership

Mirrors the REQ-9 / REQ-10 split: Cost owns money math and status; OSAC owns gates; billing owns payment capture.

| Concern | Owner | Notes |
|---|---|---|
| Payment capture / invoice at top-up | **Billing system** (or OSAC UX calling it) | Lago/Zuora/etc. — OUT of Cost |
| Postpaid corporate monthly invoice | **Billing system** | Uses rated cost; Cost does not issue invoices |
| Wallet create / top-up / adjust API | **Cost** | Ledger source of truth for remaining balance (unlike quotas, where OSAC owns limit CRUD) |
| Top-up UX | **TBD** — OSAC or billing console | Cost exposes API only for PoC |
| Metering + rating → cost amount | **Cost** | Existing sweeps → `cost_entries` (all spend, prepaid or not) |
| Deduct cost from wallet | **Cost** | Post-rating debit **only** for wallet-matched scope |
| Wallet status API (pull) | **Cost** → **OSAC** | Same latency class as REQ-9 (`< 500 ms` target); tenant-scoped for PoC (project filter = stretch) |
| Low-balance alerts (push) | **Cost** → **OSAC** | Pairs with REQ-10 (parked); pull flags sufficient for PoC |
| Hard stop / deny provisioning | **OSAC** | Uses pull status; Cost never enforces |
| Audit of payment side | **Billing system** | Cost audits ledger ops only |

```mermaid
flowchart LR
    subgraph billing [Billing / OSAC UX]
        pay["Card / invoice top-up"]
    end
    subgraph cost [Cost Management]
        api["Wallet API\ncreate · top-up · status"]
        ledger["Wallet ledger"]
        rate["Rating sweep\n→ cost_entries"]
        deduct["Deduction job"]
        status["Status + threshold flags"]
        rate --> deduct
        deduct --> ledger
        api --> ledger
        ledger --> status
    end
    subgraph osac [OSAC]
        gate["Pre-create / inference gate"]
        alert["Console / notify"]
    end

    pay -->|"credit amount + external_ref"| api
    status -->|"pull"| gate
    status -.->|"push when REQ-10 unparked"| alert
```

---

## 5. Architecture

### 5.1 End-to-end flows

**1 — Top-up:** Billing captures payment → calls Cost `POST .../wallets/{id}/top-ups` with amount + external payment id → Cost credits ledger → balance increases → status API reflects new balance.

**2 — Spend deduction:** Metering sweep → rating sweep writes `cost_entries` → wallet deduction consumes unapplied cost → ledger debit → balance decreases.

**3 — Low-balance alert:** After deduction, `% remaining` crosses threshold → alert state `firing` (REQ-10 pattern) → visible on pull status; optional push to OSAC.

**4 — Pre-create / inference gate (OSAC):** OSAC pulls wallet status → `within_balance: false` or `balance_status: depleted` → OPA denies / throttles. Cost does not block.

```mermaid
sequenceDiagram
    participant Billing
    participant Cost
    participant OSAC
    participant OPA

    Billing->>Cost: POST top-up ($100, payment_ref)
    Cost-->>Billing: balance = 100

    Note over Cost: metering → rating → cost_entries
    Cost->>Cost: deduct $12 from wallet
    Cost-->>Cost: balance = 88; maybe fire low-balance

    OSAC->>Cost: GET wallet status
    Cost-->>OSAC: remaining 88, pct 88%, status ok
    OSAC->>OPA: authorize?
    OPA-->>OSAC: allow / deny
```

### 5.2 Placement in inventory-watcher

Proposed PoC wiring (same process as quotas):

| Component | Role |
|---|---|
| HTTP ingest / Cost API | Wallet CRUD, top-up, status, ledger query |
| Rating sweep (post-step) | Or dedicated wallet sweep after rating: apply un-deducted `cost_entries` |
| Alert evaluator | Treat low-balance like budget thresholds (`limit_kind: wallet`) |
| PostgreSQL | `wallets` + `wallet_ledger_entries` (+ reuse `alerts`) |

---

## 6. Data model (proposed)

> Proposed — confirm against [data-model.md](../../data-model.md) when implementing. Not built today.

### 6.1 `wallets`

Current balance cache + policy. Ledger is authoritative for history; `balance` is the fast-read projection.

```
wallets
  id                 UUID PK
  tenant_id          TEXT NOT NULL
  project_id         TEXT NULL          -- PoC: always NULL (tenant wallet). Stretch: project wallet
  currency           TEXT NOT NULL      -- 'USD'
  balance            DECIMAL NOT NULL   -- available funds (projection)
  balance_floor      DECIMAL NOT NULL DEFAULT 0
  reference_balance  DECIMAL NOT NULL   -- denominator for % remaining (see §6.3)
  lifecycle_state    TEXT NOT NULL      -- active | frozen | closed
  thresholds         JSONB              -- e.g. [50, 25, 10, 0] (% remaining)
  created_at         TIMESTAMPTZ
  updated_at         TIMESTAMPTZ
  UNIQUE (tenant_id, COALESCE(project_id, ''))
```

PoC may create only tenant wallets (`project_id` null). Keeping the nullable column (and unique key) avoids a migration if project scope lands later.

### 6.2 `wallet_ledger_entries` (immutable)

```
wallet_ledger_entries
  id                 BIGSERIAL PK
  wallet_id          UUID NOT NULL REFERENCES wallets(id)
  entry_type         TEXT NOT NULL      -- top_up | deduction | adjustment | reversal
  amount             DECIMAL NOT NULL   -- signed: +credit / -debit
  balance_after      DECIMAL NOT NULL
  currency           TEXT NOT NULL
  cost_entry_id      BIGINT NULL        -- set for deductions
  external_ref       TEXT NULL          -- billing payment id / Lago invoice id
  reason             TEXT NULL          -- adjustment notes
  created_at         TIMESTAMPTZ NOT NULL
  created_by         TEXT NULL          -- service account / actor
```

Rules:

- Append-only; never update/delete ledger rows in normal operation
- Every mutation updates `wallets.balance` in the same transaction
- Deduction is idempotent per `cost_entry_id` (unique partial index where not null)
- Top-ups idempotent on `(wallet_id, external_ref)` when `external_ref` present

### 6.3 Reference balance for “% remaining”

REQ-14 example: alert when remaining funds fall below X% of the topped-up amount.

**Proposed PoC rule:**

| Event | Effect on `reference_balance` |
|---|---|
| Wallet create | `0` |
| Top-up `+A` | `reference_balance += A` |
| Deduction | unchanged |
| Adjustment credit | optional: treat like top-up (configurable) |
| Adjustment debit | unchanged |

Then:

```
remaining_pct = (balance / reference_balance) × 100   -- if reference_balance > 0
```

Alternatives (open): last top-up only; rolling 30-day credits; absolute thresholds only (`balance < $50`). PoC should support **percent of reference** and **absolute floor** thresholds.

### 6.4 Relationship to `cost_entries`

```
cost_entries (existing)
  → wallet deduction selects rows not yet applied
  → inserts wallet_ledger_entries (deduction)
  → marks cost_entry as wallet_applied (column or join table)
```

**Proposed:** `wallet_cost_applications (cost_entry_id, ledger_entry_id, amount_applied)` (or `applied_amount` on `cost_entries`) so a cost row can be **partially** applied across multiple ledger debits after a later top-up. Do **not** use a unique `cost_entry_id` alone for idempotency — idempotency is `sum(amount_applied) ≤ cost_amount`.

Insufficient balance: deduct down to `balance_floor`; leave remainder of cost **unapplied** and surface `insufficient_funds` / `unapplied_cost_amount` on status (OSAC decides hard stop). Do **not** silently drop cost — financial record stays in `cost_entries` for postpaid reporting and later wallet resume after top-up.

**Currency:** only deduct when `cost_entries.currency` matches `wallets.currency`; otherwise skip with a metric/log (PoC is single-currency `USD`).

---

## 7. APIs (proposed)

Paths follow the existing PoC HTTP API under inventory-watcher `INGEST_LISTEN_ADDR` (e.g. `:8020`), same `/api/v1/...` prefix as quotas and reports (see [api-reference.md](../../api-reference.md)).

### 7.1 Manage wallet

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/wallets` | Create wallet (`tenant_id` required; `project_id` stretch; `thresholds`, `currency`) |
| `GET` | `/api/v1/wallets/{tenant_id}` | List wallets + status for tenant (OSAC gate) |
| `GET` | `/api/v1/wallets/{tenant_id}/{wallet_id}` | Get wallet + balance |
| `POST` | `/api/v1/wallets/{tenant_id}/{wallet_id}/top-ups` | Credit balance |
| `POST` | `/api/v1/wallets/{tenant_id}/{wallet_id}/adjustments` | Manual credit/debit |
| `GET` | `/api/v1/wallets/{tenant_id}/{wallet_id}/ledger` | Audit trail (paginated) |

**Create body (PoC — tenant wallet):**

```json
{
  "tenant_id": "tenant-acme",
  "currency": "USD",
  "thresholds": [50, 25, 10],
  "balance_floor": 0
}
```

Omit `project_id` (or pass `null`) for the tenant-scoped wallet. That is the PoC default and satisfies the PM acceptance criteria.

**Create body (stretch — project / experimental-team wallet):**

```json
{
  "tenant_id": "tenant-acme",
  "project_id": "project-skunkworks",
  "currency": "USD",
  "thresholds": [50, 25, 10],
  "balance_floor": 0
}
```

**Top-up body:**

```json
{
  "amount": 100.00,
  "currency": "USD",
  "external_ref": "lago_inv_01HZX...",
  "idempotency_key": "topup-acme-2026-07-20-1"
}
```

### 7.2 Status pull (OSAC gate) — REQ-14 ↔ REQ-9 latency

```
GET /api/v1/wallets/{tenant_id}
```

Parallel to `GET /api/v1/quotas/{tenant_id}`. Query: optional `wallet_id`; stretch: optional `project_id`.

**Hard latency target:** same as REQ-9 — **`< 500 ms`**, served from `wallets` projection (not raw ledger scan).

**Response (PoC — tenant wallet):**

```json
{
  "tenant_id": "tenant-acme",
  "evaluated_at": "2026-07-20T15:01:05Z",
  "wallets": [
    {
      "wallet_id": "019f0123-abcd-7890-abcd-ef1234567890",
      "project_id": null,
      "currency": "USD",
      "balance": 88.00,
      "reference_balance": 100.00,
      "remaining_pct": 88.0,
      "balance_floor": 0,
      "lifecycle_state": "active",
      "balance_status": "ok",
      "within_balance": true,
      "insufficient_funds": false,
      "unapplied_cost_amount": 0,
      "thresholds_breached": [],
      "highest_threshold_fired": null
    }
  ]
}
```

OSAC gates pull by `tenant_id` for PoC. Stretch: experimental-team gates may query `?project_id=...` once project wallets exist. Absence of a wallet is not an error (tenant/project on postpaid).

| Field | Values (proposed) |
|---|---|
| `lifecycle_state` | `active` \| `frozen` \| `closed` (wallet policy) |
| `balance_status` | `ok` \| `warning` / `approaching` / `critical` \| `depleted` |

| `balance_status` | Condition (proposed) |
|---|---|
| `ok` | `remaining_pct` above first warning threshold |
| `warning` / `approaching` / `critical` | Crossed configured low-balance bands |
| `depleted` | `balance <= balance_floor` |

`within_balance` = `balance > balance_floor`. Grace / soft-allow is OSAC policy, not Cost.

### 7.3 Low-balance alerts (REQ-10 pairing)

Reuse alert lifecycle from [alerting-spec-draft.md](alerting-spec-draft.md):

- Pull flags on `GET /api/v1/wallets/{tenant_id}` (PoC minimum; REQ-10 parked)
- Optional push CloudEvent when unparked, e.g. `cost.wallet.threshold.v1`

Proposed `data` delta vs quota events:

| Field | Notes |
|---|---|
| `limit_kind` | `"wallet"` |
| `wallet_id` | instead of `quota_id` |
| `balance`, `reference_balance`, `remaining_pct` | instead of consumed/limit |
| `threshold_pct` | e.g. `25` meaning “≤25% remaining” |

Threshold semantics are inverted vs budgets: budgets fire as **consumed % rises**; wallets fire as **remaining % falls**.

---

## 8. Deduction algorithm

Mutations lock the wallet row (`SELECT … FOR UPDATE`) in the same transaction as the ledger insert + balance update.

```
[after rating sweep writes new cost_entries]
  select unrated-for-wallet cost_entries (applied_amount < cost_amount)
    ordered by calculated_at (FIFO)
  for each entry:
      wallet = resolve_wallet(entry)   # see scope resolution below
      if wallet is null:
          continue                     # postpaid path — leave cost_entries only
      if wallet.lifecycle_state != active:
          continue                     # frozen/closed — queue (do not deduct)
      remaining = entry.cost_amount - entry.applied_amount
      debit = min(remaining, wallet.balance - wallet.balance_floor)
      if debit <= 0:
          mark wallet balance_status depleted; continue to next entry/wallet
      insert ledger deduction (-debit); update wallets.balance
      record application (amount_applied += debit)
      if remaining_pct crossed threshold: update alerts / flags
  # after top-up: same sweep resumes partial/unapplied backlog
```

**Scope resolution:**

| Option | Behavior | Priority |
|---|---|---|
| **A — Tenant wallet only** | All tenant cost deducts from the tenant wallet (`project_id` null) | **PoC must-have** |
| **B — Project wallet preferred** | Project wallet if present for `cost_entry.project_id`; else tenant wallet if present; else **no deduction** (postpaid) | Stretch (MB-005 hybrid) |
| **C — Split** | Project wallets only; tenant wallet never covers project spend | Not recommended |

**PoC: Option A.** Satisfies “create / top up / query scoped to tenant” and keeps deduction simple.

**Stretch: Option B** when project wallets land — enables hybrid postpaid + experimental-team prepaid:

| Cost scope | Wallet present? | Funding path |
|---|---|---|
| Any project under tenant | Tenant wallet only (Option A / PoC) | Prepaid draw-down from tenant wallet |
| `project-skunkworks` | Project wallet (Option B) | Prepaid draw-down from project wallet |
| `project-corp-finance` | No project wallet, no tenant wallet | Postpaid invoice |
| `project-corp-finance` | No project wallet, tenant wallet exists | Tenant prepaid (fallthrough) |
| Tenant-level cost (`project_id` empty) | Tenant wallet if present | Prepaid; else postpaid |

---

## 9. Coexistence with budgets / quotas / postpaid

Independent evaluations after each rating cycle:

| Check | Source | Gate signal |
|---|---|---|
| Quota | `metering_entries` vs `quotas` | `within_limit` |
| Budget | `SUM(cost_entries)` vs budget limit | `within_limit` |
| Wallet | `wallets.balance` vs floor (when a wallet applies) | `within_balance` |
| Postpaid invoice | Billing system over rated `cost_entries` | Outside Cost |

Notes:

- Wallet draw-down does **not** remove rows from `cost_entries` — reports and postpaid invoicing still see accrued cost
- OSAC may require **all** applicable checks to pass before create/inference when a wallet applies (quota + budget + wallet)
- Cost returns each status independently; no composite boolean unless OSAC asks later

---

## 10. Open questions

| # | Question | Impact | Lean |
|---|---|---|---|
| 1 | ~~Tenant-only vs tenant + project for PoC?~~ | — | **Decided (PM AC):** tenant is PoC must-have; project is optional / stretch |
| 2 | Can projects share a tenant wallet? | Stretch / Option B | Yes if Option B lands (fallthrough when no project wallet); N/A for Option A PoC |
| 3 | Who owns top-up UX? | Demo path | API in Cost; UX in OSAC or billing |
| 4 | ~~Zero balance hard stop?~~ | — | **Decided:** report-only (OSAC enforces) |
| 5 | `% of what` for low-balance — cumulative top-ups, last top-up, or absolute $? | `reference_balance` rules | Cumulative top-ups + absolute floor (still confirm UX) |
| 6 | ~~Partial deduction when cost > balance?~~ | — | **Decided:** deduct to floor; `amount_applied`; resume after top-up |
| 7 | Frozen wallet (dispute) — still deduct? | Ops | No deductions while `frozen`; costs queue |
| 8 | Shared alert table vs wallet-specific? | Schema | Reuse `alerts` with `limit_kind=wallet` |
| 9 | ~~MB-005 reserved allocations / multipliers~~ | — | **Decided:** Remain OUT (billing system) |
| 10 | Idempotency keys vs `external_ref` only? | Integration with Lago | Support both (`external_ref` + `idempotency_key`) |
| 11 | Does “experimental team” always = OSAC `project_id`? | Stretch attribution | Lean yes when project wallets land; confirm with OSAC |
| 12 | Acceptable overspend lag (meter→rate→deduct)? | Gate tightness | Accept ≤90s soft overspend for PoC; holds post-PoC |

---

## 10b. Implementation notes (Jul 22, 2026)

PoC implementation covers P0–P5 (must-have phases). Known gaps
relative to this spec:

| Spec feature | Status | Notes |
|---|---|---|
| `active` / `closed` lifecycle | **Done** | Create sets `active`; no close API yet (deferred) |
| `frozen` lifecycle state | **Not implemented** | Spec says "no deductions while frozen; costs queue" (§8, Q7) but does not define: (1) API to freeze/unfreeze (PATCH? transition endpoint?), (2) whether top-ups are accepted on a frozen wallet, (3) whether adjustments are accepted, (4) who can freeze (admin only? any API caller?). `DeductWallets` already skips non-`active` wallets, so the deduction side would work once the state can be set. **Needs product input before implementation.** |
| `reversal` entry type | **Not implemented** | Listed in ledger schema (`entry_type: reversal`) but semantics are undefined. Is it "undo a specific prior ledger entry by reference" or just a negative adjustment with a different label? **Needs clarification.** |
| Negative adjustments | **Done** (PR #95) | `AdjustWallet` modifies balance only (not `reference_balance`); signed amount; reason field for audit |
| `created_by` on ledger | **Not implemented** | No auth in PoC = no actor to record. Trivial to add once auth lands. |
| Project-scoped wallets (Option B) | **Deferred** | `project_id` column exists on `wallets`; deduction routing and scope resolution not built |
| Push alerts for low balance | **Not implemented** | Threshold flags computed on status GET; push depends on REQ-10 unparking |
| `idempotency_key` (separate from `external_ref`) | **Not implemented** | PoC uses `external_ref` only for idempotent top-ups |

---

## 11. PoC implementation plan

| Phase | Deliverable | Depends on | Priority |
|---|---|---|---|
| **P0** | `wallets` + `wallet_ledger_entries` schema; create / get / top-up API (**tenant** wallets) | — | Must |
| **P1** | Deduction after rating with Option A + `amount_applied`; link to `cost_entries` | P0, rating sweep | Must |
| **P2** | `GET /api/v1/wallets/{tenant_id}` with remaining % + threshold flags | P1 | Must |
| **P3** | Low-balance alert rows (pull-visible); optional push when REQ-10 unparked | P2, alerting patterns | Must |
| **P4** | Ledger query API + audit fields (`external_ref`, actor) | P0 | Must |
| **P5** | e2e in `test-inventory-watcher.sh` (tenant top-up → metered cost → balance drop → status flags) | P1–P2 | Must |
| **P6** | Optional `project_id` on create + Option B routing + `?project_id=` status filter | P1–P2 | Stretch |
| **P7** | Hybrid demo seed: postpaid project (no wallet) + prepaid experimental project wallet | P6 | Stretch |

**Minimum demo (must-have):** tenant → create + top up tenant wallet → generate metered cost → balance drops → status API shows remaining % / threshold flags.

**Stretch demo:** same enterprise → project wallet for experimental team + corporate project with no wallet (postpaid path untouched).

---

## 12. Testing

| Test | Assert | Priority |
|---|---|---|
| Top-up | Balance and `reference_balance` increase; ledger credit row | Must |
| Idempotent top-up | Same `external_ref` does not double-credit | Must |
| Tenant deduction | Rated cost for tenant reduces tenant wallet; ledger debit | Must |
| Partial + resume | Cost > balance → partial apply; top-up then remainder applied; no double-debit past `cost_amount` | Must |
| Depleted | Balance stops at floor; further cost left unapplied; `balance_status=depleted` | Must |
| Threshold | Crossing ≤25% remaining sets flag / alert once | Must |
| Status latency | `GET /api/v1/wallets/{tenant_id}` served from projection, not full ledger aggregate | Must |
| Coexistence | Budget exceeded and wallet OK (and vice versa) reported independently | Must |
| Audit | Ledger lists top-up, deduction, adjustment in order | Must |
| Project deduction | Rated cost on wallet project reduces that project wallet | Stretch |
| Postpaid isolation | Cost on project **without** wallet does not change any wallet balance | Stretch |
| Tenant fallthrough | No project wallet + tenant wallet present → tenant wallet debited | Stretch |

---

## 13. References

- [poc_requirements_overview.md — REQ-14](../../requirements/poc_requirements_overview.md#req-14-wallets-prepaid-balance)
- [req9-quota-budget-gap-analysis.md](../../requirements/req9-quota-budget-gap-analysis.md) — wallet vs budget boundary
- [alerting-osac-integration.md](alerting-osac-integration.md) — push/pull ownership for thresholds
- [alerting-spec-draft.md](alerting-spec-draft.md) — alert lifecycle + status API patterns
- [cost-calculation-spec-draft.md](../pricing/cost-calculation-spec-draft.md) — `cost_entries` source of deductions
- [data-model.md](../../data-model.md) — existing tables to extend
- [COST-7939](https://redhat.atlassian.net/browse/COST-7939) — PoC task
- [COST-7938](https://redhat.atlassian.net/browse/COST-7938) — product feature
- [COST-5694](https://redhat.atlassian.net/browse/COST-5694) — alerts/notifications (product dependency noted on COST-7938)
