#!/bin/bash
# Quick health check for all Mac Mini services

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

check() {
  local name=$1
  local cmd=$2
  if eval "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}OK${NC}  ${name}"
  else
    echo -e "  ${RED}FAIL${NC}  ${name}"
  fi
}

echo "=== Mac Mini Service Health ==="
echo ""
check "BIND9 (10.100.20.30:53)"      "dig @10.100.20.30 amer.home SOA +short +time=2"
check "Pihole DNS (10.100.20.31:53)"  "dig @10.100.20.31 google.com +short +time=2"
check "Pihole Web (10.100.20.31:80)"  "curl -sf http://10.100.20.31/admin/ -o /dev/null"
check "Home Assistant (:8123)"        "curl -sf http://localhost:8123/api/ -o /dev/null"
check "Whisper (:10300)"              "echo | nc -w1 localhost 10300"
check "Node Exporter (:9100)"         "curl -sf http://localhost:9100/metrics -o /dev/null"
check "Pihole Exporter (:9617)"       "curl -sf http://localhost:9617/metrics -o /dev/null"
echo ""
echo "=== Docker Containers ==="
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
