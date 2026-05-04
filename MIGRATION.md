# Migration: mac-mini-compose → komodo-dean-gitops

One-time operator checklist. Delete this file once everything is green.

The repo / file changes are already in place across two repos:

- This repo (renamed): `mac-mini-compose` → `komodo-dean-gitops`, with
  current stacks moved under `mac-mini-m4/` and a new `archlinux/` tree
  containing `komodo/` (Periphery, Ansible-managed) and `media-server/`
  (the new Komodo stack replacing `amerenda/media-server`).
- `ansible-playbooks`: `setup-macmini.yml` re-pointed at the new repo URL
  and path; new `setup-archlinux-komodo.yml` bootstraps Periphery on
  archlinux.

Everything below is **operator action** — none of it is in code.

## 0. Before merging anything

- [ ] In DigitalOcean, **revoke the leaked API token** that lived in the
  legacy `amerenda/media-server` `.env` (never paste tokens into git). Issue
  a new token with the same scope.

## 1. Bitwarden Secrets Manager

- [ ] In the existing `k3s` BWS project, create a new secret
  `media-server-do-api-token` with the new DigitalOcean token from step 0.
- [ ] Note the new secret's UUID and replace the placeholder in:
  - [`archlinux/media-server/pre-deploy.sh`](archlinux/media-server/pre-deploy.sh)
    (`BWS_DO_API_TOKEN_UUID="REPLACE_WITH_NEW_BWS_UUID"`)
  - `ansible-playbooks/group_vars/archlinux_komodo_hosts.yml`
    (`media_server_do_api_token_bws_uuid: "REPLACE_WITH_NEW_BWS_UUID"`)
- [ ] Create a new BWS **machine account** scoped to read the `k3s` project
  for the archlinux host. Save its access token; you'll pass it to the
  Ansible playbook below.
- [ ] (Optional) Reuse the existing `komodo-dean-passkey` BWS secret for the
  archlinux Periphery, or create a new `komodo-dean-passkey-archlinux`
  scoped only to the archlinux machine account. The
  `komodo_periphery_passkey_bws_uuid` in
  `ansible-playbooks/group_vars/archlinux_komodo_hosts.yml` defaults to the
  existing one — change it if you split.

## 2. GitHub repo rename

- [ ] In the GitHub UI, rename `amerenda/mac-mini-compose` to
  `amerenda/komodo-dean-gitops`. GitHub auto-creates a redirect for the
  old URL.
- [ ] Locally:
  ```bash
  cd ~/projects
  mv mac-mini-compose komodo-dean-gitops
  cd komodo-dean-gitops
  git remote set-url origin git@github.com:amerenda/komodo-dean-gitops.git
  ```
- [ ] Open the `rename/komodo-dean-gitops` branch in this repo as PR 1
  ("Rename + restructure under mac-mini-m4/"). Merge once green.

## 3. Mac Mini side (after PR 1 merges)

- [ ] Re-run the Mac Mini Ansible playbook from your control machine:
  ```bash
  cd ~/projects/ansible-playbooks
  ansible-playbook -i inventory/inventory.ini \
    playbooks/infrastructure/setup-macmini.yml \
    --extra-vars "bws_access_token=<YOUR_BWS_TOKEN>"
  ```
  This re-clones into `~/komodo-dean-gitops`, re-installs LaunchDaemons
  with the new paths, and updates the Komodo ResourceSync to
  `name: komodo-dean-gitops`, `repo: amerenda/komodo-dean-gitops`.
- [ ] Verify all five mac-mini stacks redeploy cleanly through the next
  ResourceSync (≤5 min), watching especially `monitoring` (the
  `MONITORING_DIR` change) and `automation` (HA bind mounts walk through
  `../homeassistant/...`).
- [ ] In GitHub > `amerenda/komodo-dean-gitops` > Settings > Webhooks,
  edit the ResourceSync webhook (Hook ID `606876027`) and change its path
  to `/listener/github/sync/komodo-dean-gitops/sync`.
- [ ] (Optional cleanup) On the Mac Mini, delete the old
  `~/mac-mini-compose` directory after confirming
  `~/komodo-dean-gitops/mac-mini-m4/...` is fully populated and Komodo
  Periphery's `/etc/komodo/stacks/<stack>` checkouts have re-synced.

## 4. archlinux Periphery (PR 2)

- [ ] Run the new playbook:
  ```bash
  cd ~/projects/ansible-playbooks
  ansible-playbook -i inventory/inventory.ini \
    playbooks/infrastructure/setup-archlinux-komodo.yml \
    --extra-vars "bws_access_token=<ARCHLINUX_BWS_TOKEN>"
  ```
- [ ] Confirm `https://10.100.20.25:8120` answers
  (`curl -k https://10.100.20.25:8120` from another host).
- [ ] In Komodo UI > Variables, set `KOMODO_PERIPHERY_PASSKEY` to the same
  value stored in `komodo-dean-passkey` (the `[[server]]` block in
  `resource-sync/stacks.toml` references this variable). The next
  ResourceSync will register the `archlinux` server resource and the
  `media-server` stack.
- [ ] In Komodo UI > Servers > `archlinux`, confirm status is healthy
  before the first stack deploy.

## 5. media-server stack (PR 3)

- [ ] Confirm `media.amer.dev` A record points at the archlinux external
  IP (the `dns` container will keep it updated, but the first cert needs
  it correct).
- [ ] Confirm port 80 is open and free on archlinux (certbot uses
  HTTP-01 standalone). Same for 443 if you want public Jellyfin access.
- [ ] Trigger the first `media-server` deploy from Komodo UI. Watch the
  `pre_deploy` step succeed (it'll fail loudly if `BWS_DO_API_TOKEN_UUID`
  is still `REPLACE_WITH_NEW_BWS_UUID`).
- [ ] Verify each container is healthy
  (`docker compose ps` on archlinux), and that
  `https://media.amer.dev` resolves to Jellyfin once cert issuance lands.
- [ ] In GitHub > Webhooks, add a new webhook with the same HMAC secret
  (`komodo-dean-webhook-secret`) and path
  `/listener/github/stack/<media-server-stack-uuid>/deploy`, so future
  pushes that touch `archlinux/**` redeploy media-server only — copy the
  stack UUID from Komodo UI after the first sync.

## 6. Wind down the old repo

- [ ] After at least one full successful deploy AND one certbot renewal
  cycle (≥ 24 h), in GitHub UI archive `amerenda/media-server` (do NOT
  delete — keep history accessible).
- [ ] Delete the local `~/projects/media-server` checkout if you no
  longer need it.

## Rollback

- The `git mv` in PR 1 is content-preserving; reverting the merge restores
  the old layout exactly.
- Periphery on archlinux is a docker-compose service with `komodo.skip`
  labels — `docker compose down` in `archlinux/komodo/` cleanly removes
  it without touching media-server data on `/mnt/storage`.
- The leaked DO token, once rotated in step 0, cannot be unrotated. There
  is no rollback path for that step; do it deliberately.
