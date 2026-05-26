# Z2M Crash Loop Investigation — 2026-05-25

## Summary

Z2M crashes every ~35 seconds (7 seconds after startup) due to SLZB firmware bug
in SLZB-06MG24 firmware **8.0.2 build 397** that sends `RESET_SOFTWARE` in response
to certain EZSP commands at runtime.

**Permanent fix:** Update SLZB coordinator firmware at http://10.100.20.179
(Settings → Firmware update → Flash latest Zigbee coordinator firmware).

---

## Root Cause

### Issue 1 — SLZB-OS device firmware 3.3.1 (ESP32 layer) — PRIMARY CRASH CAUSE

**SLZB-OS 3.3.1** added: *"OS will now reboot the EFR32 radios at startup"*.
This hard-resets the EFR32 when the SLZB device boots, which wipes/resets the EFR32's
NVM state and triggers `RESET_SOFTWARE` at runtime (~7s after `Zigbee2MQTT started!`)
as the EFR32 finishes its re-initialization. With herdsman 9.x, runtime `RESET_SOFTWARE`
has no retry → `Adapter disconnected, stopping` → crash loop.

**The crash loop started immediately after upgrading SLZB-OS 3.2.4 → 3.3.1.**

**Fix: Downgrade SLZB-OS to 3.2.4** (http://10.100.20.179 → Settings → Core firmware).
Version 3.2.4 is the last known-good. All 3.2.x versions are safe; the EFR32 reboot
behavior was only added in 3.3.1. Do NOT upgrade to 3.3.1+.

Two RESET_SOFTWARE events per session (with 3.3.1):

1. **During startup (~17s in):** `SET_CONFIGURATION_VALUE` EZSP → RESET_SOFTWARE.
   Herdsman 9.x has one startup retry — re-establishes ASH without RST, continues.

2. **At runtime (~7s after started!):** `SEND_UNICAST` (availability ping) → RESET_SOFTWARE.
   No retries left at runtime → `Adapter disconnected, stopping` → crash.

### Issue 2 — EFR32 coordinator firmware 8.0.2 b397 — Z2M UPGRADE BLOCKER

Once SLZB-OS is downgraded to 3.2.4 and Z2M 2.9.1 is stable again, the secondary issue
remains: herdsman 10.x (Z2M 2.9.2+) triggers `SET_CONFIGURATION_VALUE → RESET_SOFTWARE`
on EFR32 8.0.2 b397. Do not upgrade Z2M past 2.9.1 until the EFR32 coordinator firmware
is updated via the SLZB web UI (Settings → Firmware update → Flash latest Zigbee
coordinator firmware). After that, Z2M 2.10.x + herdsman 10.x + SLZB-OS 3.3.1 works
(confirmed by community reports).

---

## Crash Timeline (observed)

```
T+0s   : Docker restarts Z2M
T+1-11s: Z2M connects to slzb-proxy, proxy is still in drain period
T+12s  : Proxy drain complete, Z2M connects to SLZB
T+12-17s: Z2M sends RST → RSTACK → EZSP init sequence starts
T+17s  : RESET_SOFTWARE (SET_CONFIGURATION_VALUE) — STARTUP, handled by herdsman retry
T+27s  : Zigbee2MQTT started!
T+34s  : RESET_SOFTWARE (SEND_UNICAST, availability ping) — RUNTIME, FATAL
T+34s  : Adapter disconnected, stopping → Z2M process exits
T+35s  : Docker restarts Z2M (restart: unless-stopped)
… repeat …
```

---

## Fixes Applied (2026-05-25)

### 1. Removed startup scene push (`smart-lighting.js`, commit 3de6e40)

**Before:** Extension had `setTimeout(() => this._fullScenePush(), 5000)` on every start.
Each `scene_add` command → `SET_MULTICAST_TABLE_ENTRY` → RESET_SOFTWARE → crash.

**After:** Startup push removed entirely. Hash-based guard added to both the startup
bootstrapping and the HA config-push path. HA's periodic `zigbee2mqtt/sl/config`
push (on every Z2M restart) now only triggers `_fullScenePush()` if the config hash
has actually changed since the last successful push.

Files: `external_extensions/smart-lighting.js` — new constants:
- `PUSHED_HASH_FILE` (`sl-pushed-hash.json` in the data volume)
- `_loadPushedHash()`, `_savePushedHash()` helpers
- Bootstrap in `start()`: writes hash on first run so HA's startup push is a no-op

**Verification:** Logs show `[SL] Scenes up to date on bulbs (hash=d97535f0097c)` — no
scene push triggered. Extension is working correctly.

### 2. Removed stray ingress from komodo-dean-gitops (commit 553c3ca)

`infra/ingresses/z2m-ingress-amer-dev.yaml` had wrong IP (`10.100.20.19` instead of
`10.100.20.18`) and should not have been in this repo. DNS/ingress config belongs in
`k3s-dean-gitops` only. Deleted entire `infra/` directory.

The correct ingress is in `k3s-dean-gitops/infra/ingresses/z2m-ingress-amer-dev.yaml`
with the correct EndpointSlice IP `10.100.20.18`.

### 3. Cleared stale MQTT retained extension message

Z2M stores its loaded extension code as a retained message on
`zigbee2mqtt/bridge/extensions`. If Z2M crashes and restarts with new file code,
the retained MQTT message (old code) overrides the file. Fix procedure:

```bash
# Stop Z2M, clear retained message, start Z2M (in this order!)
docker stop zigbee2mqtt
docker exec mosquitto mosquitto_pub -h 127.0.0.1 -p 1883 \
  -t 'zigbee2mqtt/bridge/extensions' -n -r
docker start zigbee2mqtt
```

---

## Outstanding — REQUIRES MANUAL ACTION

### SLZB firmware update

**This is the only permanent fix.** Until updated, Z2M will crash every ~35s.

1. Open http://10.100.20.179 in a browser
2. Go to Settings → Firmware update
3. Click "Flash latest Zigbee coordinator firmware"
4. Wait for update to complete (EFR32 will reboot)
5. After update: trigger a scene re-push from HA so all 4 windows are stored on bulbs.
   Easiest way: delete `sl-pushed-hash.json` from the zigbee2mqtt-data Docker volume,
   then restart Z2M. The SL extension will push scenes on the next HA config push.

**Current firmware:** 8.0.2 build 397 (confirmed in logs)
**Adapter page:** http://10.100.20.179
**Z2M version lock:** DO NOT upgrade Z2M past 2.9.1 until SLZB firmware is updated
  (herdsman 10.x in Z2M 2.9.2+ has worse SET_CONFIGURATION_VALUE trigger behavior)

---

## Architecture (for context)

```
[Z2M container] → tcp://127.0.0.1:6639 → [slzb-proxy.py] → tcp://10.100.20.179:6638
                                                                → [SLZB-06MG24 Ethernet adapter]
                                                                    → [EFR32MG24 Zigbee chip]
```

**slzb-proxy.py** keeps the SLZB TCP connection alive across Z2M restarts and drains
stale RSTACK frames for 12s after each Z2M disconnect (prevents HOST_FATAL_ERROR on
reconnect due to stale RSTACK in the TCP buffer).

**Scenes are stored in bulb flash** — not in Z2M, not in the coordinator. They survive
Z2M restarts, coordinator resets, and power cycles. HA is NOT in the critical path for
lighting (switches → scene_recall ZCL → bulb applies stored scene directly).
