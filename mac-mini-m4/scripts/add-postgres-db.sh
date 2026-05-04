#!/bin/bash
# Add a new PostgreSQL database to the unified postgres instance.
#
# Creates:
#   - A random password
#   - A BWS secret to store it
#   - The postgres user and database (live, on the running container)
#
# Usage:
#   BWS_ACCESS_TOKEN=<token> bash scripts/add-postgres-db.sh <db-name> <bws-secret-name>
#
# Example:
#   BWS_ACCESS_TOKEN=xxx bash scripts/add-postgres-db.sh myapp myapp-dean-db-password
#
# After running, paste the printed output to Claude — Claude will update
# stacks.toml, init.sh, backup.sh, and commit. You do not need to touch
# BWS UI or write any SQL.
#
# BWS token: obtain from BWS UI → Machine Accounts.
# Run from the Mac Mini.
set -e

DB_NAME="$1"
BWS_SECRET_NAME="$2"
BWS_PROJECT_ID="6353f589-39c0-45f2-9e9c-b36f00e0c282"
DOCKER=~/.orbstack/bin/docker
BWS=/usr/local/bin/bws

if [ -z "$DB_NAME" ] || [ -z "$BWS_SECRET_NAME" ]; then
  echo "Usage: BWS_ACCESS_TOKEN=<token> $0 <db-name> <bws-secret-name>"
  echo "Example: BWS_ACCESS_TOKEN=xxx $0 myapp myapp-dean-db-password"
  exit 1
fi

if [ -z "$BWS_ACCESS_TOKEN" ]; then
  echo "ERROR: BWS_ACCESS_TOKEN env var required"
  echo "Get it from BWS UI -> Machine Accounts"
  exit 1
fi

echo "=== Generating password ==="
PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)

echo "=== Creating BWS secret: $BWS_SECRET_NAME ==="
BWS_RESULT=$($BWS secret create "$BWS_SECRET_NAME" "$PASSWORD" "$BWS_PROJECT_ID" \
  --access-token "$BWS_ACCESS_TOKEN" -o json)
BWS_ID=$(echo "$BWS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Created: $BWS_ID"

echo "=== Creating postgres user and database ==="
POSTGRES_PW=$($DOCKER exec postgres printenv POSTGRES_PASSWORD)

$DOCKER exec -e PGPASSWORD="$POSTGRES_PW" postgres \
  psql -U postgres -c "CREATE USER $DB_NAME WITH PASSWORD '$PASSWORD';"
$DOCKER exec -e PGPASSWORD="$POSTGRES_PW" postgres \
  psql -U postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_NAME;"
$DOCKER exec -e PGPASSWORD="$POSTGRES_PW" postgres \
  psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;"
$DOCKER exec -e PGPASSWORD="$POSTGRES_PW" postgres \
  psql -U postgres -d "$DB_NAME" -c "
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_NAME;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_NAME;
  "
echo "Database ready."

echo ""
echo "========================================================"
echo "DONE — paste the following to Claude:"
echo "========================================================"
echo "db: $DB_NAME"
echo "bws-secret: $BWS_SECRET_NAME"
echo "bws-id: $BWS_ID"
