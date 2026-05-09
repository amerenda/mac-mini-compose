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

# Avoid `bws | jq` pipe: Rust bws can panic with EPIPE if jq closes stdout early (Komodo hooks).
_bws_json="$(bws secret get "$BWS_LLM_AGENT_PSK_UUID" --access-token "$BWS_ACCESS_TOKEN")"
PSK="$(jq -r .value <<<"$_bws_json")"

# Fetch HuggingFace read-only token for vLLM model pulls (gated models).
_bws_list_json="$(bws secret list --access-token "$BWS_ACCESS_TOKEN" --output json 2>&1 >/dev/null)"
BWS_HF_TOKEN_UUID="$(jq -r '.[] | select(.key == "hugging-face-read-only") | .id' <<<"$_bws_list_json" 2>/dev/null | head -1)"
if [[ -n "$BWS_HF_TOKEN_UUID" ]]; then
  HF_TOKEN="$(bws secret get "$BWS_HF_TOKEN_UUID" --access-token "$BWS_ACCESS_TOKEN"
  HF_TOKEN=""
  echo "Warning: BWS secret 'hugging-face-read-only' not found — HF_TOKEN will be empty"
fi

BACKEND_PUBLIC="${BACKEND_PUBLIC:-https://llm-manager-backend.amer.dev}"
BACKEND_PUBLIC="${BACKEND_PUBLIC%/}"
AGENT_IMAGE_TAG_RESOLVED="${AGENT_IMAGE_TAG:-}"
if [[ -z "$AGENT_IMAGE_TAG_RESOLVED" ]] && command -v curl >/dev/null && command -v jq >/dev/null; then
  # Fetch target version from backend API (curl outputs to temp file, no pipe to jq)
  curl -sfL "$BACKEND_PUBLIC/api/runners/target-version" -o /tmp/target-version.json
  AGENT_IMAGE_TAG_RESOLVED="$(jq -r '.target_version // empty' /tmp/target-version.json 2>/dev/null | tr -d ' \t\r\n')"
  if [ $? -eq 0 ]; then
    AGENT_IMAGE_TAG_RESOLVED="$(jq -r '.target_version // empty' | tr -d ' \t\r\n')
  fi
if [[ -z "$AGENT_IMAGE_TAG_RESOLVED" ]]; then
  AGENT_IMAGE_TAG_RESOLVED="latest"
fi

{
  echo "LLM_MANAGER_AGENT_PSK=${PSK}"
  echo "BACKEND_URL

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
