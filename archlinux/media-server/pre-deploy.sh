#!/usr/bin/env bash
# Renders archlinux/media-server/.env from BWS for Komodo deploy.
# Invoked by Komodo Periphery from the gitops repo root, so all paths below
# are relative to that root.
set -euo pipefail

: "${BWS_ACCESS_TOKEN:?BWS_ACCESS_TOKEN required (cat /run/secrets/bws-access-token)}"

# Bitwarden Secrets Manager — secret key `do-dns-api-key` (DigitalOcean API token for dyndns).
BWS_DO_API_TOKEN_UUID="d043a77f-ca1e-4ac6-8cfa-b38200f7b6c9"

ENV=archlinux/media-server/.env

DO_API_TOKEN=$(bws secret get "$BWS_DO_API_TOKEN_UUID" --access-token "$BWS_ACCESS_TOKEN" | jq -r .value)
if [[ -z "$DO_API_TOKEN" || "$DO_API_TOKEN" == "null" ]]; then
  echo "media-server pre-deploy: failed to fetch DO_API_TOKEN from BWS" >&2
  exit 1
fi

umask 077
{
  echo "CONFIG_BASE=/opt/media"
  echo "PROFILARR_CONFIG=/opt/media/profilarr/config"
  echo "WHISPARR_CONFIG=/opt/media/whisparr/config"
  echo "RADARR_CONFIG=/opt/media/radarr/config"
  echo "BAZARR_CONFIG=/opt/media/bazarr/config"
  echo "SONARR_CONFIG=/opt/media/sonarr/config"
  echo "SONARR_SCRIPTS=/opt/media/sonarr/scripts"
  echo "PROWLARR_CONFIG=/opt/media/prowlarr/config"
  echo "SABNZBD_CONFIG=/opt/media/sabnzbd/config"
  echo "JELLYFIN_CONFIG=/opt/media/jellyfin/config"
  echo "DATA_BASE=/mnt/storage"
  echo "MOVIES_FOLDER=/mnt/storage/movies"
  echo "TV_FOLDER=/mnt/storage/tv"
  echo "BOOKS_FOLDER=/mnt/storage/books"
  echo "WHISPARR_FOLDER=/mnt/storage/misc/porn"
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
test -f archlinux/media-server/compose.yaml \
  && test -d archlinux/media-server/dns \
  && test -d archlinux/media-server/nginx \
  && test -d archlinux/media-server/certbot \
  || { echo "media-server pre-deploy: layout check failed in $(pwd)" >&2; exit 1; }
