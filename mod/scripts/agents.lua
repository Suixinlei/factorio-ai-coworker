-- Dynamic character profiles. Legacy skill modules receive a scoped context;
-- it is always restored, including when a handler raises an error.
AIAgents = {}
local function valid_id(id)
  return type(id) == 'string' and #id >= 1 and #id <= 64 and id:match('^[%w_-]+$') ~= nil
end
function AIAgents.init()
  storage.ai_agents = storage.ai_agents or {}
  storage.ai_agent_sequence = storage.ai_agent_sequence or 0
  if storage.ai_player and not next(storage.ai_agents) then
    local old = storage.ai_player
    old.id = 'legacy'
    old.name = 'Legacy AI'
    old.autonomy_enabled = false
    storage.ai_agents.legacy = old
  end
  storage.ai_player = nil
end
function AIAgents.ids()
  local ids = {}
  for id in pairs(storage.ai_agents or {}) do ids[#ids+1] = id end
  table.sort(ids)
  return ids
end
function AIAgents.create(id, name)
  if not valid_id(id) then return {error='id must contain 1-64 letters, digits, underscores or hyphens'} end
  if storage.ai_agents[id] then return {error='role already exists; use its id to read it'} end
  if type(name) ~= 'string' or #name < 1 or #name > 80 then return {error='name must contain 1-80 bytes'} end
  storage.ai_agents[id] = {
    id=id, name=name, force_name='player', tick_counter=0, pending_requests={},
    chat_log={}, memory=AIBrain.init_memory(), machines={}, last_reconcile_tick=0,
    autonomy_enabled=false, created_tick=game.tick,
    last_seen_tick=game.tick,
  }
  return {ok=true, agent_id=id}
end
function AIAgents.with(id, fn, touch)
  local profile = (storage.ai_agents or {})[id]
  if not profile then return {error='unknown role: '..tostring(id), ok=false} end
  local previous = storage.ai_player
  storage.ai_player = profile
  if touch ~= false then profile.last_seen_tick = game.tick end
  local ok, result = pcall(fn, profile)
  storage.ai_player = previous
  if not ok then return {error=tostring(result), ok=false} end
  return result
end
return AIAgents
