#!/bin/sh
# Home Assistant startup script — replaces the 3 k8s init containers:
#   1. install-hacs
#   2. setup-default-config
#   3. validate-config
# Run this before starting HA for the first time, or after config changes.

set -e

CONFIG_DIR="/config"
HACS_VERSION="2.0.5"

# ── Step 1: Install HACS ─────────────────────────────────────────────────────

CC_DIR="${CONFIG_DIR}/custom_components"
HACS_DST="${CC_DIR}/hacs"
VERSION_FILE="${HACS_DST}/.installed_version"

mkdir -p "${CC_DIR}"

if [ -f "${VERSION_FILE}" ] && [ -d "${HACS_DST}" ]; then
  INSTALLED_VERSION=$(cat "${VERSION_FILE}" 2>/dev/null || echo "")
  if [ "${INSTALLED_VERSION}" = "${HACS_VERSION}" ]; then
    echo "HACS ${HACS_VERSION} already installed. Skipping."
  else
    echo "HACS version mismatch (${INSTALLED_VERSION} -> ${HACS_VERSION}). Reinstalling..."
  fi
fi

if [ ! -f "${VERSION_FILE}" ] || [ "$(cat "${VERSION_FILE}" 2>/dev/null)" != "${HACS_VERSION}" ]; then
  TMPDIR=$(mktemp -d)
  URL="https://github.com/hacs/integration/releases/download/${HACS_VERSION}/hacs.zip"
  # Try without 'v' prefix first, then with
  if ! curl -fsI "${URL}" >/dev/null 2>&1; then
    URL="https://github.com/hacs/integration/releases/download/v${HACS_VERSION}/hacs.zip"
  fi

  echo "Downloading HACS: ${URL}"
  curl -fsSL "${URL}" -o "${TMPDIR}/hacs.zip"
  unzip -q "${TMPDIR}/hacs.zip" -d "${TMPDIR}"

  # Find HACS source
  HACS_SRC=""
  if [ -f "${TMPDIR}/manifest.json" ]; then
    HACS_SRC="${TMPDIR}"
  else
    for dir in "${TMPDIR}"/*; do
      if [ -d "$dir" ] && [ -f "$dir/manifest.json" ]; then
        HACS_SRC="$dir"
        break
      fi
    done
  fi

  if [ -z "$HACS_SRC" ]; then
    echo "ERROR: Could not find HACS source directory"
    exit 1
  fi

  rm -rf "${HACS_DST}" 2>/dev/null || true
  mkdir -p "${HACS_DST}"
  cp -r "${HACS_SRC}"/* "${HACS_DST}/"

  VER=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${HACS_DST}/manifest.json" | sed 's/.*"\([^"]*\)".*/\1/')
  echo "$VER" > "${VERSION_FILE}"
  echo "HACS $VER installed successfully"
  rm -rf "${TMPDIR}"
fi

# ── Step 2: Setup default config ─────────────────────────────────────────────

mkdir -p "${CONFIG_DIR}/themes"
mkdir -p "${CONFIG_DIR}/www/pets"
mkdir -p "${CONFIG_DIR}/www/intruders"
mkdir -p "${CONFIG_DIR}/www/calendar_cache"
mkdir -p "${CONFIG_DIR}/scripts"
mkdir -p "${CONFIG_DIR}/automations"
mkdir -p "${CONFIG_DIR}/scenes"
mkdir -p "${CONFIG_DIR}/dashboards/views"
mkdir -p "${CONFIG_DIR}/helpers/input_boolean"
mkdir -p "${CONFIG_DIR}/helpers/input_datetime"
mkdir -p "${CONFIG_DIR}/helpers/input_select"
mkdir -p "${CONFIG_DIR}/helpers/input_number"
mkdir -p "${CONFIG_DIR}/helpers/input_text"
mkdir -p "${CONFIG_DIR}/packages/helpers/generated"

cat > "${CONFIG_DIR}/configuration.yaml" << 'EOF'
# Loads default set of integrations. Do not remove.
default_config: {}

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

