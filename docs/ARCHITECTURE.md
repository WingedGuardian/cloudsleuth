# Architecture

## DR Tier: Pilot Light

Secondary region has all infrastructure provisioned (VPC, security groups, EC2 instance) but the instance is stopped. Data layer would use cross-region replication in production (Aurora Global Database, S3 CRR). For this demo, the application is stateless — the architecture focuses on compute failover and traffic routing.

Pilot light was chosen over warm standby (running but scaled-down secondary) because the anomaly detector's pre-emptive warming eliminates the cold-start penalty that makes pilot light slow. You get warm standby RTO at pilot light cost.

## Detection Layers

Two independent detection paths, either of which can trigger failover:

### Predictive (Anomaly Detector)

Lambda runs every 60 seconds. Pulls CloudWatch metrics for the primary instance:

- CPU utilization (EC2 built-in)
- Memory usage (CloudWatch Agent custom metric)
- Disk usage (CloudWatch Agent custom metric)
- Network I/O (EC2 built-in)
- Status check failures (EC2 built-in — binary but weighted heavily)

Each metric is tracked against an EWMA baseline (span=30 minutes). The z-score measures deviation from baseline. A composite score (0-100) is computed as the weighted sum of per-metric z-scores, normalized to a 0-100 scale.

Weights reflect operational criticality:
| Metric | Weight | Rationale |
|--------|--------|-----------|
| CPUUtilization | 25% | Most common degradation signal |
| mem_used_percent | 20% | Memory leaks are slow killers |
| StatusCheckFailed | 15% | Binary but definitive |
| StatusCheckFailed_Instance | 10% | Application-level failure |
| NetworkIn | 10% | Traffic anomalies |
| disk_used_percent | 10% | Full disk = silent failure |
| NetworkOut | 5% | Usually follows NetworkIn |
| StatusCheckFailed_System | 5% | AWS hardware failure (rare) |

### Reactive (Route53 + Global Accelerator)

Route53 health check pings the primary instance every 10 seconds. Three consecutive failures triggers a CloudWatch alarm → SNS notification. Global Accelerator has its own health checks on both endpoint groups.

The reactive path catches hard failures (instance crash, network partition). The predictive path catches gradual degradation that precedes hard failures.

## Graduated Response

| Score | Level | Action | Blast Radius | Cost |
|-------|-------|--------|-------------|------|
| < 60 | Normal | None | None | $0 |
| 60-79 | Warning | Log + SNS alert | None | $0 |
| 80-89 (3+ min) | Elevated | Start secondary instance | Instance boots, no traffic shift | ~$0.02 |
| 90+ (3+ min) | Critical | Shift GA traffic dials | Users hit secondary (healthy) | Minimal |
| Health check fail | Emergency | Full SSM automation | Complete failover | Standard DR |

The "3+ min" qualifier is the sustained threshold — prevents transient spikes from triggering. A single CPU burst that resolves in under 3 minutes produces warnings but no infrastructure action.

Cooldown period (30 min) prevents flapping after an action is taken.

## SSM Automation Failover

The SSM document executes a 6-step failover:

1. Start secondary EC2 instance
2. Wait for instance to reach "running" state (timeout: 5 min)
3. Wait 30s for application health check
4. Set secondary endpoint group traffic dial to 100%
5. Set primary endpoint group traffic dial to 0%
6. Publish SNS notification

The SSM role uses tag-based IAM conditions — it can only manage instances tagged `Project=cloudsleuth`. Global Accelerator permissions use wildcard resource (GA ARN format doesn't support fine-grained scoping).

## OIDC Authentication

GitHub Actions authenticates to AWS via OIDC federation — no stored credentials. The CI role is read-only (describe APIs + terraform state read). Separate from the SSM automation and Lambda execution roles.

## State Management

The anomaly detector persists state in DynamoDB (single item):
- EWMA baselines per metric (mean, variance, observation count)
- Consecutive elevated counter
- Cooldown expiry timestamp
- Last score and action level

DynamoDB was chosen over SSM Parameter Store because structured state is a natural fit and the read/write pattern (one GetItem + one PutItem per invocation) is clean. At demo scale either would work.
