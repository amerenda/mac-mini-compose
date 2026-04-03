#!/bin/bash
# pf-dns-redirect.sh — Redirect DNS traffic to Technitium container.
#
# OrbStack intercepts *:53, *:5353, and *:5354 and does not forward LAN UDP
# to containers. pf intercepts at the NIC before OrbStack sees packets.
#
# Strategy:
#   DNS_IP (10.100.20.240) is aliased onto en0 as the public DNS address.
#   UDP: pf redirects DNS_IP:53 -> DNS_IP:15354 (dns-udp-proxy.py).
#        Proxy is bound to en0 via IP_BOUND_IF, forwards to OrbStack VM.
#   TCP: pf redirects DNS_IP:53 -> 127.0.0.1:5354. OrbStack's *:5354 TCP
#        listener intercepts and forwards to Technitium in the VM.
#
# Runs as root via LaunchDaemon at boot.

set -euo pipefail

IFACE="en0"
LAN_IP="10.100.20.18"    # Mac Mini primary IP
DNS_IP="10.100.20.240"   # Public DNS IP — aliased onto en0
DNS_PORT=53
PROXY_PORT=15354          # dns-udp-proxy.py listener port

ANCHOR_FILE="/etc/pf.anchors/com.local"
PF_CONF="/etc/pf.conf"

ORBSTACK_VM_IP="192.168.139.2"
TECHNITIUM_PORT=5354

# ── Add DNS IP alias to en0 ────────────────────────────────────────────────
# Idempotent — ifconfig alias is a no-op if already present.

ifconfig ${IFACE} alias ${DNS_IP} 255.255.255.0
logger -t pf-dns-redirect "IP alias ${DNS_IP} on ${IFACE} configured"

# ── Enable IP forwarding ───────────────────────────────────────────────────

sysctl -w net.inet.ip.forwarding=1
logger -t pf-dns-redirect "IP forwarding enabled"

# ── Write anchor rules ──────────────────────────────────────────────────────

mkdir -p /etc/pf.anchors
cat > "${ANCHOR_FILE}" <<EOF
# UDP: redirect to dns-udp-proxy.py on same IP (avoids routing-via-Tailscale issue).
rdr pass on ${IFACE} proto udp from any to ${DNS_IP} port ${DNS_PORT} -> ${DNS_IP} port ${PROXY_PORT}
# TCP: redirect to loopback:5354 — OrbStack's *:5354 TCP listener forwards to Technitium.
rdr pass on ${IFACE} proto tcp from any to ${DNS_IP} port ${DNS_PORT} -> 127.0.0.1 port ${TECHNITIUM_PORT}
EOF

# ── Clean up any previous bad append ─────────────────────────────────────

if grep -q '# Local service redirects' "${PF_CONF}"; then
    sed -i '' '/^# Local service redirects/d' "${PF_CONF}"
fi

sed -i '' '/^load anchor "com.local\/dns-redirect"/d' "${PF_CONF}" 2>/dev/null || true

# ── Ensure pf.conf references our anchors ─────────────────────────────────
# pf requires strict ordering: normalization, translation (rdr), filtering.
# Insert each directive after its corresponding com.apple counterpart.
# Safe to re-run (idempotent).

if ! grep -q 'rdr-anchor "com.local"' "${PF_CONF}"; then
    sed -i '' 's|rdr-anchor "com.apple/\*"|rdr-anchor "com.apple/*"\
rdr-anchor "com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added rdr-anchor com.local to ${PF_CONF}"
fi

if ! grep -q '^anchor "com.local"' "${PF_CONF}"; then
    sed -i '' 's|^anchor "com.apple/\*"|anchor "com.apple/*"\
anchor "com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added anchor com.local to ${PF_CONF}"
fi

if ! grep -q 'load anchor "com.local"' "${PF_CONF}"; then
    sed -i '' 's|load anchor "com.apple" from.*|&\
load anchor "com.local" from "/etc/pf.anchors/com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added load anchor com.local to ${PF_CONF}"
fi

# ── Enable pf and reload ───────────────────────────────────────────────────

pfctl -e 2>/dev/null || true
pfctl -f "${PF_CONF}"

logger -t pf-dns-redirect "DNS redirect active: UDP+TCP ${DNS_IP}:${DNS_PORT} -> Technitium via proxy/OrbStack"
