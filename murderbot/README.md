# murderbot — Komodo Periphery host (Debian)

Stacks deployed to the **murderbot** home server (`10.100.20.19`) via Komodo
Periphery. Komodo Core lives on the Mac Mini M4 and connects out to this host's
Periphery on `:8120`.

## Stacks

| Stack | Path | Purpose |
|-------|------|---------|
| `media-server` | [`media-server/`](media-server/) | Jellyfin + servarr (radarr/sonarr/bazarr/prowlarr/profilarr) + sabnzbd + nginx/certbot + DigitalOcean dyndns |

## Periphery (self-managed)

[`komodo/`](komodo/) is **not** a Komodo-managed stack — it is deployed by
Ansible (`playbooks/infrastructure/setup-debian-komodo.yml` in the
[ansible-playbooks](https://github.com/amerenda/ansible-playbooks) repo). It
runs the upstream `ghcr.io/moghtech/komodo-periphery` image with the `bws`
CLI baked in (see [`Dockerfile.periphery`](komodo/Dockerfile.periphery)) so
stack `pre_deploy` blocks can fetch secrets from Bitwarden.

## Bootstrap

```bash
# In ansible-playbooks/
ansible-playbook -i inventory/inventory.ini \
  playbooks/infrastructure/setup-debian-komodo.yml \
  --extra-vars "bws_access_token=<YOUR_BWS_TOKEN>"
```

The playbook:

1. Installs Docker + jq + git (apt) and adds the login user to the `docker` group.
2. Installs the `bws` CLI on the host and writes the BWS access token to
   `/etc/komodo/.bws-secret` (mode 0600).
3. Clones [`amerenda/komodo-dean-gitops`](https://github.com/amerenda/komodo-dean-gitops)
   to `~/komodo-dean-gitops`.
4. Renders `murderbot/komodo/compose.env` from `compose.env.example`,
   injecting `PERIPHERY_PASSKEYS` from BWS (`komodo-dean-passkey`).
5. `docker compose --env-file compose.env up -d --build` for Periphery.
   The Compose **project name** is `murderbot-periphery` (top-level `name` in
   [`komodo/compose.yaml`](komodo/compose.yaml)); confirm with `docker compose ls`
   from `~/komodo-dean-gitops/murderbot/komodo`.
6. Pre-creates `/mnt/storage/media/config/{profilarr,radarr,bazarr,sonarr/{config,scripts},prowlarr,sabnzbd,jellyfin}/config`
   and `/mnt/storage/{movies,tv,books,downloads/{complete,incomplete},cache/transcode}`,
   all owned `1000:1000` so the linuxserver.io containers can write.

After Periphery is up, the host is registered in Komodo when `murderbot` appears
in [`resource-sync/stacks.toml`](../resource-sync/stacks.toml) as a `[[server]]`
and ResourceSync runs.

## Prerequisites assumed by the playbook

- `/mnt/storage` is already mounted (the playbook does not format or fstab
  it). Out-of-band setup of the underlying block device is your job.
- Ports `80`, `443`, and `8120` are reachable on the host (no host firewall,
  or holes punched). The `media-server` stack's certbot service requires `80`
  to be free at renewal time.
- LAN reachability from the Mac Mini to `10.100.20.19:8120` for
  Komodo Core → Periphery traffic.

## Secrets

Same model as `mac-mini-m4`: BWS is the single source of truth, `bws` CLI
runs inside the Periphery container at deploy time, and stacks fetch their
secrets in `pre_deploy`. The murderbot host has its own BWS machine account
with read access to the same project as the Mac Mini account.

See per-stack `pre-deploy.sh` files (e.g.
[`media-server/pre-deploy.sh`](media-server/pre-deploy.sh)) for the secret
UUIDs that stack uses.
