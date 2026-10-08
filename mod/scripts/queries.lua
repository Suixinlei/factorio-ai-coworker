-- Read-only world/prototype queries for external callers (the MCP server via
-- the "ai_player" remote interface; see control.lua). Where skills DO things,
-- queries only LOOK — none of these mutate game state.
--
-- Each query gets (ctx, params):
--   ctx    = {surface, force, character}  — character may be nil; queries that
--            need a position fall back to it only when x/y are not given.
--   params = flat table from the caller (numbers/strings).
-- All queries return a JSON-serialisable table; {error = "..."} on failure.
-- Dispatch is pcall-guarded in AIQueries.run so a bad query never crashes the mod.

AIQueries = {}

local REGISTRY = {}

local function num(v, default) return tonumber(v) or default end
local function round1(n) return math.floor(n * 10 + 0.5) / 10 end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Resolve the query's center point: explicit x/y (flat or {x,y} table) beats
-- character position, so both {"x":1,"y":2} and {"position":{"x":1,"y":2}} work.
local function center_of(ctx, p)
  local px, py = p.x, p.y
  if (px == nil or py == nil) and type(p.position) == "table" then
    px, py = p.position.x, p.position.y
  end
  if px ~= nil and py ~= nil then return {x = tonumber(px), y = tonumber(py)} end
  if ctx.character then return ctx.character.position end
  return nil
end

