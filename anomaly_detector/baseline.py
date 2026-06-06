"""EWMA baseline modeling for anomaly detection.

Uses exponentially weighted moving average to track "normal" for each metric.
Z-scores measure how far a new observation deviates from the learned baseline.
"""
import math


class EWMABaseline:
    """Single-metric baseline tracker using EWMA for mean and variance."""

    def __init__(self, span: int = 30):
        # span=30 → alpha=0.065, so ~30 data points to capture 86% of weight.
        # with 1-minute intervals, this is a 30-minute rolling window.
        self.alpha = 2.0 / (span + 1)
        self.mean = None
        self.variance = None
        self.count = 0

    def update(self, value: float) -> None:
        if self.mean is None:
            self.mean = value
            self.variance = 0.0
            self.count = 1
            return

        delta = value - self.mean
        self.mean = self.alpha * value + (1 - self.alpha) * self.mean
        # Welford-style online variance with exponential weighting
        self.variance = (1 - self.alpha) * (self.variance + self.alpha * delta * delta)
        self.count += 1

    # fixed threshold needs tuning per instance type; EWMA adapts —
    # "is this weird for this box right now" not "is CPU above 70%"
    def z_score(self, value: float) -> float:
        """How many standard deviations is value from the baseline mean."""
        if self.mean is None or self.count < 5:
            # not enough data to judge — report no anomaly
            return 0.0
        std = math.sqrt(self.variance) if self.variance > 0 else 0.0
        if std < 1e-10:
            # constant metric (e.g., status check always 0) — any deviation is big
            return 10.0 if abs(value - self.mean) > 1e-10 else 0.0
        return abs(value - self.mean) / std

    def to_dict(self) -> dict:
        return {"mean": self.mean, "variance": self.variance, "count": self.count}

    @classmethod
    def from_dict(cls, data: dict, span: int = 30) -> "EWMABaseline":
        b = cls(span=span)
        b.mean = data.get("mean")
        b.variance = data.get("variance")
        b.count = data.get("count", 0)
        return b
