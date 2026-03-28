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
| Whisper | bridge | 10300 | Speech-to-text (Wyoming protocol) |
| Piper | bridge | 10200 | Text-to-speech (Wyoming protocol) |
| OpenWakeWord | bridge | 10400 | Wake word detection |
| Node Exporter | bridge | 9100 | Host metrics for Prometheus |
| HACS init | — | — | One-shot: installs HACS into HA config volume |

BIND9 and Pihole are defined but disabled (commented out) — not yet migrated.

### Runners stack (`runners/compose.yaml`)

| Service | Purpose |
|---------|---------|
| runner-k3s-runners | GitHub Actions runner for k3s-runners repo |
| runner-ecdysis | GitHub Actions runner for ecdysis repo |
| runner-llm-manager | GitHub Actions runner for llm-manager repo |
| runner-llm-agents | GitHub Actions runner for llm-agents repo |

### Komodo stack (`komodo/compose.yaml`)

| Service | Port | Purpose |
|---------|------|---------|
| Komodo Core | 9120 | GitOps UI and API |
| Komodo Periphery | 8120 (internal) | Agent for managing Docker on the host |
| FerretDB | 27017 (internal) | MongoDB-compatible database for Komodo |
| Postgres (DocumentDB) | 5432 (internal) | Storage backend for FerretDB |

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

```
Push to main → Komodo polls (5 min) → ResourceSync updates stacks
→ pre_deploy fetches secrets from BWS → docker compose up
```

1. Komodo Core polls `amerenda/mac-mini-compose` on `main` every 5 minutes (`KOMODO_RESOURCE_POLL_INTERVAL=5-min`)
2. ResourceSync reads `resource-sync/stacks.toml` which defines the services and runners stacks
3. Each stack has a `pre_deploy` script that fetches secrets from BWS via the `bws` CLI (installed in the periphery container)
4. Stacks with `deploy = true` auto-deploy after sync

Stack definitions: `resource-sync/stacks.toml`
Sync definition: `resource-sync/sync.toml`

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
| `.env` | Pihole admin password | Services Compose |
| `bind9/keys/key.conf` | BIND9 TSIG key | BIND9 container |
| Komodo database | Git provider PAT | Komodo Core (updated via API by inject-secrets.sh) |

Generated files (not in git, created by inject-secrets.sh):
- `runners/compose.env` — non-secret runner config
- `komodo/secrets/*` — Komodo secret files
- `.env` — pihole password
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
├── docker-compose.yaml          # Services stack (HA, whisper, piper, node-exporter)
├── homeassistant/               # HA configuration (gitops-managed)
│   ├── configuration/           # Mounted read-only into HA container
│   └── scripts/                 # Setup/migration scripts
├── komodo/                      # Komodo stack
│   ├── compose.yaml             # Core + Periphery + FerretDB + Postgres
│   ├── compose.env              # Config (secrets injected by script)
│   ├── Dockerfile.periphery     # Periphery + bws CLI
│   └── secrets/                 # (gitignored) secret files on disk
├── runners/                     # GitHub Actions runners stack
│   ├── compose.yaml             # 4 repo-scoped runners
│   ├── compose.env.example      # Template for non-secret config
│   └── entrypoint-wrapper.sh    # Reads secrets from /run/secrets into env
├── resource-sync/               # Komodo GitOps definitions
│   ├── stacks.toml              # Stack definitions + pre_deploy scripts
│   └── sync.toml                # ResourceSync self-definition
├── scripts/
│   ├── inject-secrets.sh        # BWS → disk + Komodo API (boot, ansible, manual)
│   ├── backup.sh                # Backup HA, pihole, bind9 data
│   ├── healthcheck.sh           # Verify services are running
│   └── migrate-ha-data.sh       # One-time HA data migration from k3s
├── launchd/
│   └── com.local.inject-secrets.plist  # Boot-time secret injection daemon
├── bind9/                       # BIND9 config + zone files (disabled)
├── pihole/                      # Pihole config (disabled)
└── whisper/                     # Whisper model cache
```

## Zigbee (ser2net)

The Zigbee USB stick stays on rpi5-1. Install ser2net there:

```bash
sudo apt install ser2net
# /etc/ser2net.yaml:
# connection: &zigbee
#   accepter: tcp,3333
#   connector: serialdev,/dev/ttyUSB0,115200n81,local
#   options:
#     kickolduser: true
sudo systemctl enable --now ser2net
```

In Home Assistant ZHA integration, use: `socket://rpi5-1.amer.home:3333`

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

**Affected version:** OrbStack 2.0.5 (2000500). Remove the workaround if a
future OrbStack update fixes this.

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
