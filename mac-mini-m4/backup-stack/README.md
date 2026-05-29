# Backup Stack — Recovery Procedures

This document describes how to restore each service's data from local backups staged in `/backups-local/staging/`. Cloud uploads via GCS are **opt-in** (run `gcs-sync.sh --force`).

## Prerequisites for All Restorations

### Local Backups Location

Local staging directory is shared across all backup containers as the Docker volume named `backups-local:`, mounted at `/backups-local/staging/{service}/` inside each container. On the host (mac-mini-m4), this maps to a Docker-managed volume accessible via:

```bash
# Find where Docker stores the backups-local volume on the Mac Mini
docker volume inspect backups-local 2>/dev/null || docker run --rm -v backups-local:/data alpine ls /data/

# List all staged local backups (from outside container)
# Inside a running backup container:
ls -laR /backups-local/staging/

# Or from the host via docker exec:
docker exec z2m-backup ls -la /backups-local/staging/z2m/
docker exec ha-backup ls -la /backups-local/staging/homeassistant/
```

### Upload to GCS (Optional — Only After Size Confirmation)

When ready to enable cloud backups, run:

```bash
# Dry-run first — see what would be uploaded without uploading anything
docker exec gcs-sync sh /gcs-sync.sh --dry-run

# Actually upload to GCS with safety caps enforced
docker exec gcs-sync sh /gcs-sync.sh --force
```

**Safety:** `--dry-run` is the default; `--force` is required for actual uploads. Caps: 1GB max total size, 30 files per service (configurable via env vars).

### Restore Pattern for All Services

1. Stop the affected container  
2. Overwrite/restore data files from local staging volume → Docker volume
3. Start the container  

---

## Service Recovery Procedures

### 1. Zigbee2MQTT Coordinator Recovery

**When to restore:** SLZB-06 coordinator hardware failure, firmware corruption, network key loss

**Backup location (local staging):** Docker volume `backups-local` → `/backups-local/staging/z2m/` inside backup container  
Files: `coordinator_backup_YYYYMMDD_HHMMSS.json`, `database_YYYYMMDD_HHMMSS.db`

```bash
# Step 1: List available local backups (from host)
docker exec z2m-backup ls -la /backups-local/staging/z2m/

# Step 2: Copy latest backup from staging volume to a temporary location
docker cp $(docker inspect --format='{{range .Mounts}}{{if eq .Name "backups-local"}}{{.Destination}}{{end}}{{end}}' z2m-backup):/backups-local/staging/z2m/coordinator_backup_*.json /tmp/coordinator_latest.json 2>/dev/null || \
  docker exec z2m-backup ls -t /backups-local/staging/z2m/*.json | head -1

# Simpler approach — just copy the latest file into the Z2M container directly:
LATEST=$(docker exec z2m-backup ls -t /backups-local/staging/z2m/coordinator_backup_*.json 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
  docker cp "${LATEST#/}" zigbee2mqtt:/app/data/coordinator_backup.json
else
  echo "No coordinator backups found in staging. Try GCS recovery (see below)."
fi

# Or restore database.db:
LATEST_DB=$(docker exec z2m-backup ls -t /backups-local/staging/z2m/database_*.db 2>/dev/null | head -1)
if [ -n "$LATEST_DB" ]; then
  docker cp "${LATEST_DB#/}" zigbee2mqtt:/app/data/database.db
fi

# Step 3: Stop Z2M container
docker stop zigbee2mqtt

# Step 4: Start Z2M — it will load the coordinator state and device bindings from volume files
docker start zigbee2mqtt

# Verify recovery (Z2M UI or API)
curl -sf http://localhost:8099/api/status | jq .
```

**Notes:**
- The `coordinator_backup.json` uses Open Coordinator Backup Format v1 (from zigpy/open-coordinator-backup spec)  
- Device bindings/routing info is in `database.db` SQLite file — restoring this preserves all paired devices and their network addresses
- If you've replaced the SLZB-06 coordinator entirely, see [SLZB-06 Migration Guide](https://github.com/smlight-tech/slzb-os) for firmware flashing steps

### 2. Home Assistant Recovery

**When to restore:** HA container/data loss, `.storage/` corruption (helper values lost), scenes.yaml deletion

