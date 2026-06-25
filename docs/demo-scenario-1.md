# Demo Scenario 1: Inventory Watcher End-to-End

## Purpose

Demonstrate the inventory-watcher consuming events from OSAC in real-time,
building inventory, and producing metering entries. Suitable for a live demo
or a recorded walkthrough.

## Prerequisites

Install tools for the demo:

```bash
brew install watch        # live-refresh terminal commands
brew install asciinema    # terminal recording (optional)
```

Everything else should already be set up per `docs/dev/local-dev-setup.md`.

## Demo Flow

### Act 1: Show the infrastructure

**Goal:** Establish that OSAC and the cost database are running.

```bash
# Show running containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
  --filter name=osac-db --filter name=cost-db
```

Expected output:
```
NAMES     STATUS         PORTS
osac-db   Up X hours     127.0.0.1:5433->5432/tcp
cost-db   Up X hours     127.0.0.1:5434->5432/tcp
```

```bash
# Show OSAC is serving — list existing compute instances
curl -s http://localhost:8011/api/fulfillment/v1/compute_instances \
  -H "Authorization: Bearer $(cat /tmp/osac_token.txt)" | jq '.size'
```

```bash
# Show the cost database is empty (clean slate)
docker exec cost-db psql -U user -d costdb -c "\dt"
```

### Act 2: Start the inventory-watcher

**Goal:** Show reconciliation happening on startup.

**Terminal 1 — watcher logs:**
```bash
cd inventory-watcher
OSAC_BASE_URL=http://localhost:8011 \
OSAC_TOKEN=$(cat /tmp/osac_token.txt) \
INVENTORY_DB_URL=postgres://user:pass@localhost:5434/costdb \
RECONCILE_INTERVAL=5m \
SUMMARIZE_INTERVAL=5m \
./inventory-watcher
```

Point out the log lines:
```
msg="database schema ready"
msg="upserted compute instance" id=... name=worker-1 state=...RUNNING
msg="upserted compute instance" id=... name=worker-2 state=...RUNNING
msg="reconciled compute instances" osac_count=N inventory_count=0 created=N deleted=0
msg="reconciled instance types" count=3
msg="reconciliation complete"
msg="watch stream connected"
```

**Terminal 2 — live database view:**
```bash
watch -n 2 'docker exec cost-db psql -U user -d costdb -c \
  "SELECT instance_id, name, cores, memory_gib, state FROM inventory_compute_instance ORDER BY name;"'
```

The table populates immediately on startup — all OSAC instances appear.

### Act 3: Real-time event ingestion

**Goal:** Create a new compute instance in OSAC and watch it appear in the
cost database in real-time.

**Terminal 2** — keep the `watch` command running on the inventory table.

**Terminal 3** — create a new compute instance:
```bash
TOKEN=$(cat /tmp/osac_token.txt)
SUBNET_ID=$(curl -s http://localhost:8011/api/fulfillment/v1/subnets \
  -H "Authorization: Bearer $TOKEN" | jq -r '.items[0].id')
TPL_ID=$(curl -s http://localhost:8011/api/private/v1/compute_instance_templates \
  -H "Authorization: Bearer $TOKEN" | jq -r '.items[0].id')

curl -s -X POST http://localhost:8011/api/private/v1/compute_instances \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"metadata\": {\"name\": \"demo-vm\", \"labels\": {\"demo\": \"live\"}},
    \"spec\": {
      \"template\": \"$TPL_ID\",
      \"cores\": 4, \"memory_gib\": 16,
      \"network_attachments\": [{\"subnet\": \"$SUBNET_ID\"}],
      \"boot_disk\": {\"size_gib\": 100},
      \"image\": {\"source_type\": \"registry\", \"source_ref\": \"quay.io/fedora/fedora:latest\"},
      \"run_strategy\": \"Always\"
    },
    \"status\": {\"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\"}
  }" | jq '{id: .id, name: .metadata.name}'
```

**What to show:**
- Terminal 1 (logs): `received event ... type=EVENT_TYPE_OBJECT_CREATED resource=ComputeInstance`
  followed by `stored raw event` and `upserted compute instance`
- Terminal 2 (watch): `demo-vm` appears in the table within 1-2 seconds

### Act 4: Raw event log

**Goal:** Show that every event is stored immutably for audit.

**Terminal 3:**
```bash
docker exec cost-db psql -U user -d costdb -c \
  "SELECT event_id, event_type, resource_type, resource_id, received_at
   FROM raw_events ORDER BY received_at DESC LIMIT 5;"
```

Point out: the event that created `demo-vm` is stored with its full payload.

### Act 5: Metering in action

**Goal:** Show the 60-second metering sweep producing usage records.

**Terminal 2** — switch to watching metering entries:
```bash
watch -n 5 'docker exec cost-db psql -U user -d costdb -c \
  "SELECT meter_name, resource_id, round(value::numeric, 1) as value, unit
   FROM metering_entries ORDER BY resource_id, meter_name LIMIT 20;"'
```

**Wait ~60 seconds.** The metering sweep fires and the table populates.