-- -------------------------------------------------------------------------
-- get_recipe — ingredients/products/craft time for one recipe, plus whether
-- this force has it unlocked and whether it is hand-craftable. Fills the gap
-- left by perception.craftable (names only): the model can now plan multi-step
-- crafts ("gear needs 2 iron-plate") instead of guessing.
-- -------------------------------------------------------------------------
REGISTRY.get_recipe = function(ctx, p)
  local name = p.name or p.recipe
  if not name then return {error = "missing recipe name (pass name or recipe)"} end
  local proto = prototypes.recipe[name]
  if not proto then return {error = "no recipe named '" .. tostring(name) .. "'"} end

  local ingredients = {}
  for _, ing in ipairs(proto.ingredients or {}) do
    ingredients[#ingredients + 1] = {name = ing.name, amount = ing.amount, type = ing.type}
  end
  local products = {}
  for _, pr in ipairs(proto.products or {}) do
    products[#products + 1] = {name = pr.name, amount = pr.amount or pr.amount_max, type = pr.type}
  end

  local frecipe = ctx.force.recipes[name]
  return {
    name           = name,
    category       = proto.category,
    energy         = proto.energy,   -- craft time in seconds at crafting speed 1
    ingredients    = ingredients,
    products       = products,
    enabled        = (frecipe and frecipe.enabled) or false,
    -- Only plain "crafting"-category recipes can be hand-crafted by a character;
    -- smelting/chemistry/etc. need the right machine.
    hand_craftable = proto.category == "crafting",
  }
end

-- -------------------------------------------------------------------------
-- get_resource_patch — bounding box, tile count, and total amount of a
-- resource around a point (FLE-style get_resource_patch). Complements
-- perception.nearby_resources (which only reports the nearest tile): with the
-- bbox the model can plan drill rows along the patch instead of guessing.
--
-- radius=0 or all=true scans EVERY generated chunk of the current surface (no
-- radius cap — megabase planning needs whole-map resource awareness) and
-- returns ALL distinct patches, clustered by tile adjacency, nearest-first.
-- Fluid resources (crude-oil) are merged with a looser linkage because their
-- wells are scattered with gaps.
-- -------------------------------------------------------------------------

-- Flood-fill resource tiles (keyed by integer tile coords) into contiguous
-- clusters. Returns a list of tile-index lists.
local function cluster_resource_tiles(ents)
  local present, order = {}, {}
  for i, e in ipairs(ents) do
    local key = math.floor(e.position.x) .. "," .. math.floor(e.position.y)
    if not present[key] then
      present[key] = i
      order[#order + 1] = key
    end
  end
  local clusters = {}
  for _, seed in ipairs(order) do
    if present[seed] then
      local members, stack = {}, {seed}
      present[seed] = nil
      while #stack > 0 do
        local key = table.remove(stack)
        members[#members + 1] = key
        local sx, sy = key:match("^(-?%d+),(-?%d+)$")
        sx, sy = tonumber(sx), tonumber(sy)
        for dx = -1, 1 do for dy = -1, 1 do
          local nk = (sx + dx) .. "," .. (sy + dy)
          if present[nk] then
            present[nk] = nil
            stack[#stack + 1] = nk
          end
        end end
      end
      clusters[#clusters + 1] = members
    end
  end
  return clusters
end

-- Merge clusters whose bounding boxes are within `link` tiles of each other
-- (crude-oil wells sit apart). Repeated until stable; cluster counts are small.
local function merge_nearby(clusters, boxes, link)
  local changed = true
  while changed do
    changed = false
    for i = 1, #clusters do
      for j = i + 1, #clusters do
        local a, b = boxes[i], boxes[j]
        if a and b
            and a.minx <= b.maxx + link and b.minx <= a.maxx + link
            and a.miny <= b.maxy + link and b.miny <= a.maxy + link then
          for _, k in ipairs(clusters[j]) do clusters[i][#clusters[i] + 1] = k end
          a.minx = math.min(a.minx, b.minx); a.maxx = math.max(a.maxx, b.maxx)
          a.miny = math.min(a.miny, b.miny); a.maxy = math.max(a.maxy, b.maxy)
          table.remove(clusters, j); table.remove(boxes, j)
          changed = true
          break
        end
      end
      if changed then break end
    end
  end
  return clusters, boxes
end

REGISTRY.get_resource_patch = function(ctx, p)
  local resource = p.resource
  if not resource then return {error = "missing resource name"} end
  if not prototypes.entity[resource] then
    return {error = "no resource prototype '" .. tostring(resource) .. "'"}
  end
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end

  local whole_map = (p.all == true) or (tonumber(p.radius) == 0)
  if whole_map then
    -- No area filter: the engine only has entities for generated chunks, so
    -- this is inherently limited to the explored map on the current surface.
    local ents = ctx.surface.find_entities_filtered{type = "resource", name = resource}
    if #ents == 0 then
      return {found = false, resource = resource, scope = "explored_map"}
    end
    local by_key = {}
    for _, e in ipairs(ents) do
      by_key[math.floor(e.position.x) .. "," .. math.floor(e.position.y)] = e
    end
    local clusters = cluster_resource_tiles(ents)
    local boxes = {}
    for ci, members in ipairs(clusters) do
      local box = {minx = math.huge, miny = math.huge, maxx = -math.huge, maxy = -math.huge}
      for _, key in ipairs(members) do
        local e = by_key[key]
        if e and e.valid then
          local rp = e.position
          if rp.x < box.minx then box.minx = rp.x end
          if rp.y < box.miny then box.miny = rp.y end
          if rp.x > box.maxx then box.maxx = rp.x end
          if rp.y > box.maxy then box.maxy = rp.y end
        end
      end
      boxes[ci] = box
    end
    if resource == "crude-oil" then
      clusters, boxes = merge_nearby(clusters, boxes, 24)
    end

    local patches = {}
    local grand_total, grand_tiles = 0, 0
    for ci, members in ipairs(clusters) do
      local total, cx, cy = 0, 0, 0
      local n = 0
      for _, key in ipairs(members) do
        local e = by_key[key]
        if e and e.valid then
          total = total + (e.amount or 0)
          cx = cx + e.position.x; cy = cy + e.position.y
          n = n + 1
        end
      end
      -- Skip depleted remnants: a cluster whose average amount per tile is
      -- ~1 is mined-out residue (ore tiles normally carry hundreds+), noise
      -- for whole-map planning.
      if n > 0 and total > n then
        local box = boxes[ci]
        local center_x, center_y = cx / n, cy / n
        patches[#patches + 1] = {
          tiles        = n,
          total_amount = total,
          center       = {x = math.floor(center_x), y = math.floor(center_y)},
          distance     = math.floor(dist({x = center_x, y = center_y}, center)),
          bounding_box = {
            left_top     = {x = math.floor(box.minx), y = math.floor(box.miny)},
            right_bottom = {x = math.ceil(box.maxx),  y = math.ceil(box.maxy)},
          },
        }
        grand_total = grand_total + total
        grand_tiles = grand_tiles + n
      end
    end
    table.sort(patches, function(a, b) return a.distance < b.distance end)
    local truncated = #patches > 64
    while #patches > 64 do table.remove(patches) end
    return {
      found        = true,
      resource     = resource,
      scope        = "explored_map",
      patch_count  = #patches,
      patches      = patches,
      truncated    = truncated or nil,
      total_tiles  = grand_tiles,
      total_amount = grand_total,
    }
  end

  local radius = math.min(num(p.radius, 48), 128)

  local ents = ctx.surface.find_entities_filtered{
    type = "resource", name = resource, position = center, radius = radius,
  }
  if #ents == 0 then
    return {found = false, resource = resource, radius = radius}
  end

  local minx, miny = math.huge, math.huge
  local maxx, maxy = -math.huge, -math.huge
  local total = 0
  local nearest, ndist = nil, math.huge
  for _, r in ipairs(ents) do
    if r.valid then
      local rp = r.position
      if rp.x < minx then minx = rp.x end
      if rp.y < miny then miny = rp.y end
      if rp.x > maxx then maxx = rp.x end
      if rp.y > maxy then maxy = rp.y end
      total = total + (r.amount or 0)
      local d = dist(rp, center)
      if d < ndist then ndist = d; nearest = rp end
    end
  end

  return {
    found        = true,
    resource     = resource,
    tiles        = #ents,
    total_amount = total,
    bounding_box = {
      left_top     = {x = math.floor(minx), y = math.floor(miny)},
      right_bottom = {x = math.ceil(maxx),  y = math.ceil(maxy)},
    },
    nearest          = {x = math.floor(nearest.x), y = math.floor(nearest.y)},
    nearest_distance = math.floor(ndist),
  }
end

-- -------------------------------------------------------------------------
-- can_place — would a manual build of `entity` at {x,y} succeed? Runs the SAME
-- checks the place primitive uses (special cases like offshore-pump-on-water
-- and drill-on-resource, then the authoritative manual build check), so a
-- can_place=true here means a subsequent place_entity will not be rejected.
-- -------------------------------------------------------------------------
REGISTRY.can_place = function(ctx, p)
  local entity = p.entity or p.item
  if not entity then return {error = "missing entity name (pass entity or item)"} end
  if not prototypes.entity[entity] then
    return {error = "no entity prototype '" .. tostring(entity) .. "'"}
  end
  local position = center_of(ctx, p)
  if not position then return {error = "no position — pass x,y (or position={x,y})"} end
  local dir = AIActions.DIRECTION_MAP[(p.direction or "north"):lower()]
    or defines.direction.north

  local problem = AIActions.placement_problem(ctx.surface, entity, position)
  if problem then return {can_place = false, reason = problem} end

  local ok = ctx.surface.can_place_entity{
    name      = entity,
    position  = position,
    direction = dir,
    force     = ctx.force,
    build_check_type = defines.build_check_type.manual,
  }
  return {
    can_place = ok,
    reason    = (not ok) and "blocked, misaligned, or wrong tile" or nil,
  }
end

-- -------------------------------------------------------------------------
-- nearest_buildable — nearest clear spot where `entity` fits, spiralling out
-- from a center (FLE nearest_buildable, via the engine's own collision search).
-- NOTE: only checks collision. Entities with placement RULES beyond collision
-- (mining drills need a resource patch, offshore pumps need water) should be
-- planned with get_resource_patch / can_place instead.
-- -------------------------------------------------------------------------
REGISTRY.nearest_buildable = function(ctx, p)
  local entity = p.entity or p.item
  if not entity then return {error = "missing entity name (pass entity or item)"} end
  if not prototypes.entity[entity] then
    return {error = "no entity prototype '" .. tostring(entity) .. "'"}
  end
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end
  local radius = math.min(num(p.radius, 32), 128)

  local pos = ctx.surface.find_non_colliding_position(entity, center, radius, 1)
  if not pos then
    return {found = false, entity = entity, radius = radius}
  end
  return {
    found    = true,
    entity   = entity,
    position = {x = round1(pos.x), y = round1(pos.y)},
    distance = math.floor(dist(pos, center)),
  }
end

-- -------------------------------------------------------------------------
-- inspect_entity — full perception-grade detail of ONE entity at/near {x,y}:
-- status, recipe, fuel/input/output contents, fluid connections, slots — the
-- same entry the autonomous router sees for nearby entities, queryable at any
-- position on the map (ai-companion building_info equivalent).
-- -------------------------------------------------------------------------
REGISTRY.inspect_entity = function(ctx, p)
  local position = center_of(ctx, p)
  if not position then return {error = "no position — pass x,y (or position={x,y})"} end
  local filter = {position = position, radius = math.min(num(p.radius, 4), 16)}
  if p.name and p.name ~= "" then filter.name = p.name end

  local best, bestd = nil, math.huge
  for _, e in ipairs(ctx.surface.find_entities_filtered(filter)) do
    if e.valid and e.type ~= "character" then
      local d = dist(e.position, position)
      if d < bestd then best, bestd = e, d end
    end
  end
  if not best then
    return {error = string.format("no entity within %d tiles of {%d,%d}",
      filter.radius, position.x, position.y)}
  end

  local entry = AIPerception.describe_entity(best, ctx.force)
  entry.health    = best.health and math.floor(best.health) or nil
  entry.force     = best.force and best.force.name or nil
  entry.direction = best.direction
  entry.minable   = best.minable
  return entry
end

-- -------------------------------------------------------------------------
-- get_enemies — enemies around a point, nearest-first with health and a
-- composition/threat summary (ai-companion world_enemies equivalent).
-- Threat: danger (>5 enemies), caution (1-5), safe (0).
-- -------------------------------------------------------------------------
REGISTRY.get_enemies = function(ctx, p)
  local center = center_of(ctx, p)
  if not center then return {error = "no position — pass x,y or spawn the character"} end
  local radius = math.min(num(p.radius, 50), 200)

  local ents = ctx.surface.find_entities_filtered{
    position = center, radius = radius, force = "enemy",
    type = {"unit", "unit-spawner", "turret"},
  }

  local list = {}
  local composition = {units = 0, spawners = 0, worms = 0}
  for _, e in ipairs(ents) do
    if e.valid then
      if     e.type == "unit"         then composition.units    = composition.units + 1
      elseif e.type == "unit-spawner" then composition.spawners = composition.spawners + 1
      else                                 composition.worms    = composition.worms + 1 end
      list[#list + 1] = {
        name       = e.name,
        type       = e.type,
        position   = {x = math.floor(e.position.x), y = math.floor(e.position.y)},
        health     = e.health and math.floor(e.health) or nil,
        max_health = e.max_health and math.floor(e.max_health) or nil,
        distance   = math.floor(dist(e.position, center)),
      }
    end
  end
  table.sort(list, function(a, b) return a.distance < b.distance end)
  while #list > 20 do table.remove(list) end

  local threat = "safe"
  if #ents > 5 then threat = "danger"
  elseif #ents > 0 then threat = "caution" end

  return {
    count        = #ents,
    threat_level = threat,
    composition  = composition,
    radius       = radius,
    enemies      = list,   -- nearest-first, capped at 20
  }
end

-- -------------------------------------------------------------------------
-- get_character_state — live embodiment state of the AI character, including
-- the HAND-CRAFTING QUEUE, which no other surface exposes (perception shows
-- inventory but not what is mid-craft). Essential for diagnosing "craft was
-- queued but nothing happened" — e.g. the phase-0 craft-trigger issue.
-- -------------------------------------------------------------------------
REGISTRY.get_character_state = function(ctx, p)
  local c = ctx.character
  if not c then return {error = "no ai character — spawn_ai_player first"} end

  local queue = {}
  local okq, q = pcall(function() return c.crafting_queue end)
  if okq and q then
    for _, item in ipairs(q) do
      queue[#queue + 1] = {recipe = item.recipe, count = item.count}
    end
  end

  local home = storage.ai_player and storage.ai_player.home_position
  return {
    position   = {x = round1(c.position.x), y = round1(c.position.y)},
    surface    = c.surface.name,
    force      = c.force.name,
    health     = math.floor(c.health),
    health_pct = math.floor((c.health / (c.max_health or 250)) * 100),
    is_walking = (c.walking_state and c.walking_state.walking) or false,
    is_mining  = (c.mining_state and c.mining_state.mining) or false,
    crafting_queue      = queue,
    crafting_queue_size = c.crafting_queue_size or 0,
    crafting_progress   = round1(c.crafting_queue_progress or 0),
    home = home and {
      position = {x = home.x, y = home.y},
      distance = math.floor(dist(c.position, home)),
    } or nil,
  }
end

-- -------------------------------------------------------------------------
-- get_chart_tags — chart tags (map labels) on the AI force's surface: both the
-- ones HUMANS place via the map GUI and the ones agents create through
-- set_annotation. This is the read side of the annotation channel — without
-- it, human map notes ("熔炉区", "油井") are invisible to AI players.
-- Optional x/y sorts by distance and fills `distance`; radius>0 filters to
-- that range, otherwise ALL tags on the surface are returned.
-- -------------------------------------------------------------------------
REGISTRY.get_chart_tags = function(ctx, p)
  local center = center_of(ctx, p)
  local radius = num(p.radius, 0)

  local list = {}
  for _, t in ipairs(ctx.force.find_chart_tags(ctx.surface)) do
    if t.valid then
      local d = center and math.floor(dist(t.position, center)) or nil
      if not center or radius <= 0 or (d and d <= radius) then
        local ok_icon, icon = pcall(function() return t.icon end)
        local ok_user, user = pcall(function()
          return t.last_user and t.last_user.name
        end)
        list[#list + 1] = {
          position  = {x = round1(t.position.x), y = round1(t.position.y)},
          text      = t.text or "",
          icon      = (ok_icon and type(icon) == "table" and icon.name) or nil,
          last_user = (ok_user and user) or nil,
          distance  = d,
        }
      end
    end
  end

  if center then
    table.sort(list, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
  else
    table.sort(list, function(a, b)
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      return a.position.y < b.position.y
    end)
  end
  return {count = #list, tags = list}
end

-- -------------------------------------------------------------------------
-- scan_area — THE map-perception query: a compressed tile grid of a rectangle
-- (centre defaults to the character; width×height tiles, capped at 128 per
-- side per call — tile several calls for bigger regions). Limited to the
-- current surface and to GENERATED (explored) chunks; unknown tiles are '?'.
--
-- Returns:
--   origin   = {x,y} tile coordinate of grid row 1, column 1 (top-left)
--   grid     = array of `height` strings, one char per tile:
--     '.' buildable land   '?' unexplored      'W' water
--     'T' tree  'R' rock   'C' cliff           'E' enemy structure
--     'B' allied building  'g' entity ghost
--     resources: 'i' iron-ore  'u' copper-ore  'c' coal  's' stone
--                'o' crude-oil 'U' uranium-ore 'x' other resource
--   entities = precise roster of allied buildings in the area
--              (name/type/position/direction), so the grid stays compact while
--              no information is lost; capped at 500 (truncated=true).
-- -------------------------------------------------------------------------
local SCAN_WATER_TILES = {"water", "deepwater", "water-green", "deepwater-green",
                          "water-shallow", "water-mud"}
local SCAN_RESOURCE_CHARS = {
  ["iron-ore"] = "i", ["copper-ore"] = "u", ["coal"] = "c", ["stone"] = "s",
  ["crude-oil"] = "o", ["uranium-ore"] = "U",
}

local DIR_NAMES = {
  [0] = "north", [1] = "north_northeast", [2] = "northeast", [3] = "east_northeast",
  [4] = "east", [5] = "east_southeast", [6] = "southeast", [7] = "south_southeast",
  [8] = "south", [9] = "south_southwest", [10] = "southwest", [11] = "west_southwest",
  [12] = "west", [13] = "west_northwest", [14] = "northwest", [15] = "north_northwest",
}

REGISTRY.scan_area = function(ctx, p)
  local surface = ctx.surface
  local center = center_of(ctx, p)
  if not center then
    center = {x = 0, y = 0}
  end
  if (tonumber(p.width) or 0) > 128 or (tonumber(p.height) or 0) > 128 then
    return {error = "scan_area: width/height capped at 128 per side — tile several calls for bigger regions"}
  end
  local w = math.min(math.max(math.floor(num(p.width, 64)), 1), 128)
  local h = math.min(math.max(math.floor(num(p.height, 64)), 1), 128)
  local ox = math.floor(center.x - w / 2)
  local oy = math.floor(center.y - h / 2)

  -- Row-major char cells; everything starts unexplored.
  local cells = {}
  for r = 1, h do
    local row = {}
    for c = 1, w do row[c] = "?" end
    cells[r] = row
  end

  -- Generated-chunk bitmap, computed FIRST: every feature pass below (water,
  -- resources, entities…) may only render inside GENERATED chunks. Previously
  -- find_tiles_filtered painted water over ungenerated chunks, so a rect could
  -- return 'W' tiles while explored_pct said 0 — grid and pct now cannot
  -- disagree, and ungenerated terrain is never queried at all.
  local generated_chunks = 0
  local total_chunks = 0
  local gen = {}
  local gx0, gy0, gx1, gy1
  local cx0, cy0 = math.floor(ox / 32), math.floor(oy / 32)
  local cx1, cy1 = math.floor((ox + w - 1) / 32), math.floor((oy + h - 1) / 32)
  for cx = cx0, cx1 do for cy = cy0, cy1 do
    total_chunks = total_chunks + 1
    if surface.is_chunk_generated({x = cx, y = cy}) then
      generated_chunks = generated_chunks + 1
      gen[cx .. "," .. cy] = true
      local tx0, ty0 = math.max(ox, cx * 32), math.max(oy, cy * 32)
      local tx1, ty1 = math.min(ox + w - 1, cx * 32 + 31), math.min(oy + h - 1, cy * 32 + 31)
      if not gx0 or tx0 < gx0 then gx0 = tx0 end
      if not gy0 or ty0 < gy0 then gy0 = ty0 end
      if not gx1 or tx1 > gx1 then gx1 = tx1 end
      if not gy1 or ty1 > gy1 then gy1 = ty1 end
    end
  end end

  -- Explored land: any tile inside a GENERATED chunk becomes buildable '.'.
  local function mark(tx, ty, ch)
    local c, r = tx - ox + 1, ty - oy + 1
    if c >= 1 and c <= w and r >= 1 and r <= h
        and gen[math.floor(tx / 32) .. "," .. math.floor(ty / 32)] then
      cells[r][c] = ch
    end
  end
  if gx0 then
    for ty = gy0, gy1 do for tx = gx0, gx1 do mark(tx, ty, ".") end end
  end

  -- Feature queries are clamped to the generated bounding box; when nothing
  -- in the rect is generated we skip them entirely (keeps '?' semantics and
  -- avoids touching ungenerated terrain).
  local query_area = gx0 and {{gx0, gy0}, {gx1 + 1, gy1 + 1}} or nil
  local legend_used, entities, truncated = {}, {}, false

  if query_area then
    for _, t in ipairs(surface.find_tiles_filtered{area = query_area, name = SCAN_WATER_TILES}) do
      mark(math.floor(t.position.x), math.floor(t.position.y), "W")
    end

    for _, e in ipairs(surface.find_entities_filtered{area = query_area, type = "resource"}) do
      if e.valid then
        local ch = SCAN_RESOURCE_CHARS[e.name] or "x"
        legend_used[ch] = e.name
        mark(math.floor(e.position.x), math.floor(e.position.y), ch)
      end
    end

    for _, e in ipairs(surface.find_entities_filtered{area = query_area, type = "tree"}) do
      if e.valid then mark(math.floor(e.position.x), math.floor(e.position.y), "T") end
    end
    for _, e in ipairs(surface.find_entities_filtered{area = query_area, type = "simple-entity"}) do
      if e.valid and e.minable then
        mark(math.floor(e.position.x), math.floor(e.position.y), "R")
      end
    end
    for _, e in ipairs(surface.find_entities_filtered{area = query_area, type = "cliff"}) do
      if e.valid then mark(math.floor(e.position.x), math.floor(e.position.y), "C") end
    end

    -- Precise allied-building roster + coarse grid marks. Natural categories
    -- (resource/tree/rock/cliff) were handled above; characters are skipped.
    -- Only entities owned by OUR force count as 'B'/roster entries — enemy
    -- structures show as 'E', neutral entities (fish) are ignored entirely.
    -- unit_number is included so genuinely OVERLAPPING entities (possible via
    -- Lua placement) stay distinguishable instead of looking like duplicates.
    local my_force = ctx.force
    for _, e in ipairs(surface.find_entities_filtered{area = query_area}) do
      if e.valid then
        local t = e.type
        local ex, ey = math.floor(e.position.x), math.floor(e.position.y)
        if t == "entity-ghost" then
          if my_force and e.force == my_force then mark(ex, ey, "g") end
        elseif e.force and e.force.name == "enemy" then
          mark(ex, ey, "E")
        elseif my_force and e.force == my_force
            and t ~= "character" and t ~= "resource" and t ~= "tree"
            and t ~= "simple-entity" and t ~= "cliff"
            and t ~= "corpse" and t ~= "particle" and t ~= "item-on-ground" then
          mark(ex, ey, "B")
          if #entities < 500 then
            entities[#entities + 1] = {
              name        = e.name,
              type        = t,
              unit_number = e.unit_number,
              position    = {x = round1(e.position.x), y = round1(e.position.y)},
              direction   = DIR_NAMES[e.direction] or tostring(e.direction),
            }
          else
            truncated = true
          end
        end
      end
    end
  end

  local grid = {}
  for r = 1, h do grid[r] = table.concat(cells[r]) end

  return {
    origin         = {x = ox, y = oy},
    width          = w,
    height         = h,
    surface        = surface.name,
    explored_pct   = math.floor((generated_chunks / math.max(total_chunks, 1)) * 100),
    grid           = grid,
    legend         = legend_used,
    entities       = entities,
    truncated_entities = truncated or nil,
  }
end

-- -------------------------------------------------------------------------
-- Dispatch
-- -------------------------------------------------------------------------

AIQueries.REGISTRY = REGISTRY

function AIQueries.list()
  local names = {}
  for n in pairs(REGISTRY) do names[#names + 1] = n end
  table.sort(names)
  return names
end

function AIQueries.run(name, params)
  local fn = REGISTRY[name]
  if not fn then
    return {error = "unknown query '" .. tostring(name) .. "' — known: "
      .. table.concat(AIQueries.list(), ", ")}
  end
  local character = AICharacter.get_character()
  local ctx = {
    character = character,
    force     = AICharacter.get_force() or game.forces.player,
    surface   = (character and character.surface) or game.surfaces["nauvis"],
  }
  local ok, result = pcall(fn, ctx, params or {})
  if not ok then return {error = tostring(result)} end
  return result
end

return AIQueries
