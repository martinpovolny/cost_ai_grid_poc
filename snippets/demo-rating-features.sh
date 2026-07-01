#!/bin/bash
# Demo: Rating Engine Features
# Shows flat rates, tiered pricing, per-tenant overrides, and Koku alignment.
#
# Prerequisites:
#   - cost-db running (docker)
#   - OSAC running with token
#   - inventory-watcher built and started with INGEST_LISTEN_ADDR=localhost:8020
#
# Usage:
#   bash snippets/demo-rating-features.sh

set -uo pipefail

DB=cost-db
DBNAME=costdb
INGEST=http://localhost:8020

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${BLUE}  $1${RESET}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

q() {
  docker exec "$DB" psql -U user -d "$DBNAME" -c "$1" 2>/dev/null
}

pause() {
  if [ -t 0 ]; then
    echo ""
    echo -e "${DIM}  Press Enter to continue...${RESET}"
    read -r
  fi
}

send_event() {
  local type=$1 id=$2 tenant=$3
  shift 3
  local data=$1

  curl -s -X POST "$INGEST/api/v1/events" \
    -H "Content-Type: application/json" \
    -d "{
      \"specversion\": \"1.0\",
      \"type\": \"$type\",
      \"source\": \"demo.rating\",
      \"id\": \"$id\",
      \"time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"subject\": \"$tenant\",
      \"data\": $data
    }" > /dev/null
}

# ─────────────────────────────────────────────────────────────
# ACT 1: Show the default rates (flat pricing)
# ─────────────────────────────────────────────────────────────

section "Act 1: Default Flat Rates"

echo -e "  The system seeds default rates on first startup."
echo -e "  Each rate has a ${BOLD}cost_type${RESET} (Infrastructure/Supplementary)"
echo -e "  and a ${BOLD}koku_metric${RESET} mapping for Koku compatibility."
echo ""

q "SELECT resource_type, meter_name, cost_type, koku_metric,
          round(price_per_unit::numeric, 10) as price_per_unit, currency
   FROM rates
   WHERE tenant_id IS NULL
   ORDER BY resource_type, meter_name;"

echo -e "  ${DIM}These are global rates — tenant_id IS NULL means they apply to everyone.${RESET}"

pause

# ─────────────────────────────────────────────────────────────
# ACT 2: Flat rate in action
# ─────────────────────────────────────────────────────────────

section "Act 2: Flat Rate Calculation"

echo -e "  Sending a VM heartbeat: 4 cores, 16 GiB, running for 60 seconds..."
echo ""

send_event "osac.compute_instance.lifecycle" \
  "demo-flat-$(date +%s)" \
  "tenant-acme" \
  "{
    \"duration_seconds\": 60,
    \"cpu_core_seconds\": 240,
    \"memory_gib_seconds\": 960,
    \"tenant_id\": \"tenant-acme\",
    \"instance_id\": \"demo-flat-vm\",
    \"template\": \"osac.templates.ocp_virt_vm\",
    \"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\",
    \"cores\": 4,
    \"memory_gib\": 16
  }"

echo -e "  ${GREEN}✓${RESET} Event sent. Waiting for rating sweep (up to 35s)..."
sleep 35

echo ""
echo -e "  ${BOLD}Metering entries:${RESET}"
q "SELECT meter_name, round(value::numeric, 2) as value, unit
   FROM metering_entries
   WHERE resource_id = 'demo-flat-vm'
   ORDER BY meter_name;"

echo -e "  ${BOLD}Cost entries (flat rate applied):${RESET}"
q "SELECT ce.meter_name,
          round(ce.metered_value::numeric, 2) as metered,
          r.cost_type,
          round(r.price_per_unit::numeric, 10) as rate,
          round(ce.cost_amount::numeric, 8) as cost,
          ce.currency
   FROM cost_entries ce
   JOIN rates r ON ce.rate_id = r.id
   WHERE ce.resource_id = 'demo-flat-vm'
   ORDER BY ce.meter_name;"

echo -e "  ${DIM}Math: vm_uptime_seconds = 60s × \$0.01/3600 = \$0.000167${RESET}"
echo -e "  ${DIM}      vm_cpu_core_seconds = 240 core·s × \$0.005/3600 = \$0.000333${RESET}"
echo -e "  ${DIM}      vm_memory_gib_seconds = 960 GiB·s × \$0.002/3600 = \$0.000533${RESET}"

pause

# ─────────────────────────────────────────────────────────────
# ACT 3: Per-tenant rate override
# ─────────────────────────────────────────────────────────────

section "Act 3: Per-Tenant Rate Override"

echo -e "  tenant-globex gets a premium rate for CPU — 3× the default."
echo -e "  We insert a tenant-specific rate that overrides the global one."
echo ""

