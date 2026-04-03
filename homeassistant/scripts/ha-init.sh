#!/bin/sh
# Home Assistant init — installs HACS + frontend cards into the HA config volume
# Runs as a one-shot container before HA starts.
# All versions are pinned. Bump versions here, push, redeploy.
set -e

# ── Versions ─────────────────────────────────────────────────
HACS_VERSION="2.0.5"
MUSHROOM_VERSION="v5.1.1"
BUBBLE_VERSION="v3.1.4"
CARD_MOD_VERSION="v4.2.1"
VSTACK_VERSION="v1.0.1"
STREAMLINE_VERSION="v0.2.0"
HUE_LIGHT_VERSION="v1.9.0"

# Combined marker for all components
MARKER=/config/.ha-init-versions
EXPECTED="${HACS_VERSION}|${MUSHROOM_VERSION}|${BUBBLE_VERSION}|${CARD_MOD_VERSION}|${VSTACK_VERSION}|${STREAMLINE_VERSION}|${HUE_LIGHT_VERSION}"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$EXPECTED" ]; then
  echo "All components at expected versions — nothing to do"
  exit 0
fi

apk add --no-cache wget unzip

# ── HACS integration ─────────────────────────────────────────
HACS_MARKER=/config/custom_components/hacs/.version
if [ ! -f "$HACS_MARKER" ] || [ "$(cat "$HACS_MARKER")" != "$HACS_VERSION" ]; then
  echo "Installing HACS ${HACS_VERSION}..."
  wget -qO /tmp/hacs.zip "https://github.com/hacs/integration/releases/download/${HACS_VERSION}/hacs.zip"
  rm -rf /config/custom_components/hacs
  mkdir -p /config/custom_components/hacs
  unzip -o /tmp/hacs.zip -d /config/custom_components/hacs
  echo "$HACS_VERSION" > "$HACS_MARKER"
  echo "HACS ${HACS_VERSION} installed"
else
  echo "HACS ${HACS_VERSION} already installed"
fi

# ── Frontend cards ───────────────────────────────────────────
mkdir -p /config/www

install_card() {
  local name=$1 url=$2 filename=$3 version=$4
  local dest="/config/www/${filename}"
  local marker="/config/www/.${name}-version"

  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$version" ]; then
    echo "${name} ${version} already installed"
    return 0
  fi

  echo "Installing ${name} ${version}..."
  wget -qO "$dest" "$url"
  echo "$version" > "$marker"
  echo "${name} ${version} installed"
}

install_card "mushroom" \
  "https://github.com/piitaya/lovelace-mushroom/releases/download/${MUSHROOM_VERSION}/mushroom.js" \
  "mushroom.js" "$MUSHROOM_VERSION"

install_card "bubble-card" \
  "https://raw.githubusercontent.com/Clooos/Bubble-Card/${BUBBLE_VERSION}/dist/bubble-card.js" \
  "bubble-card.js" "$BUBBLE_VERSION"

install_card "card-mod" \
  "https://raw.githubusercontent.com/thomasloven/lovelace-card-mod/${CARD_MOD_VERSION}/card-mod.js" \
  "card-mod.js" "$CARD_MOD_VERSION"

install_card "vertical-stack-in-card" \
  "https://github.com/ofekashery/vertical-stack-in-card/releases/download/${VSTACK_VERSION}/vertical-stack-in-card.js" \
  "vertical-stack-in-card.js" "$VSTACK_VERSION"

install_card "streamline-card" \
  "https://github.com/brunosabot/streamline-card/releases/download/${STREAMLINE_VERSION}/streamline-card.js" \
  "streamline-card.js" "$STREAMLINE_VERSION"

install_card "hue-like-light-card" \
  "https://github.com/Gh61/lovelace-hue-like-light-card/releases/download/${HUE_LIGHT_VERSION}/hue-like-light-card.js" \
  "hue-like-light-card.js" "$HUE_LIGHT_VERSION"

# ── Register lovelace resources ──────────────────────────────
# Only write if the file doesn't exist or is missing our resources
RESOURCES_FILE="/config/.storage/lovelace_resources"
if [ ! -f "$RESOURCES_FILE" ] || ! grep -q "mushroom.js" "$RESOURCES_FILE"; then
  echo "Registering frontend resources..."
  cat > "$RESOURCES_FILE" << 'RESEOF'
{
  "version": 1,
  "minor_version": 1,
  "key": "lovelace_resources",
  "data": {
    "items": [
      {
        "id": "mushroom",
        "type": "module",
        "url": "/local/mushroom.js"
      },
      {
        "id": "bubble-card",
        "type": "module",
        "url": "/local/bubble-card.js"
      },
      {
        "id": "card-mod",
        "type": "module",
        "url": "/local/card-mod.js"
      },
      {
        "id": "vertical-stack-in-card",
        "type": "module",
        "url": "/local/vertical-stack-in-card.js"
      },
      {
        "id": "streamline-card",
        "type": "module",
        "url": "/local/streamline-card.js"
      },
      {
        "id": "hue-like-light-card",
        "type": "module",
        "url": "/local/hue-like-light-card.js"
      }
    ]
  }
}
RESEOF
  echo "Lovelace resources registered"
else
  echo "Lovelace resources already registered"
fi

# ── Write combined marker ────────────────────────────────────
echo "$EXPECTED" > "$MARKER"
echo "All components installed successfully"
