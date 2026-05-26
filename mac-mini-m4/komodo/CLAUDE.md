# komodo stack

Contains: Komodo Core, FerretDB, PostgreSQL DocumentDB.

## Version pinning — DO NOT UPDATE without explicit instruction

| Service | Tag | Notes |
|---------|-----|-------|
| `komodo-core` | `${COMPOSE_KOMODO_IMAGE_TAG:-latest}` | Driven by env; "latest" is intentional for Komodo itself |
| `ferretdb` | tag-pinned | Do not bump without testing |
| `postgres-documentdb` | digest-pinned | Do not bump without testing |

Komodo Core uses `latest` by default because Komodo manages its own upgrades.
All other images in this stack are pinned — do not update them without explicit instruction.
