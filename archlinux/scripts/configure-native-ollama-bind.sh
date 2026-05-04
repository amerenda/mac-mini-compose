#!/usr/bin/env bash
# Ensure native Ollama listens on 0.0.0.0 so the agent container can reach it
# via host.docker.internal:11434 (same idea as mac-mini-m4 Homebrew plist).
# Idempotent; restarts ollama only when the drop-in changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLLAMA_HOST_VAL="0.0.0.0:11434"
if [[ -f "$ROOT/ollama/environment" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/ollama/environment"
  set +a
fi
OLLAMA_HOST_VAL="${OLLAMA_HOST:-$OLLAMA_HOST_VAL}"

DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN_FILE="${DROPIN_DIR}/99-komodo-ollama-bind.conf"

_run() {
  if [[ "${EUID:-0}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v systemctl >/dev/null 2>&1; then
  echo "configure-native-ollama-bind: skip (no systemctl)" >&2
  exit 0
fi

if ! systemctl cat ollama.service &>/dev/null; then
  echo "configure-native-ollama-bind: skip (ollama.service not found — install native Ollama on the host)" >&2
  exit 0
fi

_run mkdir -p "$DROPIN_DIR"

want="$(printf '%s\n' \
  '# Managed by komodo-dean-gitops archlinux/scripts/configure-native-ollama-bind.sh' \
  '[Service]' \
  "Environment=OLLAMA_HOST=${OLLAMA_HOST_VAL}")"

if [[ -f "$DROPIN_FILE" ]] && echo "$want" | cmp -s - "$DROPIN_FILE"; then
  exit 0
fi

echo "$want" | _run tee "$DROPIN_FILE" >/dev/null
_run systemctl daemon-reload
_run systemctl restart ollama.service
