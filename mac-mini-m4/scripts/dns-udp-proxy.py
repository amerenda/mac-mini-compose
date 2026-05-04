#!/usr/bin/env python3
"""
dns-proxy.py — UDP + TCP DNS proxy: 10.100.20.240:15354 -> OrbStack VM:5354

pf-dns-redirect.sh redirects DNS port 53 (UDP and TCP) to port 15354.
This script receives those packets and forwards them to Technitium
running inside the OrbStack VM (network_mode: host).

Why a userspace proxy:
  Tailscale installs a route for 10.100.20.0/24 via utun0, so replies
  from plain sockets get routed through the Tailscale tunnel instead of
  en0. IP_BOUND_IF pins sockets to en0 so all sends go via the LAN.

Runs as root via LaunchDaemon at boot.
"""

import socket
import struct
import threading
import syslog
import sys
import ipaddress

LISTEN_IP    = "10.100.20.240"
LISTEN_PORT  = 15354
BACKEND_IP   = "192.168.139.2"
BACKEND_PORT = 5354
TIMEOUT      = 3

# macOS <netinet/in.h> — bind socket to a specific interface index
IP_BOUND_IF  = 25


def en0_bound_socket(kind: int) -> socket.socket:
    """Create a socket bound to en0 so replies go via LAN, not Tailscale."""
    s = socket.socket(socket.AF_INET, kind)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, socket.if_nametoindex("en0"))
    return s


# ── EDNS Client Subnet ───────────────────────────────────────────────────────

def _build_ecs_option(client_ip: str) -> bytes:
    """Build an EDNS Client Subnet option (RFC 7871) for an IPv4 address."""
    addr = ipaddress.IPv4Address(client_ip)
    prefix_len = 32
    addr_bytes = addr.packed
    # OPTION-CODE=8 (CLIENT-SUBNET), FAMILY=1 (IPv4), SOURCE PREFIX, SCOPE=0
    option_data = struct.pack("!HBB", 1, prefix_len, 0) + addr_bytes
    return struct.pack("!HH", 8, len(option_data)) + option_data


def _add_ecs_to_query(data: bytes, client_ip: str) -> bytes:
    """Inject EDNS Client Subnet into a DNS query so the backend sees the real client IP."""
    if len(data) < 12:
        return data
    # Parse header
    qdcount = struct.unpack("!H", data[4:6])[0]
    arcount = struct.unpack("!H", data[10:12])[0]

    # Walk past question section to find additional section
    offset = 12
    for _ in range(qdcount):
        while offset < len(data) and data[offset] != 0:
            if (data[offset] & 0xC0) == 0xC0:
                offset += 2
                break
            offset += 1 + data[offset]
        else:
            offset += 1  # skip null terminator
        offset += 4  # QTYPE + QCLASS

    ecs_opt = _build_ecs_option(client_ip)

    # Check if an OPT record already exists
    saved = offset
    for _ in range(arcount if qdcount else 0):
        # Skip answer + authority sections (we only parsed questions)
        break

    # Simple approach: if there's already an OPT RR (arcount > 0 and last record
    # is type 41), we'd need to splice into it. For simplicity, if no OPT exists,
    # append one. If one exists, skip ECS injection rather than risk corruption.
    if arcount > 0:
        return data

    # Build OPT pseudo-RR: NAME=0, TYPE=41, UDP=4096, RCODE=0, VERSION=0, FLAGS=0
    opt_rr = b'\x00'  # NAME (root)
    opt_rr += struct.pack("!H", 41)  # TYPE = OPT
    opt_rr += struct.pack("!H", 4096)  # UDP payload size
    opt_rr += struct.pack("!I", 0)  # extended RCODE + flags
    opt_rr += struct.pack("!H", len(ecs_opt))  # RDLENGTH
    opt_rr += ecs_opt

    # Update ARCOUNT
    new_arcount = arcount + 1
    data = data[:10] + struct.pack("!H", new_arcount) + data[12:]
    return data + opt_rr


def _strip_ecs_from_response(data: bytes) -> bytes:
    """Pass response through unchanged — Technitium may echo ECS back, clients handle it fine."""
    return data


# ── UDP ───────────────────────────────────────────────────────────────────────

def handle_udp(data: bytes, client_addr: tuple, listen_sock: socket.socket) -> None:
    try:
        tagged = _add_ecs_to_query(data, client_addr[0])
        be = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        be.settimeout(TIMEOUT)
        be.sendto(tagged, (BACKEND_IP, BACKEND_PORT))
        resp, _ = be.recvfrom(4096)
        listen_sock.sendto(resp, client_addr)
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING, f"dns-proxy UDP: {client_addr}: {e}")
    finally:
        be.close()


def udp_listener() -> None:
    sock = en0_bound_socket(socket.SOCK_DGRAM)
    sock.bind((LISTEN_IP, LISTEN_PORT))
    syslog.syslog(syslog.LOG_INFO, f"dns-proxy: UDP listening on {LISTEN_IP}:{LISTEN_PORT}")
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except OSError as e:
            syslog.syslog(syslog.LOG_ERR, f"dns-proxy UDP recv: {e}")
            sys.exit(1)
        threading.Thread(target=handle_udp, args=(data, addr, sock), daemon=True).start()


# ── TCP ───────────────────────────────────────────────────────────────────────

def recv_dns_tcp(s: socket.socket) -> bytes:
    """Read a DNS-over-TCP message (2-byte length prefix + payload)."""
    raw_len = s.recv(2)
    if len(raw_len) < 2:
        return b""
    msg_len = struct.unpack("!H", raw_len)[0]
    data = b""
    while len(data) < msg_len:
        chunk = s.recv(msg_len - len(data))
        if not chunk:
            break
        data += chunk
    return data


def handle_tcp(conn: socket.socket, client_addr: tuple) -> None:
    try:
        conn.settimeout(TIMEOUT)
        query = recv_dns_tcp(conn)
        if not query:
            return
        be = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        be.settimeout(TIMEOUT)
        be.connect((BACKEND_IP, BACKEND_PORT))
        be.sendall(struct.pack("!H", len(query)) + query)
        resp = recv_dns_tcp(be)
        be.close()
        if resp:
            conn.sendall(struct.pack("!H", len(resp)) + resp)
    except Exception as e:
        syslog.syslog(syslog.LOG_WARNING, f"dns-proxy TCP: {client_addr}: {e}")
    finally:
        conn.close()


def tcp_listener() -> None:
    sock = en0_bound_socket(socket.SOCK_STREAM)
    sock.bind((LISTEN_IP, LISTEN_PORT))
    sock.listen(32)
    syslog.syslog(syslog.LOG_INFO, f"dns-proxy: TCP listening on {LISTEN_IP}:{LISTEN_PORT}")
    while True:
        try:
            conn, addr = sock.accept()
        except OSError as e:
            syslog.syslog(syslog.LOG_ERR, f"dns-proxy TCP accept: {e}")
            sys.exit(1)
        threading.Thread(target=handle_tcp, args=(conn, addr), daemon=True).start()


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    threading.Thread(target=udp_listener, daemon=True).start()
    threading.Thread(target=tcp_listener, daemon=True).start()
    syslog.syslog(syslog.LOG_INFO, f"dns-proxy: started on {LISTEN_IP}:{LISTEN_PORT}")
    threading.Event().wait()  # block forever


if __name__ == "__main__":
    main()
