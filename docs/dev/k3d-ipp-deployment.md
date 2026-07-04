# k3d IPP Gateway Deployment — Troubleshooting & Discovery Notes

> Notes from deploying the full IPP gateway stack on k3d (local Mac).
> Date: 2026-07-04

## Setup

```bash
# k3d must be created WITHOUT Traefik to avoid Gateway API CRD conflicts
k3d cluster create cost-test \
    --port "18020:8020@loadbalancer" \
    --port "18080:8080@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
```

## Image Building on ARM Mac → k3d (amd64)

### Problem: OCI index manifests

Docker buildx on ARM creates OCI image index manifests by default
(including attestation layers). k3d's containerd can't resolve these —
images show as `unavailable (0/?)` in `ctr images check`.

### Solution: Disable attestations

```bash
docker buildx build --platform linux/amd64 \
    --provenance=false --sbom=false \
    --output type=docker \
    -t myimage:latest -f Dockerfile .
```

Key flags:
- `--provenance=false --sbom=false` — prevents OCI index with attestation
  layers
- `--output type=docker` — forces Docker v2 manifest (not OCI index)

Then import:
```bash
docker save myimage:latest | docker exec -i k3d-cost-test-server-0 ctr images import -
```

Verify with:
```bash
docker exec k3d-cost-test-server-0 ctr images check | grep myimage
# Should show "complete (N/N)" not "unavailable (0/?)"
```

### DO NOT use `k3d image import` for cross-platform images

`k3d image import` may not correctly handle cross-platform images.
Use `docker save | ctr images import` directly instead.

## Kubernetes Service Name Collisions with Env Vars

### Problem: llm-katan crashes on startup

```
ValueError: invalid literal for int() with base 10: 'tcp://10.43.2.251:8000'
```

Kubernetes auto-creates `{SERVICE_NAME}_PORT` env vars (e.g.,
`LLM_KATAN_PORT=tcp://10.43.2.251:8000`). llm-katan reads
`LLM_KATAN_PORT` as an integer for its listen port.

### Solution: Override the env var explicitly

```yaml
containers:
  - name: katan
    env:
      - name: LLM_KATAN_PORT
        value: "8000"
```

General rule: if a service name matches an app's env var prefix,
override the conflicting vars in the Deployment spec.

## Envoy Gateway

### Installation

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.4.0 \
    -n envoy-gateway-system --create-namespace \
    --wait --timeout 180s
```

Requires k3d without Traefik (Traefik installs its own Gateway API
CRDs which conflict).

## IPP Image (with external-metering)

### Problem: Pre-built image lacks external-metering

The `quay.io/opendatahub/odh-ai-gateway-payload-processing:odh-stable`
image does NOT include the `external-metering` plugin — it's in
[PR #320](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/320),
not merged to main yet.

### Solution: Build from PR #320

```bash
cd ~/Projects/ai-gateway-payload-processing
git fetch origin pull/320/head:feat/external-metering-dp
git checkout feat/external-metering-dp

# Cross-compile for amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 GOTOOLCHAIN=auto go build -o /tmp/bbr ./cmd

# Build image
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
    --output type=docker -t ipp-metering:latest -f - /tmp <<'EOF'
FROM registry.access.redhat.com/ubi9-minimal:latest
COPY bbr /bbr
USER 1001
ENTRYPOINT ["/bbr"]
EOF

docker save ipp-metering:latest | docker exec -i k3d-cost-test-server-0 ctr images import -
```

### IPP CLI Flags

Binary: `/bbr` (entrypoint)

| Flag | Default | Description |
|------|---------|-------------|
| `--config-file` | — | Path to PayloadProcessorConfig YAML |
| `--config-text` | — | Config as inline text (alternative to file) |
| `--grpc-port` | 9004 | ext_proc gRPC port |
| `--grpc-health-port` | 9005 | Health probe port |
| `--metrics-port` | 9090 | Prometheus metrics |
| `--secure-serving` | true | TLS for metrics (disable for k3d) |
| `--metrics-endpoint-auth` | true | Auth for metrics (disable for k3d) |

### IPP Config Format

```yaml
apiVersion: config.payload-processor.llm-d.io/v1alpha1
kind: PayloadProcessorConfig
plugins:
- type: external-metering
  name: metering
  parameters:
    meteringURL: "http://cost-event-consumer.cost-mgmt.svc:8020"
    featureKey: "inference-tokens"
    source: "maas-gateway"
    failOpen: true
profiles:
- name: default
  plugins:
    request:
    - pluginRef: metering
    response:
    - pluginRef: metering
```

### External-Metering Plugin Parameters

Source: `pkg/plugins/external-metering/plugin.go`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `meteringURL` | string | **Yes** | — | Base URL for checkBalance and reportUsage |
| `featureKey` | string | No | `"inference-tokens"` | Entitlement key for balance check |
| `source` | string | No | `"maas-gateway"` | CloudEvent source field |
| `failOpen` | bool | No | `true` | Allow requests if metering is down |
| `timeoutSeconds` | int | No | `5` | HTTP client timeout |

## Component Status

| Component | Image | Status |
|-----------|-------|--------|
| Envoy Gateway | `envoyproxy/gateway-helm:v1.4.0` | Installed via Helm |
| llm-katan | `localhost/llm-katan:latest` | Running (echo mode) |
| IPP | `ipp-metering:latest` | Built from PR #320 |
| Cost consumer | `cost-consumer:latest` | Built from repo |
| PostgreSQL | TBD | Not deployed yet |

## Progress — What Works

1. **Envoy Gateway** — installed, Gateway `Programmed: True`
2. **llm-katan** — running echo mode, serving OpenAI-compatible API
3. **IPP (PR #320)** — running, gRPC on 9004, controllers started
4. **Cost consumer** — running, ingest endpoint on 8020
5. **Direct routing** — Gateway → llm-katan works, returns inference responses
6. **RBAC** — IPP has cluster-level permissions for ExternalModel/ExternalProvider CRDs

## Remaining Issue — ext_proc Timeout

When `EnvoyExtensionPolicy` enables ext_proc, requests get
`504 Gateway Timeout` with `ext_proc_error_per-message_timeout_exceeded`.

The IPP receives NO log entries from the request — the gRPC ext_proc
connection may not be completing before Envoy's default 200ms per-message
timeout.

**Tried:**
- `Streamed` body mode → timeout
- `Buffered` body mode → hangs
- `messageTimeout: 10s` → no effect (may not be the right API field)

**Root cause hypothesis:**
- The IPP binary from PR #320 may need a `kubeconfig` or in-cluster
  config to function — it uses controller-runtime which expects K8s API
  access. The ext_proc gRPC handler may not start until the controller
  manager is fully running.
- The EnvoyExtensionPolicy `messageTimeout` field may have a different
  name in v1alpha1. Check Envoy Gateway docs for the correct timeout
  configuration.

**Next steps:**
1. Check if IPP ext_proc gRPC is actually accepting connections:
   `grpcurl -plaintext localhost:9004 list`
2. Check if Envoy Gateway v1.4.0 EnvoyExtensionPolicy supports
   `messageTimeout` or if it needs `EnvoyProxy` resource customization
3. Try with `--v=5` on IPP for verbose logging

## Config API Version

The PayloadProcessorConfig uses:
```
apiVersion: llm-d.ai/v1alpha1
kind: PayloadProcessorConfig
```

NOT `config.payload-processor.llm-d.io/v1alpha1` (which was in earlier
documentation).
