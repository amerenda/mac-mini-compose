#!/bin/bash
# One-time script: export Home Assistant data from k3s PVC to local directory
# Run this from murderbot (where kubectl is available)
#
# Usage: ./scripts/migrate-ha-data.sh /path/to/local/ha-data
#
# After export, copy the data into the Docker volume:
#   docker compose up -d homeassistant  # creates the volume
#   docker compose stop homeassistant
#   docker cp /path/to/local/ha-data/. homeassistant:/config/
#   docker compose start homeassistant

set -e

DEST="${1:-./_ha-export}"
NAMESPACE="home-assistant"
PVC="homeassistant-config"
POD_NAME="ha-data-export"

echo "=== Home Assistant Data Migration ==="
echo "Destination: ${DEST}"
echo ""

# Scale down HA
echo "Step 1: Scaling down Home Assistant..."
kubectl -n "${NAMESPACE}" scale deployment homeassistant --replicas=0
sleep 5

# Create export pod
echo "Step 2: Creating export pod..."
kubectl -n "${NAMESPACE}" run "${POD_NAME}" \
  --image=alpine:3.20 \
  --restart=Never \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"export\",
        \"image\": \"alpine:3.20\",
        \"command\": [\"sleep\", \"3600\"],
        \"volumeMounts\": [{
          \"name\": \"config\",
          \"mountPath\": \"/config\"
        }]
      }],
      \"volumes\": [{
        \"name\": \"config\",
        \"persistentVolumeClaim\": {
          \"claimName\": \"${PVC}\"
        }
      }]
    }
  }"

echo "Waiting for export pod to be ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s

# Copy data
echo "Step 3: Copying data (this may take a few minutes)..."
mkdir -p "${DEST}"
kubectl -n "${NAMESPACE}" cp "${POD_NAME}:/config" "${DEST}"

# Cleanup
echo "Step 4: Cleaning up export pod..."
kubectl -n "${NAMESPACE}" delete pod "${POD_NAME}" --force

echo ""
echo "=== Export complete ==="
echo "Data saved to: ${DEST}"
echo ""
echo "Critical directories exported:"
ls -la "${DEST}/.storage/" 2>/dev/null && echo "  .storage/ - OK" || echo "  .storage/ - MISSING (check export)"
ls "${DEST}/home-assistant_v2.db" 2>/dev/null && echo "  home-assistant_v2.db - OK" || echo "  home-assistant_v2.db - MISSING"
ls -d "${DEST}/custom_components/" 2>/dev/null && echo "  custom_components/ - OK" || echo "  custom_components/ - MISSING"
echo ""
echo "Next steps:"
echo "  1. Copy this data to the Mac Mini"
echo "  2. Import into Docker volume (see comments at top of this script)"
echo "  3. DO NOT scale k3s HA back up until Mini HA is verified"
echo "     (To rollback: kubectl -n ${NAMESPACE} scale deployment homeassistant --replicas=1)"
