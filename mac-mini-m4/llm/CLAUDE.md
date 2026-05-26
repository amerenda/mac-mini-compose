# llm stack

Contains: Ollama, LLM Manager agent.

## Version pinning — DO NOT UPDATE without explicit instruction

| Service | Tag | Notes |
|---------|-----|-------|
| `ollama` | `${OLLAMA_IMAGE_TAG:-0.21.0}` | Env-driven; default pinned to 0.21.0 |
| `llm-manager` | `agent-${AGENT_IMAGE_TAG:-latest}` | CI-managed; latest is intentional |

Do not change the default version in the env variable fallback without explicit instruction.
