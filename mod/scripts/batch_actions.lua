-- Batch action orchestration.
--
-- A batch action is a parameterized loop. Batch actions own the deterministic
-- mechanics (positions, orientation, fuelling, drop-positions); the LLM only
-- chooses the action and its params. Batch actions orchestrate atomic handlers
-- (AIActions.run) wherever possible, so placement legality / slot resolution /
-- mining all stay in one place (atomic_actions.lua).
--
-- Each batch action: function(character, params) -> (ok:boolean, detail:string)
-- detail feeds the E1 result loop, so make it specific and actionable.

AIBatchActions = {}

function AIBatchActions.canonical(name)
  return tostring(name or ""):lower()
end

-- Water tile names (mirror of queries.lua SCAN_WATER_TILES) for the ghost
-- water-guard in batch_create_ghost.
local WATER_TILE_NAMES = {
  ["water"] = true, ["deepwater"] = true, ["water-green"] = true,
  ["deepwater-green"] = true, ["water-shallow"] = true, ["water-mud"] = true,
}

local function inv_of(character)
  return character.get_inventory(defines.inventory.character_main)
end

-- -------------------------------------------------------------------------
-- Exact-coordinate contract: coordinates are NEVER silently rewritten. An
-- axis is aligned iff odd-size axes sit on tile centres (n+0.5) and even-size
-- axes on integer corners (n.0). Misaligned input is REJECTED with the
-- nearest legal value spelled out — the caller fixes the number explicitly.
-- (Calibrated 2026-10-08: the old parity snap moved anchors by up to half a
-- tile, so agents could no longer reason about where things actually landed.)
-- -------------------------------------------------------------------------
local function aligned_position(name, x, y, dir)
  local proto = prototypes.entity[name]
  if not proto then return nil, "unknown entity '" .. tostring(name) .. "'" end
  local w, h = proto.tile_width or 1, proto.tile_height or 1
  -- Rotation-aware: east/west (16-dir 4/12) swap the axes, so an east-facing
  -- 3x2 boiler actually occupies 2 wide x 3 high — its aligned anchor is
  -- (integer x, n+0.5 y), not the unrotated form. (Calibrated 2026-10-08:
  -- the working east boilers at (-38,-26.5) in the save use exactly that.)
  if dir == defines.direction.east or dir == defines.direction.west then
    w, h = h, w
  end
  local function axis(v, tiles, label)
    if type(v) ~= "number" then return nil, label .. " must be a number" end
    local frac = v % 1
    if tiles % 2 == 1 then
      if math.abs(frac - 0.5) > 1e-9 then
        return nil, string.format("%s is %dx%d — %s must be n+0.5 (got %g; use %g)",
          name, w, h, label, v, math.floor(v) + 0.5)
      end
    else
      if math.abs(frac) > 1e-9 then
        return nil, string.format("%s is %dx%d — %s must be an integer (got %g; use %g)",
          name, w, h, label, v, math.floor(v + 0.5))
      end
    end
    return v
  end
  local ax, err = axis(x, w, "x")
  if ax == nil and err then return nil, err end
  local ay, err = axis(y, h, "y")
  if ay == nil and err then return nil, err end
  return {x = ax, y = ay}
end

