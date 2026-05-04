#!/bin/bash
# socat-dns-proxy.sh — UDP DNS proxy: LAN IP:5355 -> OrbStack VM:5354
#
# pf-dns-redirect.sh redirects DNS_PORT (5354/53) UDP to LAN_IP:5355.
# This script receives those UDP packets and forwards them to Technitium
# running inside the OrbStack VM (network_mode: host).
#
# Why socat instead of pure pf rdr to VM IP:
#   macOS will not route packets originally destined for its own LAN IP
#   (10.100.20.18) to bridge100 after pf rdr changes the dst to 192.168.139.2.
#   By redirecting to the same LAN IP on a different port, macOS delivers
#   the packet locally; socat (running on macOS) makes the forwarding call
#   to the VM from a normal userspace socket that routes correctly.
#
# Runs as root via LaunchDaemon at boot (after pf-dns-redirect).

set -euo pipefail

SOCAT_BIN="/opt/homebrew/bin/socat"
BIND_IP="10.100.20.18"    # LAN IP — pf redirects DNS to this port
LISTEN_PORT=5355
ORBSTACK_VM_IP="192.168.139.2"
TECHNITIUM_PORT=5354

# Kill any stale socat on this port before starting fresh
pkill -f "socat.*:${LISTEN_PORT}" 2>/dev/null || true
sleep 0.5

logger -t socat-dns-proxy "Starting UDP proxy: ${BIND_IP}:${LISTEN_PORT} -> ${ORBSTACK_VM_IP}:${TECHNITIUM_PORT}"

# UDP4-LISTEN with fork: each arriving datagram spawns a child that
# maintains a connected UDP socket to the backend and relays the response.
exec "${SOCAT_BIN}" \
    "UDP4-LISTEN:${LISTEN_PORT},bind=${BIND_IP},reuseaddr,fork" \
    "UDP4:${ORBSTACK_VM_IP}:${TECHNITIUM_PORT}"
