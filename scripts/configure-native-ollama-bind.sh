#!/usr/bin/env bash
# Patch Homebrew's user LaunchAgent plist so Ollama listens on all interfaces.
# Idempotent; restarts ollama only when the plist changes.
# Repo root is two levels up from this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLLAMA_HOST_VAL="0.0.0.0:11434"
if [[ -f "$ROOT/ollama/environment" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/ollama/environment"
  set +a
fi
OLLAMA_HOST_VAL="${OLLAMA_HOST:-$OLLAMA_HOST_VAL}"

BREW="${BREW:-}"
if [[ -z "$BREW" || ! -x "$BREW" ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
  else
    BREW="$(command -v brew || true)"
  fi
fi

PLIST="${HOME}/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "configure-native-ollama-bind: skip (no $PLIST — install Ollama and: brew services start ollama)" >&2
  exit 0
fi

CURRENT="$(plutil -extract EnvironmentVariables.OLLAMA_HOST raw "$PLIST" 2>/dev/null || true)"
if [[ "$CURRENT" == "$OLLAMA_HOST_VAL" ]]; then
  exit 0
fi

if plutil -extract EnvironmentVariables raw "$PLIST" &>/dev/null; then
  plutil -replace EnvironmentVariables.OLLAMA_HOST -string "$OLLAMA_HOST_VAL" "$PLIST"
else
  plutil -insert EnvironmentVariables -dictionary "$PLIST"
  plutil -replace EnvironmentVariables.OLLAMA_HOST -string "$OLLAMA_HOST_VAL" "$PLIST"
fi

if [[ -n "$BREW" && -x "$BREW" ]]; then
  export HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1
  "$BREW" services restart ollama
else
  echo "configure-native-ollama-bind: plist updated; restart Ollama manually (brew not found in PATH)" >&2
fi
