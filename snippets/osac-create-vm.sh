#!/usr/bin/env bash
set -euo pipefail

# Creates all OSAC prerequisites and a test VM via the fulfillment-service
# private REST API.
#
# Chain: NetworkClass → VirtualNetwork → Subnet → InstanceType → ComputeInstance
#
# Prerequisites:
#   - OSAC fulfillment-service REST gateway on localhost:8011
#   - Valid token in /tmp/osac_token.txt
#
# Usage:
#   bash snippets/osac-create-vm.sh
#   bash snippets/osac-create-vm.sh --name my-vm --cores 8 --memory 16

OSAC="${OSAC_BASE_URL:-http://localhost:8011}"
TOKEN="${OSAC_TOKEN:-$(cat /tmp/osac_token.txt 2>/dev/null || echo "")}"
VM_NAME="${VM_NAME:-e2e-vm-$(date +%s)}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8}"
INSTANCE_TYPE_NAME="${INSTANCE_TYPE_NAME:-standard-${CORES}-${MEMORY}}"

if [ -z "$TOKEN" ]; then
    echo "ERROR: no token. Set OSAC_TOKEN or create /tmp/osac_token.txt"
    exit 1
fi

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

echo "=== OSAC VM Creation ==="
echo "  REST gateway: $OSAC"
echo ""

# 1. NetworkClass
echo "--- Step 1: NetworkClass ---"
NC_ID=$(osac_get "/api/private/v1/network_classes" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print(items[0]['id'] if items else '')" 2>/dev/null)

if [ -z "$NC_ID" ]; then
    NC_ID=$(osac_post "/api/private/v1/network_classes" '{
        "metadata": {"name": "default-net-class"},
        "title": "Default Network",
        "description": "Default network class for testing",
        "implementation_strategy": "cudn",
        "capabilities": {"supports_ipv4": true},
        "status": {"state": "NETWORK_CLASS_STATE_READY"},
        "is_default": true,
        "fabric_manager": "test"
    }' | get_id)
    echo "  Created: $NC_ID"
else
    echo "  Existing: $NC_ID"
fi

# 2. VirtualNetwork
echo "--- Step 2: VirtualNetwork ---"
VNET_ID=$(osac_get "/api/private/v1/virtual_networks" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print(items[0]['id'] if items else '')" 2>/dev/null)

if [ -z "$VNET_ID" ]; then
    VNET_ID=$(osac_post "/api/private/v1/virtual_networks" "{
        \"metadata\": {\"name\": \"default-vnet\"},
        \"spec\": {
            \"region\": \"us-east-1\",
            \"network_class\": \"$NC_ID\",
            \"ipv4_cidr\": \"10.0.0.0/16\",
            \"capabilities\": {\"enable_ipv4\": true}
        },
        \"status\": {\"state\": \"VIRTUAL_NETWORK_STATE_READY\"}
    }" | get_id)
    echo "  Created: $VNET_ID"
else
    echo "  Existing: $VNET_ID"
fi

# 3. Subnet
echo "--- Step 3: Subnet ---"
SUBNET_ID=$(osac_get "/api/private/v1/subnets" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print(items[0]['id'] if items else '')" 2>/dev/null)

if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID=$(osac_post "/api/private/v1/subnets" "{
        \"metadata\": {\"name\": \"default-subnet\"},
        \"spec\": {
            \"virtual_network\": \"$VNET_ID\",
            \"ipv4_cidr\": \"10.0.1.0/24\"
        },
        \"status\": {\"state\": \"SUBNET_STATE_READY\"}
    }" | get_id)
    echo "  Created: $SUBNET_ID"
else
    echo "  Existing: $SUBNET_ID"
fi

# 4. InstanceType
echo "--- Step 4: InstanceType ---"
IT_EXISTS=$(osac_get "/api/private/v1/instance_types" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print('yes' if any(i.get('metadata',{}).get('name')=='$INSTANCE_TYPE_NAME' for i in items) else '')" 2>/dev/null)

if [ -z "$IT_EXISTS" ]; then
    osac_post "/api/private/v1/instance_types" "{
        \"metadata\": {\"name\": \"$INSTANCE_TYPE_NAME\"},
        \"spec\": {
            \"cores\": $CORES,
            \"memory_gib\": $MEMORY,
            \"description\": \"$CORES cores $MEMORY GiB\",
            \"state\": \"INSTANCE_TYPE_STATE_ACTIVE\"
        }
    }" > /dev/null
    echo "  Created: $INSTANCE_TYPE_NAME"
else
    echo "  Existing: $INSTANCE_TYPE_NAME"
fi

# 5. ComputeInstance template (if needed)
echo "--- Step 5: ComputeInstance Template ---"
TPL_ID=$(osac_get "/api/private/v1/compute_instance_templates" | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); print(items[0]['id'] if items else '')" 2>/dev/null)

if [ -z "$TPL_ID" ]; then
    TPL_ID=$(osac_post "/api/private/v1/compute_instance_templates" '{
        "metadata": {"name": "default-template"},
        "title": "Default",
        "description": "Default compute instance template"
    }' | get_id)
    echo "  Created: $TPL_ID"
else
    echo "  Existing: $TPL_ID"
fi

# 6. Create the VM
echo "--- Step 6: ComputeInstance ---"
VM_RESP=$(osac_post "/api/private/v1/compute_instances" "{
    \"metadata\": {\"name\": \"$VM_NAME\"},
    \"spec\": {
        \"template\": \"$TPL_ID\",
        \"instance_type\": \"$INSTANCE_TYPE_NAME\",
        \"boot_disk\": {\"size_gib\": 50},
        \"image\": {\"source_type\": \"registry\", \"source_ref\": \"quay.io/fedora/fedora:latest\"},
        \"run_strategy\": \"Always\",
        \"network_attachments\": [{\"subnet\": \"$SUBNET_ID\"}]
    },
    \"status\": {\"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\"}
}")

VM_ID=$(echo "$VM_RESP" | get_id)
if [ -n "$VM_ID" ]; then
    echo "  Created: $VM_ID ($VM_NAME)"
    echo ""
    echo "=== Success ==="
    echo "  VM ID: $VM_ID"
    echo "  Name:  $VM_NAME"
    echo "  Type:  $INSTANCE_TYPE_NAME (${CORES}c/${MEMORY}g)"
else
    echo "  ERROR: VM creation failed"
    echo "$VM_RESP" | python3 -m json.tool 2>/dev/null || echo "$VM_RESP"
    exit 1
fi
