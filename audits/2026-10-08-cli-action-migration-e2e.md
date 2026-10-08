# CLI action migration E2E

Date: 2026-10-08

The standalone CLI was tested against the local headless server at
`127.0.0.1:27016` after moving its configuration and RCON transport into
`cli/` and removing the Python `bridge/` package.

## Checks

```bash
PW="$(cat local-server/rcon.pw)"
.venv/bin/python -m cli --host 127.0.0.1 --port 27016 --password "$PW" status
.venv/bin/python -m cli --host 127.0.0.1 --port 27016 --password "$PW" catalog
.venv/bin/python audits/2026-10-08-cli-action-migration-e2e.py
```

`catalog` returned the server's 15 compound actions, 9 queries, and the 11
skill-defined atomic actions. The checked-in script passed every compound and
atomic action through an individual CLI `step --dry-run` validation:

- Compound: `build_ghosts`, `deconstruct`, `clear_area`, `plan_blueprint`,
  `place_batch`, `review_build`, `clear_ghosts`, `plan_mining_outpost`,
  `gather`, `fill`, `collect`, `deposit_to_chest`, `return_home`, `goto`,
  `research`.
- Atomic: `move`, `mine`, `place`, `set_recipe`, `craft`, `pickup`, `chat`,
  `insert`, `take`, `summary`, `wait`.

The following real RCON dispatches were run with the existing `blueprint`
role and a remote coordinate outside the factory: `deconstruct`,
`review_build`, `clear_ghosts`, `move` with distance 0, `pickup`, and `wait`.
They returned structured per-action results; the first, second, third, and
fifth correctly reported no eligible target, while `move` and `wait` returned
`ok=true`. No factory entity was changed by these checks.

The first probe used a temporary solo role to verify routing. It was removed
afterward. `build_ghosts` correctly acted on pre-existing ghosts, so it is
validated by dry-run in the repeatable check rather than executed again.
