# kube-cost-agent

A lightweight Kubernetes controller that watches billable resources and
emits CloudEvents to the [cost-event-consumer](../inventory-watcher/) for
metering, rating, and cost reporting.

Complementary to OSAC — tracks what runs *inside* clusters (pods, nodes,
PVCs, load balancers), not the provisioned capacity from the management plane.

## What it watches

| Resource | Event types | Key data |
|---|---|---|
| **Pods** | `kube.pod.lifecycle`, `kube.pod.heartbeat` | CPU/memory requests, GPU count, QoS, owner |
| **Nodes** | `kube.node.lifecycle`, `kube.node.heartbeat` | Instance type, zone, capacity, spot |
| **PVCs** | `kube.pvc.lifecycle` | Storage class, capacity |
| **LoadBalancer Services** | `kube.service.lifecycle` | External IPs, port count |

All data comes from the Kubernetes API — no Prometheus or metrics-server required.

## Configuration

Via ConfigMap projected as environment variables:

| Variable | Required | Default | Description |
|---|---|---|---|
| `COST_CONSUMER_URL` | Yes | — | Consumer ingest endpoint |
| `COST_CONSUMER_TOKEN` | No | — | Bearer token for auth |
| `CLUSTER_ID` | Yes | — | Unique cluster identifier |
| `TENANT_ID` | No | — | Default tenant (empty = namespace name) |
| `HEARTBEAT_INTERVAL` | No | `60s` | Pod heartbeat period |
| `NODE_RECONCILE_INTERVAL` | No | `5m` | Node heartbeat period |
| `BATCH_SIZE` | No | `100` | Max events per HTTP POST |
| `BATCH_INTERVAL` | No | `5s` | Max delay before flushing |
| `EXCLUDE_NAMESPACES` | No | `kube-system` | Comma-separated namespaces to skip |

## Quick start

### Build and push

```sh
make docker-build docker-push IMG=quay.io/martin_povolny/kube-cost-agent:latest
```

### Deploy to a cluster

```sh
# Edit config/configmap/kube-cost-agent-config.yaml with your consumer URL and cluster ID
make deploy IMG=quay.io/martin_povolny/kube-cost-agent:latest
```

### Run locally (against current kubeconfig)

```sh
export COST_CONSUMER_URL=http://localhost:8020/api/v1/events
export CLUSTER_ID=local-dev
make run
```

### Undeploy

```sh
make undeploy
```

## Development

```sh
make build          # compile binary
make lint           # golangci-lint (with logcheck plugin)
make test           # unit tests
make manifests      # regenerate RBAC from markers
```

## Design

See [docs/design.md](docs/design.md) for the full architecture, CloudEvent
schemas, and consumer-side changes.

## License

Apache License 2.0 — see [LICENSE](../LICENSE).
