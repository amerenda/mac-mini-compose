#!/bin/bash
# Smart Lighting v3 — Test Script
# Run through these tests tonight after rebinding switches.
# Delete this file when all tests pass.

DOCKER="$HOME/.orbstack/bin/docker"

echo "Smart Lighting v3 Test Plan"
echo "==========================="
echo ""

echo "PREREQUISITE: Run rebind_switches_to_groups.sh first!"
echo ""

echo "--- Test 1: Z2M Extension Status ---"
$DOCKER exec mosquitto mosquitto_sub -t "zigbee2mqtt/sl/status" -C 1 -W 5 2>/dev/null
echo ""
echo "Expected: status shows current window and has_config=true"
echo ""

echo "--- Test 2: Scenes on Groups ---"
$DOCKER exec mosquitto mosquitto_sub -t "zigbee2mqtt/bridge/groups" -C 1 -W 5 2>/dev/null | python3 -c "
import json,sys
for g in json.loads(sys.stdin.read()):
    n=g.get('friendly_name','?'); s=g.get('scenes',[])
    if n != 'default_bind_group': print(f'  {n}: {len(s)} scenes — {[x[\"name\"] for x in s]}')" 2>/dev/null
echo ""
echo "Expected: Each room has 4 scenes: morning, day, evening, night"
echo ""

echo "--- Test 3: Zigbee Switch (press living_room_s_1 power button) ---"
echo "Press the power button on the living room switch."
echo "Expected: Living room light turns ON with current window's scene."
echo "Expected: No HA involvement — pure Zigbee."
echo ""
read -p "Did the light turn on correctly? [y/n] " answer
echo ""

echo "--- Test 4: Wall Switch Power Cycle ---"
echo "Turn living_room_1 OFF via Zigbee switch."
echo "Now physically flip the wall switch OFF, wait 5 seconds, then ON."
echo "Expected: Light stays dark for 1-3 seconds, then comes on with correct scene."
echo "Expected: NO flash of wrong color."
echo ""
read -p "Did the light come on with correct scene, no flash? [y/n] " answer
echo ""

echo "--- Test 5: HA Down Test ---"
echo "Stop HA: $DOCKER stop homeassistant"
echo "Press the living room switch."
echo "Expected: Light still works (Zigbee direct binding)."
echo ""
read -p "Did the light work with HA down? [y/n] " answer
echo ""

echo "--- Test 6: Window Transition ---"
echo "Temporarily change the schedule to trigger a transition."
echo "On the HA dashboard, change the current window boundary to 1 minute from now."
echo "Expected: If lights are on, they transition to the new scene."
echo "Expected: Z2M logs show '[SL] Window transition'"
echo ""
read -p "Did the transition work? [y/n] " answer
echo ""

echo "--- Test 7: Config Push from HA ---"
echo "Change a schedule time on the HA Smart Lighting dashboard."
echo "Check Z2M logs: $DOCKER logs --since 30s zigbee2mqtt 2>&1 | grep '\[SL\]'"
echo "Expected: '[SL] Received and cached new config from HA'"
echo ""
read -p "Did the config push work? [y/n] " answer
echo ""

echo "Start HA again: $DOCKER start homeassistant"
echo ""
echo "=== Tests Complete ==="
echo "Delete this file and rebind_switches_to_groups.sh when all tests pass."
