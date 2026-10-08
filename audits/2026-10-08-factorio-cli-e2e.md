# Factorio CLI E2E verification

Date: 2026-10-08

The top-level `cli/` package was exercised against the local headless Factorio
server at `127.0.0.1:27016`. The existing `blueprint` role was used for
read-only checks. The later action-migration run is recorded separately in
`2026-10-08-cli-action-migration-e2e.md`.

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

.venv/bin/python -m cli step --dry-run \
  '[{"skill":"gather","item":"iron-ore","count":20}]'
```

## Results

- `status`: `connected=true`, target `127.0.0.1:27016`.
- `session list`: returned the server role roster, including `blueprint`.
- `state`: returned the bound role state and a 12-character `state_hash`.
- `get_recipe`: returned the `iron-gear-wheel` recipe.
- `map`: returned an 8×8 grid, origin, legend, and entity roster.
- `step --dry-run`: returned `ok=true` without contacting the game.
- Invalid JSON parameters returned a JSON error and exit code `2`.

The explicit command-line credentials and environment-based credentials both
work, so a changed RCON target is picked up on the next CLI invocation without
restarting the client application.
