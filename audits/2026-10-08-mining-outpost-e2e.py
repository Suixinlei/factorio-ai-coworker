"""E2E: plan_mining_outpost skill (ai-coworker 0.8.0).

Drives the local headless server over RCON (no MCP layer needed):
  1. bind+spawn a throwaway agent
  2. find the nearest iron patch (get_resource_patch)
  3. plan_mining_outpost -> ghost census + geometry assertions
  4. negative cases (bad direction, undersized pole for big-mining-drill,
     idempotent re-run)
  5. cheat materials, build_ghosts, verify REAL entities: belt on every
     drill drop tile, every drill on a pole's electric network
  6. cleanup (destroy outpost + ghosts)

Run: .venv/bin/python audits/2026-10-08-mining-outpost-e2e.py
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

AGENT = "e2e-outpost-080"
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


DESTROY_OCCUPANTS = """
local s = game.surfaces['nauvis']
local targets = %(targets)s
local out = {}
for _, t in ipairs(targets) do
  local cx, cy = t.x + 0.5, t.y + 0.5
  for _, e in ipairs(s.find_entities_filtered{name=t.name, position={x=cx, y=cy}, radius=3}) do
    if e.valid then
      local bb = e.bounding_box
      if cx >= bb.left_top.x and cx < bb.right_bottom.x
         and cy >= bb.left_top.y and cy < bb.right_bottom.y then
        out[#out+1] = t.name .. '@' .. t.x .. ',' .. t.y
        e.destroy()
        break
      end
    end
  end
end
rcon.print(helpers.table_to_json(out))
"""

def to_lua_table(targets: list[dict]) -> str:
    """JSON arrays are not Lua table constructors — build one literally."""
    inner = ", ".join(f"{{name='{t['name']}', x={t['x']}, y={t['y']}}}" for t in targets)
    return "{" + inner + "}"


GHOST_CENSUS = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local out = {}
for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', area=area}) do
  out[g.ghost_name] = (out[g.ghost_name] or 0) + 1
end
out.leftover = s.count_entities_filtered{type='entity-ghost'}
rcon.print(helpers.table_to_json(out))
"""

GHOST_GEOMETRY = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local drills = s.find_entities_filtered{type='entity-ghost', ghost_name='electric-mining-drill', area=area}
local belts = s.find_entities_filtered{type='entity-ghost', ghost_name='transport-belt', area=area}
local poles = s.find_entities_filtered{type='entity-ghost', ghost_name='medium-electric-pole', area=area}
local bset = {}
for _, b in ipairs(belts) do bset[b.position.x..','..b.position.y] = true end
local DV = {[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local missing_belt, wrong_belt_dir = 0, 0
for _, d in ipairs(drills) do
  local dv = DV[d.direction] or {0,0}
  local key = (d.position.x + dv[1]*2)..','..(d.position.y + dv[2]*2)
  if not bset[key] then missing_belt = missing_belt + 1 end
end
for _, b in ipairs(belts) do
  if b.direction ~= 4 then wrong_belt_dir = wrong_belt_dir + 1 end
end
local unpowered = 0
for _, d in ipairs(drills) do
  local ok = false
  for _, pp in ipairs(poles) do
    if math.abs(d.position.x - pp.position.x) <= 5.4 and math.abs(d.position.y - pp.position.y) <= 5.4 then
      ok = true break
    end
  end
  if not ok then unpowered = unpowered + 1 end
end
local rows = {}
for _, pp in ipairs(poles) do
  local k = string.format('%%.1f', pp.position.y)
  rows[k] = rows[k] or {}
  table.insert(rows[k], pp.position.x)
end
local wire_gap = 0
for _, xs in pairs(rows) do
  table.sort(xs)
  for i = 2, #xs do
    if xs[i] - xs[i-1] > 9 then wire_gap = wire_gap + 1 end
  end
end
rcon.print(helpers.table_to_json{missing_belt=missing_belt, unpowered=unpowered,
  wire_gap=wire_gap, wrong_belt_dir=wrong_belt_dir})
"""

GHOST_COLLIDERS = """
local s = game.surfaces['nauvis']
local area = { {%(x)g-70,%(y)g-70}, {%(x)g+70,%(y)g+70} }
local out = {}
for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', area=area}) do
  local around = {}
  for _, e in ipairs(s.find_entities_filtered{position=g.position, radius=3}) do
    if e.valid and e.type ~= 'resource' and e.type ~= 'character'
        and e.type ~= 'tree' and e.type ~= 'corpse' and e ~= g then
      around[#around+1] = e.name .. '@' .. math.floor(e.position.x) .. ',' .. math.floor(e.position.y)
    end
  end
  out[#out+1] = g.ghost_name .. '@' .. math.floor(g.position.x) .. ',' .. math.floor(g.position.y)
    .. ' near[' .. table.concat(around, ' ') .. ']'
end
rcon.print(helpers.table_to_json{blockers=out, tiles=(function()
  local t = {}
  for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', area=area, limit=5}) do
    local tl = s.get_tile(math.floor(g.position.x), math.floor(g.position.y))
    t[#t+1] = tl.name
  end
  return t
end)()})
"""

GIVE_ITEMS = """
local st = remote.call('ai_player','get_state','%(agent)s')
local c = st.unit_number and game.get_entity_by_unit_number(st.unit_number)
if not (c and c.valid) then rcon.print(helpers.table_to_json{ok=false, why='no character', st=st}) return end
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
    name={'electric-mining-drill','transport-belt','medium-electric-pole',
          'steam-engine','boiler','offshore-pump','pipe'}}) do
  if e.valid then e.destroy() end
end
for _, g in ipairs(s.find_entities_filtered{area=area, type='entity-ghost'}) do
  if g.valid then g.destroy() end
end
rcon.print('cleaned')
"""


def main() -> None:
    global gw
    gw = RCONGateway("127.0.0.1", 27016, pw)
    assert gw.connect(), "RCON connect failed"

    created = gw.create_agent(AGENT, "e2e outpost 080")
    check("create_agent", created.get("ok") is True or created.get("agent_id") == AGENT, str(created))
    assert gw.spawn_ai_player(AGENT), "spawn failed"
    print("agent ready:", AGENT)

    # -- locate a patch ----------------------------------------------------
    allp = gw.run_query("get_resource_patch", {"resource": "iron-ore", "all": True}, agent_id=AGENT)
    assert allp.get("found") and allp.get("patches"), f"no iron patch anywhere: {allp}"
    best = allp["patches"][0]  # nearest-first
    bb = best["bounding_box"]
    cx = (bb["left_top"]["x"] + bb["right_bottom"]["x"]) / 2
    cy = (bb["left_top"]["y"] + bb["right_bottom"]["y"]) / 2
    print(f"patch: tiles={best['tiles']} amount={best['total_amount']} center=({cx:.0f},{cy:.0f}) dist={best['distance']}")

    # Pre-clean: a previous E2E run (or a rejected-direction attempt) may have
    # left ghosts on this patch — the plan skill extends existing plans, so a
    # dirty patch would make counts unpredictable. Also step aside any foreign
    # character standing inside the footprint (their collision box silently
    # blocks ghost revive — reproduced by a leftover builder role at 57,36).
    gw.query_lua(CLEANUP % {"x": cx, "y": cy})
    gw.query_lua(STEP_ASIDE % {"x": cx, "y": cy})

    # -- negative cases ----------------------------------------------------
    bad_dir = gw.run_skill("plan_mining_outpost",
                           {"resource": "iron-ore", "x": cx, "y": cy, "direction": "northeast"},
                           agent_id=AGENT)
    check("reject bad direction", not bad_dir["ok"] and "north/east/south/west" in bad_dir["detail"], bad_dir["detail"])

    bad_pole = gw.run_skill("plan_mining_outpost",
                            {"resource": "iron-ore", "x": cx, "y": cy,
                             "drill": "big-mining-drill", "pole": "medium-electric-pole"},
                            agent_id=AGENT)
    check("reject undersized pole for big-mining-drill",
          not bad_pole["ok"] and "cannot power" in bad_pole["detail"], bad_pole["detail"])

    # -- plan (explicit pole so the medium-pole geometry asserts are deterministic;
    #         the small-pole AUTO-fallback is covered by pole_unknown below) ----
    PLAN_ARGS = {"resource": "iron-ore", "x": cx, "y": cy,
                 "direction": "east", "pole": "medium-electric-pole"}
    RESULT_RE = (r"(\d+) electric-mining-drill \(skip (\d+)\) \+ (\d+) transport-belt \(skip (\d+)\)"
                 r" \+ (\d+) (\S+) \(skip (\d+)\), coverage (\d+)%")
    plan = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)
    check("plan ok", plan["ok"], plan["detail"])
    m = re.search(RESULT_RE, plan["detail"])
    assert m, f"cannot parse initial plan detail: {plan['detail']}"

    # Clean EXACTLY what the skill reports as occupating its slots (the
    # user-authorized "clean that part") — the skill lists name@tile, so no
    # heuristics and no collateral. Loop: destroy listed non-rock occupants ->
    # re-plan (reports the next batch, capped at 5) until only rocks remain;
    # rocks are natural obstacles for clear_area (the authorized path).
    for _ in range(3):
        if "OCCUPIED" not in plan["detail"]:
            break
        seg = plan["detail"].split("OCCUPIED by")[-1].split(" — remove")[0]
        occ = re.findall(r"([A-Za-z0-9_-]+)@(-?\d+),(-?\d+)", seg)
        targets = [{"name": n, "x": int(x), "y": int(y)} for n, x, y in occ if "rock" not in n]
        if not targets:
            break  # only rocks left — clear_area's job
        destroyed = lua_dict(DESTROY_OCCUPANTS % {"targets": to_lua_table(targets)})
        destroyed_list = destroyed if isinstance(destroyed, list) else destroyed.get("destroyed", [])
        check("occupants removed exactly as reported",
              len(destroyed_list) == len(targets),
              f"reported={targets} destroyed={destroyed_list}")
        plan = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)

    # Rocks/trees don't block ghost PLANNING but block ghost BUILDING —
    # clear_area is the documented, authorized terrain-clearing skill (bounded;
    # re-run while it reports remaining). Scope: the patch bbox only.
    pw_, ph_ = (bb["right_bottom"]["x"] - bb["left_top"]["x"]) + 6, (bb["right_bottom"]["y"] - bb["left_top"]["y"]) + 6
    for _ in range(8):
        ca = gw.run_skill("clear_area", {"x": cx, "y": cy, "width": pw_, "height": ph_}, agent_id=AGENT)
        if not (ca["ok"] and "remaining" in ca["detail"]):
            break
    check("clear_area (trees/rocks) done", ca["ok"] and "remaining" not in ca["detail"], ca["detail"][:120])

    # FINAL re-plan: extends into any slots freed by the cleanup. A complete
    # no-op ("already planned") is a valid end state — keep the last FULL
    # report's counts then.
    plan = gw.run_skill("plan_mining_outpost", PLAN_ARGS, agent_id=AGENT)
    check("re-plan after cleanup ok", plan["ok"] and "OCCUPIED" not in plan["detail"], plan["detail"][:160])
    m_final = re.search(RESULT_RE, plan["detail"])
    if m_final:
        m = m_final
    else:
        assert "already planned" in plan["detail"], plan["detail"]
    n_drills, n_belts, n_poles = int(m.group(1)), int(m.group(3)), int(m.group(5))
    cover = int(m.group(8))
    check("coverage >= 85%", cover >= 85, f"coverage={cover}% tiles={best['tiles']}")
    check("medium poles used", m.group(6) == "medium-electric-pole", m.group(6))

    census = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    check("ghost census matches report",
          census.get("electric-mining-drill") == n_drills
          and census.get("transport-belt") == n_belts
          and census.get("medium-electric-pole") == n_poles,
          str(census))

    # auto pole fallback on a second patch: no medium-pole research on this
    # save -> the skill must fall back to small-electric-pole automatically
    second = next((p for p in allp["patches"][1:] if p["tiles"] >= 20), None)
    if second:
        p2 = second["bounding_box"]
        c2x = (p2["left_top"]["x"] + p2["right_bottom"]["x"]) / 2
        c2y = (p2["left_top"]["y"] + p2["right_bottom"]["y"]) / 2
        gw.query_lua(CLEANUP % {"x": c2x, "y": c2y})
        auto = gw.run_skill("plan_mining_outpost", {"resource": "iron-ore", "x": c2x, "y": c2y}, agent_id=AGENT)
        check("auto pole fallback (small when medium unresearched)",
              auto["ok"] and "small-electric-pole" in auto["detail"], auto["detail"][:140])
        gw.query_lua(CLEANUP % {"x": c2x, "y": c2y})
    else:
        print("[SKIP] auto pole fallback — no second iron patch")

    # idempotent re-run on the now-FULLY-planned patch: success, nothing new
    rerun = gw.run_skill("plan_mining_outpost",
                         {"resource": "iron-ore", "x": cx, "y": cy,
                          "direction": "east", "pole": "medium-electric-pole"},
                         agent_id=AGENT)
    census2 = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    check("re-run on complete plan is a no-op success",
          rerun["ok"] and "already planned" in rerun["detail"]
          and census2.get("electric-mining-drill") == n_drills,
          rerun["detail"][:140])

    # -- geometry assertions (ghosts) ---------------------------------------
    geo = lua_dict(GHOST_GEOMETRY % {"x": cx, "y": cy})
    check("every drill has a belt ghost on its output tile", geo.get("missing_belt", -1) == 0,
          f"missing={geo.get('missing_belt')}")
    check("every drill within pole supply reach", geo.get("unpowered", -1) == 0,
          f"unpowered={geo.get('unpowered')}")
    check("pole chains within wire reach", geo.get("wire_gap", -1) == 0,
          f"gap_violations={geo.get('wire_gap')}")
    check("all belts face flow (east)", geo.get("wrong_belt_dir", -1) == 0,
          f"wrong={geo.get('wrong_belt_dir')}")

    # -- build with cheated materials ---------------------------------------
    give = lua_dict(GIVE_ITEMS % {"agent": AGENT, "drills": n_drills, "belts": n_belts, "poles": n_poles})
    check("cheated materials", give.get("ok"), str(give))
    my_ghosts = n_drills + n_belts + n_poles
    built = gw.run_skill("build_ghosts", {}, agent_id=AGENT)
    m3 = re.search(r"built (\d+) ghost", built["detail"])
    built_n = int(m3.group(1)) if m3 else 0
    ghosts_after = lua_dict(GHOST_CENSUS % {"x": cx, "y": cy})
    leftover_mine = sum(v for k, v in ghosts_after.items() if k != "leftover")
    if leftover_mine > 0:
        diag = lua_dict(GHOST_COLLIDERS % {"x": cx, "y": cy})
        print("leftover ghost colliders:", diag)
    check("build_ghosts built the whole outpost",
          built["ok"] and built_n >= my_ghosts and leftover_mine == 0,
          f"built={built_n} mine={my_ghosts} leftover_in_area={leftover_mine} detail={built['detail'][:160]}")

    # -- real-entity verification -------------------------------------------
    real = lua_dict(REAL_CHECK % {"x": cx, "y": cy})
    check("real drills", real.get("drills", -1) == n_drills, f"drills={real.get('drills')}")
    check("real belts", real.get("belts", -1) == n_belts, f"belts={real.get('belts')}")
    check("real poles", real.get("poles", -1) == n_poles, f"poles={real.get('poles')}")
    check("belt present on every drill drop tile", real.get("drop_no_belt", -1) == 0,
          f"missing={real.get('drop_no_belt')}")
    check("every drill shares a pole's electric network", real.get("no_network", -1) == 0,
          f"orphan={real.get('no_network')}")

    # -- cleanup -------------------------------------------------------------
    gw.query_lua(CLEANUP % {"x": cx, "y": cy})
    gw.remove_ai_player(AGENT)
    print("cleaned up")

    print("=" * 60)
    if failures:
        print(f"FAILED: {failures}")
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
