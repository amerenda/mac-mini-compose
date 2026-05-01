#!/usr/bin/env bash
# Patch Homebrew's Ollama service plist (cellar canonical copy) so Ollama listens
# on all interfaces. brew services copies this into ~/Library/LaunchAgents on restart.
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

PLIST_USER="${HOME}/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
PLIST_CELLAR=""
if [[ -n "$BREW" && -x "$BREW" ]]; then
  OLLAMA_PREFIX="$("$BREW" --prefix ollama 2>/dev/null || true)"
  if [[ -n "$OLLAMA_PREFIX" && -f "$OLLAMA_PREFIX/homebrew.mxcl.ollama.plist" ]]; then
    PLIST_CELLAR="$OLLAMA_PREFIX/homebrew.mxcl.ollama.plist"
  fi
fi

# Homebrew `brew services restart ollama` re-copies the service plist from the cellar into
# ~/Library/LaunchAgents, which would drop OLLAMA_HOST if we only patched the user copy.
PLIST_EDIT="$PLIST_CELLAR"
if [[ -z "$PLIST_EDIT" ]]; then
  PLIST_EDIT="$PLIST_USER"
fi

if [[ ! -f "$PLIST_EDIT" ]]; then
  echo "configure-native-ollama-bind: skip (no $PLIST_USER — install Ollama and: brew services start ollama)" >&2
  exit 0
fi

CURRENT="$(plutil -extract EnvironmentVariables.OLLAMA_HOST raw "$PLIST_EDIT" 2>/dev/null || true)"
if [[ "$CURRENT" == "$OLLAMA_HOST_VAL" ]]; then
  exit 0
fi

if plutil -extract EnvironmentVariables raw "$PLIST_EDIT" &>/dev/null; then
  plutil -replace EnvironmentVariables.OLLAMA_HOST -string "$OLLAMA_HOST_VAL" "$PLIST_EDIT"
else
  plutil -insert EnvironmentVariables -dictionary "$PLIST_EDIT"
  plutil -replace EnvironmentVariables.OLLAMA_HOST -string "$OLLAMA_HOST_VAL" "$PLIST_EDIT"
fi

if [[ -n "$BREW" && -x "$BREW" ]]; then
  export HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1
  "$BREW" services restart ollama
else
  echo "configure-native-ollama-bind: plist updated; restart Ollama manually (brew not found in PATH)" >&2
fi
