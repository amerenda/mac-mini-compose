# Z2M Crash Loop Investigation — 2026-05-25

## Summary

Z2M crashes every ~35 seconds due to two compounding firmware issues. One is
partially mitigated; the other requires a manual EFR32 firmware update.

**The only permanent fix: update the EFR32 coordinator firmware at http://10.100.20.179**

---

## Root Causes

### Issue 1 — SLZB-OS 3.3.1 (ESP32 layer) — PARTIALLY MITIGATED

**SLZB-OS 3.3.1** added: *"OS will now reboot the EFR32 radios at startup"*.
This hard-resets the EFR32 when the SLZB device boots, wiping its NVM state.

**Status:** SLZB-OS downgraded to **3.2.4** (2026-05-25). The EFR32 is no longer
force-rebooted on each SLZB startup. However, the NVM was already wiped by 3.3.1,
and the crash loop continues due to Issue 2 below.

### Issue 2 — EFR32 Zigbee coordinator firmware 8.0.2 b397 — REQUIRES FIRMWARE UPDATE

After the EFR32's NVM was wiped by 3.3.1, every Z2M session triggers two
RESET_SOFTWARE events:

1. **Init-phase (T+17s, SET_CONFIGURATION_VALUE):** herdsman 9.x handles with
   one startup retry — re-establishes ASH, continues to "Zigbee2MQTT started!".

2. **Runtime (T+7s after started!):** EFR32 sends RESET_SOFTWARE spontaneously
   at exactly ~7 seconds after "started!" with no triggering Z2M command. No
   debug EZSP frames appear between "started!" and the crash — the reset is
   purely internal to the EFR32 firmware. This is a bug in EFR32 8.0.2 b397.

   Confirmed non-causes (tested):
   - NOT the availability ping (crash persists with availability disabled)
   - NOT SET_CONFIGURATION_VALUE (happens 7s after startup completes, not during init)
   - NOT any Z2M command (zero EZSP frames logged in the 7s window)

**No proxy or software workaround can prevent the runtime RESET_SOFTWARE.**
The EFR32 firmware 8.0.2 b397 has this bug. Updating it is the only fix.

---

## Crash Timeline (current)

```
T+0s   : Docker restarts Z2M
T+0-12s: Z2M waits for slzb-proxy drain period to end
T+12s  : Z2M connects to SLZB via proxy
T+17s  : RESET_SOFTWARE (SET_CONFIGURATION_VALUE) — STARTUP, handled by herdsman retry
T+22s  : Zigbee2MQTT started!
T+29s  : RESET_SOFTWARE (spontaneous, runtime bug in EFR32 8.0.2 b397) — FATAL
T+29s  : Adapter disconnected, stopping → Z2M process exits
T+30s  : Docker restarts Z2M (restart: unless-stopped)
… repeat …
```

---

## ⚠️ REQUIRED ACTION: Update EFR32 Coordinator Firmware

**Go to http://10.100.20.179 → Settings → Firmware update → Flash latest
Zigbee coordinator firmware**

This replaces EFR32 8.0.2 b397 with a version that does not have the runtime
RESET_SOFTWARE bug. Community confirms: SLZB-OS 3.3.1 + Z2M 2.10.x + updated
EFR32 firmware works stably.

After updating:
- Delete `sl-pushed-hash.json` from zigbee2mqtt-data volume to trigger a scene
  re-push: `docker run --rm -v services_zigbee2mqtt-data:/data alpine rm /data/sl-pushed-hash.json`
- Then restart Z2M to push scenes to all bulbs

---

## Fixes Applied (2026-05-25)

### 1. Removed startup scene push (`smart-lighting.js`, commit 3de6e40)

**Before:** Extension had `setTimeout(() => this._fullScenePush(), 5000)` on every start.
Each `scene_add` command → `SET_MULTICAST_TABLE_ENTRY` → RESET_SOFTWARE → crash.

