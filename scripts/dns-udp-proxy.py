#!/usr/bin/env python3
"""
dns-udp-proxy.py — UDP DNS proxy: LAN IP:5355 -> OrbStack VM:5354

pf-dns-redirect.sh redirects DNS_PORT (5354/53) UDP to LAN_IP:5355.
This script receives those UDP packets and forwards them to Technitium
running inside the OrbStack VM (network_mode: host).

Why a userspace proxy instead of pure pf rdr to the VM IP:
  macOS will not route packets originally destined for its own LAN IP
  (10.100.20.18) to bridge100 after pf rdr changes the dst to 192.168.139.2.
  By redirecting to the same LAN IP on a different port, macOS delivers the
  packet locally; this script forwards it to the VM from a normal outbound
  socket that routes correctly through bridge100.

Runs as root via LaunchDaemon at boot.
"""

import socket
import threading
import syslog
import sys

LISTEN_IP   = "10.100.20.18"
LISTEN_PORT = 5355
BACKEND_IP  = "192.168.139.2"
BACKEND_PORT = 5354
TIMEOUT     = 3  # seconds to wait for backend response


def handle(data: bytes, client_addr: tuple, listen_sock: socket.socket) -> None:
    """Forward one DNS query to the backend and relay the response."""
    try:
        be = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        be.settimeout(TIMEOUT)
        be.sendto(data, (BACKEND_IP, BACKEND_PORT))
        resp, _ = be.recvfrom(4096)
        listen_sock.sendto(resp, client_addr)
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING, f"dns-udp-proxy: forward error for {client_addr}: {e}")
    finally:
        be.close()


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((LISTEN_IP, LISTEN_PORT))

    syslog.syslog(
        syslog.LOG_INFO,
        f"dns-udp-proxy: listening {LISTEN_IP}:{LISTEN_PORT} -> {BACKEND_IP}:{BACKEND_PORT}"
    )

    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except OSError as e:
            syslog.syslog(syslog.LOG_ERR, f"dns-udp-proxy: recv error: {e}")
            sys.exit(1)
        t = threading.Thread(target=handle, args=(data, addr, sock), daemon=True)
        t.start()


if __name__ == "__main__":
    main()
