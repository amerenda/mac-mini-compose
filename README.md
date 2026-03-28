# Mac Mini Compose — Core Home Lab Services

Docker Compose stack for the Mac Mini M4, running core services migrated from k3s.

## Services

| Service | IP | Port | Purpose |
|---------|-----|------|---------|
| BIND9 | 10.100.20.18 | 53 | Authoritative DNS (primary) for amer.home |
| Pihole | 10.100.20.19 | 53, 80 | Ad-blocking DNS resolver |
| Cloudflared | (internal) | 5053 | DNS-over-HTTPS upstream for Pihole |
| Home Assistant | (host net) | 8123 | Smart home hub |
| Whisper | 0.0.0.0 | 10300 | Speech-to-text (Wyoming protocol) |
| Node Exporter | 0.0.0.0 | 9100 | Host metrics for Prometheus |
| Pihole Exporter | 0.0.0.0 | 9617 | Pihole metrics for Prometheus |

## Setup

1. Copy `.env.example` to `.env` and fill in secrets from Bitwarden
2. Place TSIG key in `bind9/keys/key.conf` (format in `.env.example`)
3. Add secondary IP for Pihole: `sudo ifconfig en0 alias 10.100.20.19 255.255.255.0`
4. Start services: `docker compose up -d`

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

## First-time Home Assistant Setup

```bash
# 1. Start HA to create the volume
docker compose up -d homeassistant
docker compose stop homeassistant

# 2. Run setup script inside the container
docker compose run --rm homeassistant /bin/sh /path/to/setup-config.sh

# 3. Import data from k3s (run migrate-ha-data.sh on murderbot first)
docker cp /path/to/ha-export/. homeassistant:/config/

# 4. Start HA
docker compose start homeassistant
```

## Known Issues

### OrbStack host networking broken after reboot (v2.0.5)

OrbStack's `network_mode: host` does not correctly bridge containers to the LAN after a macOS reboot. Containers can reach the host but not other LAN devices (e.g., Hue Bridge, cameras). This breaks Home Assistant device integrations.

**Workaround:** A LaunchAgent (`com.local.orbstack-lan-fix`) is installed by the Ansible playbook. It waits for OrbStack to start, tests LAN connectivity from a container, and restarts OrbStack if broken. This is a no-op if networking is already working.

**Affected version:** OrbStack 2.0.5 (2000500). Remove the workaround if a future OrbStack update fixes this.

## Health Check

```bash
./scripts/healthcheck.sh
```

## Backups

```bash
./scripts/backup.sh
# Or via cron:
# 0 3 * * * /path/to/mac-mini-compose/scripts/backup.sh
```
