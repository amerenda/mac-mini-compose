# media-server stack

Komodo-managed Docker Compose stack on murderbot (Debian Periphery host).

## Version pinning — REQUIRED

All container images MUST be pinned to a specific version tag. **Never use `:latest`.**

Rules for agents/editors working with this repo:

1. Always pin images to the latest stable semver release tag (e.g. `4.0.17`, not a commit hash or digest)
2. For linuxserver images, use the simple X.Y.Z tag (not the `-lsN` build suffix unless needed for compatibility)
3. For GitHub container registry images, include the `v` prefix if that's how releases are tagged (e.g. `v3.2.0`)
4. Do NOT pin to commit SHA digests or image digests — use human-readable version numbers only
5. When bumping versions: verify the new tag exists on Docker Hub/ghcr.io, check changelogs for breaking changes, then update the compose.yaml and pre-deploy.sh if env vars changed

### Current pinned versions

| Service | Image | Pinned Version | Notes |
|---------|-------|----------------|-------|
| profilarr | `santiagosayshey/profilarr` | `v1.1.4` | Latest stable release |
| prowlarr | `linuxserver/prowlarr` | `2.3.5` | linuxserver tag (no `-lsN`) |
| sabnzbd | `lscr.io/linuxserver/sabnzbd` | `5.0.3` | linuxserver tag |
| radarr | `lscr.io/linuxserver/radarr` | `6.1.1` | linuxserver tag |
| sonarr | `linuxserver/sonarr` | `4.0.17` | Sonarr V4 — no custom script hooks |
| bazarr | `linuxserver/bazarr` | `1.5.6` | linuxserver tag |
| jellyfin | `linuxserver/jellyfin` | `10.11.8` | Pinned since stack creation |
| seerr | `ghcr.io/seerr-team/seerr` | `v3.2.0` | GitHub release tag |
| recyclarr | `ghcr.io/recyclarr/recyclarr` | `7` | Major version only (stable v7 API) |
