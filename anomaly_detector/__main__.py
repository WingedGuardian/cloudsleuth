"""Run anomaly detection locally (outside Lambda)."""
from anomaly_detector.handler import lambda_handler

if __name__ == "__main__":
    lambda_handler({}, None)
