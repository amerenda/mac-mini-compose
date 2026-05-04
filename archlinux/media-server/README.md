# archlinux/media-server

Komodo-managed Docker Compose stack: Jellyfin, the *arr ecosystem (radarr,
sonarr, bazarr, prowlarr, whisparr, profilarr), sabnzbd, plus a small
nginx/certbot reverse proxy and a DigitalOcean dyndns updater.

Replaces the standalone [`amerenda/media-server`](https://github.com/amerenda/media-server)
repo. Deploys via Komodo Periphery on the archlinux host.

## Services

| Service | Port | Image | Purpose |
|---------|------|-------|---------|
| `jellyfin` | 8096, 8920, 7359/udp | `linuxserver/jellyfin:10.11.4` | Streaming server (HW transcode via `/dev/dri`) |
| `radarr` | 7878 | `lscr.io/linuxserver/radarr` | Movies |
| `sonarr` | 8989 | `linuxserver/sonarr` | TV |
| `bazarr` | 6767 | `linuxserver/bazarr` | Subtitles |
| `prowlarr` | 9696 | `linuxserver/prowlarr` | Indexer manager |
| `whisparr` | 6969 | `ghcr.io/hotio/whisparr:v3` | Adult media |
| `profilarr` | 6868 | `santiagosayshey/profilarr` | Custom format profiles |
| `sabnzbd` | 8080 | `lscr.io/linuxserver/sabnzbd` | Usenet downloader |
| `nginx` | 443 | built (`./nginx`) | TLS termination for `media.amer.dev` |
| `certbot` | 80 | built (`./certbot`) | Let's Encrypt standalone, 12 h renewal loop |
| `dns` | — | built (`./dns`) | Updates DigitalOcean A record `media.amer.dev` to current external IP every 30 min |

`whisparr` and `bazarr` deliberately bind `${WHISPARR_FOLDER}` /
`${BAZARR_CONFIG}` to host paths owned `1000:1000`; the linuxserver / hotio
images run as `PUID=1000 PGID=1000`.

## Volumes

All bind-mount roots are pre-created by
[`setup-archlinux-komodo.yml`](https://github.com/amerenda/ansible-playbooks/blob/main/playbooks/infrastructure/setup-archlinux-komodo.yml)
with owner `1000:1000`:

- `/opt/media/<service>/config` — small per-app config volumes
- `/mnt/storage/{movies,tv,books,downloads/{complete,incomplete},cache/transcode}` — large library volumes (assumes `/mnt/storage` is mounted out of band)

## Deployment

Stack registered in [`../../resource-sync/stacks.toml`](../../resource-sync/stacks.toml)
as `media-server` on the `archlinux` server. Komodo runs `pre-deploy.sh`
(reads BWS for `DO_API_TOKEN` and writes `.env`), then `docker compose up -d
--build` from this directory.

```bash
# Manual local deploy from this directory (debugging only):
docker compose --env-file .env up -d --build
```

## Secrets

| Secret | Source | Used by |
|--------|--------|---------|
| `DO_API_TOKEN` | BWS (`media-server-do-api-token`) | `dns` service (`./dns/main.py`) |
| BWS access token | `/etc/komodo/.bws-secret` (root, mode 0600) | Periphery container at deploy time |

**Rotation note:** the legacy `amerenda/media-server` repo's `.env` contains
a leaked DigitalOcean API token. Rotate it in the DigitalOcean console
before populating `media-server-do-api-token` in BWS, and replace
`BWS_DO_API_TOKEN_UUID` in [`pre-deploy.sh`](pre-deploy.sh) with the new UUID.

## Initial setup checklist

1. Bootstrap the host: run
   `playbooks/infrastructure/setup-archlinux-komodo.yml` from
   [ansible-playbooks](https://github.com/amerenda/ansible-playbooks) (this
   installs Docker, Periphery, bws CLI, and pre-creates volume dirs).
2. Confirm `/mnt/storage` is a real mountpoint (the playbook only warns).
3. Point `media.amer.dev` at the host's external IP at the registrar/DO so
   certbot's first run can solve the HTTP-01 challenge on port 80.
4. Open ports 80/443 (and 8096/8920/7359 if you want direct Jellyfin) on the
   home router.
5. Push to `amerenda/komodo-dean-gitops` `main` (this folder + the new
   `[[stack]]` block in `resource-sync/stacks.toml`). The next ResourceSync
   creates the stack in Komodo; click *Deploy* (or wait for the deploy
   webhook once it's wired up).
6. After the first successful deploy, verify each service is healthy:
   `docker compose ps` on the host, then visit `https://media.amer.dev`
   for Jellyfin and the per-app ports for the *arr suite.

## Known prerequisites / gotchas

- **Port 80 must be free at renewal time.** Certbot uses standalone HTTP-01,
  which means the certbot container binds 80 every 12 h. If anything else on
  archlinux listens on 80, renewals will quietly fail.
- **`/mnt/storage` mount.** The Ansible playbook does not format or fstab
  the disk; do that out of band (parted / mkfs.ext4 / fstab / `systemctl
  daemon-reload && mount -a`).
- **HW transcode.** Jellyfin mounts `/dev/dri:/dev/dri`. If the archlinux
  host has no GPU exposed (or no Intel/AMD VAAPI driver), drop the `devices`
  block from `compose.yaml` or transcoding will fail.
