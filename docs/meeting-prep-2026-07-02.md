# Meeting Prep — 2026-07-02

## OpenShift/CRC Deployment Implementation

### Summary

Implemented minimal OpenShift deployment for cost-event-consumer, successfully tested on local CRC (CodeReady Containers). The service is now containerized and running in OpenShift with PostgreSQL backend.

### What Was Completed

1. **Health Check Endpoints** (Step 2 from deployment plan)
   - Added `/healthz` (liveness probe) - returns 200 OK if service is running
   - Added `/readyz` (readiness probe) - returns 200 OK when ready for traffic
   - Modified: `inventory-watcher/internal/ingest/handler.go`

2. **Container Image** (Step 1 from deployment plan)
   - Created `inventory-watcher/Containerfile`
   - Multi-stage build: UBI10 go-toolset → ubi10-minimal runtime
   - Workaround: `GOTOOLCHAIN=auto` to download Go 1.26.4 (UBI10 ships with 1.24.6)
   - Built binaries: `cost-event-consumer` and `maas-simulator`
   - Image size: 164MB (45MB compressed)
   - Published to: `quay.io/martin_povolny/cost-event-consumer:latest`

3. **Kubernetes Manifests** (Step 3 from deployment plan)
   - Created `deploy/k8s/` directory with:
     - `namespace.yaml` - creates `cost-mgmt` namespace
     - `postgres.yaml` - StatefulSet with 1Gi PVC, pg_isready probes
     - `consumer.yaml` - Deployment with health probes, resource limits, Service
   - Secrets for DB credentials and OSAC token (created via oc CLI)

4. **CRC Deployment** (Step 4 from deployment plan)
   - Created `oc.sh` wrapper script for CRC environment setup
   - Deployed PostgreSQL StatefulSet - **running successfully**
   - Deployed cost-event-consumer Deployment - **running successfully**
   - Verified health endpoints via port-forward: both return 200 OK
   - Created `deploy/k8s/README.md` with deployment guide

5. **Documentation**
   - `deploy/k8s/README.md` - Quick start guide, status, test commands
   - Committed all changes to `openshift-deployment` branch

### Current State in CRC

```
NAME                                   READY   STATUS    RESTARTS   AGE
cost-db-0                              1/1     Running   0          63m
cost-event-consumer-7b9bf46fb5-646xv   1/1     Running   0          20s
```

**Service is functional:**
- ✅ Health probes working (`/healthz`, `/readyz`)
- ✅ PostgreSQL connected (tables auto-created on startup)
- ✅ HTTP API listening on port 8020
- ✅ Dashboard accessible via port-forward
- ⏸️  OSAC integration errors (expected - fulfillment-service not deployed)

### Registry Note

Used `quay.io/martin_povolny/cost-event-consumer` instead of planned `quay.io/cost-mgmt/cost-event-consumer` (the `cost-mgmt` org doesn't exist yet or we don't have access).

### What's NOT Done Yet (from deployment plan)

- Step 5: Deploy OSAC fulfillment-service in CRC (requires cert-manager, Keycloak, PostgreSQL for OSAC)
- Step 7: Prometheus metrics endpoint (exists in code but no ServiceMonitor manifest)
- Step 8: Helm chart extraction (still using plain manifests)

### Next Steps

1. **For full integration testing:** Deploy OSAC fulfillment-service in CRC
   - Requires: cert-manager, trust-manager, Keycloak operator, PostgreSQL
   - Use OSAC's production Helm chart with CRC values override
   
2. **For production readiness:**
   - Extract Helm chart from working manifests
   - Add ServiceMonitor for Prometheus scraping
   - Set up proper `cost-mgmt` org on quay.io

3. **For CI/CD:**
   - Add GitHub Actions / Tekton pipeline to build & push on merge
   - Tag images with git SHA (not just `latest`)

### Files Changed

```
A  deploy/k8s/README.md              # Deployment guide
A  deploy/k8s/consumer.yaml          # Consumer Deployment + Service
A  deploy/k8s/deploy-crc.sh          # Automated deploy script (untested)
A  deploy/k8s/namespace.yaml         # Namespace manifest
A  deploy/k8s/postgres.yaml          # PostgreSQL StatefulSet + Service
A  inventory-watcher/Containerfile   # Multi-stage build
M  inventory-watcher/internal/ingest/handler.go  # Health endpoints
A  oc.sh                             # CRC oc wrapper
```

Commit: `109c170` on `openshift-deployment` branch
