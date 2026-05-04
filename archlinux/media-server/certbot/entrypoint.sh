#!/bin/sh

# Function to renew the certificate every 12 hours
renew_certificate() {
  while true; do
    certbot -v certonly --standalone -d "$JELLYFIN_URL" -n || true
    sleep 12h
  done
}

# Start renewing the certificate
renew_certificate
#certbot -v certonly --standalone -d "$JELLYFIN_URL" -n
