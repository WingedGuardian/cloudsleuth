import os
import time

from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
def health():
    return {"status": "healthy", "region": os.environ.get("AWS_REGION", "unknown")}


@app.get("/")
def root():
    return {"service": "cloudsleuth-demo", "version": "0.1.0"}


@app.post("/simulate/cpu-load")
def simulate_cpu(duration_seconds: int = 30):
    """Burn CPU to trigger anomaly detection during demos."""
    end = time.time() + min(duration_seconds, 120)
    while time.time() < end:
        _ = sum(i * i for i in range(10000))
    return {"simulated": "cpu_load", "duration": duration_seconds}