**After:** Startup push removed entirely. Hash-based guard added. HA's periodic
`zigbee2mqtt/sl/config` push only triggers `_fullScenePush()` if the config hash
has actually changed since the last successful push.

**Verification:** Logs show `[SL] Scenes up to date on bulbs (hash=d97535f0097c)` — no
scene push triggered.

### 2. Removed stray ingress (commit 553c3ca)

`infra/ingresses/z2m-ingress-amer-dev.yaml` had wrong IP and wrong repo. Deleted.

### 3. Cleared stale MQTT retained extension message

Z2M stores its loaded extension code as a retained MQTT message on
`zigbee2mqtt/bridge/extensions`. If Z2M crashes and restarts with new file code,
the retained message (old code) overrides the file. Fix procedure:

```bash
# Stop Z2M, clear retained message, start Z2M (in this order!)
docker stop zigbee2mqtt
docker exec mosquitto mosquitto_pub -h 127.0.0.1 -p 1883 \
  -t 'zigbee2mqtt/bridge/extensions' -n -r
docker start zigbee2mqtt
```

### 4. Downgraded SLZB-OS to 3.2.4

Downgraded from 3.3.1 to 3.2.4 via http://10.100.20.179 → Settings → Core firmware.
This stops the EFR32 from being force-rebooted on each SLZB startup. The crash loop
continues due to the runtime RESET_SOFTWARE bug in EFR32 8.0.2 b397 (Issue 2).

### 5. slzb-proxy.py — stale connection detection + improved drain cycle

`slzb-proxy.py` updated with:
- `POST_DISCONNECT_DELAY = 45s` (was 12s) — long enough to drain stale RSTACK data
  from the SLZB buffer after each Z2M crash
- `SLZB_RECONNECT_PAUSE = 20s` (was 2s) — close and reopen SLZB TCP after each Z2M
  disconnect, waiting 20s for the EFR32 to detect a host disconnect and commit NVM
- `MIN_REAL_SESSION_DURATION = 5.0s` — skip drain cycle for stale connections
  (Z2M instances that crashed before the proxy accepted their connection)

The proxy now correctly handles the init-phase RESET_SOFTWAREs and prevents
HOST_FATAL_ERROR from stale RSTACK data. The runtime RESET_SOFTWARE at T+7s
after "started!" cannot be prevented by the proxy.

---

## Architecture

```
[Z2M container] → tcp://127.0.0.1:6639 → [slzb-proxy.py] → tcp://10.100.20.179:6638
                                                                → [SLZB-06MG24 Ethernet adapter]
                                                                    → [EFR32MG24 Zigbee chip]
```

**slzb-proxy.py** keeps the SLZB TCP connection alive across Z2M restarts, drains
stale RSTACK frames after each Z2M disconnect, and cycles the SLZB TCP connection
to let the EFR32 detect host disconnect (NVM burn-in). Deployed on mac-mini-m4 at
`~/docker/zigbee2mqtt/slzb-proxy.py` (PID managed manually; autostart via launchd TBD).

**Scenes are stored in bulb flash** — not in Z2M, not in the coordinator. They survive
Z2M restarts, coordinator resets, and power cycles. HA is NOT in the critical path for
lighting (switches → scene_recall ZCL → bulb applies stored scene directly).

---

## Upgrade Path (after EFR32 firmware update)

1. ✅ (done) Downgrade SLZB-OS to 3.2.4
2. ⬜ **Update EFR32 coordinator firmware** (the immediate fix needed)
3. ⬜ Then optionally upgrade SLZB-OS back to 3.3.1 (or keep 3.2.4)
4. ⬜ Then upgrade Z2M to 2.10.x in compose.yaml (after EFR32 update)

**DO NOT upgrade Z2M past 2.9.1 until EFR32 firmware is updated** — herdsman 10.x
(Z2M 2.9.2+) triggers SET_CONFIGURATION_VALUE → RESET_SOFTWARE on EFR32 8.0.2 b397.
