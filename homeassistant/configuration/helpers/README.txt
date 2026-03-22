Helper Generator Template
=========================
This directory provides reusable templates and script for generating input helpers per room, organized by domain type.

Usage:
1) Install Jinja2 CLI:
   pip install jinja2-cli

2) Generate helper files and ConfigMaps:
   bash generate_helpers.sh

Output:
- ./generated/input_boolean/<room>.yaml
- ./generated/input_datetime/<room>.yaml
- ./generated/input_select/<room>.yaml
- ./generated/input_number/<room>.yaml
- ../../helpers-input-boolean-configmap.yaml
- ../../helpers-input-datetime-configmap.yaml
- ../../helpers-input-select-configmap.yaml
- ../../helpers-input-number-configmap.yaml

Each domain includes:
- input_boolean: custom_schedule, motion_enabled, timer_enabled, per-window enabled/auto_on
- input_datetime: s1..s4 (morning/day/evening/night) start times
- input_select: per-window scene override (stores scene entity_id)
- input_number: brightness step, min/max brightness (for dashboards/future use)

The generated files are organized by domain type to work with Home Assistant's
!include_dir_merge_named directive for cleaner configuration management.