**What to show:**
- Terminal 1 (logs): `metering sweep complete compute_instances=N`
- Terminal 2 (watch): metering entries appear — `vm_uptime_seconds`,
  `vm_cpu_core_seconds`, `vm_memory_gib_seconds` for each running VM

**Explain the math** for one instance (e.g., worker-1 with 4 cores):
```
vm_uptime_seconds    = ~60        (one sweep interval)
vm_cpu_core_seconds  = ~240       (4 cores × 60 seconds)
vm_memory_gib_seconds = ~960      (16 GiB × 60 seconds)
```

### Act 6: DELETE and final metering

**Goal:** Show that deleting a VM produces final metering entries covering
the time since the last sweep.

**Terminal 2** — watch metering entries for the demo-vm specifically:
```bash
DEMO_ID=$(docker exec cost-db psql -U user -d costdb -t -A -c \
  "SELECT instance_id FROM inventory_compute_instance WHERE name = 'demo-vm';")
watch -n 2 "docker exec cost-db psql -U user -d costdb -c \
  \"SELECT meter_name, round(value::numeric, 1) as value, unit, period_start, period_end
   FROM metering_entries WHERE resource_id = '$DEMO_ID' ORDER BY meter_name;\""
```

**Terminal 3** — delete the VM:
```bash
DEMO_ID=$(docker exec cost-db psql -U user -d costdb -t -A -c \
  "SELECT instance_id FROM inventory_compute_instance WHERE name = 'demo-vm';")
curl -s -X DELETE "http://localhost:8011/api/fulfillment/v1/compute_instances/$DEMO_ID" \
  -H "Authorization: Bearer $(cat /tmp/osac_token.txt)"
```

**What to show:**
- Terminal 1 (logs): `received event ... type=EVENT_TYPE_OBJECT_DELETED`,
  `final metering for deleted instance`
- Terminal 2 (watch): final metering entries appear immediately (no need to
  wait for the next sweep)

**Verify deletion:**
```bash
docker exec cost-db psql -U user -d costdb -c \
  "SELECT name, state, deleted_at FROM inventory_compute_instance WHERE name = 'demo-vm';"
```

### Act 7: Run the test suite

**Goal:** Show automated test coverage.

```bash
SKIP_METERING=1 bash snippets/test-inventory-watcher.sh
```

Shows colored output with checkmarks, all passing. For a full run
(including metering and non-billable filtering), drop the `SKIP_METERING=1`.

## Recording the Demo

### Option A: asciinema (terminal recording, shareable)

```bash
brew install asciinema

# Record the whole demo
asciinema rec demo-scenario-1.cast

# ... run the demo steps ...
# Press Ctrl-D or type 'exit' to stop

# Play back
asciinema play demo-scenario-1.cast

# Upload (optional — creates a shareable link)
asciinema upload demo-scenario-1.cast
```

### Option B: script (built-in, simple)

```bash
# Record terminal session with timestamps
script -r demo-scenario-1.log

# ... run the demo steps ...
# Type 'exit' to stop

# Play back at original speed
script -p demo-scenario-1.log
```

### Option C: tmux split panes (live demo layout)

For a live demo, use a 3-pane tmux layout:

```bash
# Create the layout
tmux new-session -s demo -d

# Pane 0 (top-left): watcher logs
tmux send-keys -t demo 'cd inventory-watcher && OSAC_BASE_URL=http://localhost:8011 OSAC_TOKEN=$(cat /tmp/osac_token.txt) INVENTORY_DB_URL=postgres://user:pass@localhost:5434/costdb ./inventory-watcher' Enter

# Pane 1 (top-right): live DB view
tmux split-window -h -t demo
tmux send-keys -t demo 'watch -n 2 "docker exec cost-db psql -U user -d costdb -c \"SELECT name, cores, memory_gib, state FROM inventory_compute_instance ORDER BY name;\""' Enter

# Pane 2 (bottom): command input
tmux split-window -v -t demo
tmux send-keys -t demo 'echo "Ready for demo commands"' Enter

tmux attach -t demo
```

Layout:
```
┌─────────────────────┬─────────────────────┐
│  Watcher logs       │  Live DB view       │
│  (streaming)        │  (watch -n 2)       │
│                     │                     │
├─────────────────────┴─────────────────────┤
│  Command input (create/delete instances)  │
│                                           │
└───────────────────────────────────────────┘
```

## Talking Points

1. **No Kafka needed** — the gRPC Watch stream provides real-time events,
   the reconciler catches anything missed. Same pattern as Kubernetes
   controllers.

2. **Sub-second ingestion** — creating a VM in OSAC appears in the cost
   database within 1-2 seconds. No polling, no batch processing.

3. **Capacity-based billing** — metering entries track provisioned resources
   × time. A 4-core VM running for 60 seconds = 240 cpu_core_seconds.
   You pay for what's provisioned, not what's used.

4. **No data loss on deletion** — final metering entries are produced
   immediately on DELETE, covering the gap since the last sweep.

5. **Immutable audit trail** — every event is stored in raw_events before
   processing. Full replay capability.

6. **Billable state filtering** — only RUNNING VMs are metered. STOPPED
   VMs are tracked in inventory but produce no cost.
