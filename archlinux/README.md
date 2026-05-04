# archlinux — Komodo Periphery host

Stacks deployed to the **archlinux** machine (`10.100.20.25`) via Komodo Periphery.

## Stacks

| Stack | Path | Purpose |
|-------|------|---------|
| `llm-archlinux` | [`llm/`](llm/) | llm-manager agent + native Ollama on the host (same pattern as `mac-mini-m4/llm`) |

## Bootstrap

Periphery and BWS token: [`setup-archlinux-komodo.yml`](https://github.com/amerenda/ansible-playbooks/blob/main/playbooks/infrastructure/setup-archlinux-komodo.yml) in **ansible-playbooks** (clone under `~/komodo-dean-gitops`).

For [`llm/`](llm/): install [native Ollama](https://ollama.com) on the host; pre-deploy configures `OLLAMA_HOST=0.0.0.0:11434` via a systemd drop-in so the agent container can use `host.docker.internal:11434`.