q "INSERT INTO rates (tenant_id, resource_type, meter_name, koku_metric, cost_type, price_per_unit, currency, description, effective_from)
   VALUES ('tenant-globex', 'compute_instance', 'vm_cpu_core_seconds', 'cpu_core_request_per_hour', 'Supplementary',
           0.015 / 3600, 'USD', 'Premium CPU rate for Globex', NOW())
   ON CONFLICT DO NOTHING;"

echo -e "  ${GREEN}✓${RESET} Tenant-specific rate inserted."
echo ""

echo -e "  ${BOLD}Rate lookup comparison:${RESET}"
q "SELECT
     COALESCE(tenant_id, '(global)') as scope,
     meter_name,
     round(price_per_unit::numeric, 10) as price_per_unit,
     description
   FROM rates
   WHERE resource_type = 'compute_instance' AND meter_name = 'vm_cpu_core_seconds'
   ORDER BY tenant_id NULLS FIRST;"

echo ""
echo -e "  Sending identical VM events for both tenants..."

send_event "osac.compute_instance.lifecycle" \
  "demo-acme-$(date +%s)" \
  "tenant-acme" \
  "{
    \"duration_seconds\": 60,
    \"cpu_core_seconds\": 240,
    \"memory_gib_seconds\": 960,
    \"tenant_id\": \"tenant-acme\",
    \"instance_id\": \"demo-override-acme\",
    \"template\": \"osac.templates.ocp_virt_vm\",
    \"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\",
    \"cores\": 4,
    \"memory_gib\": 16
  }"

send_event "osac.compute_instance.lifecycle" \
  "demo-globex-$(date +%s)" \
  "tenant-globex" \
  "{
    \"duration_seconds\": 60,
    \"cpu_core_seconds\": 240,
    \"memory_gib_seconds\": 960,
    \"tenant_id\": \"tenant-globex\",
    \"instance_id\": \"demo-override-globex\",
    \"template\": \"osac.templates.ocp_virt_vm\",
    \"state\": \"COMPUTE_INSTANCE_STATE_RUNNING\",
    \"cores\": 4,
    \"memory_gib\": 16
  }"

echo -e "  ${GREEN}✓${RESET} Events sent. Waiting for rating sweep..."
sleep 35

echo ""
echo -e "  ${BOLD}CPU cost comparison — same usage, different rates:${RESET}"
q "SELECT ce.tenant_id,
          ce.meter_name,
          round(ce.metered_value::numeric, 2) as metered,
          round(r.price_per_unit::numeric, 10) as rate,
          round(ce.cost_amount::numeric, 8) as cost,
          CASE WHEN r.tenant_id IS NOT NULL THEN 'tenant override' ELSE 'global default' END as rate_source
   FROM cost_entries ce
   JOIN rates r ON ce.rate_id = r.id
   WHERE ce.resource_id IN ('demo-override-acme', 'demo-override-globex')
     AND ce.meter_name = 'vm_cpu_core_seconds'
   ORDER BY ce.tenant_id;"

echo -e "  ${DIM}Same 240 core·seconds, but Globex pays 3× more due to tenant override.${RESET}"

pause

# ─────────────────────────────────────────────────────────────
# ACT 4: Tiered pricing
# ─────────────────────────────────────────────────────────────

section "Act 4: Tiered Pricing"

echo -e "  MaaS token pricing with tiers:"
echo -e "    • First 1M tokens:  free"
echo -e "    • 1M to 10M:        \$0.30 per million"
echo -e "    • Above 10M:        \$0.20 per million"
echo ""

q "UPDATE rates SET tiers = '[
     {\"up_to\": 1000000,  \"price_per_unit\": 0},
     {\"up_to\": 10000000, \"price_per_unit\": 0.0000003},
     {\"up_to\": null,     \"price_per_unit\": 0.0000002}
   ]'::jsonb,
   price_per_unit = 0,
   description = 'Tiered: first 1M free, 1-10M at \$0.30/M, 10M+ at \$0.20/M'
   WHERE resource_type = 'model'
     AND meter_name = 'maas_tokens_in'
     AND tenant_id IS NULL;"

echo -e "  ${GREEN}✓${RESET} Tiered rate configured."
echo ""

echo -e "  ${BOLD}Rate definition with tiers:${RESET}"
q "SELECT meter_name, description, tiers
   FROM rates
   WHERE resource_type = 'model' AND meter_name = 'maas_tokens_in' AND tenant_id IS NULL;"

echo ""
echo -e "  Sending 3 MaaS events with increasing token counts..."

# Small event — within free tier
send_event "osac.model.lifecycle" \
  "demo-tier-small-$(date +%s)" \
  "tenant-acme" \
  "{
    \"model_name\": \"llama-3-70b\",
    \"model_id\": \"demo-tier-model\",
    \"tenant_id\": \"tenant-acme\",
    \"tokens_in\": 500000,
    \"tokens_out\": 100000,
    \"request_count\": 50,
    \"duration_seconds\": 60,
    \"state\": \"MODEL_STATE_RUNNING\"
  }"

# Medium event — spans free + second tier
send_event "osac.model.lifecycle" \
  "demo-tier-med-$(date +%s)" \
  "tenant-acme" \
  "{
    \"model_name\": \"llama-3-70b\",
    \"model_id\": \"demo-tier-model-med\",
    \"tenant_id\": \"tenant-acme\",
    \"tokens_in\": 5000000,
    \"tokens_out\": 500000,
    \"request_count\": 200,
    \"duration_seconds\": 60,
    \"state\": \"MODEL_STATE_RUNNING\"
  }"