-- Compact "skipped entries" renderer shared by batch actions.
local function format_skipped(skipped)
  local parts = {}
  for i = 1, math.min(#skipped, 3) do
    local s = skipped[i]
    parts[#parts + 1] = string.format("[%s #%d: %s]", tostring(s.name), s.index, s.reason)
  end
  if #skipped > 3 then parts[#parts + 1] = "(+" .. (#skipped - 3) .. " more)" end
  return table.concat(parts, " ")
end

-- Post-build audit: status buckets for everything just placed/built, problem
-- entities listed explicitly. Shared by batch_build_ghost and
-- batch_review_build so every build path reports the same way.
local SKIP_AUDIT_TYPES = {
  ["character"] = true, ["entity-ghost"] = true, ["resource"] = true,
  ["tree"] = true, ["simple-entity"] = true, ["cliff"] = true,
  ["corpse"] = true, ["particle"] = true, ["item-on-ground"] = true,
}

local function audit_entities(character, ents)
  local by_status, problems, total = {}, {}, 0
  for _, e in ipairs(ents) do
    if e.valid and not SKIP_AUDIT_TYPES[e.type] then
      local _, detail, record = AIActions.run(character, {
        action = "review_build", name = e.name, position = e.position, radius = 0.1,
      })
      if record then
        total = total + 1
        by_status[record.status] = (by_status[record.status] or 0) + 1
        if record.problem and #problems < 20 then problems[#problems + 1] = detail end
      end
    end
  end
  return {total = total, by_status = by_status, problems = problems}
end

local function audit_detail(a)
  local parts = {}
  for st, c in pairs(a.by_status) do parts[#parts + 1] = c .. " " .. st end
  table.sort(parts)
  local s = string.format("audit %d: %s", a.total, table.concat(parts, ", "))
  if #a.problems > 0 then
    s = s .. " — PROBLEMS: " .. table.concat(a.problems, "; ")
  end
  return s
end

-- Remember the most recent batch per character so batch_review_build has a default.
local function remember_build(character, ents)
  storage.ai_last_build = storage.ai_last_build or {}
  local rec = {tick = game.tick, entries = {}}
  for _, e in ipairs(ents) do
    if e.valid then
      rec.entries[#rec.entries + 1] = {name = e.name, x = e.position.x, y = e.position.y}
    end
  end
  storage.ai_last_build[character.unit_number] = rec
end

-- Remember the most recent batch_create_ghost layout=mining_outpost plan per character so batch_build_ghost
-- (use="last_plan") can execute it without the agent re-sending coordinates —
-- the planner's geometry never leaves the mod. Entries are LIVE ghost refs:
-- reviving or clearing a ghost invalidates its ref, so the record always
-- reflects what is still unbuilt. Re-runs MERGE with the previous record
-- (a re-run only places the missing slots).
local function remember_plan(character, ghosts)
  storage.ai_last_plan = storage.ai_last_plan or {}
  local unit = character.unit_number
  local by_key, merged = {}, {}
  local function keep(g)
    if g.valid and g.type == "entity-ghost" then
      local key = g.ghost_name .. "@" .. math.floor(g.position.x) .. "," .. math.floor(g.position.y)
      if not by_key[key] then
        by_key[key] = true
        merged[#merged + 1] = g
      end
    end
  end
  local prev = storage.ai_last_plan[unit]
  if prev then
    for _, g in ipairs(prev.entries) do keep(g) end
  end
  for _, g in ipairs(ghosts) do keep(g) end
  storage.ai_last_plan[unit] = {tick = game.tick, entries = merged}
end

-- -------------------------------------------------------------------------
-- batch_mine(item, count) — mine the nearest sources of `item` until `count`.
-- Handles wood (mine trees by type) and ores/rocks (mine by name).
-- -------------------------------------------------------------------------
local function batch_action_gather(character, p)
  local item = p.item
  if not item then return false, "batch_mine: missing 'item'" end
  local need = math.min(p.count or 50, 300)
  local surface = character.surface
  local inv = inv_of(character)
  local is_wood = (item == "wood")
  local gained = 0

  local have0 = inv.get_item_count(item)
  if have0 >= need then
    return true, string.format("batch_mine: already have %d %s (need %d) — nothing to batch_mine", have0, item, need)
  end

  for _ = 1, 150 do
    if inv.get_item_count(item) >= need then break end
    local filter = {position = character.position, radius = 40, limit = 60}
    if is_wood then filter.type = "tree" else filter.name = item end
    local sources = surface.find_entities_filtered(filter)
    local src, sd = nil, math.huge
    for _, e in ipairs(sources) do
      if e.valid and e.minable and e ~= character then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if d < sd then sd = d; src = e end
      end
    end
    if not src then break end
    -- Teleport adjacent so the source is within mining reach, then mine.
    local sp = surface.find_non_colliding_position("character", src.position, 3, 0.5)
    if sp then character.teleport(sp) end
    local before = inv.get_item_count()
    local mined = AIActions.run(character, {
      action = "mine", name = src.name, position = src.position, radius = 1,
    })
    if not mined then break end
    local delta = inv.get_item_count() - before
    if delta <= 0 then break end  -- inventory full or stuck
    gained = gained + delta
  end

  local have = inv.get_item_count(item)
  if gained == 0 then
    return false, "batch_mine: no reachable " .. item .. " sources within 40 tiles"
  end
  return true, string.format("gathered %d %s (now have %d)", gained, item, have)
end

-- Nearest LEGAL centre for an entity (generative twin of the aligned_position
-- validator): odd-size axes land on tile centres (n+0.5), even-size axes on
-- integer corners (n.0). Used by generators that must emit aligned positions.
local function snap_center(name, x, y)
  local proto = prototypes.entity[name]
  local w, h = proto.tile_width or 1, proto.tile_height or 1
  return {
    x = (w % 2 == 1) and math.floor(x) + 0.5 or math.floor(x + 0.5),
    y = (h % 2 == 1) and math.floor(y) + 0.5 or math.floor(y + 0.5),
  }
end

-- Base-game pole supply/wire specs (official wiki, Factorio 2.0). Preferred
-- source is the live prototype, but every quality-parameterized prototype
-- getter (get_supply_area_distance/get_max_wire_distance) currently throws
-- "Invalid QualityID" in the RCON sandbox (2.0.77), so these verified values
-- are the runtime fallback; unknown poles get conservative small-pole spacing.
local POLE_SPECS = {
  ["small-electric-pole"]  = {supply = 2.5, wire = 7.5},
  ["medium-electric-pole"] = {supply = 3.5, wire = 9},
  ["big-electric-pole"]    = {supply = 2,   wire = 30},
  ["substation"]           = {supply = 9,   wire = 18},
}

local function pole_geometry(pole_proto)
  local ok_s, s = pcall(function() return pole_proto:get_supply_area_distance() end)
  local ok_w, w = pcall(function() return pole_proto:get_max_wire_distance() end)
  if ok_s and type(s) == "number" and ok_w and type(w) == "number" then
    return s, w, true
  end
  local spec = POLE_SPECS[pole_proto.name]
  if spec then return spec.supply, spec.wire, true end
  return 2.5, 7.5, false
end

-- -------------------------------------------------------------------------
-- batch_create_ghost layout=mining_outpost(resource, x,y?, direction?, drill?, pole?, belt?,
--                      min_ore?, max_drills?, radius?) — fully-automatic
-- mining outpost planner: ONE call turns an ore patch into a complete ghost
-- layout of mining drills + output belts + power poles. The model picks the
-- patch (get_resource_patch), the flow direction and the drill/pole/belt
-- tiers; the deterministic mechanics below encode the canonical outpost
-- rules (official wiki), ALL geometry derived from live prototypes:
  --   * Drills mine a square area of radius H = floor(mining_drill_radius)
  --     around their centre → drills on a lattice of step S = 2H+1 cover the
  --     patch completely with no overlap (electric 3x3 mines 5x5: H=2, S=5;
  --     big 5x5 mines 13x13: H=6, S=13).
--   * A drill drops ore one tile past its footprint on the facing side
--     (offset B = floor(F/2)+1 from the centre row) → a belt line on row
--     r+B collects a whole "+"-facing drill row.
--   * PAIRED ROWS: adjacent drill rows (S apart) face EACH OTHER and share
--     the free band between their footprints as belt rows (r+B / r+S-B);
--     the same-width band between row PAIRS stays free as a street for
--     power poles, one street row per 2*S period, poles chained
--     min(wire-1, 2*supply+1) apart (2.0 poles rebalanced — read live!).
-- Preflight verifies the pole's supply actually reaches both neighbouring
-- drill rows (a big-mining-drill lattice needs substation-class poles).
-- flow east/west → rows run along x; north/south → transposed. Blocked
-- slots are skipped+reported; ghosts never expire; re-runs extend the plan
-- (the plan registry merges, so use=last_plan always covers the WHOLE outpost).
-- Execution: batch_mine/craft + batch_build_ghost use="last_plan" (or batch_build_ghost).
-- -------------------------------------------------------------------------
local function batch_action_plan_mining_outpost(character, p)
  local resource = p.resource or p.item or "iron-ore"
  local res_proto = prototypes.entity[resource]
  if not res_proto or res_proto.type ~= "resource" then
    return false, "batch_create_ghost layout=mining_outpost: '" .. tostring(resource) .. "' is not a resource name"
  end
  if resource == "crude-oil" then
    return false, "batch_create_ghost layout=mining_outpost: crude-oil needs pumpjacks, not mining drills"
  end
  if resource == "uranium-ore" then
    return false, "batch_create_ghost layout=mining_outpost: uranium-ore needs sulfuric-acid plumbing — not supported yet"
  end

  -- Drill tier → lattice geometry, straight from the prototype.
  local drill = p.drill or "electric-mining-drill"
  local drill_proto = prototypes.entity[drill]
  if not drill_proto or drill_proto.type ~= "mining-drill" then
    return false, "batch_create_ghost layout=mining_outpost: '" .. tostring(drill) .. "' is not a mining drill"
  end
  local F = drill_proto.tile_width or 3
  if F ~= (drill_proto.tile_height or F) or F % 2 == 0 then
    return false, "batch_create_ghost layout=mining_outpost: only odd square-footprint drills are supported"
      .. " (burner-mining-drill: plan a single drill with batch_create_ghost + batch_build_ghost instead)"
  end
  local H = math.floor(drill_proto.mining_drill_radius or (F / 2))
  local S = 2 * H + 1                -- lattice step: full coverage, no overlap
  local B = math.floor(F / 2) + 1    -- belt row offset from the drill centre row
  if S - F < 1 then
    return false, string.format(
      "batch_create_ghost layout=mining_outpost: %s mining area leaves no belt gap between rows (footprint %dx%d, step %d)",
      drill, F, F, S)
  end

  local surface = character.surface
  local force = character.force

  local flow_name = tostring(p.direction or "east"):lower()
  local flow = AIActions.DIRECTION_MAP[flow_name]
  -- Belts run in CARDINAL directions only — reject the 16-dir half-steps the
  -- generic DIRECTION_MAP would happily accept (northeast etc.).
  if flow ~= defines.direction.north and flow ~= defines.direction.east
      and flow ~= defines.direction.south and flow ~= defines.direction.west then
    return false, "batch_create_ghost layout=mining_outpost: direction must be north/east/south/west"
  end
  local along_x = (flow == defines.direction.east or flow == defines.direction.west)

  local belt = p.belt or "transport-belt"
  local belt_proto = prototypes.entity[belt]
  if not belt_proto or belt_proto.type ~= "transport-belt" then
    return false, "batch_create_ghost layout=mining_outpost: '" .. tostring(belt) .. "' is not a transport belt"
  end
  local pole = p.pole
  if not pole then
    local medium = force.recipes["medium-electric-pole"]
    pole = (medium and medium.enabled) and "medium-electric-pole" or "small-electric-pole"
  end
  local pole_proto = prototypes.entity[pole]
  if not pole_proto or pole_proto.type ~= "electric-pole" then
    return false, "batch_create_ghost layout=mining_outpost: '" .. tostring(pole) .. "' is not an electric pole"
  end
  local supply, wire, pole_known = pole_geometry(pole_proto)
  -- Conservative chain spacing: neighbours auto-wire (step < wire) and every
  -- drill column stays within supply reach of some pole column.
  local pole_step = math.max(2, math.floor(math.min(wire - 1, 2 * supply + 1)))
  local street_reach = math.floor(supply) + 1  -- drill rows within this of a street get power
  -- A street row sits between row PAIRS: it must reach both flanking drill
  -- rows (up to ceil(S/2) away) and the farthest column between poles.
  local required_reach = math.max(math.ceil(S / 2), math.floor(pole_step / 2))
  if street_reach < required_reach then
    return false, string.format(
      "batch_create_ghost layout=mining_outpost: %s (supply %g) cannot power a %s lattice (rows %d apart, needs reach %d) — pass a bigger pole (e.g. substation)",
      pole, supply, drill, S, required_reach)
  end

  -- Locate the patch tiles (explicit x/y wins; else around the character).
  local center = {x = character.position.x, y = character.position.y}
  if tonumber(p.x) and tonumber(p.y) then
    center = {x = tonumber(p.x), y = tonumber(p.y)}
  end
  local radius = math.min(tonumber(p.radius) or 64, 96)
  local ore, n_ore = {}, 0
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(surface.find_entities_filtered{
      type = "resource", name = resource, position = center, radius = radius, limit = 4000}) do
    local tx, ty = math.floor(e.position.x), math.floor(e.position.y)
    local key = tx .. "," .. ty
    if not ore[key] then
      ore[key] = true
      n_ore = n_ore + 1
      if tx < minx then minx = tx end
      if tx > maxx then maxx = tx end
      if ty < miny then miny = ty end
      if ty > maxy then maxy = ty end
    end
  end
  if n_ore == 0 then
    return false, string.format(
      "batch_create_ghost layout=mining_outpost: no %s tiles within %d of {%d,%d} — get_resource_patch then pass x/y",
      resource, radius, center.x, center.y)
  end

  -- Idempotency: ghost slots already planned (ours or a human blueprint) are
  -- left alone so a re-run EXTENDS the plan instead of stacking duplicates.
  local existing = {}
  for _, g in ipairs(surface.find_entities_filtered{
      type = "entity-ghost", force = force,
      area = {{minx - 8, miny - 8}, {maxx + 8, maxy + 8}}}) do
    existing[g.ghost_name .. "@" .. math.floor(g.position.x) .. "," .. math.floor(g.position.y)] = true
  end

  -- Real buildings sharing a slot: an IDENTICAL entity means "already built"
  -- (kept, counted as already); any other solid building means the slot is
  -- occupied — skipped honestly instead of leaving a ghost that can never
  -- revive. Trees/rocks are NOT blockers (ghosts overlap them, GUI-style).
  local solid = {}
  local NON_SOLID = {
    resource = true, tree = true, character = true, corpse = true,
    particle = true, ["item-on-ground"] = true, ["entity-ghost"] = true,
    smoke = true, ["fish"] = true, ["decorative"] = true,
  }
  for _, e in ipairs(surface.find_entities_filtered{
      area = {{minx - 8, miny - 8}, {maxx + 8, maxy + 8}}}) do
    if e.valid and not NON_SOLID[e.type] then
      local proto = prototypes.entity[e.name]
      local w = math.max(proto and proto.tile_width or 1, proto and proto.tile_height or 1)
      local cx, cy = math.floor(e.position.x), math.floor(e.position.y)
      local x0, x1 = math.floor(e.position.x - w / 2), math.ceil(e.position.x + w / 2) - 1
      local y0, y1 = math.floor(e.position.y - w / 2), math.ceil(e.position.y + w / 2) - 1
      for tx = x0, x1 do
        for ty = y0, y1 do
          solid[tx .. "," .. ty] = e.name
        end
      end
    end
  end

  local total, already, occupied = 0, 0, 0
  local planned = {}  -- ghost refs placed THIS run -> remember_plan registry
  local occupant_list, occupant_seen = {}, {}
  -- Ghost semantics match batch_create_ghost (0.7.10): can_place_entity with
  -- build_check_type=blueprint_ghost is STRICTER than real ghost placement
  -- (drill/belt ghosts over trees are routine in GUI blueprints), so we only
  -- guard the centre tile against water and let create_entity's own
  -- accept/reject be the verdict.
  local function place_ghost(name, x, y, dir)
    if total >= 1000 then return nil, "cap" end
    local pos = snap_center(name, x, y)
    local tkey = math.floor(pos.x) .. "," .. math.floor(pos.y)
    local key = name .. "@" .. tkey
    if existing[key] then
      already = already + 1
      return nil, "already"
    end
    local resident = solid[tkey]
    if resident == name then
      already = already + 1  -- identical real entity already there
      return nil, "already"
    elseif resident then
      occupied = occupied + 1
      -- Report the exact occupant so the caller can remove precisely THAT
      -- entity — no guessing, no collateral (fix for the E2E heuristic pit).
      local okey = resident .. "@" .. tkey
      if not occupant_seen[okey] then
        occupant_seen[okey] = true
        occupant_list[#occupant_list + 1] = okey
      end
      return nil, "occupied"
    end
    local tile = surface.get_tile(math.floor(pos.x), math.floor(pos.y))
    if WATER_TILE_NAMES[tile.name] then
      return nil, "blocked"
    end
    local ok = AIActions.run(character, {
      action = "create_ghost", name = name, position = pos, direction = dir,
    })
    if not ok then return nil, "blocked" end
    local g = surface.find_entities_filtered{
      type = "entity-ghost", ghost_name = name, position = pos, radius = 0.1, force = force,
    }[1]
    if not (g and g.valid) then return nil, "blocked" end
    existing[key] = true
    total = total + 1
    return g
  end

  -- Lattice: "rows" run perpendicular to flow (drill rows), "cols" along it.
  -- Phase is global (mod S) so re-runs and neighbouring plans stay aligned.
  local r0, r1, c0, c1
  if along_x then
    r0, r1 = S * math.floor(miny / S), S * math.floor(maxy / S)
    c0, c1 = S * math.floor(minx / S), S * math.floor(maxx / S)
  else
    r0, r1 = S * math.floor(minx / S), S * math.floor(maxx / S)
    c0, c1 = S * math.floor(miny / S), S * math.floor(maxy / S)
  end
  local function rowcol_to_xy(row, col)
    if along_x then return col, row end
    return row, col
  end
  local plus_dir = along_x and defines.direction.south or defines.direction.east
  local minus_dir = along_x and defines.direction.north or defines.direction.west

  local min_ore_n = math.max(1, tonumber(p.min_ore) or 4)
  local max_drills = math.min(math.max(tonumber(p.max_drills) or 120, 1), 500)
  local drills, drill_skip, already_drills = 0, 0, 0
  local row_has_drill = {}
  local belt_rows = {}
  local bc_min, bc_max = math.huge, -math.huge
  local covered = {}
  for row = r0, r1, S do
    local k = math.floor((row - r0) / S)
    local facing = (k % 2 == 0) and plus_dir or minus_dir
    local belt_row = row + ((k % 2 == 0) and B or -B)
    for col = c0, c1, S do
      local x0t, y0t = rowcol_to_xy(row - H, col - H)
      local x1t, y1t = rowcol_to_xy(row + H, col + H)
      local cnt, keys = 0, {}
      for tx = math.min(x0t, x1t), math.max(x0t, x1t) do
        for ty = math.min(y0t, y1t), math.max(y0t, y1t) do
          if ore[tx .. "," .. ty] then
            cnt = cnt + 1
            keys[#keys + 1] = tx .. "," .. ty
          end
        end
      end
      if cnt < min_ore_n then
        -- fringe slot: not worth a drill
      elseif drills >= max_drills then
        drill_skip = drill_skip + 1  -- cap reached; counted so the report adds up
      else
        local x, y = rowcol_to_xy(row, col)
        local g, why = place_ghost(drill, x, y, facing)
        if g then
          planned[#planned + 1] = g
          drills = drills + 1
          row_has_drill[row] = true
          belt_rows[belt_row] = true
          if col < bc_min then bc_min = col end
          if col > bc_max then bc_max = col end
          for _, key in ipairs(keys) do covered[key] = true end
        elseif why == "already" then
          already_drills = already_drills + 1
          row_has_drill[row] = true
          belt_rows[belt_row] = true
          if col < bc_min then bc_min = col end
          if col > bc_max then bc_max = col end
          for _, key in ipairs(keys) do covered[key] = true end
        elseif why ~= "cap" then
          drill_skip = drill_skip + 1  -- blocked (water) or occupied (building)
        end
      end
    end
  end
  -- No NEW drills this run. If earlier rows exist (ghosts or real drills) the
  -- plan continues with them — belts/poles below fill any slots still missing
  -- (e.g. freed by a cleanup) — and the summary reports a no-op only when
  -- nothing new was placed at all.
  local pre_planned = already_drills > 0
  if drills == 0 and not pre_planned then
    return false, string.format(
      "batch_create_ghost layout=mining_outpost: no placeable drill slots on the %s patch (%d skipped — batch_mine blockers, or lower min_ore)",
      resource, drill_skip)
  end

  -- Output belts: one line per belt row, spanning the drill extent (+2 so ore
  -- visibly leaves the patch), every belt facing the flow direction.
  local belts, belt_skip = 0, 0
  for belt_row in pairs(belt_rows) do
    for col = bc_min - 2, bc_max + 2 do
      local x, y = rowcol_to_xy(belt_row, col)
      local g, why = place_ghost(belt, x, y, flow)
      if g then planned[#planned + 1] = g belts = belts + 1
      elseif why ~= "already" and why ~= "cap" then belt_skip = belt_skip + 1 end
    end
  end

  -- Power poles: one street row per 2*S period, centred in the free band
  -- between row PAIRS so it powers the drill rows on BOTH sides.
  local street_phase = r0 + S + B + math.floor((S - 2 * B) / 2)
  local poles, pole_skip = 0, 0
  local s = street_phase + 2 * S * math.floor((r0 - street_reach - street_phase) / (2 * S))
  while s <= r1 + street_reach do
    local needed = false
    for row in pairs(row_has_drill) do
      if math.abs(row - s) <= street_reach then needed = true break end
    end
    if needed then
      local last_placed = nil
      local col = bc_min - 2
      while col <= bc_max + 2 do
        local x, y = rowcol_to_xy(s, col)
        local g, why = place_ghost(pole, x, y, defines.direction.north)
        if g then planned[#planned + 1] = g poles = poles + 1 last_placed = col
        elseif why ~= "already" and why ~= "cap" then pole_skip = pole_skip + 1 end
        col = col + pole_step
      end
      if last_placed and bc_max - last_placed > street_reach then
        local x, y = rowcol_to_xy(s, bc_max + 2)
        local g, why = place_ghost(pole, x, y, defines.direction.north)
        if g then planned[#planned + 1] = g poles = poles + 1
        elseif why ~= "already" and why ~= "cap" then pole_skip = pole_skip + 1 end
      end
    end
    s = s + 2 * S
  end

  local covered_n = 0
  for _ in pairs(covered) do covered_n = covered_n + 1 end
  local cover_pct = math.floor(covered_n / n_ore * 100 + 0.5)
  if drills == 0 and belts == 0 and poles == 0 and pre_planned then
    -- Complete no-op re-run: every slot (drills, belts, poles) already there.
    remember_plan(character, planned)
    return true, string.format(
      "batch_create_ghost layout=mining_outpost: %s patch already planned (%d %s slot(s) kept) — proceed to batch_build_ghost use=last_plan",
      resource, already_drills, drill)
  end
  local detail = string.format(
    "planned %s outpost: %d %s (skip %d) + %d %s (skip %d) + %d %s (skip %d), coverage %d%% of %d tiles, flow=%s; need %dx %s + %dx %s + %dx %s — then batch_build_ghost use=last_plan (or batch_build_ghost)",
    resource, drills, drill, drill_skip, belts, belt, belt_skip, poles, pole, pole_skip,
    cover_pct, n_ore, flow_name, drills, drill, belts, belt, poles, pole)
  if already > 0 then detail = detail .. string.format("; %d slot(s) already planned or built (kept)", already) end
  if occupied > 0 then
    local parts, cap = {}, math.min(#occupant_list, 5)
    for i = 1, cap do parts[#parts + 1] = occupant_list[i] end
    detail = detail .. string.format(
      "; %d slot(s) OCCUPIED by %s%s — remove exactly those, then re-run (plan extends)",
      occupied, table.concat(parts, ", "),
      #occupant_list > cap and string.format(" (+%d more)", #occupant_list - cap) or "")
  end
  if total >= 1000 then detail = detail .. "; hit 1000-ghost cap — plan the rest with a shifted x/y window" end
  if drills >= max_drills then detail = detail .. string.format("; capped at max_drills=%d", max_drills) end
  local drill_recipe = force.recipes[drill]
  if not (drill_recipe and drill_recipe.enabled) then
    detail = detail .. string.format("; WARNING: %s not unlocked — research it before building", drill)
  end
  if wire < 2 * S then
    detail = detail .. string.format(
      "; note: parallel pole streets are %d apart (> %s wire %g) — bridge them at the belt exit or pass pole=substation for one grid",
      2 * S, pole, wire)
  end
  if not pole_known then
    detail = detail .. string.format(
      "; note: %s not in the base-game pole table (prototype getter unavailable) — conservative small-pole spacing used",
      pole)
  end
  remember_plan(character, planned)
  return true, detail
end

-- -------------------------------------------------------------------------
-- batch_insert(items? | item+count?, radius?) — GENERIC batch resupply action: push
-- items from inventory into nearby machines and containers.
--   * items=[{name,count},...] (or single item+count): each named item goes
--     to every nearby entity that accepts it — burners via their FUEL slot
--     when the item is an accepted fuel, chests/machine inputs otherwise.
--     count caps the amount per entity (default 10).
--   * WITHOUT items: smart mode — each device gets what it NEEDS: burners
--     take the best fuel they accept (fuel-category match, highest
--     fuel_value first), machines with a set recipe take carried
--     ingredients, labs take carried science packs, turrets take ammo.
-- radius default 48.
-- -------------------------------------------------------------------------
local function batch_action_fill(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(tonumber(p.radius) or 48, 128)

  -- Normalize requests: items list wins; single item+count is sugar.
  local requests = {}
  if type(p.items) == "table" and #p.items > 0 then
    for _, it in ipairs(p.items) do
      local n = type(it) == "table" and (it.name or it.item) or tostring(it)
      local c = type(it) == "table" and tonumber(it.count) or nil
      if n and n ~= "" then
        requests[#requests + 1] = {name = n, count = math.min(c or 10, 100)}
      end
    end
  elseif p.item and p.item ~= "" then
    requests[#requests + 1] = {name = p.item, count = math.min(tonumber(p.count) or 10, 100)}
  end
  for _, req in ipairs(requests) do
    if not prototypes.item[req.name] then
      return false, "batch_insert: unknown item '" .. tostring(req.name) .. "'"
    end
  end

  local function fuel_accepted_by(e, item)
    local ip = prototypes.item[item]
    if not (ip and ip.fuel_category) then return false end
    local proto = prototypes.entity[e.name]
    local burner = proto and proto.burner_prototype
    if not burner then return false end
    -- fuel_categories is a DICT {name=true} — iterate KEYS, not values.
    for c in pairs(burner.fuel_categories or {}) do
      if c == ip.fuel_category then return true end
    end
    return false
  end

  local function carried_fuels_accepted(e)
    -- Carried fuels this entity's burner accepts, best fuel_value first.
    local proto = prototypes.entity[e.name]
    local burner = proto and proto.burner_prototype
    if not burner then return {} end
    -- fuel_categories is a DICT {name=true} — batch_take KEYS.
    local cats = {}
    for c in pairs(burner.fuel_categories or {}) do cats[c] = true end
    local out = {}
    for _, it in ipairs(inv.get_contents()) do
      local ip = prototypes.item[it.name]
      if ip and ip.fuel_category and cats[ip.fuel_category] and it.count > 0 then
        out[#out + 1] = {name = it.name, value = ip.fuel_value or 0}
      end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    return out
  end

  local filled, used = 0, {}
  local function give(target, item, give_count, slot)
    local before = inv.get_item_count(item)
    local ok = AIActions.run(character, {
      action = "insert", item = item, count = give_count,
      position = target.position, radius = 1, inventory = slot,
    })
    local inserted = before - inv.get_item_count(item)
    if ok and inserted > 0 then
      filled = filled + 1
      used[item] = (used[item] or 0) + inserted
      return inserted
    end
    return 0
  end

  for _, e in ipairs(surface.find_entities_filtered{
    force = AICharacter.get_force(), position = character.position, radius = radius,
  }) do
    if e.valid and e.type ~= "character" then
      local fb = e.get_fuel_inventory and e.get_fuel_inventory()
      if fb and fb.valid then
        -- Burner: one fuel type per call. Explicit requests use the first
        -- listed fuel the device accepts; smart mode picks the best fuel.
        local choice, cap
        if #requests > 0 then
          for _, req in ipairs(requests) do
            if fuel_accepted_by(e, req.name) then choice, cap = req.name, req.count break end
          end
        else
          local fuels = carried_fuels_accepted(e)
          if fuels[1] then choice, cap = fuels[1].name, 10 end
        end
        if choice then
          local have = fb.get_item_count(choice)
          if have < cap then
            local give_n = math.min(cap - have, inv.get_item_count(choice))
            if give_n > 0 then give(e, choice, give_n, "fuel") end
          end
        end
      else
        -- Non-burner.
        if #requests > 0 then
          for _, req in ipairs(requests) do
            local carried = inv.get_item_count(req.name)
            if carried > 0 then
              local slot = (e.type == "lab" and "lab")
                or (e.type == "ammo-turret" and "ammo") or "input"
              give(e, req.name, math.min(req.count, carried), slot)
            end
          end
        else
          -- Smart mode: recipe ingredients / science packs / ammo.
          local wants = nil
          if e.type == "assembling-machine" or e.type == "furnace" then
            local r = e.get_recipe and e.get_recipe()
            if r then
              wants = {}
              for _, ing in ipairs(r.ingredients or {}) do
                if ing.type == "item" then wants[ing.name] = (ing.amount or 1) * 2 end
              end
            end
          elseif e.type == "lab" then
            wants = {}
            for _, it in ipairs(inv.get_contents()) do
              local ip = prototypes.item[it.name]
              if ip and ip.type == "tool" then wants[it.name] = 10 end
            end
          elseif e.type == "ammo-turret" then
            wants = {}
            for _, it in ipairs(inv.get_contents()) do
              local ip = prototypes.item[it.name]
              if ip and ip.type == "ammo" then wants[it.name] = 10 end
            end
          end
          if wants then
            for item, want in pairs(wants) do
              local carried = inv.get_item_count(item)
              if carried > 0 then
                local slot = (e.type == "lab" and "lab")
                  or (e.type == "ammo-turret" and "ammo") or "input"
                give(e, item, math.min(want, carried), slot)
              end
            end
          end
        end
      end
    end
  end

  if filled == 0 then
    return false, "batch_insert: nothing nearby accepted anything (wrong item, nothing needed, or out of range)"
  end
  local parts = {}
  for name, c in pairs(used) do parts[#parts + 1] = c .. "x " .. name end
  table.sort(parts)
  return true, string.format("filled %d slot(s): +%s", filled, table.concat(parts, ", "))
end

-- -------------------------------------------------------------------------
-- batch_take(items=[{name,count},...] | item+count, radius?) — GENERIC batch
-- fetch action: take EXACTLY the requested items from nearby containers
-- (any force — chests are the human↔AI sharing channel), nearest first.
-- There is deliberately NO take-everything mode; machines' internal slots
-- are never touched. Reports per-item totals and shortfalls.
-- -------------------------------------------------------------------------
local function batch_action_collect(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(tonumber(p.radius) or 32, 128)

  local requests = {}
  if type(p.items) == "table" and #p.items > 0 then
    for _, it in ipairs(p.items) do
      local n = type(it) == "table" and (it.name or it.item) or tostring(it)
      local c = type(it) == "table" and tonumber(it.count) or nil
      if n and n ~= "" and c and c >= 1 then
        requests[#requests + 1] = {name = n, remaining = math.min(c, 1000), taken = 0}
      end
    end
  elseif p.item and p.item ~= "" and tonumber(p.count) then
    requests[#requests + 1] = {name = p.item, remaining = math.min(tonumber(p.count), 1000), taken = 0}
  end
  if #requests == 0 then
    return false, "batch_take: pass items=[{name,count},...] or item+count (no take-everything mode)"
  end
  for _, req in ipairs(requests) do
    if not prototypes.item[req.name] then
      return false, "batch_take: unknown item '" .. tostring(req.name) .. "'"
    end
  end

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  table.sort(chests, function(a, b)
    local da = (a.position.x - character.position.x) ^ 2 + (a.position.y - character.position.y) ^ 2
    local db = (b.position.x - character.position.x) ^ 2 + (b.position.y - character.position.y) ^ 2
    return da < db
  end)

  local done, from = 0, {}
  for _, chest in ipairs(chests) do
    local open = false
    for _, req in ipairs(requests) do
      if req.remaining > 0 then open = true break end
    end
    if not open then break end
    if chest.valid then
      local ci = chest.get_inventory(defines.inventory.chest)
      if ci then
        local touched = false
        for _, req in ipairs(requests) do
          if req.remaining > 0 then
            local avail = ci.get_item_count(req.name)
            if avail > 0 then
              local before = inv.get_item_count(req.name)
              local ok = AIActions.run(character, {
                action = "take", item = req.name,
                position = chest.position, radius = 1,
                inventory = "chest", count = math.min(avail, req.remaining),
              })
              local n = inv.get_item_count(req.name) - before
              if ok and n > 0 then
                req.remaining = req.remaining - n
                req.taken = req.taken + n
                done = done + n
                touched = true
              end
            end
          end
        end
        if touched then
          from[#from + 1] = string.format("@{%d,%d}", math.floor(chest.position.x), math.floor(chest.position.y))
        end
      end
    end
  end

  if done == 0 then
    return false, "batch_take: none of the requested items found in containers within " .. radius .. " tiles"
  end
  local parts = {}
  for _, req in ipairs(requests) do
    if req.taken > 0 then
      parts[#parts + 1] = req.taken .. "x " .. req.name .. (req.remaining > 0 and (" (short " .. req.remaining .. ")") or "")
    end
  end
  return true, "collected " .. table.concat(parts, ", ") .. " — " .. #from .. " chest(s)"
end

-- -------------------------------------------------------------------------
-- batch_insert(radius?, keep?) — deposit excess inventory into a nearby
-- chest. Keeps `keep` of each item; deposits the rest. Use for inventory
-- management and AI→human resource sharing.
-- -------------------------------------------------------------------------
local function batch_action_deposit_to_chest(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local keep    = math.max(p.keep or 50, 0)
  local inv     = inv_of(character)

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "batch_insert: no chests within " .. radius .. " tiles"
  end

  local cp = character.position
  table.sort(chests, function(a, b)
    local da = (a.position.x - cp.x)^2 + (a.position.y - cp.y)^2
    local db = (b.position.x - cp.x)^2 + (b.position.y - cp.y)^2
    return da < db
  end)

  local deposited = {}
  -- item+count: deposit exactly `count` of ONE named item, keep the rest.
  if p.item and p.count then
    local want, remaining = p.item, tonumber(p.count) or 0
    for _, chest in ipairs(chests) do
      if chest.valid and remaining > 0 then
        local before = inv.get_item_count(want)
        local ok = AIActions.run(character, {
          action = "insert", item = want, count = remaining,
          position = chest.position, radius = 1, inventory = "chest",
        })
        local n = before - inv.get_item_count(want)
        if ok and n > 0 then
          deposited[want] = (deposited[want] or 0) + n
          remaining = remaining - n
        end
      end
    end
    if not next(deposited) then
      return false, "batch_insert: couldn't deposit " .. tostring(p.count) .. " " .. want
        .. " (not in inventory or chests full)"
    end
    local parts0 = {}
    for name, count in pairs(deposited) do parts0[#parts0 + 1] = count .. "x " .. name end
    return true, "deposited " .. table.concat(parts0, ", ")
  end
  for _, slot in ipairs(inv.get_contents()) do
    local name, have = slot.name, slot.count
    local excess = have - keep
    if excess > 0 then
      for _, chest in ipairs(chests) do
        if chest.valid then
          local before = inv.get_item_count(name)
          local ok = AIActions.run(character, {
            action = "insert", item = name, count = excess,
            position = chest.position, radius = 1, inventory = "chest",
          })
          local n = before - inv.get_item_count(name)
          if ok and n > 0 then
            deposited[name] = (deposited[name] or 0) + n
            excess = excess - n
          end
        end
        if excess <= 0 then break end
      end
    end
  end

  if not next(deposited) then
    return false, "batch_insert: nothing deposited (nothing exceeds keep=" .. keep .. " or chests full)"
  end
  local parts = {}
  for name, count in pairs(deposited) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "deposited " .. table.concat(parts, ", ")
end

-- Insert is the single batch counterpart of the insert atomic. `mode=deposit`
-- selects chest deposit; otherwise the default is smart machine refill.
local function batch_action_insert(character, p)
  local mode = tostring(p.mode or ""):lower()
  if mode == "deposit" or p.keep ~= nil then
    return batch_action_deposit_to_chest(character, p)
  end
  return batch_action_fill(character, p)
end

-- -------------------------------------------------------------------------
-- batch_build_ghost() — build the human's placed entity-ghosts (validated mechanic).
-- Highest-priority batch action: ghosts are explicit human intent.
-- -------------------------------------------------------------------------
local function batch_action_build_ghosts(character, p)
  p = p or {}
  local surface = character.surface
  local inv = inv_of(character)
  -- Scope the broad path so a batch never consumes unrelated ghosts belonging
  -- to another plan or another agent. With no scope, retain the historical
  -- whole-surface behavior for explicitly requested broad construction.
  local filter = {type = "entity-ghost", force = character.force}
  local scope = "surface"
  local a = p.area
  if type(a) == "table" then
    local lt = a.left_top or a[1]
    local rb = a.right_bottom or a[2]
    if lt and rb and tonumber(lt.x) and tonumber(lt.y) and tonumber(rb.x) and tonumber(rb.y) then
      filter.area = {{tonumber(lt.x), tonumber(lt.y)}, {tonumber(rb.x), tonumber(rb.y)}}
      scope = string.format("area {%g,%g}-{%g,%g}", tonumber(lt.x), tonumber(lt.y), tonumber(rb.x), tonumber(rb.y))
    elseif tonumber(a.x) and tonumber(a.y) and tonumber(a.width) and tonumber(a.height) then
      local w, h = tonumber(a.width), tonumber(a.height)
      filter.area = {{a.x - w / 2, a.y - h / 2}, {a.x + w / 2, a.y + h / 2}}
      scope = string.format("area {%g,%g}+{%g,%g}", tonumber(a.x), tonumber(a.y), w, h)
    else
      return false, "batch_build_ghost: area needs left_top/right_bottom or x,y,width,height"
    end
  elseif p.position or (p.x ~= nil and p.y ~= nil) then
    local pos = p.position or {x = tonumber(p.x), y = tonumber(p.y)}
    local radius = math.min(tonumber(p.radius) or 96, 1000)
    filter.position, filter.radius = pos, radius
    scope = string.format("radius %g around {%g,%g}", radius, pos.x, pos.y)
  end
  if p.name and p.name ~= "" then filter.ghost_name = p.name end
  local ghosts = surface.find_entities_filtered(filter)
  if #ghosts == 0 then return false, "batch_build_ghost: no ghosts in " .. scope end

  -- Find nearest ghost so we can teleport to it.
  local nearest, nd = nil, math.huge
  for _, g in ipairs(ghosts) do
    if g.valid then
      local dx = g.position.x - character.position.x
      local dy = g.position.y - character.position.y
      local d = dx * dx + dy * dy
      if d < nd then nd = d; nearest = g end
    end
  end
  if nearest then
    -- Teleport to a spot near the nearest ghost cluster so revive() can fire.
    local tp = surface.find_non_colliding_position(
      "character", {x = nearest.position.x + 3, y = nearest.position.y + 3}, 12, 0.5)
    if tp then character.teleport(tp) end
  end

  local built = 0
  local built_ents, missing = {}, {}
  for _, g in ipairs(ghosts) do
    if g.valid then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      if item and inv.get_item_count(item) > 0 then
        local ghost_name = g.ghost_name
        local pos = {x = g.position.x, y = g.position.y}
        local ok = AIActions.run(character, {
          action = "build_ghost", name = ghost_name, position = pos, radius = 0.4,
        })
        if ok then
          local built_here = surface.find_entities_filtered{
            name = ghost_name, position = pos, radius = 0.4, force = character.force,
          }
          local ent = built_here[1]
          built = built + 1
          if ent and ent.valid then built_ents[#built_ents + 1] = ent end
        end
      elseif item then
        missing[item] = (missing[item] or 0) + 1
      end
    end
  end

  local parts = {}
  for it, c in pairs(missing) do parts[#parts + 1] = c .. "x " .. it end
  local detail = string.format("built %d ghost(s)", built)
  if #parts > 0 then detail = detail .. "; need items: " .. table.concat(parts, ", ") end
  if built == 0 and #parts == 0 then return false, "batch_build_ghost: no buildable ghosts" end
  -- Post-build review (mandatory): status buckets of everything just built,
  -- problem entities listed; remember the batch as batch_review_build's default.
  if built > 0 then
    remember_build(character, built_ents)
    detail = detail .. "; " .. audit_detail(audit_entities(character, built_ents))
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- batch_mine() — mine everything the human marked for deconstruction
-- (buildings, trees, rocks). SECOND priority after batch_build_ghost: a
-- deconstruction mark is explicit human "remove this" intent, the mirror of a
-- ghost. Unlike ghosts/ore, these targets HAVE collision, so teleporting
-- adjacent (the batch_mine pattern) is safe — find_non_colliding_position lands the
-- character beside the target, not on it, and mine_entity collects the products.
-- -------------------------------------------------------------------------
local function batch_action_deconstruct(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(p.radius or 96, 200)
  local marked = surface.find_entities_filtered{
    to_be_deconstructed = true, position = character.position, radius = radius, limit = 100}
  if #marked == 0 then
    return false, "batch_mine: nothing marked for deconstruction within " .. radius .. " tiles"
  end

  -- Nearest-first so the character walks an efficient path and stays near base.
  local cp = character.position
  table.sort(marked, function(a, b)
    local dax, day = a.position.x - cp.x, a.position.y - cp.y
    local dbx, dby = b.position.x - cp.x, b.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local removed, skipped = 0, 0
  for _, m in ipairs(marked) do
    if m.valid and m ~= character then
      if not m.minable then
        skipped = skipped + 1
      else
        local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5)
        if sp then character.teleport(sp) end
        local ok = AIActions.run(character, {
          action = "mine", name = m.name, position = m.position, radius = 1,
        })
        if ok and not m.valid then
          removed = removed + 1
        elseif m.valid then
          break  -- inventory full or out of reach — stop rather than spin
        end
      end
    end
  end

  if removed == 0 then
    if skipped > 0 then return false, "batch_mine: marked objects can't be mined (unminable)" end
    return false, "batch_mine: couldn't mine any marked object (inventory full?)"
  end
  local detail = string.format("deconstructed %d marked object(s)", removed)
  if skipped > 0 then detail = detail .. string.format("; %d unminable skipped", skipped) end
  return true, detail
end

-- -------------------------------------------------------------------------
-- batch_mine(area|position+radius, kinds?) — clear TERRAIN so a planned
-- layout can go down on flat ground. Authorized to act WITHOUT a human
-- deconstruction mark, but strictly limited to natural obstacles: trees,
-- minable rocks, and (reported-only) cliffs. Player-built entities are only
-- touched when they are explicitly marked for deconstruction (kinds=marked).
-- Regions: area={left_top={x,y},right_bottom={x,y}}, or x,y+width,height
-- (centred box), or position+radius. Bounded per call; re-run while
-- remaining > 0.
-- -------------------------------------------------------------------------
local function batch_action_clear_area(character, p)
  -- A file-backed cleanup may contain many regions. Process them through the
  -- same bounded single-region operation so a large cleanup is resumable and
  -- each region keeps the existing safety rules.
  if type(p.areas) == "table" and #p.areas > 0 then
    local details, cleared = {}, 0
    for i, region in ipairs(p.areas) do
      if type(region) ~= "table" then
        details[#details + 1] = string.format("area #%d invalid", i)
      else
        local one = {}
        for k, v in pairs(p) do if k ~= "areas" then one[k] = v end end
        if region.area then
          one.area = region.area
        elseif region.position then
          one.position, one.radius = region.position, region.radius
        else
          for k, v in pairs(region) do one[k] = v end
        end
        local ok, detail = batch_action_clear_area(character, one)
        details[#details + 1] = string.format("area #%d: %s", i, detail or "")
        if ok then cleared = cleared + 1 end
      end
    end
    if cleared == 0 then return false, "batch_mine: no region cleared; " .. table.concat(details, " | ") end
    return true, string.format("cleared %d/%d region(s); %s", cleared, #p.areas, table.concat(details, " | "))
  end

  local surface = character.surface
  local inv = inv_of(character)

  local lt, rb
  if type(p.area) == "table" then
    local a = p.area
    local a_lt = a.left_top or a[1]
    local a_rb = a.right_bottom or a[2]
    if not (a_lt and a_rb and a_lt.x and a_lt.y and a_rb.x and a_rb.y) then
      return false, "batch_mine: area needs {left_top={x,y}, right_bottom={x,y}}"
    end
    lt, rb = {x = tonumber(a_lt.x), y = tonumber(a_lt.y)}, {x = tonumber(a_rb.x), y = tonumber(a_rb.y)}
  elseif p.x ~= nil and p.y ~= nil then
    local w = math.min(tonumber(p.width) or 64, 256)
    local h = math.min(tonumber(p.height) or 64, 256)
    lt = {x = tonumber(p.x) - w / 2, y = tonumber(p.y) - h / 2}
    rb = {x = tonumber(p.x) + w / 2, y = tonumber(p.y) + h / 2}
  else
    local c = p.position or character.position
    local r = math.min(tonumber(p.radius) or 32, 128)
    lt = {x = c.x - r, y = c.y - r}
    rb = {x = c.x + r, y = c.y + r}
  end
  local area = {{lt.x, lt.y}, {rb.x, rb.y}}

  local kinds = {}
  for k in tostring(p.kinds or "trees,rocks,marked"):gmatch("[^,]+") do
    kinds[k:match("^%s*(.-)%s*$")] = true
  end

  local targets = {}
  local function add_all(list, kind)
    for _, e in ipairs(list) do
      if e.valid and e ~= character then targets[#targets + 1] = {e = e, kind = kind} end
    end
  end
  if kinds.trees then
    add_all(surface.find_entities_filtered{area = area, type = "tree"}, "tree")
  end
  if kinds.rocks then
    for _, e in ipairs(surface.find_entities_filtered{area = area, type = "simple-entity"}) do
      if e.valid and e.minable then targets[#targets + 1] = {e = e, kind = "rock"} end
    end
  end
  if kinds.marked then
    add_all(surface.find_entities_filtered{area = area, to_be_deconstructed = true}, "marked")
  end
  local cliffs = #(surface.find_entities_filtered{area = area, type = "cliff"})

  if #targets == 0 then
    local msg = "batch_mine: nothing to clear in region"
    if cliffs > 0 then msg = msg .. string.format(" (%d cliff(s) need cliff explosives)", cliffs) end
    return true, msg
  end

  local cp = character.position
  local start_pos = {x = cp.x, y = cp.y}
  table.sort(targets, function(a, b)
    local dax, day = a.e.position.x - cp.x, a.e.position.y - cp.y
    local dbx, dby = b.e.position.x - cp.x, b.e.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local removed, by_kind, full = 0, {}, false
  for i, t in ipairs(targets) do
    if i > 60 then break end  -- bounded per call; report the remainder
    local m = t.e
    if m.valid then
      local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5)
      if sp then character.teleport(sp) end
      AIActions.run(character, {
        action = "mine", name = m.name, position = m.position, radius = 1,
      })
      if not m.valid then
        removed = removed + 1
        by_kind[t.kind] = (by_kind[t.kind] or 0) + 1
      else
        full = true  -- unminable or inventory full — stop rather than spin
        break
      end
    end
  end

  -- Restore the character to where it started: clearing must not leave the
  -- agent teleported away from its work site (multi-agent surprise).
  if character.valid then
    local back = surface.find_non_colliding_position("character", start_pos, 3, 0.5)
    if back then character.teleport(back) end
  end

  local remaining = 0
  for _, t in ipairs(targets) do
    if t.e.valid then remaining = remaining + 1 end
  end

  if removed == 0 then
    return false, "batch_mine: couldn't clear anything (inventory full? batch_insert first)"
  end
  local parts = {}
  for k, c in pairs(by_kind) do parts[#parts + 1] = c .. "x " .. k end
  table.sort(parts)
  local detail = string.format("cleared %d obstacle(s) (%s)", removed, table.concat(parts, ", "))
  if remaining > 0 then
    detail = detail .. string.format("; %d remaining in region — run batch_mine again", remaining)
  end
  if full then detail = detail .. " (stopped: inventory full — batch_insert, then retry)" end
  if cliffs > 0 then
    detail = detail .. string.format("; %d cliff(s) untouched (need cliff explosives)", cliffs)
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- Mine is the single batch counterpart of the mine atomic. Select a workflow
-- explicitly when the input is ambiguous: gather, deconstruct, or clear.
local function batch_action_mine(character, p)
  local mode = tostring(p.mode or ""):lower()
  if mode == "gather" or (mode == "" and p.item and not p.area and p.x == nil and p.y == nil) then
    return batch_action_gather(character, p)
  end
  if mode == "deconstruct" or p.marked == true then
    return batch_action_deconstruct(character, p)
  end
  return batch_action_clear_area(character, p)
end

-- batch_create_ghost(entities, replace?) — lay down a WHOLE layout as entity
-- ghosts in one call: scan_area → plan → batch_mine → batch_create_ghost →
-- batch_build_ghost. Each entry: {name="transport-belt", x=10, y=20,
-- direction="east"}. Coordinates follow the EXACT-coordinate contract (see
-- aligned_position — rotation-aware, no snapping); misaligned entries are
-- rejected with the nearest legal value. Ghost semantics match GUI
-- blueprints (trees/ghost fields overlappable, water rejected). Nothing is
-- consumed — batch_mine/craft happens when batch_build_ghost executes
-- the plan.
-- -------------------------------------------------------------------------
local function batch_action_plan_blueprint(character, p)
  local list = p.entities
  if type(list) ~= "table" or #list == 0 then
    return false, "batch_create_ghost: pass entities=[{name,x,y,direction?}, ...]"
  end
  if #list > 500 then
    return false, "batch_create_ghost: at most 500 entities per call (" .. #list .. " given)"
  end
  local surface = character.surface

  local placed, skipped, planned = 0, {}, {}
  for i, e in ipairs(list) do
    local name = type(e) == "table" and (e.name or e.item) or nil
    local x = type(e) == "table" and tonumber(e.x) or nil
    local y = type(e) == "table" and tonumber(e.y) or nil
    local reason = nil
    if not (name and x and y) then
      reason = "entry needs name, x, y"
    elseif not prototypes.entity[name] then
      reason = "unknown entity '" .. tostring(name) .. "'"
    else
      -- Exact-coordinate contract: NO snapping. Rotation-aware parity (see
      -- aligned_position): misaligned entries are REJECTED with the nearest
      -- legal coordinate so the caller fixes them explicitly.
      local dir = AIActions.DIRECTION_MAP[tostring(e.direction or "north"):lower()]
        or defines.direction.north
      local pos, align_err = aligned_position(name, x, y, dir)
      if not pos then
        reason = align_err
      else
        local ok = AIActions.run(character, {
          action = "create_ghost", name = name, position = pos, direction = e.direction,
        })
        if ok then
          placed = placed + 1
          local ghost = surface.find_entities_filtered{
            type = "entity-ghost", ghost_name = name, position = pos, radius = 0.1, force = character.force,
          }[1]
          if ghost then planned[#planned + 1] = ghost end
        else
          reason = string.format("blocked at {%.1f,%.1f}", pos.x, pos.y)
        end
      end
    end
    if reason then
      skipped[#skipped + 1] = {index = i, name = name, reason = reason}
    end
  end

  local detail = string.format("planned %d ghost(s)", placed)
  if #skipped > 0 then
    detail = detail .. string.format("; skipped %d", #skipped)
    for i = 1, math.min(#skipped, 3) do
      local s = skipped[i]
      detail = detail .. string.format(" [%s #%d: %s]", tostring(s.name), s.index, s.reason)
    end
  end
  if placed == 0 then
    return false, "batch_create_ghost: no ghosts placed — " .. detail
  end
  remember_plan(character, planned)
  detail = detail .. " — run batch_build_ghost when you hold the items"
  return true, detail
end

local function batch_action_create_ghost(character, p)
  if p.layout == "mining_outpost" then
    if p.entities then return false, "batch_create_ghost: choose layout or entities" end
    return batch_action_plan_mining_outpost(character, p)
  end
  if p.layout then return false, "batch_create_ghost: unknown layout " .. tostring(p.layout) end
  return batch_action_plan_blueprint(character, p)
end

-- -------------------------------------------------------------------------
-- batch_build_ghost supports broad scopes and explicit ghost lists.
-- -------------------------------------------------------------------------
-- batch_build_ghost(entities | use="last_plan") — PRECISE ghost executor: builds
-- ONLY the listed entities that already exist as ghosts (batch_create_ghost or
-- batch_create_ghost layout=mining_outpost first). Nothing is built that wasn't ghosted, so
-- mixed-agent ghost fields stay untouched — this is the scoped alternative
-- to batch_build_ghost. Entries must match the ghost's exact aligned position
-- (and direction when given); inventory is pre-checked ATOMICALLY (any
-- shortage builds nothing). use="last_plan" executes the most recent
-- batch_create_ghost layout=mining_outpost of THIS character from the mod-side registry — no
-- coordinates round-trip through the caller (cap 1000 there vs 500 for
-- explicit lists). Ends with the post-build audit; the batch becomes
-- batch_review_build's default.
-- -------------------------------------------------------------------------
local function batch_action_place(character, p)
  local list = p.entities
  local use = tostring(p.use or ""):lower()
  if use ~= "" then
    if list ~= nil then
      return false, "batch_build_ghost: pass either entities or use=last_plan, not both"
    end
    if use ~= "last_plan" then
      return false, "batch_build_ghost: unknown use '" .. use .. "' (only last_plan)"
    end
    local rec = storage.ai_last_plan and storage.ai_last_plan[character.unit_number]
    if not rec then
      return false, "batch_build_ghost: no plan on record — run batch_create_ghost layout=mining_outpost first"
    end
    list = {}
    for _, g in ipairs(rec.entries) do
      if g.valid and g.type == "entity-ghost" then
        list[#list + 1] = {name = g.ghost_name, x = g.position.x, y = g.position.y}
      end
    end
    if #list == 0 then
      return false, "batch_build_ghost: last plan has no live ghosts (all built or cleared?)"
    end
  end
  if type(list) ~= "table" or #list == 0 then
    return false, "batch_build_ghost: pass entities=[{name,x,y,direction?}, ...] or use=last_plan"
  end
  local cap = use ~= "" and 1000 or 500
  if #list > cap then
    return false, "batch_build_ghost: at most " .. cap .. " entities per call (" .. #list .. " given)"
  end
  local inv = inv_of(character)
  local surface = character.surface

  -- Pass 1: match every entry to an existing ghost at that exact position.
  local entries, skipped = {}, {}
  for i, e in ipairs(list) do
    local name = type(e) == "table" and (e.name or e.item) or nil
    local x = type(e) == "table" and tonumber(e.x) or nil
    local y = type(e) == "table" and tonumber(e.y) or nil
    local dir_given = type(e) == "table" and e.direction ~= nil or false
    local dir_name = type(e) == "table" and tostring(e.direction or "north"):lower() or "north"
    local dir = AIActions.DIRECTION_MAP[dir_name] or defines.direction.north
    local reason, pos, ghost
    if not (name and x and y) then
      reason = "entry needs name, x, y"
    else
      pos, reason = aligned_position(name, x, y, dir)
      if pos then
        for _, g in ipairs(surface.find_entities_filtered{
          type = "entity-ghost", ghost_name = name, position = pos, radius = 0.4,
          force = character.force,
        }) do
          if g.valid then ghost = g break end
        end
        if not ghost then
          reason = string.format("no %s ghost at {%.1f,%.1f} — batch_create_ghost first", name, pos.x, pos.y)
        elseif dir_given and ghost.direction ~= dir then
          reason = string.format("direction mismatch at {%.1f,%.1f} (ghost %d, asked %d)",
            pos.x, pos.y, ghost.direction, dir)
        end
      end
    end
    if ghost and not reason then
      entries[#entries + 1] = {name = name, ghost = ghost}
    else
      skipped[#skipped + 1] = {index = i, name = name, reason = reason or "unmatched"}
    end
  end

  -- Atomic inventory pre-check: any shortage builds NOTHING.
  local need = {}
  for _, en in ipairs(entries) do need[en.name] = (need[en.name] or 0) + 1 end
  local shortage = {}
  for item, c in pairs(need) do
    local have = inv.get_item_count(item)
    if have < c then
      shortage[#shortage + 1] = string.format("%dx %s (have %d)", c - have, item, have)
    end
  end
  if #shortage > 0 then
    return false, "batch_build_ghost: shortage — " .. table.concat(shortage, ", ") .. "; nothing placed"
  end

  -- Pass 2: revive the matched ghosts (batch_build_ghost semantics).
  local placed_ents = {}
  for i, en in ipairs(entries) do
    local pos = {x = en.ghost.position.x, y = en.ghost.position.y}
    local ok = AIActions.run(character, {
      action = "build_ghost", name = en.name, position = pos, radius = 0.4,
    })
    local built_here = surface.find_entities_filtered{
      name = en.name, position = pos, radius = 0.4, force = character.force,
    }
    local ent = built_here[1]
    if ok and ent and ent.valid then
      placed_ents[#placed_ents + 1] = ent
    else
      skipped[#skipped + 1] = {index = i, name = en.name,
        reason = string.format("revive failed at ghost {%.1f,%.1f}",
          pos.x, pos.y)}
    end
  end

  if #placed_ents == 0 then
    return false, "batch_build_ghost: nothing placed — " .. format_skipped(skipped)
  end
  remember_build(character, placed_ents)
  local detail = string.format("placed %d; skipped %d", #placed_ents, #skipped)
  if #skipped > 0 then detail = detail .. " " .. format_skipped(skipped) end
  return true, detail .. "; " .. audit_detail(audit_entities(character, placed_ents))
end

-- One public batch build action supports both broad scopes and explicit
-- entities/last_plan. The two execution paths share the build_ghost atomic.
local function batch_action_build_ghost(character, p)
  if p.entities ~= nil or p.use ~= nil then
    return batch_action_place(character, p)
  end
  return batch_action_build_ghosts(character, p)
end

-- -------------------------------------------------------------------------
-- batch_review_build(area | x,y+radius | last batch) — commissioning audit AFTER a
-- build: statuses of every allied entity in scope, problem entities listed
-- (no_power / no_fuel / flipped inserter …), leftover unbuilt ghosts counted.
-- Defaults to this character's last batch_build_ghost batch.
-- -------------------------------------------------------------------------
local function batch_action_review_build(character, p)
  local surface = character.surface
  local ents, scope

  local a = p.area
  if type(a) == "table" and tonumber(a.x) and tonumber(a.y)
      and tonumber(a.width) and tonumber(a.height) then
    local w, h = math.floor(a.width), math.floor(a.height)
    local x0, y0 = math.floor(a.x - w / 2), math.floor(a.y - h / 2)
    local ar = {{x0, y0}, {x0 + w, y0 + h}}
    ents = surface.find_entities_filtered{area = ar, force = character.force}
    scope = string.format("area {%d,%d}+{%d,%d}", x0, y0, w, h)
    local ghosts_left = surface.count_entities_filtered{area = ar, type = "entity-ghost"}
    if ghosts_left > 0 then
      scope = scope .. "; " .. ghosts_left .. " ghost(s) still unbuilt"
    end
  elseif tonumber(p.x) and tonumber(p.y) then
    local r = math.min(tonumber(p.radius) or 64, 200)
    local center = {x = tonumber(p.x), y = tonumber(p.y)}
    ents = surface.find_entities_filtered{position = center, radius = r, force = character.force}
    scope = string.format("radius %d around {%g,%g}", r, center.x, center.y)
    local ghosts_left = surface.count_entities_filtered{position = center, radius = r, type = "entity-ghost"}
    if ghosts_left > 0 then
      scope = scope .. "; " .. ghosts_left .. " ghost(s) still unbuilt"
    end
  else
    local last = storage.ai_last_build and storage.ai_last_build[character.unit_number]
    if not last then
      return false, "batch_review_build: pass area={x,y,width,height} or x/y(+radius); no previous batch on record"
    end
    ents = {}
    for _, rec in ipairs(last.entries) do
      local found = surface.find_entities_filtered{
        position = {x = rec.x, y = rec.y}, radius = 1,
        name = rec.name, force = character.force,
      }
      for _, e in ipairs(found) do ents[#ents + 1] = e end
    end
    scope = string.format("last batch @tick %d (%d entries)", last.tick, #last.entries)
  end

  local audit = audit_entities(character, ents)
  if audit.total == 0 then
    return false, "batch_review_build: nothing to audit in " .. scope
  end
  return #audit.problems == 0, scope .. "; " .. audit_detail(audit)
end

-- -------------------------------------------------------------------------
-- batch_remove_ghost(area | x,y+radius | name?) — batch-remove entity ghosts
-- (blueprint leftovers, mis-planned layouts). Scope: explicit area, or
-- x/y+radius, or radius (default 96) around the character. Optional `name`
-- filters by ghost entity name. Never touches real buildings.
-- -------------------------------------------------------------------------
local function batch_action_clear_ghosts(character, p)
  local surface = character.surface
  local filter = {type = "entity-ghost", force = character.force}
  local scope
  local a = p.area
  if type(a) == "table" and tonumber(a.x) and tonumber(a.y)
      and tonumber(a.width) and tonumber(a.height) then
    local w, h = math.floor(a.width), math.floor(a.height)
    local x0, y0 = math.floor(a.x - w / 2), math.floor(a.y - h / 2)
    filter.area = {{x0, y0}, {x0 + w, y0 + h}}
    scope = string.format("area {%d,%d}+{%d,%d}", x0, y0, w, h)
  else
    local cx, cy = tonumber(p.x), tonumber(p.y)
    if not cx then cx = character.position.x end
    if not cy then cy = character.position.y end
    filter.position = {x = cx, y = cy}
    filter.radius = math.min(tonumber(p.radius) or 96, 1000)
    scope = string.format("radius %d around {%g,%g}", filter.radius, cx, cy)
  end
  if p.name and p.name ~= "" then filter.ghost_name = p.name end

  local ghosts = surface.find_entities_filtered(filter)
  local n = 0
  for _, g in ipairs(ghosts) do
    if g.valid then
      local ok = AIActions.run(character, {
        action = "remove_ghost", name = g.ghost_name, position = g.position, radius = 0.4,
      })
      if ok then n = n + 1 end
    end
  end
  if n == 0 then return false, "batch_remove_ghost: no ghosts in " .. scope end
  return true, string.format("cleared %d ghost(s) in %s", n, scope)
end

local function batch_action_remove_ghost(character, p)
  return batch_action_clear_ghosts(character, p)
end

local function batch_action_pickup(character, p)
  local limit = math.min(tonumber(p.count) or 100, 500)
  local picked = 0
  for _ = 1, limit do
    local ok = AIActions.run(character, {
      action = "pickup", position = p.position, radius = p.radius or 3,
    })
    if not ok then break end
    picked = picked + 1
  end
  if picked == 0 then return false, "batch_pickup: no loose ground items in range" end
  return true, string.format("picked up %d ground stack(s)", picked)
end

-- -------------------------------------------------------------------------
-- Registry + required params (mirrored in the bridge router prompt/validation)
-- -------------------------------------------------------------------------
AIBatchActions.REGISTRY = {
  batch_build_ghost      = batch_action_build_ghost,
  batch_mine             = batch_action_mine,
  batch_create_ghost     = batch_action_create_ghost,
  batch_review_build     = batch_action_review_build,
  batch_remove_ghost     = batch_action_remove_ghost,
  batch_insert           = batch_action_insert,
  batch_take             = batch_action_collect,
  batch_pickup           = batch_action_pickup,
}

-- -------------------------------------------------------------------------
-- Unified executor: every response entry uses {action=...}. Dispatch each
-- batch or atomic action and collect E1 results.
-- -------------------------------------------------------------------------
-- Run a single entry.
-- Batch actions live in AIBatchActions.REGISTRY, atomic actions in AIActions.
-- The single "action" key dispatches both kinds with error isolation.
local function run_entry(character, entry)
  local ok, detail, label
  local requested = entry.action
  local canonical = AIBatchActions.canonical(requested)
  local compound = entry.action and AIBatchActions.REGISTRY[canonical] and canonical or nil
  if compound then
    label = "action:" .. tostring(compound)
    local handler = AIBatchActions.REGISTRY[compound]
    if handler then
      local call_ok, rok, rdetail = pcall(handler, character, entry)
      if not call_ok then ok, detail = false, "error: " .. tostring(rok)
      else ok, detail = (rok ~= false), rdetail end
    else
      ok, detail = false, "unknown action '" .. tostring(compound) .. "'"
    end
  elseif entry.action then
    label = entry.action
    ok, detail = AIActions.run(character, entry)
  else
    label = "?"
    ok, detail = false, "entry needs an 'action' key"
  end
  return (ok ~= false), detail, label
end

function AIBatchActions.execute(character, entries)
  if not character or not character.valid then return end
  local results = {}
  for _, entry in ipairs(entries) do
    local ok, detail, label = run_entry(character, entry)
    results[#results + 1] = {action = label, ok = ok, detail = detail}
  end
  storage.ai_player.memory.last_action_results = results
end

-- Single-entry runner for external (RCON/remote) callers. Same dispatch and
-- error isolation as execute(), but returns (ok, detail) directly instead of
-- recording into memory. Used by the "ai_player" remote interface (control.lua).
function AIBatchActions.run(character, entry)
  if not character or not character.valid then
    return false, "no valid character"
  end
  local ok, detail = run_entry(character, entry)
  return ok, detail or ""
end

return AIBatchActions
