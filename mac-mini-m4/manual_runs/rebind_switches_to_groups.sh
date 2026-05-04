#!/bin/bash
# Rebind all Hue dimmer switches from coordinator to their room groups.
# After rebinding, button presses go directly to lights over Zigbee mesh.
#
# IMPORTANT: Hue dimmers are sleepy devices. You must press a button on each
# switch RIGHT BEFORE running its bind commands. The switch stays awake for
# ~10 seconds after a button press.
#
# Run from Mac Mini. Z2M must be running.
# Delete this file after running successfully.

DOCKER="$HOME/.orbstack/bin/docker"

publish() {
    $DOCKER exec mosquitto mosquitto_pub -t "$1" -m "$2"
    sleep 1
}

check_response() {
    $DOCKER exec mosquitto mosquitto_sub -t "zigbee2mqtt/bridge/response/device/$1" -C 1 -W 5 2>/dev/null
}

rebind_switch() {
    local switch="$1"
    local group="$2"

    echo ""
    echo "=== $switch → $group ==="
    echo ">>> Press a button on $switch NOW, then hit Enter <<<"
    read -r

    echo "  Unbinding from Coordinator..."
    publish "zigbee2mqtt/bridge/request/device/unbind" \
        "{\"from\":\"$switch\",\"to\":\"Coordinator\",\"clusters\":[\"genOnOff\",\"genLevelCtrl\"]}"

    echo "  Binding genOnOff to $group..."
    publish "zigbee2mqtt/bridge/request/device/bind" \
        "{\"from\":\"$switch\",\"to\":\"$group\",\"clusters\":[\"genOnOff\"]}"

    echo "  Binding genLevelCtrl to $group..."
    publish "zigbee2mqtt/bridge/request/device/bind" \
        "{\"from\":\"$switch\",\"to\":\"$group\",\"clusters\":[\"genLevelCtrl\"]}"

    echo "  Done. Test the switch — light should toggle without HA."
    echo ""
}

echo "Switch Rebinding Script"
echo "======================"
echo "For each switch: press a button to wake it, then hit Enter."
echo ""

rebind_switch "living_room_s_1" "Living Room"
rebind_switch "bedroom_s_1" "Bedroom"
rebind_switch "bathroom_s_1" "Bathroom"
rebind_switch "kitchen_s_1" "Kitchen"
rebind_switch "hallway_s_1" "Hallway"
rebind_switch "hallway_s_2" "Hallway"

echo ""
echo "=== All switches rebound! ==="
echo "Test each switch. If a light doesn't respond, re-run for that switch."
echo "Delete this file after verifying."
