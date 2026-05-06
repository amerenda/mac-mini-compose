#!/usr/bin/env bash
# Writes llm/.env for Komodo deploy (Compose loads it for interpolation + container env).
# Run from the mac-mini-m4/ root inside komodo-dean-gitops.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BWS_LLM_AGENT_PSK_UUID="cdaa7917-3eba-44b5-a9ea-b41300f1dab5"

OLLAMA_DATA_HOST_PATH="${OLLAMA_DATA_HOST_PATH:-${HOME}/.ollama}"
OLLAMA_MODELS_HOST_PATH="${OLLAMA_MODELS_HOST_PATH:-}"

# Komodo often runs this script as root (HOME=/root) or from a *Linux* build container
# (`uname` ≠ Darwin) while the stack targets macOS. In both cases we must not leave
# /root/.ollama in llm/.env — the agent then stats /hostfs/root/.ollama (~4 GiB bogus)
# instead of the real APFS tree under /Users.
if [[ "${OLLAMA_DATA_HOST_PATH}" == /root/.ollama || "${OLLAMA_DATA_HOST_PATH}" == /var/root/.ollama ]]; then
  if [[ -d /Users ]]; then
    _cu=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
      _cu="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
    fi
    if [[ -n "${_cu}" && "${_cu}" != "root" && -d "/Users/${_cu}/.ollama" ]]; then
      OLLAMA_DATA_HOST_PATH="/Users/${_cu}/.ollama"
    else
      for _uh in /Users/*; do
        [[ -d "${_uh}/.ollama" ]] || continue
        OLLAMA_DATA_HOST_PATH="${_uh}/.ollama"
        break
      done
    fi
  fi
fi
if [[ -n "${OLLAMA_MODELS_HOST_PATH}" ]] && {
     [[ "${OLLAMA_MODELS_HOST_PATH}" == /root/.ollama/models ]] ||
     [[ "${OLLAMA_MODELS_HOST_PATH}" == /var/root/.ollama/models ]]; }; then
  OLLAMA_MODELS_HOST_PATH="${OLLAMA_DATA_HOST_PATH}/models"
fi
OLLAMA_MODELS_HOST_PATH="${OLLAMA_MODELS_HOST_PATH:-${OLLAMA_DATA_HOST_PATH}/models}"

export BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(cat /run/secrets/bws-access-token)}"

PSK="$(bws secret get "$BWS_LLM_AGENT_PSK_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)"

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
  echo "OLLAMA_URL=http://ollama:11434"
  echo "OLLAMA_CONTAINER=ollama"
  echo "AGENT_IMAGE_TAG=${AGENT_IMAGE_TAG_RESOLVED}"
  echo "OLLAMA_IMAGE_TAG=${OLLAMA_IMAGE_TAG:-0.21.0}"
  echo "OLLAMA_DATA_HOST_PATH=${OLLAMA_DATA_HOST_PATH}"
  echo "OLLAMA_MODELS_HOST_PATH=${OLLAMA_MODELS_HOST_PATH}"
  echo "HOST_LLM_COMPOSE_DIR=${ROOT}/llm"
} >llm/.env

if [[ -f llm/gitops.env ]]; then
  sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' llm/gitops.env >>llm/.env
fi

# UI overrides win for compose-interpolated path variables.
if [[ -f llm/ollama.ui.env ]]; then
  while IFS='=' read -r _k _v; do
    [[ -z "${_k:-}" || "${_k}" =~ ^[[:space:]]*# ]] && continue
    _k="$(echo "${_k}" | tr -d ' \t\r\n')"
    case "$_k" in
      OLLAMA_DATA_HOST_PATH|OLLAMA_MODELS_HOST_PATH)
        grep -v "^${_k}=" llm/.env >llm/.env.tmp || true
        mv llm/.env.tmp llm/.env
        echo "${_k}=${_v}" >>llm/.env
        ;;
    esac
  done <llm/ollama.ui.env
fi

if [[ ! -f llm/ollama.env ]]; then
  cp llm/ollama.env.example llm/ollama.env
fi
if [[ ! -f llm/ollama.ui.env ]]; then
  : >llm/ollama.ui.env
fi

if ! grep -q '^AGENT_UNIFIED_VRAM_TOTAL_BYTES=' llm/.env && [[ -f llm/.ansible-memory-bytes ]]; then
  _mem="$(tr -d ' \t\r\n' <llm/.ansible-memory-bytes)"
  if [[ -n "$_mem" && "$_mem" =~ ^[0-9]+$ && "$_mem" -gt 0 ]]; then
    echo "AGENT_UNIFIED_VRAM_TOTAL_BYTES=${_mem}" >>llm/.env
  fi
fi
if ! grep -q '^AGENT_UNIFIED_VRAM_TOTAL_BYTES=' llm/.env; then
  echo "AGENT_UNIFIED_VRAM_TOTAL_BYTES=17179869184" >>llm/.env
fi
