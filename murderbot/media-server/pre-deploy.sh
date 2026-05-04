#!/usr/bin/env bash
# Renders murderbot/media-server/.env from BWS for Komodo deploy.
# Invoked by Komodo Periphery from the gitops repo root, so all paths below
# are relative to that root.
set -euo pipefail

# Stale Komodo stack → server bindings may still target archlinux after the
# murderbot migration. Refuse pre-deploy on the known archlinux LAN IP
# (ansible inventory). Unset or override to allow: MEDIA_SERVER_BLOCK_LAN_IPS=""
MEDIA_SERVER_BLOCK_LAN_IPS="${MEDIA_SERVER_BLOCK_LAN_IPS:-10.100.20.25}"
if [[ -n "$MEDIA_SERVER_BLOCK_LAN_IPS" ]]; then
  _ips=" $(hostname -I 2>/dev/null || echo) "
  for _bad in $MEDIA_SERVER_BLOCK_LAN_IPS; do
    [[ -z "$_bad" ]] && continue
    if [[ "$_ips" == *" ${_bad} "* ]]; then
      echo "media-server pre-deploy: blocked on LAN IP ${_bad} (archlinux). In Komodo, set this stack's server to murderbot only; stacks.toml has deploy=false until storage is ready." >&2
      exit 1
    fi
  done
fi

: "${BWS_ACCESS_TOKEN:?BWS_ACCESS_TOKEN required (cat /run/secrets/bws-access-token)}"

# Bitwarden Secrets Manager — secret key `do-dns-api-key` (DigitalOcean API token for dyndns).
BWS_DO_API_TOKEN_UUID="d043a77f-ca1e-4ac6-8cfa-b38200f7b6c9"

ENV=murderbot/media-server/.env

DO_API_TOKEN=$(bws secret get "$BWS_DO_API_TOKEN_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)
if [[ -z "$DO_API_TOKEN" || "$DO_API_TOKEN" == "null" ]]; then
  echo "media-server pre-deploy: failed to fetch DO_API_TOKEN from BWS" >&2
  exit 1
fi

umask 077
CONFIG_ROOT=/mnt/storage/media/config
{
  echo "CONFIG_BASE=${CONFIG_ROOT}"
  echo "PROFILARR_CONFIG=${CONFIG_ROOT}/profilarr/config"
  echo "RADARR_CONFIG=${CONFIG_ROOT}/radarr/config"
  echo "BAZARR_CONFIG=${CONFIG_ROOT}/bazarr/config"
  echo "SONARR_CONFIG=${CONFIG_ROOT}/sonarr/config"
  echo "SONARR_SCRIPTS=${CONFIG_ROOT}/sonarr/scripts"
  echo "PROWLARR_CONFIG=${CONFIG_ROOT}/prowlarr/config"
  echo "SABNZBD_CONFIG=${CONFIG_ROOT}/sabnzbd/config"
  echo "JELLYFIN_CONFIG=${CONFIG_ROOT}/jellyfin/config"
  echo "DATA_BASE=/mnt/storage"
  echo "MOVIES_FOLDER=/mnt/storage/movies"
  echo "TV_FOLDER=/mnt/storage/tv"
  echo "BOOKS_FOLDER=/mnt/storage/books"
  echo "USENET_DOWNLOADS=/mnt/storage/downloads/complete"
  echo "USENET_DOWNLOADS_INCOMPLETE=/mnt/storage/downloads/incomplete"
  echo "TRANSCODE_FOLDER=/mnt/storage/cache/transcode"
  echo "CERT_FOLDER=/etc/letsencrypt/"
  echo "NGINX_FOLDER=./nginx/config"
  echo "JELLYFIN_URL=media.amer.dev"
  echo "DO_API_TOKEN=${DO_API_TOKEN}"
} > "$ENV"

# Sanity check: assert media-server compose file is at the expected path so
# Komodo's `docker compose up` doesn't silently use the wrong cwd.
test -f murderbot/media-server/compose.yaml \
  && test -d murderbot/media-server/dns \
  && test -d murderbot/media-server/nginx \
  && test -d murderbot/media-server/certbot \
  || { echo "media-server pre-deploy: layout check failed in $(pwd)" >&2; exit 1; }
