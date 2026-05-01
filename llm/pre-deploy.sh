#!/usr/bin/env bash
# Writes llm/.env for Komodo deploy (Compose loads it for interpolation + container env).
# Run from mac-mini-compose repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# OrbStack exposes `mac` at ~/.orbstack/bin/mac — use full path so it works from Docker.
if [[ -n "${NATIVE_OLLAMA_RESTART_CMD:-}" ]]; then
  RESTART_CMD="$NATIVE_OLLAMA_RESTART_CMD"
elif [[ -x "${HOME}/.orbstack/bin/mac" ]]; then
  RESTART_CMD="${HOME}/.orbstack/bin/mac brew services restart ollama"
else
  RESTART_CMD="mac brew services restart ollama"
fi

# Bitwarden Secrets Manager → secret "llm-manager-agent-psk" (same as k8s agent-psk).
# Bitwarden secret UUID for llm-manager-agent-psk.
BWS_LLM_AGENT_PSK_UUID="cdaa7917-3eba-44b5-a9ea-b41300f1dab5"

# Host path to native Ollama's models directory (read-only in the agent container).
OLLAMA_MODELS_HOST_PATH="${OLLAMA_MODELS_HOST_PATH:-/Users/alex/.ollama/models}"
OLLAMA_LAUNCH_AGENTS_DIR="${OLLAMA_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

export BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(cat /run/secrets/bws-access-token)}"

PSK="$(bws secret get "$BWS_LLM_AGENT_PSK_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)"

# Agent image tag: align with llm-manager global target (sha-…) so Runners "outdated"
# matches fleet reality. Komodo's compose-repo SHA is unrelated to AGENT_VERSION.
BACKEND_PUBLIC="${BACKEND_PUBLIC:-https://llm-manager-backend.amer.dev}"
BACKEND_PUBLIC="${BACKEND_PUBLIC%/}"
AGENT_IMAGE_TAG_RESOLVED="${AGENT_IMAGE_TAG:-}"
if [[ -z "$AGENT_IMAGE_TAG_RESOLVED" ]] && command -v curl >/dev/null && command -v jq >/dev/null; then
  AGENT_IMAGE_TAG_RESOLVED="$(curl -sfL "$BACKEND_PUBLIC/api/runners/target-version" | jq -r '.target_version // empty' | tr -d ' \t\r\n' || true)"
fi
if [[ -z "$AGENT_IMAGE_TAG_RESOLVED" ]]; then
  AGENT_IMAGE_TAG_RESOLVED="latest"
fi

{
  echo "LLM_MANAGER_AGENT_PSK=${PSK}"
  echo "BACKEND_URL=https://llm-manager-backend.amer.dev"
  echo "OLLAMA_URL=http://host.docker.internal:11434"
  echo "AGENT_IMAGE_TAG=${AGENT_IMAGE_TAG_RESOLVED}"
  echo "OLLAMA_MODELS_HOST_PATH=${OLLAMA_MODELS_HOST_PATH}"
  # Host path to this llm/ directory — agent self-update + AGENT_IMAGE_TAG pin in llm/.env
  echo "HOST_LLM_COMPOSE_DIR=${ROOT}/llm"
  # Homebrew Ollama LaunchAgent plist (native Metal Ollama — tunables + restart)
  echo "OLLAMA_LAUNCH_AGENTS_DIR=${OLLAMA_LAUNCH_AGENTS_DIR}"
  printf 'NATIVE_OLLAMA_RESTART_CMD=%q\n' "$RESTART_CMD"
} >llm/.env

# Optional: operator-created file (gitignored) with extra KEY=value lines, e.g. AGENT_ADDRESS=...
if [[ -f llm/compose.local.env ]]; then
  cat llm/compose.local.env >>llm/.env
fi

# GitOps: native Homebrew Ollama must bind 0.0.0.0 so containers reach host.docker.internal:11434.
bash "$ROOT/scripts/configure-native-ollama-bind.sh"
