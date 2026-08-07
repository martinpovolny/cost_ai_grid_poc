#!/usr/bin/env bash
set -uo pipefail

# Integration test: OSAC fulfillment-service → metering-service → Kafka → cost-consumer
#
# Tests the full event pipeline:
#   1. Create VM prerequisites (NetworkClass, VirtualNetwork, Subnet, InstanceType)
#   2. Create a ComputeInstance via OSAC REST
#   3. Verify metering-service publishes CloudEvent to Kafka
#   4. Verify cost-consumer reads from Kafka and creates inventory record
#
# Prerequisites:
#   - OSAC fulfillment-service REST on localhost:8011
#   - OSAC metering-service connected to fulfillment + Kafka
#   - Kafka on localhost:19092
#   - Postgres on localhost:5434
#   - /tmp/osac_token.txt with valid token

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $desc ${DIM}(got: $actual)${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc ${DIM}(expected: $expected, got: $actual)${NC}"
        FAIL=$((FAIL + 1))
    fi
}

check_ge() {
    local desc="$1" minimum="$2" actual="$3"
    if [ "$actual" -ge "$minimum" ] 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $desc ${DIM}(got: $actual, min: $minimum)${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc ${DIM}(expected >= $minimum, got: $actual)${NC}"
        FAIL=$((FAIL + 1))
    fi
}

check_not_empty() {
    local desc="$1" actual="$2"
    if [ -n "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $desc ${DIM}($actual)${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc ${DIM}(empty)${NC}"
        FAIL=$((FAIL + 1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER_BIN="$REPO_DIR/inventory-watcher/inventory-watcher"
BROKER="${KAFKA_BROKER_OVERRIDE:-127.0.0.1:19092}"
OSAC="${OSAC_BASE_URL:-http://localhost:8011}"
TOKEN="${OSAC_TOKEN:-$(cat /tmp/osac_token.txt 2>/dev/null || echo "")}"
DB_PORT="${DB_PORT:-5434}"

db_query() {
    if command -v psql > /dev/null 2>&1; then
        PGPASSWORD=pass psql -h 127.0.0.1 -p "$DB_PORT" -U user -d costdb -t -A -c "$1" 2>/dev/null
    else
        docker exec cost-db psql -U user -d costdb -t -A -c "$1" 2>/dev/null
    fi
}

AUTH=(-H "Authorization: Bearer $TOKEN")
JSON=(-H "Content-Type: application/json")

osac_post() {
    local path="$1" body="$2"
    curl -s -X POST "${OSAC}${path}" "${AUTH[@]}" "${JSON[@]}" -d "$body"
}

osac_get() {
    local path="$1"
    curl -s "${OSAC}${path}" "${AUTH[@]}"
}

get_id() {
    python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null
}

get_first_id() {
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print(items[0]['id'] if items else '')" 2>/dev/null
}

# Consume from Kafka topic (works with rpk or kafka-console-consumer)
kafka_consume() {
    local topic="$1" max_msgs="${2:-10}"
    if command -v rpk > /dev/null 2>&1; then
        timeout 10 rpk topic consume "$topic" --brokers "$BROKER" -o start -f '%v\n' -n "$max_msgs" 2>/dev/null
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q kafka; then
        timeout 10 docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
            --bootstrap-server "$BROKER" --topic "$topic" \
            --from-beginning --max-messages "$max_msgs" --timeout-ms 8000 2>/dev/null
    fi
}

echo "=== OSAC → Kafka Integration Test ==="
echo "  OSAC REST: $OSAC"
echo "  Kafka:     $BROKER"
echo ""

# ── Preflight ──
echo "--- Preflight ---"

if [ ! -f "$WATCHER_BIN" ]; then
    echo "Building cost consumer..."
    (cd "$REPO_DIR/inventory-watcher" && go build -o inventory-watcher ./cmd/consumer/) || {
        echo "ERROR: build failed"; exit 1
    }
fi

curl -sf "$OSAC/api/fulfillment/v1/instance_types" "${AUTH[@]}" > /dev/null 2>&1 || {
    echo "ERROR: OSAC not reachable at $OSAC"; exit 1
}
echo "  OSAC: OK"

kafka_ready=false
if command -v rpk > /dev/null 2>&1; then
    rpk cluster info --brokers "$BROKER" > /dev/null 2>&1 && kafka_ready=true
fi
if [ "$kafka_ready" != "true" ] && docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BROKER" --list > /dev/null 2>&1; then
    kafka_ready=true
fi
if [ "$kafka_ready" != "true" ]; then
    echo "ERROR: Kafka not reachable at $BROKER"; exit 1
fi
echo "  Kafka: OK"

db_query "SELECT 1" > /dev/null 2>&1 || {
    echo "ERROR: Postgres not reachable"; exit 1
}
echo "  Postgres: OK"

# ── Step 1: OSAC prerequisites ──
echo ""
echo "--- Step 1: OSAC prerequisites ---"

NC_ID=$(osac_get "/api/private/v1/network_classes" | get_first_id)
if [ -z "$NC_ID" ]; then
    NC_ID=$(osac_post "/api/private/v1/network_classes" '{
        "metadata": {"name": "ci-net-class"},
        "title": "CI Network",
        "description": "CI test network class",
        "implementation_strategy": "cudn",
        "capabilities": {"supports_ipv4": true},
        "status": {"state": "NETWORK_CLASS_STATE_READY"},
        "is_default": true,
        "fabric_manager": "test"
    }' | get_id)
fi
check_not_empty "NetworkClass" "$NC_ID"

VNET_ID=$(osac_get "/api/private/v1/virtual_networks" | get_first_id)
if [ -z "$VNET_ID" ]; then
    VNET_ID=$(osac_post "/api/private/v1/virtual_networks" "{
        \"metadata\": {\"name\": \"ci-vnet\"},
        \"spec\": {
            \"region\": \"us-east-1\",
            \"network_class\": \"$NC_ID\",
            \"ipv4_cidr\": \"10.0.0.0/16\",
            \"capabilities\": {\"enable_ipv4\": true}
        },
        \"status\": {\"state\": \"VIRTUAL_NETWORK_STATE_READY\"}
    }" | get_id)
fi
check_not_empty "VirtualNetwork" "$VNET_ID"

SUBNET_ID=$(osac_get "/api/private/v1/subnets" | get_first_id)
if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID=$(osac_post "/api/private/v1/subnets" "{
        \"metadata\": {\"name\": \"ci-subnet\"},
        \"spec\": {
            \"virtual_network\": \"$VNET_ID\",
            \"ipv4_cidr\": \"10.0.1.0/24\"
        },
        \"status\": {\"state\": \"SUBNET_STATE_READY\"}
    }" | get_id)
fi
check_not_empty "Subnet" "$SUBNET_ID"

IT_NAME="ci-standard-4-8"
IT_EXISTS=$(osac_get "/api/private/v1/instance_types" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print('yes' if any(i.get('metadata',{}).get('name')=='$IT_NAME' for i in items) else '')" 2>/dev/null)
if [ -z "$IT_EXISTS" ]; then
    osac_post "/api/private/v1/instance_types" "{
        \"metadata\": {\"name\": \"$IT_NAME\"},
        \"spec\": {\"cores\": 4, \"memory_gib\": 8, \"description\": \"CI test\", \"state\": \"INSTANCE_TYPE_STATE_ACTIVE\"}
    }" > /dev/null
fi
check_not_empty "InstanceType" "$IT_NAME"

TPL_ID=$(osac_get "/api/private/v1/compute_instance_templates" | get_first_id)
if [ -z "$TPL_ID" ]; then
    TPL_ID=$(osac_post "/api/private/v1/compute_instance_templates" '{
        "metadata": {"name": "ci-template"},
        "title": "CI Template",
        "description": "CI test template"
    }' | get_id)
fi
check_not_empty "Template" "$TPL_ID"

# ── Step 2: Start cost consumer ──
echo ""
echo "--- Step 2: Start cost consumer ---"

KAFKA_BROKERS="$BROKER" \
KAFKA_MODE="consumer" \
KAFKA_CONSUMER_GROUP="osac-kafka-ci-$(date +%s)" \
INVENTORY_DB_URL="postgres://user:pass@127.0.0.1:$DB_PORT/costdb" \
INGEST_LISTEN_ADDR="127.0.0.1:18026" \
METRICS_PORT="19006" \
DISABLE_COMPONENTS="watcher,reconciler" \
"$WATCHER_BIN" > /tmp/cost-consumer-osac.log 2>&1 &
CONSUMER_PID=$!

for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:18026/healthz > /dev/null 2>&1 && break
    sleep 1
done
if ! curl -sf http://127.0.0.1:18026/healthz > /dev/null 2>&1; then
    echo "ERROR: consumer not ready after 30s"
    tail -20 /tmp/cost-consumer-osac.log
    kill $CONSUMER_PID 2>/dev/null
    exit 1
fi
echo "  Consumer started (PID $CONSUMER_PID)"

# Wait for metering-service Watch stream to be fully established
echo "  Waiting 10s for Watch stream..."
sleep 10

# ── Step 3: Create VM ──
echo ""
echo "--- Step 3: Create ComputeInstance ---"

VM_NAME="ci-kafka-vm-$(date +%s)"
VM_RESP=$(osac_post "/api/private/v1/compute_instances" "{
    \"metadata\": {\"name\": \"$VM_NAME\"},
    \"spec\": {
        \"template\": \"$TPL_ID\",
        \"instance_type\": \"$IT_NAME\",
        \"boot_disk\": {\"size_gib\": 50},
        \"image\": {\"source_type\": \"registry\", \"source_ref\": \"quay.io/fedora/fedora:latest\"},
        \"run_strategy\": \"Always\",
        \"network_attachments\": [{\"subnet\": \"$SUBNET_ID\"}]
    },
    \"status\": {\"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\"}
}")
VM_ID=$(echo "$VM_RESP" | get_id)
check_not_empty "ComputeInstance created" "$VM_ID"

if [ -z "$VM_ID" ]; then
    echo "ERROR: VM creation failed"
    echo "$VM_RESP"
    kill $CONSUMER_PID 2>/dev/null
    exit 1
fi

# ── Step 4: Wait and verify ──
echo ""
echo "--- Step 4: Verify event pipeline (waiting 15s) ---"
sleep 15

# Check Kafka topic for event from metering-service Watch stream
KAFKA_MSG=$(kafka_consume osac.metering.lifecycle 10)
VM_IN_KAFKA=$(echo "$KAFKA_MSG" | grep -c "$VM_ID" || echo "0")

check_ge "VM event on Kafka topic" 1 "$VM_IN_KAFKA"

# Check consumer logs
CONSUMER_PROCESSED=$(grep -c "osac v1: upserted compute_instance" /tmp/cost-consumer-osac.log 2>/dev/null || echo "0")
check_ge "Consumer processed v1 events" 1 "$CONSUMER_PROCESSED"

# Check raw_events in DB
RAW_COUNT=$(db_query "SELECT count(*) FROM raw_events WHERE event_type = 'osac.resource.created.v1' AND resource_id = '$VM_ID';")
check "Raw event stored" "1" "$RAW_COUNT"

# Check inventory_compute_instance in DB
CI_STATE=$(db_query "SELECT state FROM inventory_compute_instance WHERE instance_id = '$VM_ID';")
check "Inventory record state" "RUNNING" "$CI_STATE"

CI_TYPE=$(db_query "SELECT instance_type FROM inventory_compute_instance WHERE instance_id = '$VM_ID';")
check "Inventory record instance_type" "$IT_NAME" "$CI_TYPE"

# ── Cleanup ──
kill $CONSUMER_PID 2>/dev/null; wait $CONSUMER_PID 2>/dev/null || true
echo "  Consumer stopped"

# ── Summary ──
echo ""
echo "=========================================="
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}$FAIL FAILED${NC}"
    exit 1
else
    echo -e "  ${GREEN}ALL PASSED${NC}"
fi
# Pinned OSAC versions for proto compatibility
