# DR Runbook

## Activation Criteria

Initiate manual failover when:
- CloudWatch alarm `cloudsleuth-dev-primary-down` is in ALARM state for >5 minutes
- AWS Health Dashboard shows service event impacting us-east-1 EC2
- Anomaly detector score is 90+ sustained and automated failover hasn't triggered

## Pre-Checks

Before executing failover steps:

1. Confirm secondary region (us-west-2) is healthy on AWS Health Dashboard
2. Check DynamoDB state table for current detector score and action level
3. Verify secondary instance exists: `aws ec2 describe-instances --filters "Name=tag:Role,Values=secondary" --region us-west-2`

## Automated Failover (Preferred)

The SSM document handles the full sequence. Trigger manually if the Lambda didn't:

```bash
aws ssm start-automation-execution \
  --document-name "cloudsleuth-dev-failover" \
  --parameters '{"Reason":["Manual trigger: <describe what you observed>"]}' \
  --region us-east-1
```

Monitor execution:
```bash
aws ssm describe-automation-executions \
  --filters Key=DocumentNamePrefix,Values=cloudsleuth \
  --region us-east-1
```

## Manual Failover

If SSM automation fails or is unavailable:

### Step 1: Start secondary instance

```bash
aws ec2 start-instances \
  --instance-ids <SECONDARY_INSTANCE_ID> \
  --region us-west-2
```

Wait for running state (~30-60 seconds):
```bash
aws ec2 wait instance-running \
  --instance-ids <SECONDARY_INSTANCE_ID> \
  --region us-west-2
```

### Step 2: Verify application health

```bash
curl http://<SECONDARY_PUBLIC_IP>:8000/health
# expected: {"status": "healthy", "region": "us-west-2"}
```

### Step 3: Shift Global Accelerator traffic

```bash
# route traffic to secondary
aws globalaccelerator update-endpoint-group \
  --endpoint-group-arn <SECONDARY_ENDPOINT_GROUP_ARN> \
  --traffic-dial-percentage 100 \
  --region us-west-2

# drain primary
aws globalaccelerator update-endpoint-group \
  --endpoint-group-arn <PRIMARY_ENDPOINT_GROUP_ARN> \
  --traffic-dial-percentage 0 \
  --region us-west-2
```

### Step 4: Verify traffic routing

```bash
# hit the accelerator DNS — should respond from us-west-2
curl http://<ACCELERATOR_DNS>/health
```

## Failback

After the primary region recovers:

1. Verify primary instance is healthy: `curl http://<PRIMARY_IP>:8000/health`
2. Gradually shift traffic back: set primary to 50%, secondary to 50%
3. Monitor for 15 minutes
4. If stable, shift primary to 100%, secondary to 0%
5. Stop secondary instance to return to pilot light state

## RTO/RPO Calculation

| Component | Time |
|-----------|------|
| Anomaly detection (predictive path) | ~3 min (sustained threshold) |
| Secondary instance start | ~30-60s |
| Application startup | ~15s |
| Global Accelerator traffic shift | <30s (no DNS propagation) |
| **Estimated RTO (predictive)** | **~4-5 min** |
| **Estimated RTO (reactive, health check)** | **~2-3 min** |
| **RPO** | **0 (stateless app)** |

The predictive path has a higher RTO than the reactive path because of the sustained threshold. This is intentional — the tradeoff is fewer false positives at the cost of slower detection for gradual degradation. Sudden hard failures are caught by health checks in ~30 seconds.

## Quarterly DR Drill

1. Run the `dr-validation` GitHub Actions workflow (manual dispatch)
2. Hit `/simulate/cpu-load` on the primary to trigger anomaly detection
3. Verify the anomaly detector fires warnings, then elevated actions
4. Confirm secondary starts and health check passes
5. Execute manual failback
6. Document results and update this runbook
