# Backup Stack — GitOps-Driven Backup Strategy for komodo-dean-gitops

## Overview

This directory contains the declarative backup strategy and infrastructure definitions for all services managed by `komodo-dean-gitops`. The goal is to replace manual/cron-based shell scripts with container-forward, GitOps-driven backup mechanisms.

**Architecture (Phase 1):** All backup containers write locally to a shared staging directory (`/backups-local/`). A single unified `gcs-sync.sh` script handles all cloud uploads — never individual containers talking directly to GCS. Safety caps prevent runaway costs. Once sizes are confirmed acceptable, `GCS_DRY_RUN` can be flipped on a schedule or via Komodo webhook trigger.

**Target State (Phase 2):** Containerized backup services orchestrated through Komodo stack deploys, pushing staged backups to GCS via the unified sync script

## Service Inventory & Backup Scope

### Core Stack (`mac-mini-m4/`)

| Service | Data Location | Current Backup Mechanism | GitOps-Managed? | Recovery Priority |
|---------|--------------|------------------------|------------------|-------------------|
| **Z2M** | `zigbee2mqtt-data` volume at `/app/data/`<br>• `configuration.yaml` (in git) | None yet | Partial (`configuration.yaml`) | **HIGH** — coordinator state, device network keys |
| **Home Assistant** | `ha-config` volume at `/config/` | `backup.sh`: copies only non-git files<br>• `scenes.yaml`<br>• `sl_custom_scenes.json`<br>• `.storage/` (helper values, auth) | Partial (most config in git, scenes/storage not) | **HIGH** — UI state, helper values, custom scene packs |
| **Technitium DNS** | `technitium-data` at `/etc/dns/` | None yet | No | MEDIUM — zone files, blocklists, settings |
| **Mosquitto MQTT** | `mosquitto-data` at `/mosquitto/data/`<br>• `mqtt.data` (persistent subscriptions) | None yet | Partial (`config/mosquitto.conf`) | MEDIUM — in-memory only if no persistence enabled |
| **PostgreSQL** | Docker volume `postgres-data:/var/lib/postgresql/data` | Containerized: `pg_dump → gzip → GCS` via cron at 02:00 daily, 7-day retention | No (volume-only) | CRITICAL — databases: postgres, todo (with pgvector), agent_kb (with pgvector) |
| **MongoDB** | Docker volume `mongo-data:/data/db` + `init-unifi.sh` (in git) | Containerized: `mongodump → gzip → GCS` via cron at 02:15 daily, 7-day retention | Partial (`init-unifi.sh`) | HIGH — UniFi Controller state |
| **Whisper** | Docker volume `whisper-data:/data` | None | No | LOW — model cache (can be re-downloaded) |
| **Piper TTS** | Docker volume `piper-data:/data` | None | No | LOW — voice models (can be re-downloaded) |

### Automation Stack (`mac-mini-m4/automation/`)

| Service | Data Location | Current Backup Mechanism | GitOps-Managed? | Recovery Priority |
|---------|--------------|------------------------|------------------|-------------------|
| **Custom automations** | `compose.yaml` + mounted config files | All in git via resource-sync | Yes | — (no data to backup) |

### Monitoring Stack (`mac-mini-m4/monitoring/`)

| Service | Data Location | Current Backup Mechanism | GitOps-Managed? | Recovery Priority |
|---------|--------------|------------------------|------------------|-------------------|
| **Grafana** | Docker volume (unspecified in compose) | None yet | Partial (`prometheus.yml`, dashboards may be exported from UI) | MEDIUM — custom dashboards, data source configs, alert rules |
| **Prometheus** | Docker volume (unspecified in compose) | None yet | No | HIGH — time-series metrics data for 7-30 day windows |

### LLM Stack (`mac-mini-m4/llm/`)

| Service | Data Location | Current Backup Mechanism | GitOps-Managed? | Recovery Priority |
|---------|--------------|------------------------|------------------|-------------------|
| **LLM Agent** | Container-only, stateless | No data to backup (self-updates from llm-manager repo) | Yes | — |

### Archlinux Stack (`archlinux/`)

- Currently only has `scripts/` and `README.md` in komodo-dean-gitops
- Services: TBD based on archlinux host provisioning status
- When provisioned, will follow same backup-stack pattern as mac-mini-m4

### Murderbot Stack (`murderbot/`)

