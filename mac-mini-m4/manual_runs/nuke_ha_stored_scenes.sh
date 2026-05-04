#!/bin/bash
# Delete all scenes from HA's internal storage.
# The old scene.create calls persisted scenes in .storage/core.config_entries,
# causing duplicates with our YAML-defined scenes.
#
# After running, restart the HA container. Only YAML scenes from scenes.yaml will remain.
# Run from Mac Mini.

echo "Clearing HA stored scenes..."
docker exec homeassistant bash -c 'python3 -c "
import json, pathlib

p = pathlib.Path(\"/config/.storage/core.config_entries\")
if p.exists():
    data = json.loads(p.read_text())
    before = len(data.get(\"data\", {}).get(\"entries\", []))
    data[\"data\"][\"entries\"] = [e for e in data[\"data\"][\"entries\"] if e.get(\"domain\") != \"scene\"]
    after = len(data[\"data\"][\"entries\"])
    p.write_text(json.dumps(data, indent=2))
    print(f\"Removed {before - after} scene config entries\")
else:
    print(\"No core.config_entries found\")
"'

echo "Clearing stored scene entities..."
docker exec homeassistant bash -c '
  rm -f /config/.storage/scene.entities 2>/dev/null
  echo "Removed scene.entities storage file"
'

echo ""
echo "Done. Now restart the HA container:"
echo "  docker restart homeassistant"
echo ""
echo "After restart, only the 20 YAML scenes from scenes.yaml will exist."
echo "Delete this file after running successfully."
