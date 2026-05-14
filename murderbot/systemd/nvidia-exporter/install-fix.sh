#!/bin/bash
# Fix nvidia-exporter deadlock + restart on murderbot
set -euo pipefail

echo "[1/4] Patching Lock -> RLock in exporter.py..."
sudo sed -i 's/_lock = threading.Lock()/_lock = threading.RLock()/g' /opt/nvidia-exporter/exporter.py

echo "[2/4] Restarting nvidia-exporter service..."
sudo systemctl restart nvidia-exporter

echo "[3/4] Waiting for exporter to start..."
sleep 2

echo "[4/4] Checking metrics endpoint..."
curl -sf http://localhost:9101/metrics | head -20
