# Scheduled Chargeback Export via Kubernetes CronJob

> **Requirement:** [REQ-5 — Chargeback Reporting](../requirements/poc_requirements_overview.md#req-5--chargeback-reporting)
>
> **Question for PM:** Does a CronJob-based approach (calling the existing
> report API on a schedule) satisfy the "exportable in standard formats"
> acceptance criterion, or is a built-in scheduler required?

## Approach

The cost consumer already exposes a report API that supports CSV and
JSON export:

```
GET /api/v1/reports/costs?format=csv&group_by=tenant
GET /api/v1/reports/costs?format=json&group_by=meter&tenant_id=acme-corp
```

Rather than building a scheduler into the application, we use a
Kubernetes CronJob to call this API on a schedule and store the output.
This is the standard OpenShift pattern for periodic tasks and avoids
adding scheduling complexity to the cost consumer.

## Supported Query Parameters

| Parameter | Values | Default |
|---|---|---|
| `format` | `csv`, `json` | `json` |
| `group_by` | `tenant`, `resource_type`, `meter`, `resource`, `project` | `tenant` |
| `tenant_id` | filter to specific tenant | (all) |
| `resource_type` | filter to specific type | (all) |
| `from` | ISO 8601 start date | start of current month |
| `to` | ISO 8601 end date | now |

## Example CronJob

The following CronJob runs daily at 06:00 and exports the previous
day's costs as CSV to a PVC:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cost-chargeback-export
  namespace: cost-mgmt
spec:
  schedule: "0 6 * * *"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: export
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              set -e
              YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
              TODAY=$(date -u +%Y-%m-%d)
              FILENAME="chargeback-${YESTERDAY}.csv"

              echo "Exporting chargeback report for ${YESTERDAY}..."
              curl -sf \
                "http://cost-event-consumer:8020/api/v1/reports/costs?format=csv&group_by=tenant&from=${YESTERDAY}T00:00:00Z&to=${TODAY}T00:00:00Z" \
                -o "/export/${FILENAME}"

              echo "Saved to /export/${FILENAME}"
              ls -la "/export/${FILENAME}"
            volumeMounts:
            - name: export-volume
              mountPath: /export
          volumes:
          - name: export-volume
            persistentVolumeClaim:
              claimName: cost-export-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cost-export-pvc
  namespace: cost-mgmt
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

## Variants

### JSON with per-meter breakdown

```yaml
command:
- /bin/sh
- -c
- |
  curl -sf \
    "http://cost-event-consumer:8020/api/v1/reports/costs?format=json&group_by=meter" \
    -o "/export/chargeback-$(date -u +%Y-%m-%d)-meters.json"
```

### Per-tenant reports

```yaml
command:
- /bin/sh
- -c
- |
  for tenant in $(curl -sf "http://cost-event-consumer:8020/api/v1/reports/costs?format=json&group_by=tenant" | jq -r '.data[].group'); do
    curl -sf \
      "http://cost-event-consumer:8020/api/v1/reports/costs?format=csv&group_by=meter&tenant_id=${tenant}" \
      -o "/export/chargeback-$(date -u +%Y-%m-%d)-${tenant}.csv"
  done
```

### S3 upload (instead of PVC)

Replace the PVC volume with an S3-compatible upload using `mc` or
`aws s3 cp`:

```yaml
image: minio/mc:latest
command:
- /bin/sh
- -c
- |
  curl -sf "http://cost-event-consumer:8020/api/v1/reports/costs?format=csv&group_by=tenant" \
    -o /tmp/chargeback.csv
  mc alias set s3 $S3_ENDPOINT $S3_ACCESS_KEY $S3_SECRET_KEY
  mc cp /tmp/chargeback.csv s3/cost-reports/chargeback-$(date -u +%Y-%m-%d).csv
```

## Testing

Verified on k3d cluster `cost-test`:

```bash
# Quick test — run the export as a one-shot Job
kubectl create job --from=cronjob/cost-chargeback-export test-export -n cost-mgmt

# Check output
kubectl logs job/test-export -n cost-mgmt
```

## Delivery Methods

The CronJob pattern is flexible — the export step can deliver reports
via any mechanism. Common options:

| Method | How | Precedent |
|---|---|---|
| **S3 / MinIO** | `mc cp` or `aws s3 cp` to a bucket | Koku archives daily CSVs to S3 (`create_daily_archives`) |
| **PVC** | Write to a PersistentVolumeClaim | Standard for on-prem without object storage |
| **HTTP POST** | `curl -X POST` to a webhook or BI tool ingest endpoint | Pau noted customers export to BI/FinOps tools (slides 33-34) |
| **Email** | Pipe through `sendmail` or an SMTP relay container | Common for executive chargeback summaries |
| **Slack / Teams** | Post CSV as a snippet via webhook | Quick visibility for ops teams |
| **Shared filesystem** | NFS mount, write CSV for downstream pickup | Integration with legacy billing systems |

For production, **S3 is the recommended default** — it's what Koku uses,
supports lifecycle policies for retention, and integrates with BI tools
(Grafana, Superset, custom dashboards) that can read directly from S3.

For the PoC, PVC or stdout logging is sufficient to demonstrate the
capability.

## Limitations

- No built-in retention policy — old exports accumulate on the PVC.
  Add a cleanup step or use S3 lifecycle rules.
- No email/webhook delivery — the CronJob writes to storage only.
  For push delivery, wrap in a script that posts to Slack/email.
- Date range queries depend on the consumer's data retention.

## Related

- [Report API reference](../api-reference.md)
- [REQ-5 spec](../requirements/poc_requirements_overview.md#req-5--chargeback-reporting)
- Pau's PR #33 notes: "Export in FOCUS format (though highly desirable)"
  — FOCUS export is not implemented; CSV/JSON only for now.
