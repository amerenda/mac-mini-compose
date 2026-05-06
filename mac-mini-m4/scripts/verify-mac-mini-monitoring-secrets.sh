#!/usr/bin/env bash
# verify-mac-mini-monitoring-secrets.sh — Check monitoring/.env and technitium-exporter env.
# Does not print secret values (only byte lengths). Run on the Mac Mini host from repo root:
#   bash mac-mini-m4/scripts/verify-mac-mini-monitoring-secrets.sh
#
# monitoring/.env is written by Komodo stack pre_deploy (resource-sync/stacks.toml), not by
# inject-secrets.sh. If this file is missing or TECHNITIUM_API_TOKEN is empty, redeploy the
# monitoring stack or re-run pre_deploy; see mac-mini-m4/.env.example for BWS secret UUIDs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/monitoring/.env"
HA_TOKEN="$REPO_ROOT/monitoring/ha-token"
ERR=0

len_line() {
  local key="$1"
  local line val
  line=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 || true)
  if [[ -z "$line" ]]; then
    echo "  $key: MISSING (no line in .env)"
    return 1
  fi
  val="${line#*=}"
  # trim minimal CR
  val="${val%$'\r'}"
  if [[ -z "$val" ]]; then
    echo "  $key: EMPTY"
    return 1
  fi
  if [[ "$val" == "null" ]]; then
    echo "  $key: LITERAL null (BWS fetch failed during last pre_deploy?)"
    return 1
  fi
  echo "  $key: OK (${#val} bytes)"
  return 0
}

echo "=== $ENV_FILE ==="
if [[ ! -f "$ENV_FILE" ]]; then
  echo "  File missing. Expected after Komodo deploy of stack 'monitoring' (pre_deploy writes this)."
  echo "  BWS UUID for TECHNITIUM_API_TOKEN: 4645ac46-3955-4e6e-8558-b434015613a7 (see .env.example)."
  exit 1
fi

len_line TECHNITIUM_API_TOKEN || ERR=1
len_line MINI_POSTGRES_PASSWORD || ERR=1
len_line MONGO_PASSWORD || ERR=1
len_line GRAFANA_ADMIN_PASSWORD || ERR=1
if grep -q '^MONITORING_DIR=' "$ENV_FILE" 2>/dev/null; then
  md=$(grep -E '^MONITORING_DIR=' "$ENV_FILE" | tail -1)
  mv="${md#MONITORING_DIR=}"
  mv="${mv%$'\r'}"
  if [[ -z "$mv" ]]; then
    echo "  MONITORING_DIR: EMPTY"
    ERR=1
  elif [[ ! -d "$mv" ]]; then
    echo "  MONITORING_DIR: points to missing directory: $mv"
    ERR=1
  else
    echo "  MONITORING_DIR: OK ($mv)"
  fi
else
  echo "  MONITORING_DIR: MISSING (optional for manual compose from monitoring/ only)"
fi

echo "=== $HA_TOKEN (Home Assistant bearer for Prometheus) ==="
if [[ ! -f "$HA_TOKEN" ]]; then
  echo "  File missing (pre_deploy should create from BWS c7ccdb87-b04e-428e-bbcf-b4340156edf6)."
  ERR=1
else
  hs=$(wc -c <"$HA_TOKEN" | tr -d ' ')
  if [[ "$hs" -eq 0 ]]; then
    echo "  EMPTY file"
    ERR=1
  else
    echo "  OK ($hs bytes)"
  fi
fi

echo "=== Docker: technitium-exporter ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "  docker not in PATH; skip container checks."
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx technitium-exporter; then
  # Env is baked at container create time; empty means compose saw empty TECHNITIUM_API_TOKEN.
  ev=$(docker inspect technitium-exporter --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^TECHNITIUM_TOKEN=' | tail -1 || true)
  if [[ -z "$ev" ]]; then
    echo "  TECHNITIUM_TOKEN: not set in container config"
    ERR=1
  else
    v="${ev#TECHNITIUM_TOKEN=}"
    if [[ -z "$v" ]]; then
      echo "  TECHNITIUM_TOKEN: EMPTY in container — run: docker compose -f monitoring/compose.yaml up -d --force-recreate technitium-exporter"
      ERR=1
    else
      echo "  TECHNITIUM_TOKEN: OK (${#v} bytes in container)"
    fi
  fi
  bu=$(docker inspect technitium-exporter --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^TECHNITIUM_BASE_URL=' | tail -1 || true)
  echo "  ${bu:-TECHNITIUM_BASE_URL: not set}"
else
  echo "  Container not running; start monitoring stack to verify runtime env."
fi

if [[ "$ERR" -ne 0 ]]; then
  echo ""
  echo "Fix: ensure monitoring stack pre_deploy completed (Komodo UI logs), then:"
  echo "  cd $REPO_ROOT/monitoring && docker compose up -d --force-recreate technitium-exporter"
  exit 1
fi

echo ""
echo "All checks passed."