- Media-server stack (Docker) — to be added via resource-sync
- Will need dedicated backup definition once services are defined in komodo-dean-gitops

## Backup Strategy Principles

### 1. Container-Forward Only

All backup logic must run inside Docker containers managed by Komodo. No cron jobs, no manual scripts on host filesystems. Every backup container:
- Has its own lifecycle (start/stop/scale) defined in docker-compose
- Pushes backups to GCS via HMAC-S3 compatible endpoint using `s3cmd` or AWS CLI
- Logs all operations for audit/recovery verification

### 2. Minimal Backup Sets — What We Actually Need to Recover

**Z2M Stack (CRITICAL):**
- `/app/data/coordinator_backup.json` — EmberZNet coordinator state (pan_id, ext_pan_id, network_key, channels)  
- `/app/data/database.db` — SQLite with device bindings/routing table, neighbor info
- `/app/data/configuration.yaml` — already in git, but keep for reference

**Home Assistant (HIGH):**
- `/config/scenes.yaml` — scenes created/edited in HA UI
- `/config/sl_custom_scenes.json` — Smart Lighting custom scene packs (if any)
- `/config/.storage/` — all persistent state: helper values, auth tokens, Lovelace config, entity registry

**MongoDB/UniFi (HIGH):**
- Full mongodump archive (.gz) via containerized backup job
- Already exists in docker-compose.yaml.old; migrate to new structure

**PostgreSQL (CRITICAL):**
- `pg_dump` per database (todo with pgvector, agent_kb with pgvector, postgres base)
- Already exists in docker-compose.yaml.old; migrate to new structure

**Grafana (MEDIUM):**
- Export all dashboards via Grafana API (`/api/dashboards/db`)
- Backup data source configurations (`/api/datasources`)
- Alert rule definitions (`/api/alert_rules`)

**Prometheus (HIGH but not critical):**
- Time-series data has short retention (~30 days anyway)
- Consider: backup `prometheus.yml` config + scrape targets only
- Only need to recover if all Prometheus servers go down simultaneously

### 3. No Duplicates, No Train DBs

Only back up what cannot be recovered from:
1. The komodo-dean-gitops Git repository itself (config files in git)
2. Remote sources (GCS for Postgres/MongoDB backups, model download URLs, etc.)

**Examples of what NOT to backup:**
- HA configuration.yaml (in git at `mac-mini-m4/homeassistant/configuration/configuration.yaml`)
- Z2M configuration.yaml (in git at `mac-mini-m4/zigbee2mqtt/configuration.yaml`)
- Mosquitto config (in git at `mac-mini-m4/mosquitto/config/mosquitto.conf`)
- BIND9 zone files (would be in git if enabled)
- Model weights that can be re-downloaded

### 4. Backup Storage Structure on GCS

```
gs://amerenda-backups/us/mac-mini/dean/
├── postgres/
│   ├── postgres_20260526_020000.sql.gz    # base database
│   ├── todo_20260526_020000.sql.gz        # todo DB with pgvector
│   └── agent_kb_20260526_020000.sql.gz    # agent_kb DB with pgvector
├── mongo/
│   └── mongo_20260526_021500.archive.gz
├── homeassistant/
│   ├── scenes.yaml                         # (not in GCS — local Docker volume backup only)
│   ├── sl_custom_scenes.json               # optional
│   └── .storage/                           # helper values, auth, Lovelace
├── z2m/
│   ├── coordinator_backup_20260526.json    # EmberZNet coordinator state
│   └── database.db                         # Z2M device bindings
├── grafana/
│   ├── dashboards.json                     # exported from API
│   ├── datasources.json                    # data source configs
│   └── alerts.json                         # alert rule definitions
└── prometheus/
    └── prometheus_config_20260526.yml      # scrape targets, global config only
```

## Implementation Plan

### Phase 1: Local-Only Backups with Unified GCS Sync (IN PROGRESS ✅)

**What:** All backup containers write locally to shared staging directory; single `gcs-sync.sh` handles all uploads  
**Where:** `mac-mini-m4/backup-stack/`  

