"""Pull CloudWatch metrics for an EC2 instance."""
from datetime import datetime, timedelta, timezone

import boto3

# metrics we care about and their CloudWatch namespaces
METRIC_SPECS = [
    ("AWS/EC2", "CPUUtilization", "Average"),
    ("AWS/EC2", "NetworkIn", "Average"),
    ("AWS/EC2", "NetworkOut", "Average"),
    ("AWS/EC2", "StatusCheckFailed", "Maximum"),
    ("AWS/EC2", "StatusCheckFailed_Instance", "Maximum"),
    ("AWS/EC2", "StatusCheckFailed_System", "Maximum"),
    # custom namespace from CW Agent
    ("CloudSleuth", "mem_used_percent", "Average"),
    ("CloudSleuth", "disk_used_percent", "Average"),
]


def collect_metrics(instance_id: str, region: str, lookback_minutes: int = 60) -> dict:
    """Fetch recent metrics for one instance. Returns {metric_name: [values]}."""
    cw = boto3.client("cloudwatch", region_name=region)

    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=lookback_minutes)

    # batch all metrics into a single GetMetricData call
    queries = []
    for i, (namespace, metric, stat) in enumerate(METRIC_SPECS):
        queries.append({
            "Id": f"m{i}",
            "MetricStat": {
                "Metric": {
                    "Namespace": namespace,
                    "MetricName": metric,
                    "Dimensions": [{"Name": "InstanceId", "Value": instance_id}],
                },
                "Period": 60,
                "Stat": stat,
            },
            "ReturnData": True,
        })

    resp = cw.get_metric_data(
        MetricDataQueries=queries,
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampAscending",
    )

    results = {}
    for i, (_, metric_name, _) in enumerate(METRIC_SPECS):
        for result in resp["MetricDataResults"]:
            if result["Id"] == f"m{i}":
                results[metric_name] = result["Values"]
                break

    return results


def get_latest_values(metrics: dict) -> dict:
    """Extract the most recent value for each metric."""
    latest = {}
    for name, values in metrics.items():
        if values:
            latest[name] = values[-1]
    return latest
