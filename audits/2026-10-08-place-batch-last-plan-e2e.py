"""E2E: place_batch use="last_plan" (ai-coworker 0.8.5).

Drives the local headless server over RCON via the cli package:
  1. bind+spawn a throwaway agent
  2. nearest iron patch -> plan_mining_outpost
  3. negative: place_batch use=last_plan with empty inventory -> ATOMIC
     shortage (nothing placed, ghost census unchanged)
  4. negative: entities+use together / unknown use / agent with no plan
  5. cheat materials, place_batch use=last_plan -> whole outpost built
     (real entity counts, belt on every drop tile, drills on pole networks)
  6. re-run -> "no live ghosts"; plan no-op re-run (registry merge) -> same

Run: .venv/bin/python audits/2026-10-08-place-batch-last-plan-e2e.py
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

os.environ.setdefault("FACTORIO_RCON_HOST", "127.0.0.1")
os.environ.setdefault("FACTORIO_RCON_PORT", "27016")
pw = (ROOT / "local-server" / "rcon.pw").read_text().strip()
os.environ.setdefault("FACTORIO_RCON_PASSWORD", pw)

from cli.rcon import RCONGateway  # noqa: E402

AGENT = "e2e-lastplan-080"
AGENT_B = "e2e-lastplan-noplan"
failures: list[str] = []
gw: RCONGateway | None = None


def check(name: str, ok: bool, info: str = "") -> None:
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {info}" if info else ""))
    if not ok:
        failures.append(name)


def lua_dict(code: str) -> dict:
    assert gw is not None
    raw = gw.query_lua(code)
    try:
        return json.loads((raw or "").strip() or "{}")
    except (ValueError, TypeError):
        return {"_raw": (raw or "")[:300]}


GHOST_CENSUS = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local out = {}
for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', area=area}) do
  out[g.ghost_name] = (out[g.ghost_name] or 0) + 1
end
rcon.print(helpers.table_to_json(out))
"""

GIVE_ITEMS = """
local st = remote.call('ai_player','get_state','%(agent)s')
local c = st.unit_number and game.get_entity_by_unit_number(st.unit_number)
if not (c and c.valid) then rcon.print(helpers.table_to_json{ok=false, why='no character'}) return end
local inv = c.get_inventory(defines.inventory.character_main)
inv.insert{name='electric-mining-drill', count=%(drills)d}
inv.insert{name='transport-belt', count=%(belts)d}
inv.insert{name='medium-electric-pole', count=%(poles)d}
rcon.print(helpers.table_to_json{ok=true})
"""

REAL_CHECK = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local drills = s.find_entities_filtered{name='electric-mining-drill', area=area}
local belts = s.find_entities_filtered{name='transport-belt', area=area}
local poles = s.find_entities_filtered{name='medium-electric-pole', area=area}
local drop_no_belt, no_network = 0, 0
local pole_nets = {}
for _, pp in ipairs(poles) do pole_nets[pp.electric_network_id or -1] = true end
for _, d in ipairs(drills) do
  local b = s.find_entities_filtered{name='transport-belt', position=d.drop_position, radius=0.4}
  if #b == 0 then drop_no_belt = drop_no_belt + 1 end
  if not pole_nets[d.electric_network_id or -2] then no_network = no_network + 1 end
end
rcon.print(helpers.table_to_json{drills=#drills, belts=#belts, poles=#poles,
  drop_no_belt=drop_no_belt, no_network=no_network})
"""

STEP_ASIDE = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local moved = {}
for _, c in ipairs(s.find_entities_filtered{type='character', area=area}) do
  if c.valid and c.vehicle == nil then
    local away = s.find_non_colliding_position('character', {x=c.position.x+25, y=c.position.y}, 16, 0.5)
    if away then c.teleport(away) moved[#moved+1] = math.floor(c.position.x)..','..math.floor(c.position.y) end
  end
end
rcon.print(helpers.table_to_json{moved=moved})
"""

CLEANUP = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-75,%(y)g-75}, {%(x)g+75,%(y)g+75} }
for _, e in ipairs(s.find_entities_filtered{area=area,
    name={'electric-mining-drill','transport-belt','medium-electric-pole'}}) do
  if e.valid then e.destroy() end
