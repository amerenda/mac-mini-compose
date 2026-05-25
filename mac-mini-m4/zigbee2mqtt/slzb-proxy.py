#!/usr/bin/env python3
"""
slzb-proxy v3 — TCP keep-alive proxy for SLZB-06MG24 with drain + timeout

Problem: zigbee-herdsman 9.x treats any unexpected RSTACK mid-session as
HOST_FATAL_ERROR, causing Z2M to crash every time the EFR32 sends
RESET_SOFTWARE (which it does for each NVM value that differs from the
stored value on first init).

The burn-in approach: let Z2M crash → EFR32 commits the NVM value to
flash → next restart, that value no longer triggers RESET_SOFTWARE.
Eventually all values are burned in and Z2M starts cleanly.

Two failure modes this proxy fixes:

1. HOST_FATAL_ERROR on new connection — stale RSTACK data from the
   EFR32's RESET_SOFTWARE boot accumulates in the SLZB TCP receive
   buffer while Z2M is crashed. When Z2M reconnects, _slzb_to_client
   reads and forwards the stale RSTACK before Z2M has even sent RST,
   causing immediate HOST_FATAL_ERROR. Fix: drain (discard) data from
   the SLZB socket during the post-disconnect hold period.

2. _slzb_to_client hangs forever — if Z2M crashes with ASH_ERROR_TIMEOUTS
   (adapter sent no data), _slzb_to_client is blocked on recv() with no
   data coming, so session.run() never returns and the hold/drain loop
   never starts. Fix: use select() with a timeout in _slzb_to_client so
   it can check _stop and exit promptly.

Listen: 127.0.0.1:6639  →  SLZB: 10.100.20.179:6638
"""

from __future__ import annotations

import os
import select
import socket
import threading
import time
import syslog
import sys

LISTEN_HOST          = "127.0.0.1"
LISTEN_PORT          = int(os.environ.get("PROXY_LISTEN_PORT", "6639"))
SLZB_HOST            = os.environ.get("SLZB_HOST", "10.100.20.179")
SLZB_PORT            = int(os.environ.get("SLZB_PORT", "6638"))
RECONNECT_DELAY      = 2    # seconds between SLZB reconnect attempts
POST_DISCONNECT_DELAY = 12  # seconds to drain/hold after each Z2M disconnect
SLZB_SELECT_TIMEOUT  = 1.0  # select() timeout in _slzb_to_client (lets _stop be checked)

_log_lock = threading.Lock()


def log(msg: str, level: int = syslog.LOG_INFO) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    with _log_lock:
        print(f"[{ts}] slzb-proxy: {msg}", flush=True)
    syslog.syslog(level, f"slzb-proxy: {msg}")


class SlzbConnection:
    """Persistent keep-alive connection to the SLZB adapter."""

    def __init__(self) -> None:
        self._sock: socket.socket | None = None
        self._lock = threading.Lock()
        self._connected = threading.Event()
        self._shutdown = False

    # ------------------------------------------------------------------
    # Connection management
    # ------------------------------------------------------------------

    def connect(self) -> None:
        """Establish (or re-establish) connection to SLZB, blocking until connected."""
        while not self._shutdown:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(10)
                sock.connect((SLZB_HOST, SLZB_PORT))
                sock.settimeout(None)  # blocking mode for normal I/O
                with self._lock:
                    self._sock = sock
                self._connected.set()
                log(f"Connected to SLZB at {SLZB_HOST}:{SLZB_PORT}")
                return
            except OSError as e:
                log(f"Failed to connect to SLZB: {e} — retrying in {RECONNECT_DELAY}s",
                    syslog.LOG_WARNING)
                time.sleep(RECONNECT_DELAY)

    def reconnect(self) -> None:
        """Drop current connection and re-establish."""
        self._connected.clear()
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
        log("Reconnecting to SLZB...", syslog.LOG_WARNING)
        self.connect()

    def stop(self) -> None:
        self._shutdown = True
        self._connected.set()  # unblock any waiters
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None

    def wait_connected(self) -> None:
        self._connected.wait()

    # ------------------------------------------------------------------
    # Data I/O
    # ------------------------------------------------------------------

    def sendall(self, data: bytes) -> None:
        with self._lock:
            s = self._sock
        if s is None:
            raise OSError("Not connected")
        s.sendall(data)

    def recv_select(self, n: int, timeout: float) -> bytes | None:
        """Read up to n bytes with a select() timeout.

        Returns:
            bytes — data read (may be empty → connection closed)
            None  — select() timed out (no data within `timeout` seconds)

        Raises:
            OSError — socket error or not connected
        """
        with self._lock:
            s = self._sock
        if s is None:
            raise OSError("Not connected")
        try:
            rlist, _, _ = select.select([s], [], [], timeout)
        except (ValueError, OSError) as e:
            raise OSError(f"select error: {e}") from e
        if not rlist:
            return None  # timeout
        return s.recv(n)

    def drain(self, duration: float) -> None:
        """Read and discard all data arriving from SLZB for `duration` seconds.

        Called during the post-disconnect hold period to flush stale RSTACK
        frames that the EFR32 emits after completing a RESET_SOFTWARE boot.
        Without this, the next Z2M session would receive the stale RSTACK
        before sending RST and crash with HOST_FATAL_ERROR.
        """
        end = time.monotonic() + duration
        discarded = 0
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            try:
                data = self.recv_select(4096, timeout=min(remaining, 0.5))
            except OSError as e:
                log(f"SLZB error during drain: {e} — reconnecting", syslog.LOG_WARNING)
                self.reconnect()
                return
            if data is None:
                continue  # select timeout — keep draining
            if not data:
                log("SLZB closed connection during drain — reconnecting", syslog.LOG_WARNING)
                self.reconnect()
                return
            discarded += len(data)
        if discarded:
            log(f"Drain complete — discarded {discarded} bytes of stale adapter data")


