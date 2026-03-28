#!/bin/sh
# Smart Lighting v2 — One-time configuration.yaml updates
# Run inside the HA container: docker exec homeassistant sh /config/packages/sl/sl_setup.sh
# Or via: docker exec homeassistant sh /config/sl_setup.sh
#
# This script adds the timer include, dashboard registration, and is idempotent.

CONFIG="/config/configuration.yaml"

# Add timer include if not present
if ! grep -q "^timer:" "$CONFIG"; then
  echo '' >> "$CONFIG"
  echo '# Timers (smart lighting motion auto-off)' >> "$CONFIG"
  echo 'timer: !include_dir_merge_named helpers/timer/' >> "$CONFIG"
  echo "Added timer include"
else
  echo "Timer include already present"
fi

# Add smart-lighting dashboard if not present
if ! grep -q "smart-lighting-dashboard" "$CONFIG"; then
  # Find the dashboards section and append
  python3 -c "
import re

with open('$CONFIG', 'r') as f:
    content = f.read()

dashboard_entry = '''    smart-lighting-dashboard:
      mode: yaml
      title: Smart Lighting
      icon: mdi:lightbulb-auto
      show_in_sidebar: true
      filename: dashboards/views/smart_lighting.yaml'''

# Find last dashboard entry and append after it
# Look for the pattern of a dashboard filename line followed by a non-dashboard line
lines = content.split('\n')
insert_idx = None
for i, line in enumerate(lines):
    if 'filename: dashboards/views/' in line:
        insert_idx = i + 1

if insert_idx:
    lines.insert(insert_idx, dashboard_entry)
    with open('$CONFIG', 'w') as f:
        f.write('\n'.join(lines))
    print('Added smart-lighting dashboard')
else:
    print('Could not find dashboard section — add manually')
"
else
  echo "Smart lighting dashboard already registered"
fi

echo "Done. Restart HA to apply changes."
