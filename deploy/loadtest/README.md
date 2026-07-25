# Load Test — Cost Event Consumer

Kubernetes manifests for generating synthetic MaaS IPP events and OSAC VM
lifecycle traffic against a running cost-event-consumer stack on CRC/OpenShift.

## Prerequisites

- CRC stack is running (`crc status` shows `Running`)
- Consumer, postgres, and OSAC are deployed (`kubectl get pods -n cost-mgmt`)
- OSAC token is current in `cost-consumer-secrets` (run `scripts/refresh-token.sh` if not)
- `kubectl` is configured to reach the cluster

## Deploy

```bash
kubectl apply -f deploy/loadtest/
```

This creates:
- `ConfigMap/loadtest-config` — tunable rates/workers
- `Deployment/maas-traffic-gen` — generates IPP CloudEvents at the ingest endpoint
- `Deployment/osac-traffic-gen` — drives VM lifecycle operations against OSAC REST

Both deployments start with 1 replica. Scale them independently (see below).

## Scale MaaS load

```bash
# 5 replicas × 50 events/s × 8 workers = ~400 events/s total
kubectl scale deployment maas-traffic-gen -n cost-mgmt --replicas=5
```

To change the per-pod rate without redeploying, edit the ConfigMap and restart:

```bash
kubectl edit configmap loadtest-config -n cost-mgmt
kubectl rollout restart deployment/maas-traffic-gen -n cost-mgmt
```

## Scale OSAC load

```bash
# 2 replicas × 1 op/s × 4 workers = ~8 VM lifecycle ops/s
kubectl scale deployment osac-traffic-gen -n cost-mgmt --replicas=2
```

## Watch logs

```bash
# MaaS generator
kubectl logs -f -n cost-mgmt -l app=maas-traffic-gen

# OSAC generator
kubectl logs -f -n cost-mgmt -l app=osac-traffic-gen

# Consumer (to confirm events are being processed)
kubectl logs -f -n cost-mgmt -l app=cost-event-consumer
```

## Stop load

Scale both deployments to zero to stop traffic without removing the manifests:

```bash
kubectl scale deployment maas-traffic-gen osac-traffic-gen -n cost-mgmt --replicas=0
```

## Run sizing analysis

After running load for at least 60 seconds, forward the DB port and run the
sizing script:

```bash
# Forward DB port (leave running in a separate terminal)
kubectl port-forward -n cost-mgmt svc/cost-db 5434:5432

# In another terminal
./scripts/analyze-sizing.sh
```

The script snapshots table sizes at T=0 and T=60s, computes growth rates, and
outputs DB size projections for 100 / 1,000 / 10,000 events/min rate tiers.

## Cleanup

Remove all loadtest resources:

```bash
kubectl delete -f deploy/loadtest/
```

This does not affect the consumer, postgres, or OSAC deployments.

## Tuning reference

| Parameter    | Default | Description                          |
|---|---|---|
| MAAS_RATE    | 50      | IPP events/sec per maas-traffic-gen pod |
| MAAS_WORKERS | 8       | Concurrent sender goroutines per pod |
| OSAC_RATE    | 1       | VM lifecycle ops/sec per osac-traffic-gen pod |
| OSAC_VM_COUNT | 10     | Number of VM identities in rotation  |
| OSAC_WORKERS | 4       | Concurrent sender goroutines per pod |

Edit `deploy/loadtest/configmap.yaml` and re-apply, then rollout restart the
affected deployment(s), to change these values permanently.