**Architecture:**
```
┌─────────────┐  ┌──────────┐   ┌───────────────┐
│ z2m-backup  │  │ ha-backup│   │ grafana-backup│
│ prometheus- │  │ ...      │   │ ...           │
└──────┬──────┘  └────┬─────┘   └──────┬────────┘
       │              │                 │
       ▼              ▼                 ▼
  ┌───────────────────────────────────────┐
  │  Shared staging volume                │
  │  /backups-local/staging/{service}/    │
  │  (local filesystem, retained locally) │
  └──────────────────┬────────────────────┘
                     │
        gcs-sync.sh reads from here
                     │
                     ▼
              ┌──────────────┐
              │   GCS/S3     │ ← Only gcs-sync touches cloud storage
              │  (opt-in)    │   with safety caps (max size, max files)
              └──────────────┘
```

**Safety Caps in `gcs-sync.sh`:**
- **Dry-run by default:** Must pass `--force` to upload anything
- **Max total size cap:** Default 1024 MB (configurable via `GCS_MAX_SIZE_MB`)
- **Max files per service:** Default 30 per directory (prevents unbounded growth)
- **Local retention:** All backup scripts keep only latest N copies locally before gcs-sync even sees them

**Completed artifacts in `backup-stack/`:**
```
├── PLAN.md                          # This file
├── README.md                        # Recovery procedures
├── backups.yaml                     # All backup containers: Z2M, HA, Grafana, Prometheus + gcs-sync (single file)
└── backup-scripts/                  # All scripts write locally, no GCS credentials needed
    ├── z2m.sh                       # Coordinator state + database.db → staging
    ├── ha.sh                        # scenes.yaml + .storage/ → staging  
    ├── grafana-export.sh            # Dashboard JSON export via REST API → staging
    ├── prometheus-config.sh         # Prometheus config only → staging
    └── gcs-sync.sh                  # Unified sync: staging → GCS with safety caps
```

**To deploy:** Add all services from `backups.yaml` to your docker-compose.yaml (core or monitoring stack — they share the same `backups-local` volume, so either location works), and ensure the `backups-local:` volume is declared at the bottom of that compose file. One manifest, one merge.

### Phase 2: Confirm Backup Sizes (PENDING)

- Let local backups accumulate for a few days
- Check total staging directory size: `du -sh /tmp/backups-local/staging/`
- Verify per-service sizes make sense against GCS storage cost expectations  
- Decide whether to flip the switch on cloud sync or keep everything local

### Phase 3: Enable Cloud Sync (WHEN READY)

Once sizes are confirmed acceptable, either:
1. **Manual trigger:** `docker exec gcs-sync sh /gcs-sync.sh --force` from host
2. **Schedule via Komodo webhook:** Add to a stack deploy trigger or Komodo automation rule  
3. **Optional auto-cleanup:** Set `GCS_CLEANUP_AFTER_SYNC=true` in environment if you want local files deleted after successful GCS upload

### Phase 4: Additional Services (FUTURE)

- Technitium DNS backup (`/etc/dns/*`) — medium priority
- Mosquitto persistence data (`mosquitto-data/mqtt.data`) — check if `persistence true` is set in mosquitto.conf first  
- SLZB-OS parameter dump via HTTP API (device settings, not Zigbee network state)

## Docker Volume Sharing Solution

Instead of the unified orchestrator approach (which requires Docker socket access), this design uses a **shared named volume** (`backups-local`) that all backup containers mount read-write for staging. The `gcs-sync.sh` container also mounts this volume to read and upload. This avoids:
- No Docker socket access needed
- Each service only needs its own data volume + the shared staging volume  
- Clean separation of concerns (backup write vs sync upload)

## Backup Stack Directory Structure

```
komodo-dean-gitops/mac-mini-m4/backup-stack/
├── PLAN.md                          # This file
├── BACKUP_POLICY.md                 # Retention rules, recovery procedures, SLAs (TODO)
├── backup-scripts/                  # All scripts write locally to staging directory
│   ├── z2m.sh                       # Zigbee coordinator + database backup → local staging
│   ├── ha.sh                        # Home Assistant scenes/storage backup → local staging  
│   ├── grafana-export.sh            # Grafana dashboard export via REST API → local staging
│   ├── prometheus-config.sh         # Prometheus config only (no time-series) → local staging
│   └── gcs-sync.sh                  # Unified GCS sync with safety caps ← ONLY script that touches cloud storage
├── backups.yaml                     # Single Docker compose manifest for all backup containers + gcs-sync
└── README.md                        # How to restore from backups per service (recovery procedures)
```

**Local staging directory path:** `/tmp/backups-local/staging/{service}/` (mounted as `backups-local:` named volume in Docker compose)  
**GCS remote prefix:** `amerenda-backups/us/mac-mini/dean/`

