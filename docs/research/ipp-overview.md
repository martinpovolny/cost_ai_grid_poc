# IPP — Inference Platform Plugin Overview

> Background on the OSAC AI gateway plugin chain that produces the MaaS
> metering events we consume.
>
> Date: 2026-07-04

## What It Is

IPP is the **plugin chain inside the OSAC AI gateway** (Envoy-based) that
processes every inference request flowing between clients and LLM
providers. It runs as an Envoy `ext_proc` (external processor) — Envoy
calls it on every request/response passing through the gateway.

**Repos:**
- Plugin implementations: [opendatahub-io/ai-gateway-payload-processing](https://github.com/opendatahub-io/ai-gateway-payload-processing)
- Gateway control plane: [opendatahub-io/ai-gateway](https://github.com/opendatahub-io/ai-gateway)
- External-metering plugin: [PR #320](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/320) (targeting RHOAI 3.5 Dev Preview)

## Request Flow

The gateway sits between users and model providers (Anthropic, OpenAI,
vLLM, etc.). The IPP chain handles everything along the way:

```
Client request
  → Envoy Gateway
    → Authorino (auth: API key or K8s token → identity headers)
    → IPP ext_proc plugin chain:
        1. body-field-to-header    — extract model name from request body
        2. maas-headers-guard      — capture X-MaaS-* headers, strip before forwarding
        3. external-metering       — balance check (before), usage report (after)
        4. model-provider-resolver — resolve model → backend provider
        5. api-translation         — convert between API formats (OpenAI ↔ Anthropic etc.)
        6. apikey-injection        — swap user's key for the provider credential
    → External Provider (Anthropic, OpenAI, vLLM, etc.)
```

## Plugin Chain Detail

### 1. body-field-to-header

Extracts the `model` field from the JSON request body and promotes it to
a header so downstream plugins and routing can access it without parsing
the body again.

### 2. maas-headers-guard

Captures all `X-MaaS-*` headers (username, group, subscription — injected
by Authorino after authentication) into the ext_proc CycleState. Then
**strips** them from the request so they are not leaked to the upstream
model provider.

Source: [maas-headers-guard plugin](https://github.com/opendatahub-io/ai-gateway-payload-processing/tree/main/pkg/plugins/maas-headers-guard)

### 3. external-metering

The plugin we integrate with. Runs **twice per request:**

**On request (before forwarding):**
- Calls `GET /api/v1/customers/{id}/entitlements/{key}/value?model={model}`
  on the configured metering backend
- If `hasAccess: false` → returns `ResourceExhausted` (HTTP 429)
- If metering backend is down + `failOpen: true` → request proceeds anyway

**On response (after completion):**
- Extracts token counts from the provider response (`prompt_tokens`,
  `completion_tokens`, `cached_input_tokens`, `reasoning_tokens`)
- Builds a CloudEvent (`inference.tokens.used`) with identity fields
  from CycleState
- POSTs to `POST /api/v1/events` on the metering backend
- Fire-and-forget (no retry, fail-open)
- For streaming responses, extracts usage from SSE chunks

Source: [external-metering plugin](https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/61b6160/pkg/plugins/external-metering/)

### 4. model-provider-resolver

Resolves the requested model name to a backend provider endpoint. Sets
the `provider` field in CycleState (e.g., "anthropic", "openai", "vllm")
which the metering plugin includes in the CloudEvent.

### 5. api-translation

Converts between provider API formats. A client can send an
OpenAI-format request and the gateway translates it to Anthropic format
(or vice versa) based on the resolved provider.

### 6. apikey-injection

Swaps the user's API key or token for the platform's provider credential.
The user authenticates to the gateway; the gateway authenticates to the
provider with its own keys.

## Where We Fit

The metering backend was originally [OpenMeter](https://openmeter.io/)
(or the [metering-simulator](https://github.com/noyitz/metering-simulator)
mock). **We are a drop-in replacement** — we implement both endpoints
with the same contract:

| Endpoint | Purpose | Our implementation |
|----------|---------|-------------------|
| `GET /api/v1/customers/{id}/entitlements/{key}/value` | Balance check (sync) | `handleBalanceCheck` in handler.go |
| `POST /api/v1/events` | Usage report (async) | `handleEvent` in handler.go |

The IPP plugin just needs its `meteringURL` config pointed at us.

Contract verified against:
- [IPP client.go struct tags](https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/61b6160/pkg/plugins/external-metering/client.go)
- [Metering-simulator OpenAPI spec](https://github.com/noyitz/metering-simulator/blob/main/openapi.yaml)

## Identity / Attribution

The CloudEvent identity fields and their mapping to OSAC tenant/project
are documented in [maas-tenant-attribution.md](maas-tenant-attribution.md).

Short version: `subscription` field carries `{namespace}/{name}` where
namespace = OSAC tenant. No `tenant_id` or `project_id` in the event.

## Testing Without the Full Gateway

For testing our cost pipeline without deploying the full OSAC gateway
stack:

1. **Our MaaS simulator** (`cmd/maas-simulator`) emits IPP-compatible
   CloudEvents directly to our ingest endpoint
2. **llm-katan** (`pip install llm-katan`) can serve as the mock LLM
   endpoint if testing the full gateway chain
3. **metering-simulator** is the reference implementation of the two
   metering endpoints we replace

For end-to-end testing with the real gateway, Noy's team has a dogfood
environment with live Claude Code and Codex sessions flowing through.
