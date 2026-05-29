# Button Press Flow — What Happens When

## Question (May 27, 2026)
"What happens if HA is down? If the Z2M extension is down? If my network is down?"

## Current Architecture Overview

### Smart Lighting System Components:
- **Smart Lighting Extension** (`smart-lighting.js`) — runs INSIDE Zigbee2MQTT as a Z2M plugin, NOT in Home Assistant
- **HA (Home Assistant)** — pushes config to Z2M via MQTT topic `zigbee2mqtt/sl/config` (retained)
  - Sends: room/window scene definitions, switch-to-room mappings, schedule times, house_mode
  - Does NOT listen for button press events at all
- **Zigbee switches** — Hue dimmer remotes (SMLIGHT SLZB-06MG24 at 10.100.20.179 is the coordinator)

### Config Flow (HA → Z2M):
```
script.sl_push_config (HA script)
  → reads input_helpers (window times, scene brightness/color per room/window)
  → reads switch-to-room mappings from HA UI
  → publishes JSON to zigbee2mqtt/sl/config (retained)
  
smart-lighting.js inside Z2M:
  → subscribes to zigbee2mqtt/sl/config
  → parses rooms/switches/profiles/day_assignments/house_mode
  → subscribes to each switch's /action topic
```

### Button Press Flow (when extension IS loaded and working):
```
Hue dimmer button press (Zigbee)
  → Z2M receives Zigbee action command
  → publishes MQTT: zigbee2mqtt/{switch_name}/action = {"action":"on_press_release",...}
  → smart-lighting.js listens on /action topic, parses the payload
  
Action mapping in extension:
  on_press_release     → __toggle_default (turn room on/off with scene)
  on_hold              → Power Off Room (all lights OFF)
  up_press_release     → Brightness Up (+20%)
  up_hold              → Brightness Max
  down_press_release   → Brightness Down (-20%)
  down_hold            → Brightness Min
  off_press_release    → Cycle Scenes (morning→day→evening→night)
  off_hold             → Custom Scene ← ONLY action requiring HA

Extension executes:
  - _toggleRoom() / _roomOff() / _brightnessStep() → direct MQTT commands
    to device groups: "Living Room/set { state: ON, brightness: N }"
  - scene_add stores all 4 scenes per group on the Zigbee coordinator
  - cycleScene uses stored scene_recall for instant switchback
```

## What We Know About Current State (MAY 27)

### Smart Lighting Extension: NOT LOADED
- `docker exec zigbee2mqtt ls /app/data/external_extensions/` → EMPTY directory
- Z2M v2.x logs show: `z2m: Received MQTT message on 'zigbee2mqtt/bridge/extensions' with data '[]'`
  - This means extension discovery found 0 loaded extensions
- The JS file exists in gitops at `komodo-dean-gitops/mac-mini-m4/zigbee2mqtt/external_extensions/smart-lighting.js`
  but has NOT been deployed into the running container's `/app/data/external_extensions/`
- Z2M v1.x auto-loaded files from `external_extensions/`; v2.x may require explicit config or different loading mechanism

### Device Registry (database.db — NDJSON, v2.9.1):
- 6 Groups defined (IDs 2-7), all with EMPTY members arrays `[ ]`
- Coordinator: type=Coordinator, binds=[] (no Zigbee binds configured on coordinator)
- EndDevices: some Remote type Hue dimmer switches found in state.json
  - All report battery=100%, last_seen within hours, linkquality ~160-188
  - Firmware version 33576193 (latest), all have OTA update available to same version
- **NO device-to-group Zigbee binds** found in any endpoint
- Groups are empty — no lights assigned to groups via Z2M UI

### HA Scenes.yaml:
- All scenes define `state: "on"` with specific brightness + color_temp per room/window
- Covers all 5 rooms (Living Room, Bedroom, Bathroom, Kitchen, Hallway) x 4 windows = 20 scenes
- No power-on behavior defined in scenes — that's handled by `_buildDirectScenePayload()`

### HA Automations:
- `sl_push_config_on_ha_start.yaml` — pushes config 45s after HA start (if sl_enabled is on)
- `sl_push_config_on_schedule_change.yaml` — pushes config when any input_datetime/input_select changes
- `sl_push_config_on_sl_enabled.yaml` — pushes config when input_boolean.sl_enabled toggles
- `sl_push_config_on_smart_power.yaml` — pushes config when per-room smart_power_on changes
- NO automations listen for button action events

### Z2M Configuration (configuration.yaml):
```yaml
mqtt:
  server: mqtt://mosquitto:1883
serial:
  port: tcp://10.100.20.179:6638    # SMLIGHT SLZB-06MG24 coordinator
  adapter: ember
homeassistant: true                   # HA integration enabled
```

## Key Insight for "What Happens If..." Analysis

**The critical question is whether Hue dimmer switches have Zigbee binds to their target groups.**
If they do (configured in the Z2M UI), button presses trigger direct device-group commands
on the Zigbee network — no MQTT, no Z2M process needed at all.

But our database inspection shows:
- All group members arrays are EMPTY → lights aren't assigned to groups in Z2M yet?
- No binds found on any coordinator endpoint
- This suggests either the system is not fully configured OR there's a different grouping mechanism

**If no Zigbee binds exist:** Every button press depends on this chain:
  Hue switch → Z2M receives command → publishes MQTT action → extension handles it → sends back MQTT command → light receives group set command
  
With NO bindings, HA down = lights still work IF groups are bound at device level.
With NO bindings, extension down = buttons do nothing (Z2M publishes action to MQTT but nobody processes it).

## Files Referenced:
- /home/alex/komodo-dean-gitops/mac-mini-m4/zigbee2mqtt/external_extensions/smart-lighting.js
- /home/alex/komodo-dean-gitops/mac-mini-m4/homeassistant/configuration/dashboards/smart_lighting.yaml
- /home/alex/komodo-dean-gitops/mac-mini-m4/homeassistant/configuration/scenes.yaml (template)
- /home/alex/komodo-dean-gitops/mac-mini-m4/homeassistant/scripts/sl_push_config.yaml
- /home/alex/komodo-dean-gitops/mac-mini-m4/zigbee2mqtt/configuration.yaml
- docker exec homeassistant cat /config/automations/*.yaml (all SL-related automations)
- docker exec zigbee2mqtt node -e "..." -> database.db parsed (NDJSON, 13 entries total)
