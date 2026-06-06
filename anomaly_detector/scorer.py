"""Composite anomaly scoring from per-metric z-scores.

Weights reflect how strongly each metric signals real infrastructure degradation
vs. normal operational variance. StatusCheckFailed is binary (0 or 1) but when
it fires, something is genuinely broken — so it gets high weight.
"""

METRIC_WEIGHTS = {
    "CPUUtilization": 0.25,
    "mem_used_percent": 0.20,
    "StatusCheckFailed": 0.15,
    "StatusCheckFailed_Instance": 0.10,
    "StatusCheckFailed_System": 0.05,
    "NetworkIn": 0.10,
    "NetworkOut": 0.05,
    "disk_used_percent": 0.10,
}

# z-score of 2 = moderate concern, 4 = severe
# this mapping converts z-scores to a 0-100 per-metric scale
Z_SCORE_SCALE = 25.0  # z=2 → 50, z=4 → 100


def compute_anomaly_score(z_scores: dict[str, float]) -> float:
    """Weighted composite anomaly score, 0-100.

    Higher means more anomalous. Score of 0 = all metrics at baseline.
    """
    total_weight = 0.0
    weighted_sum = 0.0

    for metric, z in z_scores.items():
        weight = METRIC_WEIGHTS.get(metric, 0.05)
        # normalize z-score to 0-100 scale
        metric_score = min(100.0, abs(z) * Z_SCORE_SCALE)
        weighted_sum += metric_score * weight
        total_weight += weight

    if total_weight < 1e-10:
        return 0.0

    return min(100.0, weighted_sum / total_weight)