end
for _, g in ipairs(s.find_entities_filtered{area=area, type='entity-ghost'}) do
  if g.valid then g.destroy() end
end
rcon.print('cleaned')
"""

REMOVE_AGENT = """
remote.call('ai_player','remove_agent','%(agent)s')
rcon.print('removed')
"""


def main() -> None:
    global gw
    gw = RCONGateway("127.0.0.1", 27016, pw)
    assert gw.connect(), "RCON connect failed"

    created = gw.create_agent(AGENT, "e2e lastplan 080")
    check("create_agent", created.get("ok") is True or created.get("agent_id") == AGENT, str(created))
    assert gw.spawn_ai_player(AGENT), "spawn failed"
    print("agent ready:", AGENT)

    # -- locate a patch ------------------------------------------------------
    allp = gw.run_query("get_resource_patch", {"resource": "iron-ore", "all": True}, agent_id=AGENT)
    assert allp.get("found") and allp.get("patches"), f"no iron patch anywhere: {allp}"
    best = allp["patches"][0]  # nearest-first
    bb = best["bounding_box"]
    cx = (bb["left_top"]["x"] + bb["right_bottom"]["x"]) / 2
    cy = (bb["left_top"]["y"] + bb["right_bottom"]["y"]) / 2
    print(f"patch: tiles={best['tiles']} amount={best['total_amount']} center=({cx:.0f},{cy:.0f}) dist={best['distance']}")

    # Pre-clean so counts are deterministic; step aside foreign characters
    # (their collision box silently blocks ghost revive).
    gw.query_lua(CLEANUP % {"x": cx, "y": cy})
    gw.query_lua(STEP_ASIDE % {"x": cx, "y": cy})

    PLAN_ARGS = {"resource": "iron-ore", "x": cx, "y": cy,
                 "direction": "east", "pole": "medium-electric-pole"}
    RESULT_RE = (r"(\d+) electric-mining-drill \(skip (\d+)\) \+ (\d+) transport-belt \(skip (\d+)\)"
                 r" \+ (\d+) (\S+) \(skip (\d+)\), coverage (\d+)%")
    plan = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)
    check("plan ok", plan["ok"], plan["detail"][:160])
    m = re.search(RESULT_RE, plan["detail"])
    assert m, f"cannot parse plan detail: {plan['detail']}"

    # Rocks/trees don't block ghost PLANNING but block ghost BUILDING —
    # clear_area is the authorized terrain-clearing skill (bounded; re-run
    # while it reports remaining). Scope: the patch bbox only.
    pw_, ph_ = (bb["right_bottom"]["x"] - bb["left_top"]["x"]) + 6, (bb["right_bottom"]["y"] - bb["left_top"]["y"]) + 6
    ca = None
    for _ in range(8):
        ca = gw.run_skill("clear_area", {"x": cx, "y": cy, "width": pw_, "height": ph_}, agent_id=AGENT)
        if not (ca["ok"] and "remaining" in ca["detail"]):
            break
    check("clear_area (trees/rocks) done", ca["ok"] and "remaining" not in ca["detail"], (ca["detail"] or "")[:120])

    # FINAL re-plan: extends into any slots freed by the cleanup. A complete
    # no-op ("already planned") is a valid end state — keep the FIRST plan's
    # counts then.
    plan = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)
    check("re-plan after cleanup ok", plan["ok"] and "OCCUPIED" not in plan["detail"], plan["detail"][:160])
    m_final = re.search(RESULT_RE, plan["detail"])
    if m_final:
        m = m_final
    else:
        assert "already planned" in plan["detail"], plan["detail"]
    n_drills, n_belts, n_poles = int(m.group(1)), int(m.group(3)), int(m.group(5))
    check("medium poles used", m.group(6) == "medium-electric-pole", m.group(6))

    census0 = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    check("ghost census matches report",
          census0.get("electric-mining-drill") == n_drills
          and census0.get("transport-belt") == n_belts
          and census0.get("medium-electric-pole") == n_poles,
          str(census0))

    # -- negative: empty inventory -> ATOMIC shortage, nothing placed --------
    neg1 = gw.run_skill("place_batch", {"use": "last_plan"}, agent_id=AGENT)
    census1 = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    check("atomic shortage on empty inventory",
          not neg1["ok"] and "shortage" in neg1["detail"] and "nothing placed" in neg1["detail"]
          and census1 == census0,
          f"detail={neg1['detail'][:140]} census_same={census1 == census0}")

    neg2 = gw.run_skill("place_batch",
                        {"use": "last_plan", "entities": [{"name": "transport-belt", "x": 0.5, "y": 0.5}]},
                        agent_id=AGENT)
    check("entities+use rejected", not neg2["ok"] and "not both" in neg2["detail"], neg2["detail"])

    neg3 = gw.run_skill("place_batch", {"use": "bogus"}, agent_id=AGENT)
    check("unknown use rejected", not neg3["ok"] and "unknown use" in neg3["detail"], neg3["detail"])

    # -- negative: a DIFFERENT role has no plan on record -------------------
    gw.create_agent(AGENT_B, "e2e lastplan noplan")
    assert gw.spawn_ai_player(AGENT_B), "spawn B failed"
    neg4 = gw.run_skill("place_batch", {"use": "last_plan"}, agent_id=AGENT_B)
    check("no plan on record for another role",
          not neg4["ok"] and "no plan on record" in neg4["detail"], neg4["detail"])

    # -- build the whole outpost via use=last_plan ---------------------------
    give = lua_dict(GIVE_ITEMS % {"agent": AGENT, "drills": n_drills, "belts": n_belts, "poles": n_poles})
    check("cheated materials", give.get("ok"), str(give))
    expected = n_drills + n_belts + n_poles
    built = gw.run_skill("place_batch", {"use": "last_plan"}, agent_id=AGENT)
    mb = re.search(r"placed (\d+)", built["detail"])
    placed_n = int(mb.group(1)) if mb else 0
    check("place_batch use=last_plan built the whole outpost",
          built["ok"] and placed_n == expected and "audit" in built["detail"],
          f"placed={placed_n} expected={expected} detail={built['detail'][:180]}")

    real = lua_dict(REAL_CHECK % {"x": cx, "y": cy})
    check("real drills", real.get("drills", -1) == n_drills, f"drills={real.get('drills')}/{n_drills}")
    check("real belts", real.get("belts", -1) == n_belts, f"belts={real.get('belts')}/{n_belts}")
    check("real poles", real.get("poles", -1) == n_poles, f"poles={real.get('poles')}/{n_poles}")
    check("belt present on every drill drop tile", real.get("drop_no_belt", -1) == 0,
          f"missing={real.get('drop_no_belt')}")
    check("every drill shares a pole's electric network", real.get("no_network", -1) == 0,
          f"orphan={real.get('no_network')}")

    census2 = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    check("no leftover ghosts in area", census2 == {}, str(census2))

    # -- re-run: registry now has zero live ghosts ---------------------------
    again = gw.run_skill("place_batch", {"use": "last_plan"}, agent_id=AGENT)
    check("re-run reports no live ghosts",
          not again["ok"] and "no live ghosts" in again["detail"], again["detail"])

    # -- plan no-op re-run exercises the registry MERGE path -----------------
    rerun = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)
    check("plan no-op re-run ok",
          rerun["ok"] and "already planned" in rerun["detail"] and "place_batch use=last_plan" in rerun["detail"],
          rerun["detail"][:160])
    after_merge = gw.run_skill("place_batch", {"use": "last_plan"}, agent_id=AGENT)
    check("merge keeps zero live ghosts after full build",
          not after_merge["ok"] and "no live ghosts" in after_merge["detail"], after_merge["detail"])

    # -- cleanup --------------------------------------------------------------
    gw.query_lua(CLEANUP % {"x": cx, "y": cy})
    gw.query_lua(REMOVE_AGENT % {"agent": AGENT})
    gw.query_lua(REMOVE_AGENT % {"agent": AGENT_B})
    print("cleaned up")

    print("=" * 60)
    if failures:
        print(f"FAILED: {failures}")
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
