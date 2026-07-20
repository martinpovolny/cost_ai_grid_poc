#!/usr/bin/env bash
set -uo pipefail

# Test BareMetalInstance events flowing through the public Watch stream.
# Expects: OSAC deployed in k3d (integration-test/deploy-osac.sh),
#          cost-consumer deployed (integration-test/deploy-consumer.sh),
#          port-forwards: osac-rest:8011, cost-consumer:8020.
#          Token in /tmp/osac_token.txt.

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
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

OSAC=http://localhost:8011
CONSUMER=http://localhost:8020
TOKEN=$(cat /tmp/osac_token.txt)
DB_CONTAINER=cost-db
DB_NAME=costdb

db_query() {
    docker exec "$DB_CONTAINER" psql -U user -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

echo "=== BareMetalInstance Watch Stream Test ==="
echo ""

# ── 1. Prerequisites ──
echo "--- Setting up prerequisites ---"

# Check OSAC connectivity
curl -sf "$OSAC/api/fulfillment/v1/baremetal_instances" \
    -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1 \
    || { echo "ERROR: OSAC REST not reachable at $OSAC"; exit 1; }
echo "  OSAC REST: OK"

# Check consumer
curl -sf "$CONSUMER/healthz" > /dev/null 2>&1 \
    || { echo "ERROR: Consumer not reachable at $CONSUMER"; exit 1; }
echo "  Consumer: OK"

# Create a host type (required for BM templates)
echo "  Creating host type..."
HOST_TYPE_ID=$(curl -s -X POST "$OSAC/api/private/v1/host_types" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{
        "metadata": {"name": "bm-test-host-type"},
        "spec": {
            "cores": 64,
            "memory_gib": 256,
            "description": "Test BM host type",
            "state": "HOST_TYPE_STATE_ACTIVE"
        }
    }' 2>/dev/null | jq -r '.id // empty')

if [ -z "$HOST_TYPE_ID" ]; then
    # May already exist - try to find it
    HOST_TYPE_ID=$(curl -s "$OSAC/api/fulfillment/v1/host_types" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.items[0].id // empty')
fi
echo "  Host type: $HOST_TYPE_ID"

# Create a BM template
echo "  Creating BM template..."
BM_TEMPLATE_ID=$(curl -s -X POST "$OSAC/api/private/v1/baremetal_instance_templates" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{
        \"metadata\": {\"name\": \"bm-test-template\"},
        \"spec\": {
            \"host_type\": \"$HOST_TYPE_ID\"
        }
    }" 2>/dev/null | jq -r '.id // empty')

if [ -z "$BM_TEMPLATE_ID" ]; then
    BM_TEMPLATE_ID=$(curl -s "$OSAC/api/fulfillment/v1/baremetal_instance_templates" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.items[0].id // empty')
fi
echo "  BM template: $BM_TEMPLATE_ID"

# Create a BM catalog item
echo "  Creating BM catalog item..."
BM_CATALOG_ID=$(curl -s -X POST "$OSAC/api/private/v1/baremetal_instance_catalog_items" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{
        \"metadata\": {\"name\": \"bm-test-catalog-item\"},
        \"spec\": {
            \"title\": \"Test BM Catalog Item\",
            \"description\": \"For integration testing\",
            \"template\": \"$BM_TEMPLATE_ID\",
            \"published\": true
        }
    }" 2>/dev/null | jq -r '.id // empty')

if [ -z "$BM_CATALOG_ID" ]; then
    BM_CATALOG_ID=$(curl -s "$OSAC/api/fulfillment/v1/baremetal_instance_catalog_items" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.items[0].id // empty')
fi
echo "  BM catalog item: $BM_CATALOG_ID"

if [ -z "$BM_CATALOG_ID" ] || [ "$BM_CATALOG_ID" = "null" ]; then
    echo "ERROR: Could not create BM catalog item prerequisites"
    echo "  host_type=$HOST_TYPE_ID template=$BM_TEMPLATE_ID catalog=$BM_CATALOG_ID"
    exit 1
fi

# ── 2. Baseline counts ──
echo ""
echo "--- Baseline ---"
RAW_BEFORE=$(db_query "SELECT count(*) FROM raw_events;" 2>/dev/null || echo "0")
BM_INV_BEFORE=$(db_query "SELECT count(*) FROM inventory_bare_metal_instance;" 2>/dev/null || echo "0")
echo "  raw_events: $RAW_BEFORE"
echo "  BM inventory: $BM_INV_BEFORE"

# ── 3. Create BareMetalInstance ──
echo ""
echo "--- Creating BareMetalInstance ---"
BM_NAME="bm-watch-test-$(date +%s)"
BM_RESPONSE=$(curl -s -X POST "$OSAC/api/private/v1/baremetal_instances" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{
        \"metadata\": {\"name\": \"$BM_NAME\"},
        \"spec\": {
            \"catalog_item\": \"$BM_CATALOG_ID\"
        },
        \"status\": {\"state\": \"BARE_METAL_INSTANCE_STATE_RUNNING\"}
    }")
BM_ID=$(echo "$BM_RESPONSE" | jq -r '.id // empty')
echo "  Created BM instance: $BM_ID"

if [ -z "$BM_ID" ] || [ "$BM_ID" = "null" ]; then
    echo "ERROR: Failed to create BareMetalInstance"
    echo "  Response: $BM_RESPONSE"
    exit 1
fi

# ── 4. Wait for Watch event to be processed ──
echo "  Waiting 10s for event propagation..."
sleep 10

# ── 5. Verify event arrived ──
echo ""
echo "--- Verification ---"

RAW_AFTER=$(db_query "SELECT count(*) FROM raw_events;")
check_ge "raw_events count increased" "$((RAW_BEFORE + 1))" "$RAW_AFTER"

BM_RAW=$(db_query "SELECT count(*) FROM raw_events WHERE resource_id = '$BM_ID';")
check_ge "BM raw event stored" 1 "$BM_RAW"

BM_RAW_TYPE=$(db_query "SELECT resource_type FROM raw_events WHERE resource_id = '$BM_ID' ORDER BY received_at DESC LIMIT 1;")
check "resource_type is BareMetalInstance" "BareMetalInstance" "$BM_RAW_TYPE"

BM_EVENT_TYPE=$(db_query "SELECT event_type FROM raw_events WHERE resource_id = '$BM_ID' ORDER BY received_at DESC LIMIT 1;")
check "event_type is CREATED" "EVENT_TYPE_OBJECT_CREATED" "$BM_EVENT_TYPE"

BM_INV_AFTER=$(db_query "SELECT count(*) FROM inventory_bare_metal_instance WHERE instance_id = '$BM_ID';")
check "BM in inventory" "1" "$BM_INV_AFTER"

# ── 6. Delete and verify DELETE event ──
echo ""
echo "--- Delete BareMetalInstance ---"
curl -s -X DELETE "$OSAC/api/fulfillment/v1/baremetal_instances/$BM_ID" \
    -H "Authorization: Bearer $TOKEN" > /dev/null
echo "  Deleted BM instance: $BM_ID"
echo "  Waiting 10s for event propagation..."
sleep 10

BM_DELETE_RAW=$(db_query "SELECT count(*) FROM raw_events WHERE resource_id = '$BM_ID' AND event_type = 'EVENT_TYPE_OBJECT_DELETED';")
check "DELETE raw event stored" "1" "$BM_DELETE_RAW"

BM_DELETED_AT=$(db_query "SELECT deleted_at IS NOT NULL FROM inventory_bare_metal_instance WHERE instance_id = '$BM_ID';")
check "BM marked deleted in inventory" "t" "$BM_DELETED_AT"

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