**Backup location (local staging):** Docker volume `backups-local` → `/backups-local/staging/homeassistant/` inside backup container  
Files: `scenes_YYYYMMDD_HHMMSS.yaml`, `custom_scenes_YYYYMMDD_HHMMSS.json`, `.storage_YYYYMMDD_HHMMSS.tar.gz`

```bash
# Step 1: List available local backups
docker exec ha-backup ls -la /backups-local/staging/homeassistant/

# Step 2: Copy scenes.yaml from staging to HA container
LATEST_SCENES=$(docker exec ha-backup ls -t /backups-local/staging/homeassistant/scenes_*.yaml 2>/dev/null | head -1)
if [ -n "$LATEST_SCENES" ]; then
  docker cp "${LATEST_SCENES#/}" homeassistant:/config/scenes.yaml
fi

# Step 3: Extract .storage/ from backup tarball to staging location, then copy to HA volume
mkdir -p /tmp/.storage-extract
LATEST_STORAGE=$(docker exec ha-backup ls -t /backups-local/staging/homeassistant/.storage_*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST_STORAGE" ]; then
  docker cp "${LATEST_STORAGE#/}" /tmp/storage_backup.tar.gz
  tar xzf /tmp/storage_backup.tar.gz -C /tmp/.storage-extract/
  # .storage is nested inside homeassistant/.homeassistant in the tarball — copy to HA volume
  if [ -d "/tmp/.storage-extract/homeassistant/.homeassistant/.storage" ]; then
    docker cp /tmp/.storage-extract/homeassistant/.homeassistant/.storage homeassistant:/config/.storage
  fi
else
  echo "No .storage backup found in staging. Try GCS recovery (see below)."
fi

# Step 4: Restore sl_custom_scenes.json if it exists and needed
LATEST_CUSTOM=$(docker exec ha-backup ls -t /backups-local/staging/homeassistant/custom_scenes_*.json 2>/dev/null | head -1)
if [ -n "$LATEST_CUSTOM" ]; then
  docker cp "${LATEST_CUSTOM#/}" homeassistant:/config/sl_custom_scenes.json
fi

# Step 5: Start HA (or just reload UI if container was already running — files are live-read)
docker start homeassistant

# Verify recovery (HA API)
curl -sf http://localhost:8123/api/config | jq .
```

**Notes:**
- `.storage/` contains helper values, auth tokens, Lovelace config, entity registry — this is the critical file  
- Scenes created in HA UI are only stored in `scenes.yaml` (not in configuration.yaml)
- `sl_custom_scenes.json` from Smart Lighting integration may not exist if no custom packs were saved

### 3. Postgres Recovery (Already Implemented)

**When to restore:** Database corruption, accidental data loss  
Backup location: `amerenda-backups/us/mac-mini/dean/postgres/`  
Files per database: `{db}_YYYYMMDD_HHMMSS.sql.gz`

```bash
# Step 1: Download latest backup for the target database
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/postgres/todo_20260526_020000.sql.gz" /tmp/todo_backup.sql.gz
gunzip < /tmp/todo_backup.sql.gz > /tmp/todo_backup.sql

# Step 2: Connect to Postgres and restore (per-database)
docker exec -it postgres psql -U postgres todo -f /tmp/todo_backup.sql

# Or for agent_kb database (includes pgvector data):
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/postgres/agent_kb_20260526_020000.sql.gz" /tmp/agent_kb_backup.sql.gz
gunzip < /tmp/agent_kb_backup.sql.gz > /tmp/agent_kb_backup.sql
docker exec -it postgres psql -U postgres agent_kb -f /tmp/agent_kb_backup.sql

# Or restore the base postgres database:
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/postgres/postgres_20260526_020000.sql.gz" /tmp/postgres_base.sql.gz  
gunzip < /tmp/postgres_base.sql.gz > /tmp/postgres_base.sql
docker exec -it postgres psql -U postgres postgres -f /tmp/postgres_base.sql
```

