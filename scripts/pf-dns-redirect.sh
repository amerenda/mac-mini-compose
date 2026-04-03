#!/bin/bash
# pf-dns-redirect.sh — Redirect DNS port to Technitium container.
#
# OrbStack does not forward LAN UDP to containers. pf intercepts
# packets at the NIC before OrbStack's network stack and redirects
# them to 127.0.0.1 where OrbStack bridges loopback to the container.
#
# Testing:  port 5354 -> 127.0.0.1:5354  (Technitium on 5354)
# Cutover:  port 53   -> 127.0.0.1:5354  (LAN clients use standard port)
#
# Runs as root via LaunchDaemon at boot.

set -euo pipefail

ANCHOR="com.local/dns-redirect"
ANCHOR_FILE="/etc/pf.anchors/dns-redirect"

# Detect the primary LAN interface (the one with 10.100.20.18)
IFACE=$(route -n get 10.100.20.18 2>/dev/null | awk '/interface:/ {print $2}' || echo "en0")

logger -t pf-dns-redirect "Setting up DNS redirect on ${IFACE}"

# Write the anchor rules
# Change DNS_PORT to 53 at cutover (after confirming Technitium works on 5354)
DNS_PORT=5354
TECHNITIUM_PORT=5354

mkdir -p /etc/pf.anchors
cat > "${ANCHOR_FILE}" <<EOF
rdr pass on ${IFACE} proto { udp, tcp } from any to 10.100.20.18 port ${DNS_PORT} -> 127.0.0.1 port ${TECHNITIUM_PORT}
EOF

# Enable pf if not already running
pfctl -e 2>/dev/null || true

# Load the anchor rules (creates or replaces)
pfctl -a "${ANCHOR}" -f "${ANCHOR_FILE}"

logger -t pf-dns-redirect "DNS redirect active: 10.100.20.18:${DNS_PORT} -> 127.0.0.1:${TECHNITIUM_PORT}"
