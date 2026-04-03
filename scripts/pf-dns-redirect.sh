#!/bin/bash
# pf-dns-redirect.sh — Redirect DNS traffic to Technitium container.
#
# OrbStack intercepts *:53, *:5353, and *:5354 and does not forward LAN UDP
# to containers. pf intercepts at the NIC before OrbStack sees packets.
#
# Strategy:
#   UDP: pf redirects 10.100.20.18:DNS_PORT -> 10.100.20.18:5355 (socat port).
#        socat-dns-proxy.sh listens on :5355 and forwards to OrbStack VM.
#        Staying on the same LAN IP means macOS delivers the packet locally.
#   TCP: OrbStack's *:5354 binding already forwards TCP to the VM; pf rule
#        is kept for consistency but TCP works without it.
#
# Testing phase:  DNS_PORT=5354. Test with: dig @10.100.20.18 -p 5354 ...
# Cutover phase:  change DNS_PORT=53 so LAN clients use standard port.
#
# Runs as root via LaunchDaemon at boot.

set -euo pipefail

# LAN interface — the one with the 10.100.20.18 address
IFACE="en0"
LAN_IP="10.100.20.18"
# Load rules directly into com.local (not a sub-anchor) so rdr-anchor
# "com.local" in pf.conf evaluates them — sub-anchors are not walked.
ANCHOR="com.local"
ANCHOR_FILE="/etc/pf.anchors/com.local"
PF_CONF="/etc/pf.conf"

# Cutover: redirecting port 53 (standard DNS).
DNS_PORT=53
# dns-udp-proxy.py listens here and forwards to OrbStack VM.
SOCAT_PORT=15354

# OrbStack Linux VM IP — Technitium runs here in network_mode: host.
ORBSTACK_VM_IP="192.168.139.2"
TECHNITIUM_PORT=5354

logger -t pf-dns-redirect "Setting up DNS redirect on ${IFACE}:${DNS_PORT} -> ${LAN_IP}:${SOCAT_PORT} (socat -> ${ORBSTACK_VM_IP}:${TECHNITIUM_PORT})"

# ── Enable IP forwarding ───────────────────────────────────────────────────
# Required so macOS forwards pf-redirected packets from en0 to the OrbStack
# VM network (192.168.139.x). Made persistent via /etc/sysctl.conf by Ansible.

sysctl -w net.inet.ip.forwarding=1
logger -t pf-dns-redirect "IP forwarding enabled"

# ── Write anchor rules ──────────────────────────────────────────────────────

mkdir -p /etc/pf.anchors
cat > "${ANCHOR_FILE}" <<EOF
# UDP: redirect to socat listener on same LAN IP (${LAN_IP}:${SOCAT_PORT}).
# macOS delivers the packet locally; socat forwards to OrbStack VM.
# This avoids the "locally-destined packets don't route to bridge100" problem.
rdr pass on ${IFACE} proto udp from any to ${LAN_IP} port ${DNS_PORT} -> ${LAN_IP} port ${SOCAT_PORT}
# TCP: OrbStack *:${TECHNITIUM_PORT} already handles TCP forwarding to the VM.
# Kept here for consistency at DNS_PORT=53 cutover.
rdr pass on ${IFACE} proto tcp from any to ${LAN_IP} port ${DNS_PORT} -> ${ORBSTACK_VM_IP} port ${TECHNITIUM_PORT}
EOF

# ── Clean up any previous bad append (appended at end = wrong order) ──────

if grep -q '# Local service redirects' "${PF_CONF}"; then
    sed -i '' '/^# Local service redirects/d' "${PF_CONF}"
    logger -t pf-dns-redirect "Removed previous appended rules from ${PF_CONF}"
fi

# Remove old sub-anchor load line if present (replaced by com.local directly)
sed -i '' '/^load anchor "com.local\/dns-redirect"/d' "${PF_CONF}" 2>/dev/null || true

# ── Ensure pf.conf references our anchors ─────────────────────────────────
# pf requires strict ordering: normalization, translation (rdr), filtering.
# Insert each directive after its corresponding com.apple counterpart.
# Safe to re-run (idempotent).

if ! grep -q 'rdr-anchor "com.local"' "${PF_CONF}"; then
    # rdr-anchor goes after rdr-anchor "com.apple/*"
    sed -i '' 's|rdr-anchor "com.apple/\*"|rdr-anchor "com.apple/*"\
rdr-anchor "com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added rdr-anchor com.local to ${PF_CONF}"
fi

if ! grep -q '^anchor "com.local"' "${PF_CONF}"; then
    # anchor goes after anchor "com.apple/*"
    sed -i '' 's|^anchor "com.apple/\*"|anchor "com.apple/*"\
anchor "com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added anchor com.local to ${PF_CONF}"
fi

if ! grep -q 'load anchor "com.local"' "${PF_CONF}"; then
    # load directive goes after load anchor "com.apple"
    sed -i '' 's|load anchor "com.apple" from.*|&\
load anchor "com.local" from "/etc/pf.anchors/com.local"|' "${PF_CONF}"
    logger -t pf-dns-redirect "Added load anchor com.local to ${PF_CONF}"
fi

# ── Enable pf and reload ───────────────────────────────────────────────────

pfctl -e 2>/dev/null || true
pfctl -f "${PF_CONF}"

logger -t pf-dns-redirect "pf rules active: UDP ${LAN_IP}:${DNS_PORT} -> ${LAN_IP}:${SOCAT_PORT} (socat proxy to ${ORBSTACK_VM_IP}:${TECHNITIUM_PORT})"
