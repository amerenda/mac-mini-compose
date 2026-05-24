#!/bin/bash
# pf-dns-redirect.sh — Configure DNS IP alias and IP forwarding.
#
# Adds 10.100.20.240 as an alias on en0 — the dedicated DNS endpoint
# that LAN and Tailscale clients point to. dns-udp-proxy.py (separate
# LaunchDaemon) listens on 10.100.20.240:53 and forwards queries to
# Technitium via OrbStack's localhost forwarder on port 5354.
#
# Why no pf redirect:
#   pf rdr would need to redirect en0 traffic to bridge100 (OrbStack VM),
#   but stateful return-path tracking fails across interfaces on macOS —
#   the reply arrives on bridge100 without matching the state created on en0.
#   The userspace proxy (dns-udp-proxy.py) sidesteps this entirely.
#
# Runs as root via LaunchDaemon at boot.

set -euo pipefail

IFACE="en0"
DNS_IP="10.100.20.240"

# ── Add DNS IP alias to en0 ────────────────────────────────────────────────
# Idempotent — ifconfig alias is a no-op if already present.

ifconfig ${IFACE} alias ${DNS_IP}/24
logger -t pf-dns-redirect "IP alias ${DNS_IP} on ${IFACE} configured"

# ── Enable IP forwarding ───────────────────────────────────────────────────

sysctl -w net.inet.ip.forwarding=1
logger -t pf-dns-redirect "IP forwarding enabled"

# ── Clear any leftover pf anchor rules ────────────────────────────────────
# Previous versions used pf rdr redirect to port 15354/5354.
# Those rules are no longer needed; dns-udp-proxy.py handles port 53 directly.

if [ -f /etc/pf.anchors/com.local ]; then
    printf '# DNS redirects handled by dns-udp-proxy.py LaunchDaemon\n' \
        > /etc/pf.anchors/com.local
    pfctl -e 2>/dev/null || true
    pfctl -f /etc/pf.conf 2>/dev/null || true
    logger -t pf-dns-redirect "pf anchor com.local cleared"
fi

logger -t pf-dns-redirect "Setup complete: ${DNS_IP} alias on ${IFACE}, dns-udp-proxy handles :53"
