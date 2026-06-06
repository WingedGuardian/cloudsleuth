"""Graduated response levels: WARNING → ELEVATED → CRITICAL → EMERGENCY."""
from datetime import datetime, timezone
from enum import Enum

import boto3


class ActionLevel(Enum):
    NORMAL = "normal"
    WARNING = "warning"
    ELEVATED = "elevated"
    CRITICAL = "critical"
    EMERGENCY = "emergency"


# one bad datapoint shouldn't spin up a secondary region — require N consecutive
# elevated readings so a CPU spike doesn't trigger failover theater
# how many consecutive elevated checks before we act
SUSTAINED_THRESHOLD = 3
COOLDOWN_MINUTES = 30


def determine_action(
    score: float,
    consecutive_elevated: int,
    cooldown_until: str | None,
    health_check_failed: bool = False,
) -> ActionLevel:
    """Map score + persistence state to an action level."""
    if health_check_failed:
        return ActionLevel.EMERGENCY

    if score < 60:
        return ActionLevel.NORMAL

    if score < 80:
        return ActionLevel.WARNING

    # in cooldown — don't re-trigger, just warn
    if cooldown_until:
        now = datetime.now(timezone.utc)
        try:
            cutoff = datetime.fromisoformat(cooldown_until)
        except (ValueError, TypeError):
            cutoff = now  # malformed → treat as expired
        if now < cutoff:
            return ActionLevel.WARNING

    if score >= 90 and consecutive_elevated >= SUSTAINED_THRESHOLD:
        return ActionLevel.CRITICAL

    if score >= 80 and consecutive_elevated >= SUSTAINED_THRESHOLD:
        return ActionLevel.ELEVATED

    # high score but not sustained long enough yet
    return ActionLevel.WARNING


def execute_warming(instance_id: str, region: str) -> dict:
    """Start the secondary instance (pre-emptive warm)."""
    ec2 = boto3.client("ec2", region_name=region)
    resp = ec2.start_instances(InstanceIds=[instance_id])
    state = resp["StartingInstances"][0]["CurrentState"]["Name"]
    return {"action": "warm_secondary", "instance": instance_id, "state": state}


def execute_traffic_shift(
    primary_endpoint_group_arn: str,
    secondary_endpoint_group_arn: str,
    primary_pct: int = 0,
    secondary_pct: int = 100,
) -> dict:
    """Shift Global Accelerator traffic dials."""
    # GA API is regional but accelerators are global — us-west-2 is conventional
    ga = boto3.client("globalaccelerator", region_name="us-west-2")
    # promote secondary BEFORE draining primary — brief overlap is fine,
    # a gap in coverage is not
    ga.update_endpoint_group(
        EndpointGroupArn=secondary_endpoint_group_arn,
        TrafficDialPercentage=secondary_pct,
    )
    ga.update_endpoint_group(
        EndpointGroupArn=primary_endpoint_group_arn,
        TrafficDialPercentage=primary_pct,
    )
    return {
        "action": "traffic_shift",
        "primary_pct": primary_pct,
        "secondary_pct": secondary_pct,
    }


def execute_ssm_failover(document_name: str, role_arn: str, reason: str) -> dict:
    """Trigger the full SSM Automation failover document."""
    ssm = boto3.client("ssm")
    resp = ssm.start_automation_execution(
        DocumentName=document_name,
        Parameters={"Reason": [reason]},
        Mode="Auto",
    )
    return {"action": "ssm_failover", "execution_id": resp["AutomationExecutionId"]}


def send_alert(topic_arn: str, subject: str, message: str) -> None:
    sns = boto3.client("sns")
    sns.publish(TopicArn=topic_arn, Subject=subject[:100], Message=message)