**Notes:**
- Backups use `pg_dump` format (compatible with `psql -f`) — not custom pg_restore binary dump  
- pgvector extension data is included in the SQL dumps (stored as regular PostgreSQL types)
- Retention: 7 daily backups (managed by postgres-backup container's s3cmd cleanup loop)

### 4. MongoDB/UniFi Recovery (Already Implemented)

**When to restore:** UniFi Controller database corruption, accidental device deletion  
Backup location: `amerenda-backups/us/mac-mini/dean/mongo/`  
Files: `mongo_YYYYMMDD_HHMMSS.archive.gz`

```bash
# Step 1: Download latest backup from GCS
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/mongo/mongo_20260526_021500.archive.gz" /tmp/mongo_backup.archive.gz

# Step 2: Restore to MongoDB container  
docker exec -it mongo mongorestore --archive=/tmp/mongo_restore.archive --gzip --nsFrom 'unifi.*' --nsTo 'unifi.*' < /tmp/mongo_backup.archive.gz

# Alternative: if you need full restore (all databases), use without --nsFrom/--nsTo
docker exec -it mongo mongorestore --archive=/tmp/mongo_backup.archive.gz --gzip
```

**Notes:**  
- Backups use `mongodump` archive format — compatible with `mongorestore --archive`
- UniFi Controller stores all device configuration, policies, and network state in MongoDB
- Retention: 7 daily backups (managed by mongo-backup container's s3cmd cleanup loop)

### 5. Grafana Dashboard Recovery

**When to restore:** Grafana container/data loss, dashboard deletion  
Backup location: `amerenda-backups/us/mac-mini/dean/grafana/`  
Files: `dashboards/YYYYMMDD_HHMMSS_{uid}_*.json`, `datasources/datasources_YYYYMMDD_HHMMSS.json`

```bash
# Step 1: Download dashboards and datasources from GCS
mkdir -p /tmp/grafana-restore/{dashboards,datasources}
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/grafana/dashboards/20260526_123456_example_dashboard.json" /tmp/grafana-restore/dashboards/
s3cmd get "s3://amerenda-backups/us/mac-mini/dean/grafana/datasources/datasources_20260526_123456.json" /tmp/grafana-restore/datasources/datasources.json

# Step 2: Restore datasources (if needed — usually already in gitops or created via UI)
curl -X POST http://localhost:3000/api/datasources \
  -H "Authorization: Bearer ${GRAFANA_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/grafana-restore/datasources/datasources.json

# Step 3: Restore dashboards (import via API)
for DASH_FILE in /tmp/grafana-restore/dashboards/*.json; do
  echo "Importing dashboard: $(basename $DASH_FILE)"
  curl -X POST http://localhost:3000/api/dashboards/db \
    -H "Authorization: Bearer ${GRAFANA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$DASH_FILE"
done

# Step 4: Verify Grafana is accessible on port 3000
curl -sf http://localhost:3000/api/health | jq .
```

**Notes:**  
- Dashboard JSON files contain full panel definitions, queries, and metadata (not just screenshots)
- Data source configurations are also backed up separately — restore them first before importing dashboards that reference those data sources
- Dashboards created via UI (not from gitops YAML) are the only ones backed up

---

## Disaster Recovery Checklist: Complete Mac Mini M4 Failure

If mac-mini-m4 is completely unavailable (hardware failure, OS reinstall), follow this sequence:

1. **Reinstall macOS + OrbStack** on replacement hardware
2. **Install Homebrew + system packages:**  
   ```bash
   brew install docker s3cmd curl jq
   ```

3. **Clone komodo-dean-gitops repo and fetch secrets from BWS:**
   ```bash
   git clone https://github.com/amerenda/komodo-dean-gitops.git
   cd mac-mini-m4/
   # Fetch secrets via bws CLI (already in ansible-playbooks: playbooks/infrastructure/setup-macmini.yml)
   ansible-playbook ... --extra-vars "bws_access_token=..."
   ```

4. **Start core services (non-stateful):**  
   ```bash
   docker compose up -d  # Starts HA, Technitium, Mosquitto, Z2M, PostgreSQL, MongoDB in order
   ```

5. **Restore state from backups:**

   **Option A — Local staging volume (if mac-mini was partially recoverable and local volumes survived):**
   ```bash
   # Z2M coordinator + database from local staging
   LATEST=$(docker exec z2m-backup ls -t /backups-local/staging/z2m/coordinator_backup_*.json | head -1)
   docker stop zigbee2mqtt && docker cp "${LATEST#/}" zigbee2mqtt:/app/data/coordinator_backup.json && docker start zigbee2mqtt

   # HA scenes + .storage from local staging  
   docker exec ha-backup ls /backups-local/staging/homeassistant/
   # (follow service recovery procedures above for detailed steps)
   ```

   **Option B — GCS backups (if uploaded via gcs-sync previously):**
   ```bash
   # Postgres databases (CRITICAL — restore first)
   s3cmd get "s3://amerenda-backups/us/mac-mini/dean/postgres/todo_YYYYMMDD_HHMMSS.sql.gz" /tmp/ && gunzip -c /tmp/todo_*.sql.gz | docker exec -i postgres psql -U postgres todo
   
   # MongoDB/UniFi (HIGH)
   s3cmd get "s3://amerenda-backups/us/mac-mini/dean/mongo/mongo_YYYYMMDD_HHMMSS.archive.gz" /tmp/ && \
     docker exec -it mongo mongorestore --archive=/tmp/mongo_backup.archive.gz --gzip
   
   # Z2M coordinator state (CRITICAL) — from GCS
   s3cmd get "s3://amerenda-backups/us/mac-mini/dean/z2m/coordinator_backup_YYYYMMDD_HHMMSS.json" /tmp/ && \
     docker exec -i zigbee2mqtt cp /dev/stdin /app/data/coordinator_backup.json < /tmp/coordinator_backup_*.json
   
   # Home Assistant state (HIGH) — from GCS  
   s3cmd get "s3://amerenda-backups/us/mac-mini/dean/homeassistant/storage_YYYYMMDD_HHMMSS.tar.gz" /tmp/ && \
     mkdir -p /tmp/.storage-extract && tar xzf /tmp/storage_*.tar.gz -C /tmp/.storage-extract/ && \
     docker cp /tmp/.storage-extract/homeassistant/.homeassistant/.storage homeassistant:/config/.storage
   
   # Grafana dashboards (MEDIUM) — from GCS
   s3cmd get "s3://amerenda-backups/us/mac-mini/dean/grafana/dashboards/*.json" /tmp/ 2>/dev/null && \
     for f in /tmp/*.json; do curl -X POST http://localhost:3000/api/dashboards/db -H "Authorization: Bearer $GRAFANA_API_TOKEN" -d @"$f"; done
   ```

6. **Verify services:**  
   Check each service API endpoints, run health checks

7. **Resume backup scheduling:** (already running via docker-compose containers' sleep loops)

---

## Backup Verification Schedule

| Frequency | Action | Owner |
|-----------|--------|-------|
| Daily | Local backups write to staging directory — verify container logs for errors | Automation (sleep loops in compose containers) |  
| Weekly | Check total staging size: `docker exec z2m-backup du -sh /backups-local/staging/` | Alex |
| **Before enabling GCS** | Confirm per-service sizes are acceptable — no runaway cloud bills | Alex (decision gate) |
| Monthly (post-GCS enable) | Spot-check latest backup from each service via `s3cmd ls` + download test file | Alex/manual verification |
| Quarterly | Full disaster recovery drill: restore from local staging or GCS, verify data integrity | Alex (manual runbook execution) |

## Known Limitations & Notes

- **Prometheus time-series data is NOT backed up** — only config files are staged locally. If Prometheus goes down with no remote_write target, metrics will be lost. Consider using a backup Prometheus instance or K3s cluster for cross-cluster redundancy.
- **Mosquitto MQTT data:** The `mqtt.data` file (persistent subscriptions) is NOT backed up yet unless persistence mode is enabled and volume is mounted in the HA backup container. Currently Mosquitto uses memory-only mode by default — verify `/mosquitto/config/mosquitto.conf` has `persistence true`.
- **Z2M pairing state:** The `coordinator_backup.json` contains network key, but newly paired devices after last backup won't be in the coordinator database until Z2M re-pairs them. If SLZB-06 is replaced entirely, all devices must be re-added to Zigbee network manually or via `zigpy-coordinator-backup` tool.
- **Cloud upload is opt-in:** Backups are local-only by default (`gcs-sync.sh --force` required to upload). This prevents accidental GCS costs until sizes are confirmed acceptable.

---

*Created: May 2026 as part of backup-stack GitOps initiative — Local-first design (no cloud uploads without explicit `--force` flag)*  
*Status: Scripts written, compose manifests ready for merge — local backups accumulating before GCS sync decision*
