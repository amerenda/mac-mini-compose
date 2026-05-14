#!/usr/bin/env python3
"""NVIDIA GPU metrics exporter for Prometheus (nvidia-smi based).

Scrapes `nvidia-smi` periodically and exposes standard nvidia_* metric names
matching the DCGM exporter output format so Grafana panels work without changes.

Usage:  /opt/nvidia-exporter/exporter.py [PORT]
Default port: 9101 (different from DCGM's 9400, update prometheus.yml if needed)
"""

import argparse
import subprocess
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

# ── nvidia-smi query template ────────────────────────────────────────
QUERY = (
    "nvidia-smi"
    "--query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,"
    "power.limit,clocks.gr.current,clocks.mem.current,fan.speed,"
    "memory.used,memory.total,utilization.memory,pcie.link.gen.current,"
    "pcie.link.width.current"
    "--format=csv,noheader,nounits"
)

# ── Metric registry ──────────────────────────────────────────────────
_metrics: dict[str, list[float]] = {}
_lock = threading.Lock()


def _parse_nvidia_smi(raw: str) -> dict[int, dict]:
    """Parse nvidia-smi CSV output into {gpu_id: {metric: value}}."""
    rows = []
    for line in raw.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 15:
            continue
        idx = int(parts[0])
        gpu = {
            "index": idx,
            "name": "",  # not needed as a metric value
            "utilization_gpu": float(parts[2]),
            "temperature": float(parts[3]),
            "power_draw_watt": _safe_float(parts[4], -1),
            "power_limit_watt": _safe_float(parts[5], -1),
            "clock_gr": int(float(parts[6])),
            "clock_mem": int(float(parts[7])),
            "fan_speed_pct": _safe_float(parts[8], -1),
            "memory_used_mb": _safe_float(parts[9], 0) * (1024**2 if float(parts[9]) < 1 else 1),
            "memory_total_mb": _safe_float(parts[10], 0) * (1024**2 if float(parts[10]) < 1 else 1),
            "utilization_mem_pct": float(parts[11]),
            "pcie_gen": int(float(parts[12])),
            "pcie_width": int(float(parts[13])),
        }
        rows.append(gpu)
    return rows


def _safe_float(val: str, default: float = 0.0) -> float:
    try:
        f = float(val)
        return f if -2 < f < 9999 else default
    except (ValueError, TypeError):
        return default


# ── Collect metrics in background thread ────────────────────────────
def _collect_loop(interval: int = 5):
    global _metrics
    while True:
        try:
            result = subprocess.run(QUERY.split(), capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip():
                gpus = _parse_nvidia_smi(result.stdout)
                snapshot: dict[str, list[float]] = {}

                for gpu in gpus:
                    idx = str(gpu["index"])

                    # DCGM-compatible metric names — Grafana panels use these:
                    snapshot[f"nvidia_gpu_utilization{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [float(gpu["utilization_gpu"])]
                    snapshot[f"nvidia_gpu_temperature{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [float(gpu["temperature"])]
                    snapshot[f"nvidia_gpu_power_usage{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [gpu["power_draw_watt"]]
                    snapshot[f"nvidia_gpu_power_limit{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [gpu["power_limit_watt"]]
                    snapshot[f"nvidia_gpu_mem_used_bytes{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [gpu["memory_used_mb"]]
                    snapshot[f"nvidia_gpu_mem_total_bytes{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [gpu["memory_total_mb"]]
                    snapshot[f"nvidia_gpu_clock_gr{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [float(gpu["clock_gr"])]
                    snapshot[f"nvidia_gpu_clock_mem{{node=\"murderbot\",gpu=\"{idx}\"}}"] = [float(gpu["clock_mem"])]

                # Global GPU count (DCGM-compatible)
                snapshot["nvidia_gpu_count"] = [len(gpus)]
                snapshot["nvidia_gpu_utilization_avg"] = [sum(g["utilization_gpu"] for g in gpus) / max(len(gpus), 1)]

                with _lock:
                    _metrics = snapshot
        except Exception:
            pass
        time.sleep(interval)


# ── Prometheus HTTP handler ─────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        with _lock:
            body = ""
            for line in _format_prometheus():
                body += line + "\n"

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass  # quiet — suppress request logs


def _format_prometheus() -> list[str]:
    """Export metrics in Prometheus exposition format."""
    lines: list[str] = []
    with _lock:
        for key_str, values in sorted(_metrics.items()):
            # Parse "metric_name{labels}" = [value, ...]
            parts = key_str.split("{", 1)
            if len(parts) == 2:
                name, labels_and_rest = parts[0], "{" + parts[1]
                label_str = labels_and_rest.rstrip("}")
                for v in values:
                    lines.append(f"{name}{label_str} {v:.6f}")
            else:
                # No labels (e.g. nvidia_gpu_count, nvidia_gpu_utilization_avg)
                name = parts[0]
                for v in values:
                    lines.append(f"# HELP {name} NVIDIA GPU metric (nvidia-smi scraped)")
                    lines.append(f"# TYPE {name} gauge")
                    lines.append(f"{name} {v:.6f}")

    return lines


# ── Main ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="NVIDIA GPU metrics exporter for Prometheus")
    parser.add_argument("--port", type=int, default=9101)
    parser.add_argument("--interval", type=int, default=5, help="Poll interval in seconds")
    args = parser.parse_args()

    # Start background collection thread
    collector = threading.Thread(target=_collect_loop, args=(args.interval,), daemon=True)
    collector.start()

    # Give first sample time before starting HTTP server
    time.sleep(1)

    server = HTTPServer(("0.0.0.0", args.port), Handler)
    print(f"[nvidia-exporter] Listening on :{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[shutdown]")
        server.shutdown()


if __name__ == "__main__":
    main()