class ClientSession:
    """Manages a single Z2M connection, bridging it to the shared SLZB connection."""

    def __init__(self, client_sock: socket.socket, addr: tuple,
                 slzb: SlzbConnection) -> None:
        self.client_sock = client_sock
        self.addr = addr
        self.slzb = slzb
        self._stop = threading.Event()

    def run(self) -> None:
        log(f"Z2M client connected from {self.addr[0]}:{self.addr[1]}")
        self.slzb.wait_connected()

        t_c2s = threading.Thread(target=self._client_to_slzb, daemon=True)
        t_s2c = threading.Thread(target=self._slzb_to_client, daemon=True)
        t_c2s.start()
        t_s2c.start()
        t_c2s.join()
        t_s2c.join()

        try:
            self.client_sock.close()
        except OSError:
            pass
        log(f"Z2M client disconnected — SLZB connection preserved")

    def _client_to_slzb(self) -> None:
        """Forward Z2M → SLZB."""
        while not self._stop.is_set():
            try:
                data = self.client_sock.recv(4096)
                if not data:
                    self._stop.set()
                    return
                self.slzb.sendall(data)
            except OSError:
                self._stop.set()
                return

    def _slzb_to_client(self) -> None:
        """Forward SLZB → Z2M.

        Uses select() with a short timeout so _stop can be checked promptly.
        This prevents the thread from hanging forever when Z2M crashes with
        ASH_ERROR_TIMEOUTS (adapter sends no data, recv() would block forever).
        """
        while not self._stop.is_set():
            try:
                data = self.slzb.recv_select(4096, timeout=SLZB_SELECT_TIMEOUT)
            except OSError:
                self._stop.set()
                return
            if data is None:
                continue  # select timeout — loop back, check _stop
            if not data:
                # SLZB side closed — reconnect backend
                self._stop.set()
                log("SLZB closed connection unexpectedly — triggering reconnect",
                    syslog.LOG_WARNING)
                threading.Thread(target=self.slzb.reconnect, daemon=True).start()
                return
            try:
                self.client_sock.sendall(data)
            except OSError:
                self._stop.set()
                return


def serve(slzb: SlzbConnection) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(1)
    log(f"Listening on {LISTEN_HOST}:{LISTEN_PORT} "
        f"(post-disconnect drain: {POST_DISCONNECT_DELAY}s)")

    last_disconnect = None  # None = first run, no hold needed

    while True:
        # Hold and drain after each Z2M disconnect
        if last_disconnect is not None:
            elapsed = time.monotonic() - last_disconnect
            remaining = POST_DISCONNECT_DELAY - elapsed
            if remaining > 0:
                log(f"Holding {remaining:.1f}s — draining stale adapter data")
                slzb.drain(remaining)

        try:
            client_sock, addr = server.accept()
        except OSError as e:
            log(f"Accept error: {e}", syslog.LOG_ERR)
            break

        session = ClientSession(client_sock, addr, slzb)
        session.run()  # synchronous — only one Z2M client at a time
        last_disconnect = time.monotonic()


def main() -> None:
    log(f"Starting — forwarding {LISTEN_HOST}:{LISTEN_PORT} → {SLZB_HOST}:{SLZB_PORT}")
    slzb = SlzbConnection()
    slzb.connect()
    serve(slzb)


if __name__ == "__main__":
    main()
