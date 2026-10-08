# place_batch use="last_plan" E2E verification (mod 0.8.5)

Date: 2026-10-08

Closes the workflow gap where `plan_mining_outpost`'s geometry never leaves
the mod (its result is a counts/materials string), so `place_batch` — which
requires the exact `entities=[{name,x,y,direction}]` list — could not follow
it. The planner now records its ghosts in a per-character registry
(`storage.ai_last_plan`, merged across extending re-runs, live entity refs
that drop out when revived/cleared), and `place_batch` accepts
`use="last_plan"` to execute that registry without any coordinate round-trip.

## Reproduction

```bash
# 1. restart the local headless server so it packs mod 0.8.5
pkill -f "factorio.*start-server"; sleep 2
bash scripts/local-headless.sh

# 2. run the audit
.venv/bin/python audits/2026-10-08-place-batch-last-plan-e2e.py
```

The script drives RCON directly via the `cli` package (no MCP layer): nearest
iron patch (center 57,36 on the dev map), `plan_mining_outpost`
(pole=medium-electric-pole), negative cases, cheated materials, build, real
entity verification, registry re-run semantics, cleanup (entities + ghosts +
both throwaway roles removed).

## Results (all 18 checks PASS)

- plan: 79 drills + 650 belts + 49 poles, coverage 99%; no-op re-run reports
  "proceed to place_batch use=last_plan".
- atomic shortage on empty inventory: `shortage — 79x electric-mining-drill
  (have 0), 600x transport-belt (have 50), ...; nothing placed`, ghost census
  unchanged (the role's default 50 belts prove partial stock still builds
  NOTHING).
- param guards: `entities`+`use` together, unknown `use`, and a second role
  with no plan are all rejected with explicit messages.
- build: `place_batch use=last_plan` placed **778/778** entities in one call
  (exercises the 1000 cap for last_plan vs 500 for explicit lists); post-build
  audit attached; real drills/belts/poles counts match; belt on every drop
  tile (missing=0); every drill shares a pole electric network (orphan=0).
  Drills report `no_power` — correct commissioning status: the outpost has no
  generator yet.
- registry semantics: after the full build, re-run says "no live ghosts";
  after a plan no-op re-run (merge path) still "no live ghosts".

## Files changed

- `mod/scripts/skills.lua`: `remember_plan` helper; `plan_mining_outpost`
  registers ghosts (both success returns); `place_batch` `use="last_plan"`
  mode (cap 1000, guards, registry expansion).
- `mod/info.json` 0.8.4 → 0.8.5; `mod/changelog.txt` entry.
- `skills/factorio-ai-coworker/SKILL.md`: place_batch / plan_mining_outpost
  rows, 标准流程, 常见循环.
- No CLI change needed: `cli/main.py` passes skill params through untouched.
