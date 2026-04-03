#!/bin/bash
# Runs once on first container start via /docker-entrypoint-initdb.d/
# Creates per-database users and schemas.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER todo WITH PASSWORD '${MINI_POSTGRES_TODO_PASSWORD}';
    CREATE DATABASE todo OWNER todo;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "todo" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL
