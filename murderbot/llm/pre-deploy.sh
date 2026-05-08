#!/usr/bin/env bash
# Writes murderbot/llm/.env for Komodo deploy (Compose loads it for interpolation + container env).
# Run from repo root: bash murderbot/llm/pre-deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BWS_LLM_AGENT_PSK_UUID="cdaa7917-3eba-44b5-a9ea-b41300f1dab5"

OLLAMA_DATA_HOST_PATH="${OLLAMA_DATA_HOST_PATH:-${HOME}/.ollama}"
OLLAMA_MODELS_HOST_PATH="${OLLAMA_MODELS_HOST_PATH:-/mnt/storage/models}"
VLLM_MODELS_HOST_PATH="${VLLM_MODELS_HOST_PATH:-/mnt/storage/models/vllm}"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
BACKEND_TYPE="${BACKEND_TYPE:-ollama}"

export BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(cat /run/secrets/bws-access-token)}"

PSK="$(bws secret get "$BWS_LLM_AGENT_PSK_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)"

# Fetch HuggingFace read-only token for vLLM model pulls (gated models).
BWS_HF_TOKEN_UUID="$(bws secret list --access-token "$BWS_ACCESS_TOKEN" --output json \
  | python3 -c "import json,sys; [print(s['id']) for s in json.load(sys.stdin) if s['key'] == 'hugging-face-read-only']" \
  2>/dev/null | head -1)"
if [[ -n "$BWS_HF_TOKEN_UUID" ]]; then
  HF_TOKEN="$(bws secret get "$BWS_HF_TOKEN_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)"
else
  HF_TOKEN=""
  echo "Warning: BWS secret 'hugging-face-read-only' not found — HF_TOKEN will be empty"
fi

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
  echo "VLLM_MODELS_HOST_PATH=${VLLM_MODELS_HOST_PATH}"
  echo "VLLM_MODEL=${VLLM_MODEL}"
  echo "BACKEND_TYPE=${BACKEND_TYPE}"
} >llm/.env

if [[ -f llm/gitops.env ]]; then
  sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' llm/gitops.env >>llm/.env
fi

# UI overrides win for compose-interpolated path variables and backend selection.
if [[ -f llm/ollama.ui.env ]]; then
  while IFS='=' read -r _k _v; do
    [[ -z "${_k:-}" || "${_k}" =~ ^[[:space:]]*# ]] && continue
    _k="$(echo "${_k}" | tr -d ' \t\r\n')"
    case "$_k" in
      OLLAMA_DATA_HOST_PATH|OLLAMA_MODELS_HOST_PATH|VLLM_MODELS_HOST_PATH|VLLM_MODEL|BACKEND_TYPE)
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

# vllm.env: copy example skeleton if missing, then inject HF_TOKEN from BWS.
if [[ ! -f llm/vllm.env ]]; then
  cp llm/vllm.env.example llm/vllm.env
fi
if [[ -n "$HF_TOKEN" ]]; then
  grep -v "^HF_TOKEN=" llm/vllm.env >llm/vllm.env.tmp || true
  mv llm/vllm.env.tmp llm/vllm.env
  echo "HF_TOKEN=${HF_TOKEN}" >>llm/vllm.env
fi
