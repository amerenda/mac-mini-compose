# murderbot/media-server

Komodo-managed Docker Compose stack: Jellyfin, the *arr ecosystem (radarr,
sonarr, bazarr, prowlarr, profilarr), and sabnzbd.

TLS/ingress is handled by k3s Traefik + cert-manager (see
`k3s-dean-gitops/infra/ingresses/jellyfin-ingress-amer-dev.yaml`), so this
stack no longer runs local nginx/certbot/dns sidecars.

Replaces the standalone [`amerenda/media-server`](https://github.com/amerenda/media-server)
repo. Deploys via Komodo Periphery on the **murderbot** host.

## Services

| Service | Port | Image | Purpose |
|---------|------|-------|---------|
| `jellyfin` | 8096, 8920, 7359/udp | `linuxserver/jellyfin:10.11.4` | Streaming server (HW transcode via `/dev/dri`) |
| `radarr` | 7878 | `lscr.io/linuxserver/radarr` | Movies |
| `sonarr` | 8989 | `linuxserver/sonarr` | TV |
| `bazarr` | 6767 | `linuxserver/bazarr` | Subtitles |
| `prowlarr` | 9696 | `linuxserver/prowlarr` | Indexer manager |
| `profilarr` | 6868 | `santiagosayshey/profilarr` | Custom format profiles |
| `sabnzbd` | 8081 (host) -> 8080 (container) | `lscr.io/linuxserver/sabnzbd` | Usenet downloader |

`*arr` apps and Jellyfin use host bind mounts under `/mnt/storage/media/config`
(config) and `/mnt/storage` (libraries) owned `1000:1000`; linuxserver images
run as `PUID=1000 PGID=1000`.

## Volumes

All bind-mount roots are pre-created by
[`setup-debian-komodo.yml`](https://github.com/amerenda/ansible-playbooks/blob/main/playbooks/infrastructure/setup-debian-komodo.yml)
with owner `1000:1000`:

- `/mnt/storage/media/config/<service>/config` — small per-app config volumes
- `/mnt/storage/{movies,tv,books,downloads/{complete,incomplete},cache/transcode}` — large library volumes (assumes `/mnt/storage` is mounted out of band)

## Deployment

Stack registered in [`../../resource-sync/stacks.toml`](../../resource-sync/stacks.toml)
as `media-server` on the `murderbot` server. Komodo runs `pre-deploy.sh`
(writes `.env`), then `docker compose up -d
--build` from this directory. The Compose **project name** is `media-server`
(top-level `name` in [`compose.yaml`](compose.yaml)); on the host, `docker compose ls`
should list that project when the stack is running.

```bash
# Manual local deploy from this directory (debugging only):
docker compose --env-file .env up -d --build
```

## Secrets

| Secret | Source | Used by |
|--------|--------|---------|
| BWS access token | `/etc/komodo/.bws-secret` (root, mode 0600) | Periphery container at deploy time |

## Initial setup checklist

1. Bootstrap the host: run
   `playbooks/infrastructure/setup-debian-komodo.yml` from
   [ansible-playbooks](https://github.com/amerenda/ansible-playbooks) (this
   installs Docker, Periphery, bws CLI, and pre-creates volume dirs).
2. Confirm `/mnt/storage` is a real mountpoint (the playbook only warns).
3. Ensure k3s Traefik ingress and certificate are configured (see ingress
   manifest noted at the top).
4. Open only the host ports you actually use directly (for example 8096/8920/7359).
5. Push to `amerenda/komodo-dean-gitops` `main` (this folder + the new
   `[[stack]]` block in `resource-sync/stacks.toml`). The next ResourceSync
   creates the stack in Komodo; click *Deploy* (or wait for the deploy
   webhook once it's wired up).
6. After the first successful deploy, verify each service is healthy:
   `docker compose ps` on the host, then visit `https://media.amer.dev`
   for Jellyfin and the per-app ports for the *arr suite.

## Known prerequisites / gotchas

- **`/mnt/storage` mount.** The Ansible playbook does not format or fstab
  the disk; do that out of band (parted / mkfs.ext4 / fstab / `systemctl
  daemon-reload && mount -a`).
- **HW transcode.** Jellyfin mounts `/dev/dri:/dev/dri`. If the murderbot
  host has no GPU exposed (or no Intel/AMD VAAPI driver), drop the `devices`
  block from `compose.yaml` or transcoding will fail.