## GCS Sync Usage

```bash
# Dry run — shows what would be uploaded without uploading anything
docker exec gcs-sync sh /gcs-sync.sh --dry-run

# Actually upload to GCS (requires --force flag, safety caps enforced)
docker exec gcs-sync sh /gcs-sync.sh --force

# Upload with auto-cleanup of local files after successful sync
GCS_CLEANUP_AFTER_SYNC=true docker exec gcs-sync sh /gcs-sync.sh --force

# Increase size cap for larger backups (default: 1024 MB)
GCS_MAX_SIZE_MB=5120 docker exec gcs-sync sh /gcs-sync.sh --force
```

**Safety caps are ALWAYS enforced** — if local staging exceeds the max size or file count, sync is aborted. Override by adjusting `GCS_MAX_SIZE_MB` and `GCS_MAX_FILES_PER_SVC` environment variables, but only after confirming acceptable storage costs with Alex.

## Current GCS Storage for Reference

Already in use by docker-compose.yaml.old:
- Bucket: `amerenda-backups`  
- Path: `us/mac-mini/dean/postgres/` and `us/mac-mini/dean/mongo/`  
- Access via HMAC-S3 endpoint (not native GCS)  
  - `BACKUP_ENDPOINT` from BWS  
  - `BACKUP_ACCESS_KEY` / `BACKUP_SECRET_KEY` from BWS

## Recovery Procedures Summary

| Service | Recovery Command | Time to Restore |
|---------|-----------------|-----------------|
| **Z2M** | Stop container → overwrite `/app/data/coordinator_backup.json` and `database.db` with backup files → restart Z2M | ~5 minutes |
| **Home Assistant** | Stop HA → replace `scenes.yaml`, `sl_custom_scenes.json`, `.storage/` from backup volume → restart HA | ~5 minutes |
| **PostgreSQL** | Run `pg_restore -U postgres todo < todo_backup.sql.gz` (per database) | ~10-30 seconds per DB |
| **MongoDB** | Run `mongorestore --archive=mongo_backup.archive.gz` | ~30 seconds to 2 minutes depending on size |
| **Grafana** | Import JSON via UI/API: `POST /api/dashboards/db` with dashboard JSON files | ~5-10 minutes per dashboard group |

## Notes & Constraints

### Docker Volume Sharing Limitation

Docker volumes are not directly shareable across containers without using the Docker socket or bind-mounting volume paths on the host. This means:
- A "unified backup orchestrator" would need to either run with Docker socket access (security risk) OR use a custom agent image that can enumerate and mount volumes programmatically
- Current docker-compose.yaml.old workaround: each service has its own backup container with cron, running independently

### GCS Storage Architecture

The current setup uses an S3-compatible HMAC endpoint (likely Google Cloud Storage or MinIO/Swift). This means `s3cmd` or AWS CLI must be used — not native `gsutil`. The same credentials work for all services.

### Komodo ResourceSync Integration

Backup service definitions should be added to:
1. `resource-sync/stacks.toml` under the appropriate stack (core, monitoring, etc.)
2. Each backup container definition goes into its stack's docker-compose.yaml as a separate service with `komodo.skip:` label if it shouldn't trigger redeploy on non-secret changes

### Secrets Management

All backup containers must source credentials from `.env` files injected during Komodo deployment:
- `BACKUP_ACCESS_KEY`, `BACKUP_SECRET_KEY`, `BACKUP_ENDPOINT` (GCS/HMAC-S3)
- Per-database credentials (Postgres, MongoDB) — already in existing docker-compose.yaml.old

## Migration Timeline

1. **Week 1:** Create Z2M backup container + scripts  
   - Priority: CRITICAL — Zigbee coordinator state is irreplaceable if lost
   - Depends on: `coordinator_backup.json` being generated regularly by Z2M zigbee-herdsman module

2. **Week 2:** Wrap HA volume backup in docker-compose service  
   - Current shell script runs via host cron; migrate to containerized approach
   - Priority: HIGH — scenes and helper state cannot be recovered from UI after loss

3. **Week 3:** Add Grafana dashboard export + Prometheus config backup  
   - Priority: MEDIUM (Grafana) / HIGH (Prometheus if remote_write fails)

4. **Ongoing:** Monitor retention, verify backup integrity quarterly

---

*Created: May 2026*  
*Status: Planning — Phase 1 not yet implemented*