# Large event — spans all three tiers
send_event "osac.model.lifecycle" \
  "demo-tier-large-$(date +%s)" \
  "tenant-acme" \
  "{
    \"model_name\": \"llama-3-70b\",
    \"model_id\": \"demo-tier-model-lg\",
    \"tenant_id\": \"tenant-acme\",
    \"tokens_in\": 15000000,
    \"tokens_out\": 1000000,
    \"request_count\": 500,
    \"duration_seconds\": 60,
    \"state\": \"MODEL_STATE_RUNNING\"
  }"

echo -e "  ${GREEN}✓${RESET} Events sent. Waiting for rating sweep..."
sleep 35

echo ""
echo -e "  ${BOLD}Tiered pricing results:${RESET}"
q "SELECT ce.resource_id,
          round(ce.metered_value::numeric, 0) as tokens_in,
          round(ce.cost_amount::numeric, 6) as cost,
          ce.currency
   FROM cost_entries ce
   WHERE ce.meter_name = 'maas_tokens_in'
     AND ce.resource_id LIKE 'demo-tier-model%'
   ORDER BY ce.metered_value;"

echo -e "  ${BOLD}Expected math:${RESET}"
echo -e "  ${DIM}  500K tokens:  all in free tier                          = \$0.00${RESET}"
echo -e "  ${DIM}  5M tokens:    1M free + 4M × \$0.30/M                   = \$1.20${RESET}"
echo -e "  ${DIM}  15M tokens:   1M free + 9M × \$0.30/M + 5M × \$0.20/M   = \$3.70${RESET}"

pause

# ─────────────────────────────────────────────────────────────
# ACT 5: Koku cost_type split
# ─────────────────────────────────────────────────────────────

section "Act 5: Koku-Compatible Cost Type Split"

echo -e "  Every cost entry carries a ${BOLD}cost_type${RESET} from the rate definition."
echo -e "  This enables the Infrastructure/Supplementary split that Koku uses."
echo ""

q "SELECT r.cost_type,
          r.koku_metric,
          count(*) as entries,
          round(sum(ce.cost_amount)::numeric, 6) as total_cost,
          ce.currency
   FROM cost_entries ce
   JOIN rates r ON ce.rate_id = r.id
   WHERE ce.resource_id LIKE 'demo-%'
   GROUP BY r.cost_type, r.koku_metric, ce.currency
   ORDER BY r.cost_type, r.koku_metric;"

echo ""
echo -e "  ${BOLD}Summary by cost type:${RESET}"
q "SELECT r.cost_type,
          round(sum(ce.cost_amount)::numeric, 6) as total,
          ce.currency
   FROM cost_entries ce
   JOIN rates r ON ce.rate_id = r.id
   WHERE ce.resource_id LIKE 'demo-%'
   GROUP BY r.cost_type, ce.currency
   ORDER BY r.cost_type;"

echo -e "  ${DIM}Infrastructure = base resource cost (uptime, nodes)${RESET}"
echo -e "  ${DIM}Supplementary  = usage-based cost (CPU, memory, tokens)${RESET}"

# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────

section "Done"
echo -e "  Demo resources created with 'demo-' prefix."
echo -e "  To clean up:"
echo -e "    ${DIM}docker exec cost-db psql -U user -d costdb -c \"DELETE FROM cost_entries WHERE resource_id LIKE 'demo-%';\"${RESET}"
echo -e "    ${DIM}docker exec cost-db psql -U user -d costdb -c \"DELETE FROM metering_entries WHERE resource_id LIKE 'demo-%';\"${RESET}"
echo -e "    ${DIM}docker exec cost-db psql -U user -d costdb -c \"DELETE FROM rates WHERE tenant_id = 'tenant-globex';\"${RESET}"
echo -e "    ${DIM}docker exec cost-db psql -U user -d costdb -c \"UPDATE rates SET tiers = NULL, price_per_unit = 0.50/1000000, description = '' WHERE meter_name = 'maas_tokens_in' AND tenant_id IS NULL;\"${RESET}"
echo ""
