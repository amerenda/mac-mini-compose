#!/usr/bin/env python3
"""
slzb-proxy v4 — TCP keep-alive proxy for SLZB-06MG24 with drain + timeout

Background: SLZB-OS 3.3.1 "reboot EFR32 at startup" wiped the EFR32's NVM.
This causes Z2M (herdsman 9.x) to crash via RESET_SOFTWARE at runtime.

What this proxy fixes (3 failure modes):

1. HOST_FATAL_ERROR on new connection — stale RSTACK data accumulates in
   the SLZB TCP receive buffer while Z2M is crashed. When Z2M reconnects,
   _slzb_to_client reads and forwards the stale RSTACK before Z2M has even
   sent RST, causing immediate HOST_FATAL_ERROR. Fix: drain (discard) data
   from the SLZB socket during the post-disconnect hold period. Also cycles
   the SLZB TCP connection after each Z2M disconnect to let the EFR32 detect
   a host disconnect and commit pending NVM values to flash (burn-in).

2. _slzb_to_client hangs forever — if Z2M crashes with ASH_ERROR_TIMEOUTS
   (adapter sent no data), _slzb_to_client is blocked on recv() with no
   data coming, so session.run() never returns and the hold/drain loop
   never starts. Fix: use select() with a timeout in _slzb_to_client so
   it can check _stop and exit promptly.

3. Stale-connection churn — during the drain period Z2M crashes and restarts
   multiple times. The OS queues these stale TCP connections in the backlog.
   When the drain ends and the proxy calls accept(), it gets a stale CLOSE_WAIT
   connection that immediately returns EOF, triggering another unnecessary drain
   cycle. Fix: track session duration; sessions < MIN_REAL_SESSION_DURATION are
   stale and skipped (SLZB not cycled, no drain started).

What this proxy DOES NOT fix:
  - The EFR32 firmware bug (8.0.2 b397) that sends RESET_SOFTWARE at runtime
    ~7s after "Zigbee2MQTT started!" regardless of Z2M's commands. This is an
    EFR32 firmware bug — no proxy timing can prevent it. Only updating the
    EFR32 Zigbee coordinator firmware via http://10.100.20.179 → Settings →
    Firmware update → Flash latest Zigbee coordinator firmware will fix this.

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
POST_DISCONNECT_DELAY = 45  # seconds to drain/hold after each Z2M disconnect
# Minimum session duration to be considered a "real" Z2M connection. Sessions
# shorter than this are stale sockets (Z2M crashed before the proxy accepted them)
# and should not trigger a SLZB drain cycle.
MIN_REAL_SESSION_DURATION = 5.0  # seconds
SLZB_SELECT_TIMEOUT  = 1.0  # select() timeout in _slzb_to_client (lets _stop be checked)
# After each Z2M disconnect, close and reconnect the SLZB TCP connection before
# draining. This lets the EFR32 detect a host disconnect and complete its
# post-hard-reset initialization (triggered by SLZB-OS 3.3.1 "reboot EFR32 at
# startup"). After the proxy reconnects to SLZB, the EFR32 starts a new
# initialization cycle:
#   T+0s : proxy reconnects TCP to SLZB-OS
#   T+8s : EFR32 completes init, spontaneously sends RESET_SOFTWARE
#   T+13s: EFR32 finishes post-reset boot and is stable
# The drain period (POST_DISCONNECT_DELAY - SLZB_RECONNECT_PAUSE) must be > 13s
# to let the EFR32's post-init reset + boot complete before Z2M connects.
# With SLZB_RECONNECT_PAUSE=20 and POST_DISCONNECT_DELAY=45: drain=25s > 13s ✓
# Set to False to revert to the original keep-alive behavior.
RECONNECT_SLZB_AFTER_Z2M_DISCONNECT = True
SLZB_RECONNECT_PAUSE = 20.0  # seconds to wait after closing before reconnecting

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

    def reconnect_after_pause(self, pause: float) -> None:
        """Close SLZB connection, wait pause seconds, then reconnect.

        The pause lets the EFR32 detect the host disconnect and commit pending
        NVM values to flash before we reconnect. Called after each Z2M session
        ends to enable NVM burn-in convergence.
        """
        self._connected.clear()
        with self._lock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
                self._sock = None
        log(f"SLZB connection closed — waiting {pause}s for EFR32 NVM commit",
            syslog.LOG_INFO)
        time.sleep(pause)
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
        # Hold and drain after each real Z2M disconnect.
        # last_disconnect is cleared (set to None) after drain completes, so
        # stale connections (< MIN_REAL_SESSION_DURATION) don't re-trigger drain.
        if last_disconnect is not None:
            elapsed = time.monotonic() - last_disconnect
            remaining = POST_DISCONNECT_DELAY - elapsed
            if remaining > 0:
                if RECONNECT_SLZB_AFTER_Z2M_DISCONNECT:
                    # Close and reconnect to SLZB so the EFR32 detects a host
                    # disconnect and completes its post-hard-reset initialization.
                    # SLZB_RECONNECT_PAUSE must be long enough for the EFR32 to
                    # complete its init cycle and spontaneous reset before Z2M
                    # reconnects (see module docstring for timing details).
                    log(f"Cycling SLZB connection — closing to trigger EFR32 NVM commit, "
                        f"reconnecting in {SLZB_RECONNECT_PAUSE}s")
                    slzb.reconnect_after_pause(SLZB_RECONNECT_PAUSE)
                    # Recalculate remaining drain time after reconnect
                    elapsed = time.monotonic() - last_disconnect
                    remaining = POST_DISCONNECT_DELAY - elapsed
                if remaining > 0:
                    log(f"Holding {remaining:.1f}s — draining stale adapter data")
                    slzb.drain(remaining)
            # Clear after drain — stale connections won't re-trigger drain cycle
            last_disconnect = None

        try:
            client_sock, addr = server.accept()
        except OSError as e:
            log(f"Accept error: {e}", syslog.LOG_ERR)
            break

        session_start = time.monotonic()
        session = ClientSession(client_sock, addr, slzb)
        session.run()  # synchronous — only one Z2M client at a time
        session_duration = time.monotonic() - session_start

        if session_duration < MIN_REAL_SESSION_DURATION:
            # Very short session = stale socket (Z2M crashed before proxy accepted it,
            # leaving a CLOSE_WAIT connection in the OS backlog). The EFR32 state
            # has not been disturbed — skip the SLZB drain cycle and just try the
            # next accept() to get a fresh connection from Docker's restarted Z2M.
            # last_disconnect is already None at this point (cleared above), so the
            # next loop iteration will skip the drain check and go straight to accept().
            log(f"Short session ({session_duration:.1f}s) — stale connection, "
                "skipping SLZB cycle")
            continue

        last_disconnect = time.monotonic()


def main() -> None:
    log(f"Starting — forwarding {LISTEN_HOST}:{LISTEN_PORT} → {SLZB_HOST}:{SLZB_PORT}")
    slzb = SlzbConnection()
    slzb.connect()
    serve(slzb)


if __name__ == "__main__":
    main()
