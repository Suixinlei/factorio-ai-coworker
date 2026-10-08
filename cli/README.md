# Factorio AI Coworker CLI

This is a one-shot CLI for the Factorio AI Coworker project. The Factorio mod remains compatible with the `ai-coworker` distribution name. It re-reads
RCON settings for every command, so changing `FACTORIO_RCON_HOST`,
`FACTORIO_RCON_PORT`, `FACTORIO_RCON_PASSWORD`, or `cli/.env` does not
require restarting the client application.

Run from the repository root:

```bash
.venv/bin/python -m cli status
.venv/bin/python -m cli catalog
.venv/bin/python -m cli session list
.venv/bin/python -m cli --agent-id my-builder state
.venv/bin/python -m cli --agent-id my-builder map --width 32 --height 32
.venv/bin/python -m cli --agent-id my-builder query get_recipe --params '{"name":"iron-gear-wheel"}'
.venv/bin/python -m cli --agent-id my-builder step '[{"action":"batch_mine","item":"iron-ore","count":20}]'
```

The CLI prints machine-readable JSON. Use `--pretty` for human-readable
output. `session bind` creates or re-binds a named role; because each command
is independent, pass `--agent-id` (or set `FACTORIO_AGENT_ID`) on later calls.

Use `step --dry-run` to validate a bounded sequence without contacting the
game. `step --file actions.json` accepts a JSON array or `{"steps":[...]}`.
For large batch payloads, put the payload in a separate JSON file and reference
it from a step with `"file":"blueprint.json"`; entity arrays are automatically
split into 500-entry `batch_create_ghost`/`batch_build_ghost` requests, while an
array used by `batch_mine` is treated as `areas`.
