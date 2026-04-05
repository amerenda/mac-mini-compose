#!/bin/bash
# Runs once on first MongoDB container start.
# Creates the 'unifi' user with dbOwner on unifi and unifi_stat databases.
set -e

mongo --quiet <<EOF
use admin

db.createUser({
  user: "unifi",
  pwd: "${MONGO_INITDB_ROOT_PASSWORD}",
  roles: [
    { role: "dbOwner", db: "unifi" },
    { role: "dbOwner", db: "unifi_stat" }
  ]
});

print("[INFO] Created 'unifi' user with dbOwner on unifi and unifi_stat");
EOF
