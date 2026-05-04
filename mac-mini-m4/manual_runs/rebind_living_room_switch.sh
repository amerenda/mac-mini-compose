#!/bin/bash
# Rebind living room Hue dimmer from Coordinator → Living Room Z2M group.
# After rebinding: ON/OFF/dim controls lights directly via Zigbee mesh.
# Z2M extension keeps hue_power_on in sync, so ON brings up the correct scene.
#
# REQUIRES: Press a button on living_room_s_1 RIGHT BEFORE running.
# The switch stays awake ~10 seconds after a button press.
#
# Run from Mac Mini. Delete after success.

DOCKER="$HOME/.orbstack/bin/docker"

pub() {
    $DOCKER exec mosquitto mosquitto_pub -t "$1" -m "$2"
    sleep 1
}

echo "=== Living Room Switch → Living Room group ==="
echo ""
echo ">>> Press a button on living_room_s_1 NOW, then hit Enter <<<"
read -r

echo "Unbinding from Coordinator..."
pub "zigbee2mqtt/bridge/request/device/unbind" \
    '{"from":"living_room_s_1","to":"Coordinator","clusters":["genOnOff","genLevelCtrl"]}'

echo "Binding genOnOff to Living Room group..."
pub "zigbee2mqtt/bridge/request/device/bind" \
    '{"from":"living_room_s_1","to":"Living Room","clusters":["genOnOff"]}'

echo "Binding genLevelCtrl to Living Room group..."
pub "zigbee2mqtt/bridge/request/device/bind" \
    '{"from":"living_room_s_1","to":"Living Room","clusters":["genLevelCtrl"]}'

echo ""
echo "Done. Test the switch:"
echo "  - ON should turn on living_room_1 at the current scene brightness/color"
echo "  - OFF should turn it off"
echo "  - Dim up/down should adjust brightness"
echo ""
echo "If it doesn't work, press the switch button again (wake it up) and re-run."
echo "Delete this file after verifying."
