#!/bin/bash
set -euo pipefail

yum update -y
yum install -y python3.12 python3.12-pip amazon-cloudwatch-agent

pip3.12 install fastapi uvicorn

cat > /home/ec2-user/app.py << 'EOF'
from fastapi import FastAPI
import os, time

app = FastAPI()

@app.get("/health")
def health():
    return {"status": "healthy", "region": os.environ.get("AWS_REGION", "unknown")}

@app.get("/")
def root():
    return {"service": "cloudsleuth-demo", "version": "0.1.0"}

@app.post("/simulate/cpu-load")
def simulate_cpu(duration_seconds: int = 30):
    end = time.time() + min(duration_seconds, 120)
    while time.time() < end:
        _ = sum(i * i for i in range(10000))
    return {"simulated": "cpu_load", "duration": duration_seconds}
EOF

cat > /etc/systemd/system/cloudsleuth.service << SVCEOF
[Unit]
Description=CloudSleuth Demo
After=network.target

[Service]
User=ec2-user
ExecStart=/usr/bin/python3.12 -m uvicorn app:app --host 0.0.0.0 --port ${app_port}
WorkingDirectory=/home/ec2-user
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable cloudsleuth
systemctl start cloudsleuth

# CloudWatch agent config — pushes memory + disk metrics
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json << 'CWEOF'
{
  "metrics": {
    "namespace": "CloudSleuth",
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["*"] }
    },
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
