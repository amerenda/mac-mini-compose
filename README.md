# komodo-dean-gitops

GitOps repository for [Komodo](https://komo.do/)-managed Docker Compose stacks
across Alex's home lab. Komodo Core runs on the Mac Mini M4; one Periphery
agent per host pulls compose files from this repo and deploys them.

ArgoCD lives in a sibling repo
([`k3s-dean-gitops`](https://github.com/amerenda/k3s-dean-gitops)) — k3s
manifests do **not** live here.

## Layout

```
komodo-dean-gitops/
├── resource-sync/             Komodo ResourceSync TOML (single source of truth)
│   ├── sync.toml              ResourceSync self-definition
│   └── stacks.toml            All [[server]] and [[stack]] resources
│
├── mac-mini-m4/               Stacks deployed to the Mac Mini M4 Periphery
│   ├── core/                  Technitium DNS, Postgres, MongoDB, backups
│   ├── automation/            Home Assistant, Whisper, Piper, OWW, MQTT, Z2M
│   ├── monitoring/            Prometheus, Grafana, exporters
│   ├── runners/               GitHub Actions self-hosted runners
│   ├── llm/                   llm-manager agent (talks to native Metal Ollama)
│   ├── komodo/                Komodo Core + Periphery (self-managed)
│   ├── homeassistant/         HA configuration (bind-mounted into automation)
│   ├── postgres/, mongo/, …   DB init; mosquitto/, zigbee2mqtt/, ollama/, whisper/, pihole/, bind9/ (legacy config dirs, active services in their respective stacks)
│   ├── launchd/               macOS LaunchDaemons / LaunchAgents
│   ├── scripts/               Boot, secret injection, sync, backup
│   └── README.md              Full Mac Mini docs
│
├── murderbot/                 Stacks deployed to the murderbot (Debian) Periphery
│   ├── README.md              Host overview + Periphery setup
│   ├── llm/                   llm-manager agent (native Ollama)
│   └── media-server/          Jellyfin + servarr + nginx/certbot + DO dyndns
│
└── archlinux/                 Stacks deployed to the Arch Linux Periphery
    ├── README.md              Host overview
    ├── scripts/               Host helpers (e.g. native Ollama bind)
    └── llm/                   llm-manager agent (native Ollama)
```

## Architecture

```
GitHub push (amerenda/komodo-dean-gitops)
   │
   ▼
pubhooks.amer.dev  (k3s Traefik proxy → Komodo Core)
   │
   ▼
Komodo Core  (mac-mini-m4 :9120)
   │
   ├──► Periphery on mac-mini-m4   ──► mac-mini-m4/{core,automation,monitoring,runners,llm}
   ├──► Periphery on murderbot     ──► murderbot/{llm, media-server, …}
   └──► Periphery on archlinux     ──► archlinux/{llm, …}
```

Secrets flow:

```
Bitwarden Secrets Manager
   │  (per-host machine account, BWS access token at /etc/komodo/secrets/bws-access-token)
   ▼
stack pre_deploy  →  <stack>/.env / runner-secrets / ha-token / …
   │
   ▼
docker compose up -d
```

For each host `llm` stack, Ollama settings follow a UI-wins precedence contract:

1. `ollama.env` carries GitOps defaults.
2. `ollama.ui.env` carries UI-managed overrides and is loaded after defaults.
3. `pre-deploy.sh` merges path overrides (`OLLAMA_DATA_HOST_PATH`, `OLLAMA_MODELS_HOST_PATH`) into stack `.env` so compose interpolation preserves UI choices across redeploys.

## Hosts

| Host | Role | OS | IP | Komodo |
|------|------|----|----|--------|
| `mac-mini-m4` | Core home services + Komodo Core | macOS (OrbStack) | 10.100.20.18 | Core + Periphery |
| `murderbot` | Media + GPU | Debian | 10.100.20.19 | Periphery only |
| `archlinux` | Workstation / GPU | Arch Linux | 10.100.20.25 | Periphery only |

Each host's bootstrap (Docker, Periphery, BWS access token, host directories)
is handled by [`amerenda/ansible-playbooks`](https://github.com/amerenda/ansible-playbooks):

- Mac Mini: `playbooks/infrastructure/setup-macmini.yml`
- murderbot (Debian): `playbooks/infrastructure/setup-debian-komodo.yml`
- archlinux: `playbooks/infrastructure/setup-archlinux-komodo.yml`

## Adding a new stack

1. Create `<host>/<stack>/compose.yaml` with the service definitions.
2. **Every container image MUST be pinned to a specific semver version tag.** Never use `:latest`. Use simple X.Y.Z tags (not commit hashes or digests). Document current versions in that stack's CLAUDE.md file.
3. If secrets are required, add a `<host>/<stack>/pre-deploy.sh` that pulls
   from BWS and writes a `.env` next to the compose (mirror the patterns under
   [`mac-mini-m4/core/`](mac-mini-m4/core/) or [`murderbot/media-server/`](murderbot/media-server/)).
4. Add a `[[stack]]` block to [`resource-sync/stacks.toml`](resource-sync/stacks.toml)
   with `server`, `repo`, `file_paths`, `branch`, and `pre_deploy.command`.
5. Push your branch (or `main` after merge). The ResourceSync webhook (or poll)
   registers the stack in Komodo. Then add a per-stack deploy webhook in GitHub
   (`/listener/github/stack/<stack-uuid>/deploy`) so future pushes deploy that
   stack without touching others.

## Adding a new host

1. Bootstrap Docker + bws CLI + Komodo Periphery on the host (Ansible).
2. Add a new BWS machine account scoped to the same project, drop its access
   token at `/etc/komodo/secrets/bws-access-token` on the host.
3. Add a `[[server]]` block to [`resource-sync/stacks.toml`](resource-sync/stacks.toml).
4. Create `<host>/` at the repo root and start adding stacks there.

## Secrets

Bitwarden Secrets Manager is the **only** source of truth — no secrets in git,
no GitHub repo/org secrets, no manually managed files. See
[`mac-mini-m4/README.md`](mac-mini-m4/README.md#secrets) for the per-host flow
and rotation steps.

## GitOps Policy

Operational rules for this repository live in
[`GITOPS_POLICY.md`](GITOPS_POLICY.md). In short: BWS-only secrets, zero manual
drift, and every fix must be codified in Ansible and/or repo config so a new
host converges without one-off commands.

## Per-host docs

- [mac-mini-m4/README.md](mac-mini-m4/README.md) — Mac Mini stacks (full operational guide)
- [murderbot/README.md](murderbot/README.md) — murderbot Periphery setup (Debian)

## Git: remote URL, typo trap, and safe updates

**Correct GitHub repo:** `amerenda/komodo-dean-gitops` (spelled **komodo** with
two `o`s — not `komdo-dean-gitops`). A typo in `origin` makes `git pull` fail
with keychain errors and a username prompt on HTTPS.

```bash
git remote -v
# should show:
#   git@github.com:amerenda/komodo-dean-gitops.git
# or:
#   https://github.com/amerenda/komodo-dean-gitops.git
```

**Do not** run `git checkout -B main origin/main` (or `git reset --hard
origin/main`) while you still have **uncommitted** migration work, unless
GitHub `main` already contains that layout. `origin/main` is still the old
flat tree until the migration commit is **pushed**; resetting to it makes Git
try to delete `mac-mini-m4/` and bring back root-level paths — your working
tree will look “destroyed”.

**Safe flow:** commit (or stash) on a branch → push or open a PR → merge on
GitHub → then `git pull` on the Mac Mini.

**Recovery after a bad checkout:** find where you were before:

```bash
git reflog
# pick the line before the checkout/reset, e.g. abc1234 HEAD@{2}: commit: ...
git checkout -B recovery-branch abc1234
# or: git reset --hard abc1234   (only if you mean to discard later changes)
```

Then fix `git remote` if needed and either commit your migration and push, or
`git stash` / cherry-pick as appropriate.

## Pointing Komodo at a non-`main` branch

Each stack's [`resource-sync/sync.toml`](resource-sync/sync.toml) and every
`[[stack]]` in [`resource-sync/stacks.toml`](resource-sync/stacks.toml) carry a
`branch = "..."` field. Komodo uses that branch when it clones compose sources.

**Testing on a feature branch:**

1. Push the branch; merge to `main` only when ready for production pulls to follow `main`.
2. In **Komodo UI → Resources → Syncs**, open the `komodo-dean-gitops` sync resource and set **Branch** to your feature branch, then save and run **Sync**.
3. Confirm stacks deploy cleanly on each Periphery.

**Production:** all branches are `main`. After editing them, push to `main` and run **Sync** (or rely on the webhook). If you pointed the ResourceSync at a feature branch in Komodo UI, set **Branch** back to `main`.
