# Product Requirements: CloudSleuth

## Problem

Enterprise DR systems are reactive — they detect failure after it happens, then spend minutes recovering. Health checks are binary (up/down) and miss the gradual degradation that precedes most outages. Teams discover their DR plan doesn't work during the actual disaster.

## Solution

Multi-region pilot light DR with a predictive anomaly detector that watches infrastructure metrics and initiates recovery actions before the health check triggers.

## Requirements

### Must Have
- [x] Multi-region Terraform IaC (primary + secondary)
- [x] Pilot light pattern — secondary instance stopped until needed
- [x] Global Accelerator for instant failover (static IPs, no DNS delay)
- [x] EWMA-based anomaly detection on CloudWatch metrics
- [x] Composite scoring with configurable metric weights
- [x] Graduated response (warning → warm → shift → full failover)
- [x] Sustained threshold to filter transient spikes
- [x] Cooldown to prevent flapping
- [x] SSM Automation document for full failover workflow
- [x] Route53 health check as reactive backup
- [x] OIDC authentication for CI (no stored AWS credentials)
- [x] DR runbook with RTO/RPO calculations

### Should Have
- [x] Optional LLM narrative for alerts (Bedrock, graceful degradation)
- [x] Demo endpoint for simulating CPU load
- [x] CloudWatch Agent for memory/disk custom metrics
- [x] GitHub Actions CI (terraform validate + ruff + tflint)
- [x] Quarterly DR validation workflow

### Won't Have (This Version)
- Database replication (app is stateless for demo)
- Multi-account setup (Organizations + SCPs)
- FIS chaos experiments (would require live AWS environment)
- Custom CloudWatch dashboard (monitoring module focuses on programmatic detection)

## Success Criteria

- `terraform validate` passes
- `ruff check .` and `tflint` pass clean
- Anomaly detector correctly scores normal metrics low (< 40) and degrading metrics high (> 60)
- Single-metric spike doesn't trigger critical action (composite scoring works)
- Cooldown prevents re-triggering within 30 minutes
- SSM document contains complete failover sequence

## Target Audience

Cloud Engineer, Cloud Security, SRE hiring managers evaluating DR and monitoring expertise.
