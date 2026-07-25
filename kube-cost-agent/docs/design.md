# Kubernetes Cost Agent — Design

A lightweight controller that watches billable Kubernetes resources and
emits CloudEvents to the cost-event-consumer for metering, rating, and
cost reporting.

## Goals

- **Complementary to OSAC.** OSAC tracks provisioned capacity (VMs,
  clusters, bare metal) from the management plane. This agent tracks
  what runs *inside* clusters — pods, storage, networking.
- **API-only, no Prometheus dependency.** All billable data comes from
  the Kubernetes API server. No metrics-server, no scraping, no eBPF.
- **Bill on requests, not usage.** Charges for reserved capacity
  (`resources.requests`), not actual consumption. Simpler, more
  conservative, and deterministic.
- **CloudEvents output.** Same format as OSAC and MaaS events — the
  consumer already handles `POST /api/v1/events`.

## Billable Resources

| Resource | Cost share | What we track | Data source |
|---|---|---|---|
| **Pods** | 60-70% | CPU/memory requests × duration | Pod specs via Watch API |
| **Nodes** | Foundation | Instance type, zone, capacity, uptime | Node objects via Watch API |
| **PVCs** | 10-20% | Provisioned capacity × storage class | PVC specs via Watch API |
| **LoadBalancer Services** | Per-unit | Each LB = discrete cloud cost | Service objects (type=LB) |
| **GPU** | Variable | `nvidia.com/gpu` limits on pods | Pod specs (resource limits) |
| **Namespaces** | Metadata | Billing boundaries, labels | Namespace objects |

### Not in scope (PoC)

- **Network egress** — needs privileged DaemonSet + eBPF
- **Actual CPU/memory usage** — needs metrics-server
- **GPU utilization %** — needs DCGM exporter
- **Cloud provider pricing** — needs billing API integration
- **Control plane fees** — fixed per-cluster, from cloud billing

## CloudEvent Schema

### Event types

| Type | Trigger | Description |
|---|---|---|
| `kube.pod.lifecycle` | Watch ADDED/DELETED | Pod created or deleted |
| `kube.pod.heartbeat` | Periodic (60s) | Running pod still alive |
| `kube.node.lifecycle` | Watch ADDED/DELETED | Node joined or left |
| `kube.node.heartbeat` | Periodic (5min) | Node capacity snapshot |
| `kube.pvc.lifecycle` | Watch ADDED/DELETED | Storage provisioned/released |
| `kube.service.lifecycle` | Watch (LB only) | LoadBalancer created/deleted |

### Common envelope

All events follow CloudEvents 1.0:

```json
{
  "specversion": "1.0",
  "type": "kube.pod.lifecycle",
  "source": "kube-cost-agent/<cluster-name>",
  "id": "<uuid>",
  "time": "2026-07-24T12:00:00Z",
  "subject": "<namespace>/<pod-name>",
  "data": { ... }
}
```

### Pod lifecycle event data

```json
{
  "action": "CREATED",
  "cluster_id": "prod-east-1",
  "namespace": "team-alpha",
  "pod_name": "api-server-7b4f5-x9k2p",
  "node_name": "worker-3",
  "cpu_request_millicores": 500,
  "memory_request_bytes": 536870912,
  "cpu_limit_millicores": 1000,
  "memory_limit_bytes": 1073741824,
  "gpu_count": 0,
  "qos_class": "Burstable",
  "owner_kind": "Deployment",
  "owner_name": "api-server",
  "labels": {
    "app": "api-server",
    "team": "alpha",
    "cost-center": "engineering"
  }
}
```

### Pod heartbeat event data

```json
{
  "cluster_id": "prod-east-1",
  "namespace": "team-alpha",
  "pod_name": "api-server-7b4f5-x9k2p",
  "cpu_request_millicores": 500,
  "memory_request_bytes": 536870912,
  "duration_seconds": 60,
  "tenant_id": "tenant-acme"
}
```

### Node lifecycle event data

```json
{
  "action": "CREATED",
  "cluster_id": "prod-east-1",
  "node_name": "worker-3",
  "instance_type": "m5.2xlarge",
  "zone": "us-east-1a",
  "region": "us-east-1",
  "cpu_capacity_millicores": 8000,
  "memory_capacity_bytes": 34359738368,
  "gpu_capacity": 0,
  "allocatable_cpu_millicores": 7800,
  "allocatable_memory_bytes": 33285996544,
  "is_spot": false,
  "labels": {}
}
```

### PVC lifecycle event data

```json
{
  "action": "CREATED",
  "cluster_id": "prod-east-1",
  "namespace": "team-alpha",
  "pvc_name": "data-postgres-0",
  "storage_class": "gp3",
  "capacity_bytes": 107374182400,
  "access_mode": "ReadWriteOnce",
  "phase": "Bound"
}
```

### LoadBalancer service event data

```json
{
  "action": "CREATED",
  "cluster_id": "prod-east-1",
  "namespace": "team-alpha",
  "service_name": "api-gateway",
  "external_ips": ["52.1.2.3"],
  "port_count": 2
}
```

## Architecture

