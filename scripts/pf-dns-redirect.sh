#!/bin/bash
# pf-dns-redirect.sh — Redirect DNS traffic to Technitium container.
#
# OrbStack intercepts *:53 and *:5353 and does not forward LAN UDP to
# containers. pf intercepts at the NIC before OrbStack sees packets.
#
# Testing phase:  redirects 10.100.20.18:5354 -> 127.0.0.1:5354
# Cutover phase:  change DNS_PORT=53 so LAN clients use standard port
#
# Runs as root via LaunchDaemon at boot.

set -euo pipefail

# LAN interface — the one with the 10.100.20.18 address
IFACE="en0"
ANCHOR="com.local/dns-redirect"
ANCHOR_FILE="/etc/pf.anchors/dns-redirect"
PF_CONF="/etc/pf.conf"

# Testing: 5354->5354. Change DNS_PORT to 53 at LAN cutover.
DNS_PORT=5354
TECHNITIUM_PORT=5354

logger -t pf-dns-redirect "Setting up DNS redirect on ${IFACE}:${DNS_PORT} -> 127.0.0.1:${TECHNITIUM_PORT}"

# ── Write anchor rules ──────────────────────────────────────────────────────

mkdir -p /etc/pf.anchors
cat > "${ANCHOR_FILE}" <<EOF
rdr pass on ${IFACE} proto udp from any to 10.100.20.18 port ${DNS_PORT} -> 127.0.0.1 port ${TECHNITIUM_PORT}
rdr pass on ${IFACE} proto tcp from any to 10.100.20.18 port ${DNS_PORT} -> 127.0.0.1 port ${TECHNITIUM_PORT}
EOF

# ── Ensure pf.conf references our rdr-anchor ──────────────────────────────
# Appends once; safe to re-run (idempotent).

if ! grep -q 'rdr-anchor "com.local"' "${PF_CONF}"; then
    echo '' >> "${PF_CONF}"
    echo '# Local service redirects' >> "${PF_CONF}"
    echo 'rdr-anchor "com.local"' >> "${PF_CONF}"
    echo 'anchor "com.local"' >> "${PF_CONF}"
    echo 'load anchor "com.local/dns-redirect" from "/etc/pf.anchors/dns-redirect"' >> "${PF_CONF}"
    logger -t pf-dns-redirect "Added com.local anchors to ${PF_CONF}"
fi

# ── Enable pf and reload ───────────────────────────────────────────────────

pfctl -e 2>/dev/null || true
pfctl -f "${PF_CONF}"

logger -t pf-dns-redirect "DNS redirect active: 10.100.20.18:${DNS_PORT} -> 127.0.0.1:${TECHNITIUM_PORT}"
