#!/bin/bash
# init.sh — One-time boot prerequisites for Mac Mini compose stacks.
# Runs at boot via LaunchDaemon before inject-secrets.sh.
# Creates shared resources that multiple stacks depend on.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[init]${NC} $*"; logger -t mac-mini-init "$*"; }
die()  { echo -e "${RED}[init]${NC} $*" >&2; logger -t mac-mini-init "ERROR: $*"; exit 1; }

# ── Wait for Docker/OrbStack ──────────────────────────────────────────────

log "Waiting for Docker..."
for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
docker info >/dev/null 2>&1 || die "Docker not available after 120s"

# ── Shared network ────────────────────────────────────────────────────────

if ! docker network inspect mac-mini-shared >/dev/null 2>&1; then
    log "Creating shared network: mac-mini-shared"
    docker network create mac-mini-shared
else
    log "Shared network mac-mini-shared already exists"
fi

log "Init complete."
