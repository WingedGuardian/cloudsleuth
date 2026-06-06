"""Optional LLM narrative for anomaly context.

Adds human-readable explanation to alerts. If Bedrock is unavailable,
falls back to a template. The detection and scoring are fully deterministic —
this just makes the SNS messages more useful for the on-call engineer.
"""
import json

import boto3

PROMPT_TEMPLATE = """You are a site reliability engineer analyzing infrastructure metrics.

Current metrics for instance {instance_id}:
{metrics_json}

Anomaly score: {score}/100 (threshold for action: 80)
Action taken: {action}

In 2-3 sentences, explain what's happening and what the on-call should check.
Be specific about which metrics are concerning and what they suggest."""


def generate_narrative(
    instance_id: str,
    metrics: dict,
    score: float,
    action: str,
) -> str:
    """Generate a brief explanation of the anomaly for the alert."""
    prompt = PROMPT_TEMPLATE.format(
        instance_id=instance_id,
        metrics_json=json.dumps(metrics, indent=2, default=str),
        score=score,
        action=action,
    )

    try:
        bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
        resp = bedrock.invoke_model(
            modelId="anthropic.claude-3-haiku-20240307-v1:0",
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 200,
                "messages": [{"role": "user", "content": prompt}],
            }),
        )
        body = json.loads(resp["body"].read())
        return body["content"][0]["text"]
    except Exception:
        # Bedrock unavailable — fall back to template
        top_metrics = sorted(metrics.items(), key=lambda x: x[1], reverse=True)[:3]
        lines = [f"Anomaly score {score:.0f}/100. Action: {action}."]
        for name, val in top_metrics:
            lines.append(f"  {name}: {val}")
        return "\n".join(lines)
