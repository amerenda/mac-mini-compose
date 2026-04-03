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
# Load rules directly into com.local (not a sub-anchor) so rdr-anchor
# "com.local" in pf.conf evaluates them — sub-anchors are not walked.
ANCHOR="com.local"
ANCHOR_FILE="/etc/pf.anchors/com.local"
PF_CONF="/etc/pf.conf"

# Testing: 5354->5354. Change DNS_PORT to 53 at LAN cutover.
DNS_PORT=5354
TECHNITIUM_PORT=5354

# OrbStack Linux VM IP — Technitium runs here in network_mode: host.
# Redirect to VM directly so the VM's response routes back to the LAN
# via the OrbStack bridge without needing NAT masquerade on loopback.
# Find with: docker exec technitium hostname -I | awk '{print $1}'
ORBSTACK_VM_IP="192.168.139.2"

logger -t pf-dns-redirect "Setting up DNS redirect on ${IFACE}:${DNS_PORT} -> 127.0.0.1:${TECHNITIUM_PORT}"

# ── Write anchor rules ──────────────────────────────────────────────────────

mkdir -p /etc/pf.anchors
cat > "${ANCHOR_FILE}" <<EOF
# Redirect to OrbStack VM directly. VM routes responses back to LAN
# via OrbStack bridge — no NAT masquerade needed.
rdr pass on ${IFACE} proto udp from any to 10.100.20.18 port ${DNS_PORT} -> ${ORBSTACK_VM_IP} port ${TECHNITIUM_PORT}
rdr pass on ${IFACE} proto tcp from any to 10.100.20.18 port ${DNS_PORT} -> ${ORBSTACK_VM_IP} port ${TECHNITIUM_PORT}
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

logger -t pf-dns-redirect "DNS redirect active: 10.100.20.18:${DNS_PORT} -> 127.0.0.1:${TECHNITIUM_PORT}"
