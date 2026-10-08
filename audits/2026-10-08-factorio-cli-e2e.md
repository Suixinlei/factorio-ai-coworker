# Factorio CLI E2E verification (ai-coworker 0.2.0)

Date: 2026-10-08

The top-level `cli/` package and the 0.2.0 mod were exercised against the local
headless Factorio server at `127.0.0.1:27016` using role `test-02`.

## Reproduction

From the repository root:

```bash
PW="$(cat local-server/rcon.pw)"

.venv/bin/python -m cli \
  --host 127.0.0.1 --port 27016 --password "$PW" status

.venv/bin/python -m cli \
  --host 127.0.0.1 --port 27016 --password "$PW" session list

.venv/bin/python -m cli \
  --host 127.0.0.1 --port 27016 --password "$PW" \
  --agent-id blueprint state --detail brief

.venv/bin/python -m cli \
  --host 127.0.0.1 --port 27016 --password "$PW" \
  --agent-id blueprint query get_recipe \
  --params '{"name":"iron-gear-wheel"}'

.venv/bin/python -m cli \
  --host 127.0.0.1 --port 27016 --password "$PW" \
  --agent-id blueprint map --width 8 --height 8

.venv/bin/python -m cli --agent-id test-02 step \
  '[{"action":"goto","home":true},{"action":"batch_mine","x":-48,"y":-10,"radius":3}]'

.venv/bin/python -m cli --agent-id test-02 step \
  '[{"action":"create_ghost","name":"stone-furnace","position":{"x":-48,"y":-10}}]'

.venv/bin/python -m cli --agent-id test-02 step \
  '[{"action":"batch_remove_ghost","x":-48,"y":-10,"radius":3}]'

.venv/bin/python -m cli --agent-id test-02 step \
  '[{"action":"batch_create_ghost","layout":"mining_outpost","resource":"iron-ore","x":0,"y":0,"max_drills":1}]'

.venv/bin/python -m cli --agent-id test-02 step \
  '[{"action":"batch_remove_ghost","x":0,"y":0,"radius":100}]'

.venv/bin/python -m cli --agent-id test-02 step --dry-run \
  '[{"action":"batch_plan_mining_outpost"}]'  # must be rejected
```

## Results

- `status`: `connected=true`, target `127.0.0.1:27016`.
- `catalog`: returned 8 registered batch actions, 24 atomic actions, and 9 queries.
- `goto`, `create_ghost`, `batch_remove_ghost`, and `batch_mine` completed through RCON.
- `batch_create_ghost(layout="mining_outpost")` planned an iron outpost, and the
  cleanup action removed its ghosts afterward.
- `batch_plan_mining_outpost` was rejected by CLI validation as an old name.
- File-backed blueprints with 501 entities expanded into two requests of 500 and 1;
  the cleanup-area file also passed dry-run validation.
- Invalid JSON parameters returned a JSON error and exit code `2`.

The explicit command-line credentials and environment-based credentials both
work, so a changed RCON target is picked up on the next CLI invocation without
restarting the client application.
