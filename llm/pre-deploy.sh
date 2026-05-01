#!/usr/bin/env bash
# Writes llm/.env for Komodo deploy (Compose loads it for interpolation + container env).
# Run from mac-mini-compose repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Bitwarden Secrets Manager → secret "llm-manager-agent-psk" (same as k8s agent-psk).
# Bitwarden secret UUID for llm-manager-agent-psk.
BWS_LLM_AGENT_PSK_UUID="cdaa7917-3eba-44b5-a9ea-b41300f1dab5"

# Host path to native Ollama's models directory (read-only in the agent container).
OLLAMA_MODELS_HOST_PATH="${OLLAMA_MODELS_HOST_PATH:-/Users/alex/.ollama/models}"

export BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(cat /run/secrets/bws-access-token)}"

PSK="$(bws secret get "$BWS_LLM_AGENT_PSK_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)"

{
  echo "LLM_MANAGER_AGENT_PSK=${PSK}"
  echo "BACKEND_URL=https://llm-manager-backend.amer.dev"
  echo "OLLAMA_URL=http://host.docker.internal:11434"
  echo "AGENT_IMAGE_TAG=${AGENT_IMAGE_TAG:-latest}"
  echo "OLLAMA_MODELS_HOST_PATH=${OLLAMA_MODELS_HOST_PATH}"
} >llm/.env

# Optional: operator-created file (gitignored) with extra KEY=value lines, e.g. AGENT_ADDRESS=...
if [[ -f llm/compose.local.env ]]; then
  cat llm/compose.local.env >>llm/.env
fi

# GitOps: native Homebrew Ollama must bind 0.0.0.0 so containers reach host.docker.internal:11434.
bash "$ROOT/scripts/configure-native-ollama-bind.sh"