```
┌──────────────────────────────────────────────┐
│              Workload Cluster                 │
│                                              │
│  ┌────────────────────────────┐              │
│  │     kube-cost-agent        │              │
│  │                            │              │
│  │  Informers:                │              │
│  │   - Pods (all namespaces)  │              │
│  │   - Nodes                  │              │
│  │   - PVCs                   │              │
│  │   - Services               │              │
│  │                            │              │
│  │  Heartbeat ticker (60s)    │              │
│  │   - scan running pods      │              │
│  │   - emit duration events   │              │
│  │                            │              │
│  │  Config:                   │              │
│  │   COST_CONSUMER_URL        │              │
│  │   CLUSTER_ID               │              │
│  │   TENANT_ID                │              │
│  └──────────┬─────────────────┘              │
│             │ POST /api/v1/events            │
└─────────────┼────────────────────────────────┘
              │ CloudEvents (HTTPS)
              ▼
┌──────────────────────────────────────────────┐
│         cost-event-consumer                  │
│                                              │
│  New handlers:                               │
│   handlePodEvent()                           │
│   handleNodeEvent()                          │
│   handlePVCEvent()                           │
│   handleServiceEvent()                       │
│                                              │
│  Metering:                                   │
│   pod_cpu_request_seconds                    │
│   pod_memory_request_gib_seconds             │
│   node_uptime_seconds                        │
│   pvc_capacity_gib_hours                     │
│   lb_uptime_hours                            │
└──────────────────────────────────────────────┘
```

## Controller Design

### Informers (client-go SharedInformerFactory)

The agent uses standard Kubernetes informers for efficient Watch + List:

- **Pod informer** — all namespaces, filters to Running phase
- **Node informer** — all nodes
- **PVC informer** — all namespaces
- **Service informer** — filtered to type LoadBalancer

Each informer registers `AddFunc`, `UpdateFunc`, `DeleteFunc` handlers
that construct and send CloudEvents.

### Heartbeat sweep

A ticker fires every 60 seconds. For each pod currently in the informer
cache that is in Running phase:

1. Calculate `duration_seconds` since last heartbeat (or since creation
   for the first heartbeat)
2. Emit a `kube.pod.heartbeat` CloudEvent with the pod's resource requests

This is the same pattern as the cost-event-consumer's metering sweep.

### Tenant/namespace mapping

The agent needs to map Kubernetes namespaces to cost tenants. Options:

1. **Label-based** — namespace label `cost.redhat.com/tenant-id`
2. **Config map** — `ConfigMap` in the agent's namespace with ns→tenant mapping
3. **Default** — namespace name = tenant_id (simplest for PoC)

### Delivery

- **HTTP POST** to the consumer's `/api/v1/events` endpoint
- **Batch buffering** — accumulate events for 1-5 seconds, send as batch
- **Retry with backoff** on failure (same pattern as Splunk forwarder)
- **Bearer token auth** if consumer has auth enabled

### RBAC

Minimal ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-cost-agent
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "persistentvolumeclaims", "services", "namespaces"]
    verbs: ["get", "list", "watch"]
```

No write access. No CRDs. No privileged containers.

## Configuration

| Env var | Required | Default | Description |
|---|---|---|---|
| `COST_CONSUMER_URL` | Yes | — | `https://consumer:8020/api/v1/events` |
| `COST_CONSUMER_TOKEN` | No | — | Bearer token for auth |
| `CLUSTER_ID` | Yes | — | Unique cluster identifier |
| `TENANT_ID` | No | — | Default tenant (overridden by ns labels) |
| `HEARTBEAT_INTERVAL` | No | `60s` | Pod heartbeat interval |
| `NODE_RECONCILE_INTERVAL` | No | `5m` | Node reconciliation interval |
| `BATCH_SIZE` | No | `100` | Max events per HTTP POST |
| `BATCH_INTERVAL` | No | `5s` | Max delay before flushing batch |

## Consumer-Side Changes

New event type handlers needed in the cost-event-consumer:

1. **`kube.pod.lifecycle`** — upsert pod in inventory, create/delete metering
2. **`kube.pod.heartbeat`** — create metering entries for duration
3. **`kube.node.lifecycle`** — upsert node in inventory
4. **`kube.pvc.lifecycle`** — upsert PVC in inventory, meter storage
5. **`kube.service.lifecycle`** — upsert LB in inventory, meter uptime

New inventory tables:
- `inventory_kube_pod`
- `inventory_kube_node`
- `inventory_kube_pvc`
- `inventory_kube_lb_service`

New meters:
- `pod_cpu_request_core_seconds`
- `pod_memory_request_gib_seconds`
- `node_uptime_seconds`
- `pvc_capacity_gib_hours`
- `lb_uptime_hours`

## Project Structure

```
kube-cost-agent/
  cmd/agent/main.go          Entry point
  internal/
    controller/controller.go  Informer setup + event handling
    emitter/emitter.go        CloudEvent construction + HTTP delivery
    config/config.go          Environment variable config
  docs/
    design.md                 This document
  go.mod
  go.sum
  Containerfile
```

## Related

- [COST-3874](https://redhat.atlassian.net/browse/COST-3874) — "Provide pod-level data"
- [OpenCost Specification](https://opencost.io/docs/specification/)
- [OpenMeter Kubernetes Collector](https://openmeter.io/docs/collectors/kubernetes)
- [ADR-001](../docs/decisions/001-metering-sweep-interval.md) — metering sweep interval (same heartbeat pattern)
