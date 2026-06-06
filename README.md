# CloudSleuth

Multi-region disaster recovery on AWS with a predictive failover layer. The target is sub-60s RTO — the kind of number that shows up in fintech and healthcare SLAs. Primary in us-east-1, pilot light secondary in us-west-2, Global Accelerator in front of both.

## Design

Most DR is reactive: health check fails, traffic shifts, users wait through cold-start. CloudSleuth moves the decision point earlier. A statistical anomaly detector watches CloudWatch metrics every minute and begins graduated failover actions before any health check goes red. By the time the health check fails, the secondary is already warm.

All decisions are deterministic (EWMA baselines, z-scores, composite scoring). Bedrock is optional and only generates human-readable alert narrative — it doesn't touch the decision path.

## Regions

```
Primary (us-east-1)                      Secondary (us-west-2)
┌──────────────────┐                     ┌──────────────────┐
│  EC2 (active)    │                     │  EC2 (stopped)   │
│  web workload    │                     │  pilot light     │
└────────┬─────────┘                     └────────┬─────────┘
         │                                        │
    CloudWatch metrics                       pre-staged AMI

    ┌──────────────────────────────────────────┐
    │  AWS Global Accelerator                  │
    │  anycast IPs → traffic dials: 100/0 ↔ 0/100 │
    └──────────────────────────────────────────┘
```

Global Accelerator gives static anycast IPs — no DNS TTL to wait out. When the failover document shifts traffic weights, propagation is sub-second. Route53 health checks still exist as an independent reactive layer; they're not the primary detection mechanism.

Pilot light was chosen deliberately: zero idle compute cost, compensated for by the predictive warm-up. The anomaly detector starts the secondary instance as a pre-emptive action — so cold-start doesn't eat into RTO.

## Anomaly Detector

Lambda on a 1-minute EventBridge schedule. For each metric (CPU, memory, latency), it computes an EWMA baseline and z-score relative to recent history, then folds those into a composite 0-100 score. Thresholds drive graduated response:

| Score | Action |
|-------|--------|
| 60–79 | SNS warning + log |
| 80–89 | Start secondary EC2 (pre-emptive warm) |
| 90+   | Shift Global Accelerator traffic dials |
| Health check fail | Full SSM failover document |

A single elevated score doesn't fire. The threshold must hold for 3+ consecutive checks — this eliminates single-spike false positives. Multi-metric correlation produces higher scores than single-metric anomalies, so a CPU spike alone stays in warning range while CPU + memory + latency trending together escalates cleanly.

False positive worst case: a secondary EC2 starts for 10 minutes and stops. ~$0.02.

## Run It

```bash
# Deploy infrastructure
cd terraform/bootstrap && terraform init && terraform apply  # one-time state backend
cd .. && terraform init && terraform apply

# Run tests locally
python -m venv .venv && source .venv/bin/activate
pip install ".[dev]"
ruff check . && pytest -v

# Trigger a demo failover (after deploy)
aws ssm start-automation-execution \
  --document-name CloudSleuth-Failover \
  --region us-east-1
```

After `terraform apply` you'll have two EC2 instances (primary running, secondary stopped), a Lambda firing every minute, a DynamoDB state table, and Global Accelerator serving anycast traffic to us-east-1. Inject load or synthetically spike CloudWatch metrics to watch the graduated response climb through the scoring tiers.

Tear down with `terraform destroy` — cost at rest is zero.
