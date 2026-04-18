# Mac Mini Compose — Core Home Lab Services

Docker Compose stacks for the Mac Mini M4, managed via Komodo GitOps.

**This host is managed by Ansible.** All changes must be made through the
[ansible-playbooks](https://github.com/amerenda/ansible-playbooks) repo
(`playbooks/infrastructure/setup-macmini.yml`). Do not manually configure
the Mac Mini — run the playbook instead.

## Services

### Services stack (`docker-compose.yaml`)

| Service | Network | Port | Purpose |
|---------|---------|------|---------|
| Home Assistant | host | 8123 | Smart home hub |
| Technitium | host | 53, 5380 | DNS server (replaced Pi-hole + BIND9) |
| Whisper | bridge | 10300 | Speech-to-text (Wyoming protocol) |
| Piper | bridge | 10200 | Text-to-speech (Wyoming protocol) |
| OpenWakeWord | bridge | 10400 | Wake word detection |
| Mosquitto | bridge | 1883 | MQTT broker (Zigbee2MQTT, HA) |
| Zigbee2MQTT | bridge | 8080 | Zigbee coordinator bridge |
| Postgres | bridge | 5432 | Primary database (pgvector/pg16) |
| MongoDB | bridge | 27017 | Secondary database (UniFi) |
| Node Exporter | bridge | 9100 | Host metrics for Prometheus |
| Postgres backup | — | — | Daily backup to GCS |
| MongoDB backup | — | — | Daily backup to GCS |

### Runners stack (`runners/compose.yaml`)

| Service | Purpose |
|---------|---------|
| runner-k3s-runners | GitHub Actions runner for k3s-runners repo |
| runner-ecdysis | GitHub Actions runner for ecdysis repo |
| runner-llm-manager | GitHub Actions runner for llm-manager repo |
| runner-llm-agents | GitHub Actions runner for llm-agents repo |
| runner-photos | GitHub Actions runner for photos repo |

### Komodo stack (`komodo/compose.yaml`)

| Service | Port | Purpose |
|---------|------|---------|
| Komodo Core | 9120 | GitOps UI and API (v2.1.2) |
| Komodo Periphery | 8120 (internal) | Agent for managing Docker on the host (v2.1.2) |
| FerretDB | 27017 (internal) | MongoDB-compatible database for Komodo |
| Postgres (DocumentDB) | 5432 (internal) | Storage backend for FerretDB |

Periphery uses a custom image (`Dockerfile.periphery`) that adds the `bws` CLI
for pre_deploy secret injection.

### Other (not in Compose)

| Service | Port | Purpose |
|---------|------|---------|
| Ollama | 11434 | LLM inference (native macOS, Metal GPU) |
| BlueBubbles | 1234 | iMessage proxy (native macOS app) |

## Setup

Run the Ansible playbook:

```bash
ansible-playbook -i inventory/inventory.ini playbooks/infrastructure/setup-macmini.yml \
  --extra-vars "bws_access_token=<YOUR_BWS_TOKEN>"
```

The playbook handles: Homebrew, OrbStack, Ollama, system config, secrets,
Komodo + GitOps bootstrap, Tailscale, BlueBubbles install.

### Manual steps after playbook

- **Tailscale**: `ssh mini && tailscale up --accept-routes --ssh` (one-time auth)
- **Auto-login**: System Settings > Users & Groups > Automatic Login
- **BlueBubbles**: Requires GUI setup (Full Disk Access, SIP disable, server password, iMessage sign-in)

## GitOps Flow

### Architecture

```
GitHub push → pubhooks.amer.dev (k3s Traefik proxy) → Komodo Core (Mac Mini:9120)
                                                        ├─ /sync/.../sync    → ResourceSync executes
                                                        ├─ /stack/.../deploy → services stack deploys
                                                        └─ /stack/.../deploy → runners stack deploys
```

### How it works

1. Push to `amerenda/mac-mini-compose` on `main`
2. Three GitHub webhooks fire simultaneously:
   - **ResourceSync webhook** (`/listener/github/sync/mac-mini-compose/sync`) — tells Komodo to re-read `resource-sync/stacks.toml` and update stack definitions
   - **Services stack deploy** (`/listener/github/stack/<id>/deploy`) — triggers `docker compose up` for the services stack
   - **Runners stack deploy** (`/listener/github/stack/<id>/deploy`) — triggers `docker compose up` for the runners stack
3. Each stack's `pre_deploy` script runs first, fetching secrets from BWS via `bws` CLI
4. Komodo runs `docker compose up -d` with the updated compose files

### Webhook configuration

All webhooks are configured on the GitHub repo (`amerenda/mac-mini-compose`
Settings > Webhooks) and proxy through `pubhooks.amer.dev` (a k3s Traefik
IngressRoute that forwards `/listener/github/*` to the Mac Mini's Komodo Core).

| Webhook | GitHub Hook ID | Endpoint | Purpose |
|---------|---------------|----------|---------|
| ResourceSync | `606876027` | `.../sync/mac-mini-compose/sync` | Sync stack definitions from TOML |
| Services deploy | `605400567` | `.../stack/69c4863a9781f84b58ffd7a6/deploy` | Deploy services stack |
| Runners deploy | `606895878` | `.../stack/69c4863a9781f84b58ffd7a8/deploy` | Deploy runners stack |

All webhooks use the `komodo-dean-webhook-secret` from BWS as the HMAC secret.

### Known issue: ResourceSync webhook does not auto-execute

As of Komodo v2.1.2, the ResourceSync `/sync` webhook authenticates successfully
but does not trigger a `RunSync` execution. This appears to be a Komodo bug
(see [moghtech/komodo#1120](https://github.com/moghtech/komodo/issues/1120)).
The stack deploy webhooks work independently, so deployments still trigger on push.
ResourceSync still runs on the 5-minute poll interval (`KOMODO_RESOURCE_POLL_INTERVAL=5-min`)
as a fallback.

### Fallback: 5-minute polling

Komodo Core polls the git repo every 5 minutes regardless of webhooks. If a
webhook fails or is missed, the sync will still happen within 5 minutes.

### Resource sync files

| File | Purpose |
|------|---------|
| `resource-sync/sync.toml` | Defines the ResourceSync resource itself (repo, branch, resource path) |
| `resource-sync/stacks.toml` | Defines the two stacks (services + runners) with pre_deploy scripts |

Stack definitions: `resource-sync/stacks.toml`
Sync definition: `resource-sync/sync.toml`

## Komodo Administration

### Upgrading Komodo

1. Update `COMPOSE_KOMODO_IMAGE_TAG` in `komodo/compose.env`
2. Update the base image tag in `komodo/Dockerfile.periphery`
3. On the Mac Mini: `cd ~/mac-mini-compose/komodo && docker compose --env-file compose.env build periphery && docker compose --env-file compose.env up -d`

Note: The Komodo stack is self-managed (has `komodo.skip` labels) — it does NOT
auto-deploy via webhooks. You must restart it manually or via SSH after changing
the compose.env or Dockerfile.

### Manually triggering a sync

If the ResourceSync shows "Pending" in the Komodo UI and the Execute button is
unavailable, use the API:

```bash
ssh mini
export PATH="$HOME/.orbstack/bin:$PATH"
ADMIN_PASS=$(cat ~/mac-mini-compose/komodo/secrets/komodo-dean-admin-password)
JWT=$(curl -sf http://localhost:9120/auth/login/LoginLocalUser \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | jq -r ".data.jwt")
curl -sf http://localhost:9120/execute/RunSync \
  -H "Content-Type: application/json" \
  -H "Authorization: $JWT" \
  -d '{"sync":"mac-mini-compose"}'
```

## Secrets

**Bitwarden Secrets Manager (BWS) is the single source of truth for all secrets.**
No secrets in git, no secrets in GitHub repo/org settings, no manually managed files.

### How secrets flow

```
BWS → inject-secrets.sh → files on disk → Docker containers read at startup
                        → Komodo API (git provider PAT)
```

Three triggers refresh secrets:

| Trigger | Mechanism | When |
|---------|-----------|------|
| **Boot** | LaunchDaemon runs `scripts/inject-secrets.sh` | Every macOS boot, before OrbStack starts |
| **Ansible** | Playbook runs `scripts/inject-secrets.sh` | On playbook run (`mini-secrets` tag) |
| **Komodo deploy** | `stacks.toml` `pre_deploy` fetches from BWS | On stack deploy/sync via Komodo |

All three paths write to the same locations. The script is idempotent.

### Secret locations on disk

| Path | Contents | Used by |
|------|----------|---------|
| `/Users/alex/.bws-secret` | BWS access token (bootstrapped by Ansible) | inject-secrets.sh, Komodo periphery |
| `/etc/komodo/runner-secrets/` | GitHub App keys, DockerHub token, GitOps PAT | Runner containers (mounted as `/run/secrets`) |
| `komodo/secrets/` | DB password, passkey, JWT secret, webhook secret, admin password | Komodo Core (via `_FILE` pattern) |
| `komodo/compose.env` | Injected DB password, admin password, passkey | Komodo Compose (plaintext, required by Postgres/FerretDB) |
| `.env` | Service passwords (Pihole, Postgres, MongoDB, backups) | Services Compose |
| `bind9/keys/key.conf` | BIND9 TSIG key | BIND9 container |
| Komodo database | Git provider PAT | Komodo Core (updated via API by inject-secrets.sh) |

Generated files (not in git, created by inject-secrets.sh):
- `runners/compose.env` — non-secret runner config
- `komodo/secrets/*` — Komodo secret files
- `.env` — service passwords
- `bind9/keys/key.conf` — TSIG key

### Rotating a secret

1. Update the secret in BWS
2. Run `sudo bash scripts/inject-secrets.sh` on the Mac Mini (or re-run the Ansible playbook, or reboot)
3. Restart the affected service

The script also updates Komodo's git provider PAT via the Komodo API, so no
separate step is needed for that.

BWS secret IDs are defined in `ansible-playbooks/group_vars/macmini_hosts.yml`.

### Rules

- **NEVER** commit secrets to git
- **NEVER** set GitHub repo/org secrets — all CI secrets come from BWS via runner secret files
- **NEVER** manually create or edit secret files on disk — use BWS + inject-secrets.sh
- `compose.env` files in git contain non-secret config only; secret values are injected by the script

## Directory Structure

```
.
├── docker-compose.yaml          # Services stack (HA, Technitium, Postgres, MongoDB, etc.)
├── homeassistant/               # HA configuration (gitops-managed)
│   ├── configuration/           # Mounted read-only into HA container
│   └── scripts/                 # Setup/migration scripts
├── komodo/                      # Komodo stack (self-managed, not auto-deployed)
│   ├── compose.yaml             # Core + Periphery + FerretDB + Postgres
│   ├── compose.env              # Config (secrets injected by script)
│   ├── Dockerfile.periphery     # Periphery v2.1.2 + bws CLI
│   └── secrets/                 # (gitignored) secret files on disk
├── runners/                     # GitHub Actions runners stack
│   ├── compose.yaml             # 5 repo-scoped runners
│   ├── compose.env.example      # Template for non-secret config
│   └── entrypoint-wrapper.sh    # Reads secrets from /run/secrets into env
├── resource-sync/               # Komodo GitOps definitions
│   ├── stacks.toml              # Stack definitions + pre_deploy scripts
│   └── sync.toml                # ResourceSync self-definition
├── scripts/
│   ├── inject-secrets.sh        # BWS → disk + Komodo API (boot, ansible, manual)
│   ├── sync-stacks.sh           # Host-side git sync (OrbStack VirtFS workaround)
│   ├── backup.sh                # Backup HA, pihole, bind9 data
│   ├── healthcheck.sh           # Verify services are running
│   └── dns-udp-proxy.py         # UDP DNS proxy with EDNS Client Subnet
├── launchd/
│   ├── com.local.inject-secrets.plist          # Boot-time secret injection
│   ├── com.local.komodo-stack-sync.plist       # Host-side git sync (every 60s)
│   ├── com.local.pf-dns-redirect.plist         # pf DNS redirect for Technitium
│   └── com.local.dns-udp-proxy.plist           # UDP DNS proxy daemon
├── zigbee2mqtt/                 # Zigbee2MQTT config + smart-lighting extension
├── mosquitto/                   # MQTT broker config
├── bind9/                       # BIND9 config + zone files (disabled)
├── pihole/                      # Pihole config (disabled)
├── mongo/                       # MongoDB init scripts
├── postgres/                    # Postgres init scripts (todo, agent_kb databases)
└── whisper/                     # Whisper model cache
```

## Zigbee (Zigbee2MQTT)

Zigbee2MQTT connects to the SMLIGHT coordinator on the local network. The
smart-lighting Z2M extension (`zigbee2mqtt/external_extensions/smart-lighting.js`)
manages scene storage and wall switch behavior.

## Known Issues

### OrbStack host networking broken after reboot (v2.0.5)

OrbStack's `network_mode: host` does not correctly bridge containers to the
LAN after a macOS reboot. Containers can reach the host but not other LAN
devices (e.g., Hue Bridge, cameras). This breaks Home Assistant device
integrations.

**Workaround:** A LaunchAgent (`com.local.orbstack-lan-fix`) is installed by
the Ansible playbook. It waits for OrbStack to start, tests LAN connectivity
from a container, and restarts OrbStack if broken. No-op if networking is
already working.

### OrbStack VirtFS directory cache staleness

OrbStack's VirtFS does not reliably propagate new directory entries created by
`git pull` inside containers to the host (and vice versa). This can cause
Komodo Periphery's git operations to fail silently.

**Workaround:** A LaunchAgent (`com.local.komodo-stack-sync.plist`) runs
`scripts/sync-stacks.sh` every 60 seconds on the host. It does `git fetch &&
reset --hard` on the local checkout and restarts Periphery if the directory
structure changed.

### Komodo ResourceSync webhook does not auto-execute

The ResourceSync `/sync` webhook endpoint authenticates but does not trigger
execution. This is tracked upstream at
[moghtech/komodo#1120](https://github.com/moghtech/komodo/issues/1120).
Stack deploy webhooks work correctly. ResourceSync falls back to 5-minute polling.

## Health Check

```bash
./scripts/healthcheck.sh
```

## Backups

```bash
./scripts/backup.sh
# Or via cron:
# 0 3 * * * /Users/alex/mac-mini-compose/scripts/backup.sh
```
