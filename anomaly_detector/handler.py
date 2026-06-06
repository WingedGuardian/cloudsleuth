"""Lambda entry point — runs every minute via EventBridge."""
import json
import os
from datetime import datetime, timedelta, timezone

import boto3

from anomaly_detector.actions import (
    COOLDOWN_MINUTES,
    ActionLevel,
    determine_action,
    execute_ssm_failover,
    execute_traffic_shift,
    execute_warming,
    send_alert,
)
from anomaly_detector.baseline import EWMABaseline
from anomaly_detector.collector import collect_metrics, get_latest_values
from anomaly_detector.scorer import compute_anomaly_score


def _load_state(table_name: str) -> dict:
    ddb = boto3.resource("dynamodb")
    table = ddb.Table(table_name)
    resp = table.get_item(Key={"pk": "state"})
    return resp.get("Item", {})


def _save_state(table_name: str, state: dict) -> None:
    ddb = boto3.resource("dynamodb")
    table = ddb.Table(table_name)
    state["pk"] = "state"
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    table.put_item(Item=state)


def lambda_handler(event, context):
    cfg = {
        "instance_id": os.environ.get("PRIMARY_INSTANCE_ID", ""),
        "region": os.environ.get("PRIMARY_REGION", "us-east-1"),
        "secondary_id": os.environ.get("SECONDARY_INSTANCE_ID", ""),
        "secondary_region": os.environ.get("SECONDARY_REGION", "us-west-2"),
        "sns_topic": os.environ.get("SNS_TOPIC_ARN", ""),
        "state_table": os.environ.get("STATE_TABLE", ""),
        "ssm_doc": os.environ.get("SSM_DOCUMENT", ""),
        "ssm_role": os.environ.get("SSM_ROLE_ARN", ""),
        "primary_eg": os.environ.get("PRIMARY_ENDPOINT_GROUP_ARN", ""),
        "secondary_eg": os.environ.get("SECONDARY_ENDPOINT_GROUP_ARN", ""),
    }

    raw_metrics = collect_metrics(cfg["instance_id"], cfg["region"], lookback_minutes=5)
    latest = get_latest_values(raw_metrics)

    if not latest:
        # no metrics yet (instance just started, CW hasn't published)
        return {"status": "no_data"}

    state = _load_state(cfg["state_table"])
    baselines_raw = state.get("baselines", {})
    consecutive = int(state.get("consecutive_elevated", 0))
    cooldown_until = state.get("cooldown_until")

    baselines = {}
    z_scores = {}
    for metric, value in latest.items():
        if metric in baselines_raw:
            bl = EWMABaseline.from_dict(baselines_raw[metric])
        else:
            bl = EWMABaseline(span=30)

        z_scores[metric] = bl.z_score(value)
        bl.update(value)
        baselines[metric] = bl.to_dict()

    score = compute_anomaly_score(z_scores)

    # check if health check is actively failing
    health_failed = latest.get("StatusCheckFailed", 0) > 0

    level = determine_action(score, consecutive, cooldown_until, health_failed)

    # increment based on score, not action level
    if score >= 80:
        consecutive += 1
    else:
        consecutive = 0

    result = {"score": score, "level": level.value, "metrics": latest}

    if level == ActionLevel.WARNING:
        send_alert(
            cfg["sns_topic"],
            f"[CloudSleuth] Warning: anomaly score {score:.0f}",
            f"Score: {score:.1f}\nMetrics: {json.dumps(latest, default=str)}",
        )

    elif level == ActionLevel.ELEVATED:
        execute_warming(cfg["secondary_id"], cfg["secondary_region"])
        send_alert(
            cfg["sns_topic"],
            f"[CloudSleuth] Pre-emptive warm: score {score:.0f}",
            f"Starting secondary instance. Score: {score:.1f}",
        )
        cooldown_until = (
            datetime.now(timezone.utc) + timedelta(minutes=COOLDOWN_MINUTES)
        ).isoformat()

    elif level == ActionLevel.CRITICAL:
        # secondary should already be warm from ELEVATED stage
        execute_traffic_shift(cfg["primary_eg"], cfg["secondary_eg"])
        send_alert(
            cfg["sns_topic"],
            f"[CloudSleuth] Traffic shifted: score {score:.0f}",
            f"Traffic moved to secondary. Score: {score:.1f}",
        )
        cooldown_until = (
            datetime.now(timezone.utc) + timedelta(minutes=COOLDOWN_MINUTES)
        ).isoformat()

    elif level == ActionLevel.EMERGENCY:
        execute_ssm_failover(cfg["ssm_doc"], cfg["ssm_role"], "health check failed")
        send_alert(
            cfg["sns_topic"],
            "[CloudSleuth] EMERGENCY failover initiated",
            "Health check failed. Full SSM automation triggered.",
        )

    _save_state(cfg["state_table"], {
        "baselines": baselines,
        "consecutive_elevated": consecutive,
        "cooldown_until": cooldown_until,
        "last_score": str(score),  # DynamoDB doesn't like float
        "last_level": level.value,
    })

    return result