# Load UI-managed files for Automations & Scenes (so the UI keeps working)
automation: !include automations.yaml
automation manual: !include_dir_list automations
scene: !include scenes.yaml
group: !include groups.yaml

# Scripts managed as separate files under /config/scripts/*.yaml (dict merge)
script: !include_dir_merge_named scripts

# Input helpers (split by domain)
input_boolean:  !include_dir_merge_named helpers/input_boolean/
input_datetime: !include_dir_merge_named helpers/input_datetime/
input_select:   !include_dir_merge_named helpers/input_select/
input_number:   !include_dir_merge_named helpers/input_number/
input_text:     !include_dir_merge_named helpers/input_text/

# Packages (loads your generated per-room helpers under packages/helpers/generated/)
homeassistant:
  packages: !include_dir_named packages
  media_dirs:
    pets: /config/www/pets
    intruders: /config/www/intruders

# Lovelace: storage mode + YAML dashboards
lovelace:
  mode: storage
  dashboards:
    dean-dashboard:
      mode: yaml
      title: Dean
      icon: mdi:home
      show_in_sidebar: true
      filename: dashboards/views/dean.yaml
    room-schedule-viewer:
      mode: yaml
      title: Room Schedule Viewer
      icon: mdi:calendar-clock
      show_in_sidebar: true
      filename: dashboards/views/room_schedule_viewer.yaml
    room-schedule-configuration:
      mode: yaml
      title: Room Schedule Configuration
      icon: mdi:calendar-edit
      show_in_sidebar: true
      filename: dashboards/views/room_schedule_configuration.yaml
    subway-dashboard:
      mode: yaml
      title: Subway
      icon: mdi:subway-variant
      show_in_sidebar: true
      filename: dashboards/views/subway.yaml
    security-dashboard:
      mode: yaml
      title: Security
      icon: mdi:cctv
      show_in_sidebar: true
      filename: dashboards/views/security.yaml
    uni-dashboard:
      mode: yaml
      title: Uni
      icon: mdi:cat
      show_in_sidebar: true
      filename: dashboards/views/uni.yaml

# HTTP reverse proxy — Traefik on k3s forwards here
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.100.20.0/24
    - 10.43.0.0/16
    - 10.42.0.0/16
    - 100.64.0.0/10

# Prometheus metrics endpoint for Grafana dashboards
prometheus:
  namespace: homeassistant
  filter:
    include_domains:
      - light
      - switch
      - binary_sensor
      - sensor
      - automation
      - script
      - scene
      - input_boolean
      - input_select
      - input_number
      - input_datetime
      - input_text
      - person
      - device_tracker
      - event

# Media sources - expose local media folders to Media dashboard
media_source: {}

# Shell commands
shell_command:
  cleanup_old_photos: 'find /config/www/pets -name "*.jpg" -mtime +30 -delete && find /config/www/intruders -name "*.jpg" -mtime +30 -delete'
EOF

# Seed UI files if missing
if [ ! -f "${CONFIG_DIR}/scripts.yaml" ] || [ ! -s "${CONFIG_DIR}/scripts.yaml" ]; then
  echo "{}" > "${CONFIG_DIR}/scripts.yaml"
fi
if [ ! -f "${CONFIG_DIR}/scenes.yaml" ] || [ ! -s "${CONFIG_DIR}/scenes.yaml" ]; then
  echo "[]" > "${CONFIG_DIR}/scenes.yaml"
fi
if [ ! -f "${CONFIG_DIR}/automations.yaml" ] || [ ! -s "${CONFIG_DIR}/automations.yaml" ]; then
  echo "[]" > "${CONFIG_DIR}/automations.yaml"
fi

chmod 755 "${CONFIG_DIR}/www/pets" "${CONFIG_DIR}/www/intruders"

echo "Default configuration and directories created"

# ── Step 3: Validate config ──────────────────────────────────────────────────

echo "Validating Home Assistant configuration..."
python -m homeassistant --script check_config --config /config
echo "Configuration validation passed"
