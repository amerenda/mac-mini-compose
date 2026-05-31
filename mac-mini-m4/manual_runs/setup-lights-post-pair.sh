#!/usr/bin/env bash
# Run after all 8 bulbs have joined Z2M.
# Adds each bulb to its Z2M group, then sets firmware power-on defaults.
# Requires: mosquitto_pub accessible (run from a host with it, or use the mosquitto container)

set -euo pipefail

BROKER="localhost"
PORT="1883"
PUB="docker exec mosquitto mosquitto_pub -h $BROKER -p $PORT"

echo "=== Step 1: Add bulbs to Z2M groups ==="

# Living Room (group 2)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Living Room\",\"device\":{\"friendly_name\":\"living_room_1\",\"endpoint\":\"11\"}}'"

sleep 1

# Bedroom (group 1)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Bedroom\",\"device\":{\"friendly_name\":\"bedroom_1\",\"endpoint\":\"11\"}}'"
sleep 0.5
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Bedroom\",\"device\":{\"friendly_name\":\"bedroom_2\",\"endpoint\":\"11\"}}'"
sleep 0.5
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Bedroom\",\"device\":{\"friendly_name\":\"lamp_1\",\"endpoint\":\"11\"}}'"
sleep 1

# Bathroom (group 3)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Bathroom\",\"device\":{\"friendly_name\":\"bathroom_1\",\"endpoint\":\"11\"}}'"
sleep 1

# Kitchen (group 4)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Kitchen\",\"device\":{\"friendly_name\":\"kitchen_1\",\"endpoint\":\"11\"}}'"
sleep 0.5
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Kitchen\",\"device\":{\"friendly_name\":\"kitchen_2\",\"endpoint\":\"11\"}}'"
sleep 1

# Hallway (group 5)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bridge/request/group/members/add' \
  -m '{\"friendly_name\":\"Hallway\",\"device\":{\"friendly_name\":\"hallway_1\",\"endpoint\":\"11\"}}'"
sleep 1

echo "=== Step 2: Set firmware power-on defaults ==="
# These values are stored in bulb flash and survive Z2M/HA restarts.
# hue_power_on_behavior: on  → always turns on after mains power restore
# bri/CT values are the fallback when HA is not available to push a scene.
# Living Room: bri=150, CT=400 (warm white)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/living_room_1/set' \
  -m '{\"hue_power_on_behavior\":\"on\",\"hue_power_on_brightness\":150,\"hue_power_on_color_temperature\":400}'"
sleep 0.5

# Bedroom: bri=150, CT=400 (warm white)
for dev in bedroom_1 bedroom_2 lamp_1; do
  ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
    -t 'zigbee2mqtt/$dev/set' \
    -m '{\"hue_power_on_behavior\":\"on\",\"hue_power_on_brightness\":150,\"hue_power_on_color_temperature\":400}'"
  sleep 0.5
done

# Bathroom: bri=200, CT=300 (neutral white — brighter for bathroom)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/bathroom_1/set' \
  -m '{\"hue_power_on_behavior\":\"on\",\"hue_power_on_brightness\":200,\"hue_power_on_color_temperature\":300}'"
sleep 0.5

# Kitchen: bri=200, CT=300 (brightness-only — kitchen_1 and kitchen_2 are white-only)
for dev in kitchen_1 kitchen_2; do
  ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
    -t 'zigbee2mqtt/$dev/set' \
    -m '{\"hue_power_on_behavior\":\"on\",\"hue_power_on_brightness\":200}'"
  sleep 0.5
done

# Hallway: bri=100 (brightness-only — white only bulb)
ssh mini "cd /Users/alex/.orbstack/bin && ./docker exec mosquitto mosquitto_pub -h localhost -p 1883 \
  -t 'zigbee2mqtt/hallway_1/set' \
  -m '{\"hue_power_on_behavior\":\"on\",\"hue_power_on_brightness\":100}'"

echo "=== Done ==="
echo "Next: trigger script.sl_push_config in HA to send the SL config to Z2M,"
echo "which will store all 4 scenes on each group via the extension."
