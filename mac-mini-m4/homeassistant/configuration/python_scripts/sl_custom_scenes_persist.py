"""Persist Smart Lighting \"All Rooms\" custom packs to disk (survives HA restart).

Stores JSON at <config>/sl_custom_scenes.json. Called via service python_script.sl_custom_scenes_persist
with data: { action: save_all_rooms_pack | apply_all_rooms_pack, slug: "<window slug>" }.

Keep this file in /config/python_scripts/ (same folder as configuration.yaml).
"""

import json

STORE_REL = "sl_custom_scenes.json"

ROOM_LIGHTS = {
    "living_room": ["light.living_room_1"],
    "bedroom": ["light.bedroom_1", "light.bedroom_2", "light.lamp_1"],
    "bathroom": ["light.bathroom_1"],
    "kitchen": ["light.kitchen_1", "light.kitchen_2"],
    "hallway": ["light.hallway_1"],
}

ATTRS_ON = (
    "brightness",
    "color_temp",
    "color_temp_kelvin",
    "hs_color",
    "rgb_color",
    "xy_color",
)


def _snapshot_light(state_obj):
    if state_obj is None:
        return None
    if state_obj.state in ("unknown", "unavailable"):
        return None
    snap = {"state": state_obj.state}
    if state_obj.state != "on":
        return snap
    for k in ATTRS_ON:
        v = state_obj.attributes.get(k)
        if v is not None:
            snap[k] = v
    return snap


def _load_store(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as err:
        logger.error("sl_custom_scenes_persist: read %s failed: %s", path, err)
        return {}


def _save_store(path, store):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(store, f, indent=2, sort_keys=True)


slug = data.get("slug") or data.get("window")
action = data.get("action")
path = hass.config.path(STORE_REL)

if action == "save_all_rooms_pack":
    if not slug:
        logger.error("sl_custom_scenes_persist: save missing slug")
    else:
        store = _load_store(path)
        pack = {}
        for room, entity_ids in ROOM_LIGHTS.items():
            pack[room] = {}
            for eid in entity_ids:
                snap = _snapshot_light(hass.states.get(eid))
                if snap is not None:
                    pack[room][eid] = snap
        store[slug] = pack
        _save_store(path, store)
        logger.info("sl_custom_scenes_persist: saved pack %r (%d rooms) to %s", slug, len(pack), path)

elif action == "apply_all_rooms_pack":
    if not slug:
        logger.error("sl_custom_scenes_persist: apply missing slug")
    else:
        store = _load_store(path)
        pack = store.get(slug)
        if not pack:
            logger.warning("sl_custom_scenes_persist: no pack for slug %r in %s", slug, path)
        else:
            for _room, lights in pack.items():
                for eid, snap in lights.items():
                    st = snap.get("state")
                    if st == "off":
                        hass.services.call("light", "turn_off", {"entity_id": eid})
                        continue
                    if st != "on":
                        continue
                    payload = {"entity_id": eid}
                    for k in ATTRS_ON:
                        if k in snap:
                            payload[k] = snap[k]
                    hass.services.call("light", "turn_on", payload)
            logger.info("sl_custom_scenes_persist: applied pack %r", slug)
else:
    logger.error("sl_custom_scenes_persist: unknown action %r", action)
