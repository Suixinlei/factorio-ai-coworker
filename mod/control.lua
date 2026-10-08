-- Factorio AI Coworker: dynamic external-agent characters.
require('scripts.agents')
require('scripts.character')
require('scripts.registry')
require('scripts.perception')
require('scripts.atomic_actions')
require('scripts.queries')
require('scripts.brain')
require('scripts.batch_actions')

local function annotation_text(value, fallback, field)
  if value == nil then return fallback end
  if type(value) ~= 'string' then
    return nil, field .. ' must be a string'
  end
  if #value > 80 then
    return nil, field .. ' must be at most 80 bytes'
  end
  if value == '' then return fallback end
  return value
end

local function annotation_icon(p)
  local icon = p.annotation and p.annotation.icon
  if icon and prototypes.virtual_signal[icon] then
    return {type='virtual', name=icon}
  end
  return {type='virtual', name='signal-A'}
end

local function markers(p)
  local c = p.character
  if p.map_tag and p.map_tag.valid then p.map_tag.destroy() end
  p.map_tag = nil
  if not c or not c.valid then return end
  local label = annotation_text(p.annotation and p.annotation.label, p.name, 'label') or p.name
  -- Charting around the character is load-bearing: it is how the AI
  -- "explores" (scan_area only sees generated/charted chunks). The follow
  -- chart tag, however, is opt-in — only created when the role explicitly
  -- sets a string map_tag.
  game.forces.player.chart(c.surface, {{c.position.x-48,c.position.y-48},{c.position.x+48,c.position.y+48}})
  local follow = p.annotation and p.annotation.map_tag
  if type(follow) == 'string' and follow ~= '' then
    local map_tag = annotation_text(follow, nil, 'map_tag')
    if map_tag then
      p.map_tag = game.forces.player.add_chart_tag(c.surface, {
        position=c.position, text=map_tag, icon=annotation_icon(p),
      })
    end
  end
  if p.label_text ~= label and p.label and p.label.valid then
    p.label:destroy()
    p.label = nil
  end
  if not p.label or not p.label.valid then
    p.label = rendering.draw_text{text=label, surface=c.surface, target={entity=c, offset={0,-2.5}},
      color=c.color, alignment='center', scale=1.2}
    p.label_text = label
  end
end

local function summary(p)
  local c = p.character
  return {agent_id=p.id, name=p.name, alive=c~=nil and c.valid,
    unit_number=c and c.valid and c.unit_number or nil,
    position=c and c.valid and {x=c.position.x,y=c.position.y} or nil,
    force=p.force_name, created_tick=p.created_tick,
    last_seen_tick=p.last_seen_tick, autonomy=false}
end
local function set_annotation(id, spec)
  if type(spec) ~= 'table' then return {ok=false, error='annotation must be a table'} end
  return AIAgents.with(id, function(p)
    if spec.clear or spec.clear_tags then
      -- Static chart tags are persistent world objects; clear them explicitly.
      if p.static_tags then
        for _, t in ipairs(p.static_tags) do if t.valid then t.destroy() end end
        p.static_tags = nil
      end
    end
    if spec.clear then
      p.annotation = nil
      markers(p)
      local s = summary(p); s.ok = true
      return s
    end
    if spec.clear_tags and spec.label == nil and spec.map_tag == nil and spec.icon == nil then
      local s = summary(p); s.ok = true; s.tags_cleared = true
      return s
    end

    -- map_tag as a TABLE creates a persistent, stationary chart tag at the
    -- given position (defaults to the character's position). Repeatable:
    -- each call adds one more tag (capped at 50 per role, oldest dropped).
    -- map_tag as a STRING keeps the legacy role tag that follows the character.
    if type(spec.map_tag) == 'table' then
      local c = p.character
      if not (c and c.valid) then return {ok=false, error='character is not alive'} end
      local value, err = annotation_text(spec.map_tag.text, nil, 'map_tag.text')
      if err then return {ok=false, error=err} end
      if not value then return {ok=false, error='map_tag.text is required'} end
      local icon_spec = nil
      local icon = spec.map_tag.icon
      if icon ~= nil and icon ~= '' then
        if type(icon) ~= 'string' or #icon > 64 then
          return {ok=false, error='icon must be a virtual signal name of at most 64 bytes'}
        end
        if not prototypes.virtual_signal[icon] then
          return {ok=false, error='unknown virtual signal: '..icon}
        end
        icon_spec = {type='virtual', name=icon}
      end
      local pos = spec.map_tag.position
      if pos ~= nil then
        if type(pos) ~= 'table' or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
          return {ok=false, error='map_tag.position must be {x=number, y=number}'}
        end
        pos = {x=tonumber(pos.x), y=tonumber(pos.y)}
      else
        pos = c.position
      end
      -- The tag is only visible on charted map; chart its surroundings first.
      game.forces.player.chart(c.surface, {{pos.x-16,pos.y-16},{pos.x+16,pos.y+16}})
      local tag = game.forces.player.add_chart_tag(c.surface, {position=pos, text=value, icon=icon_spec})
      if not tag then return {ok=false, error='add_chart_tag failed'} end
      p.static_tags = p.static_tags or {}
      p.static_tags[#p.static_tags+1] = tag
      while #p.static_tags > 50 do
        local old = table.remove(p.static_tags, 1)
        if old.valid then old.destroy() end
      end
      local s = summary(p); s.ok = true
      s.static_tag = {position={x=math.floor(pos.x), y=math.floor(pos.y)},
        text=value, static_tag_count=#p.static_tags}
      return s
    end

    if spec.label == nil and spec.map_tag == nil and spec.icon == nil then
      return {ok=false, error='provide label, map_tag, icon, or clear=true'}
    end
    p.annotation = p.annotation or {}
    for _,field in ipairs({'label', 'map_tag'}) do
      if spec[field] ~= nil then
        local value, err = annotation_text(spec[field], nil, field)
        if err then return {ok=false, error=err} end
        p.annotation[field] = value
      end
    end
    if spec.icon ~= nil then
      if type(spec.icon) ~= 'string' or #spec.icon > 64 then
        return {ok=false, error='icon must be a virtual signal name of at most 64 bytes'}
      end
      if spec.icon ~= '' and not prototypes.virtual_signal[spec.icon] then
        return {ok=false, error='unknown virtual signal: '..spec.icon}
      end
      p.annotation.icon = spec.icon == '' and nil or spec.icon
    end
    markers(p)
    local s = summary(p)
    s.ok = true
    return s
  end)
end
local function create(id, name)
  -- Rebinding an existing stable role must remain possible even when the
  -- configured roster limit is full.  The MCP facade uses create_agent as its
  -- idempotent bind operation; only genuinely new roles consume a slot.
  if storage.ai_agents and storage.ai_agents[id] then
    return AIAgents.with(id, function(p)
      if not p.character or not p.character.valid then
        local ok = AICharacter.spawn_ai_player()
        if not ok then return {ok=false, error='spawn failed'} end
      end
      markers(p)
      return {ok=true, rebound=true, agent_id=id, name=p.name,
        alive=p.character ~= nil and p.character.valid,
        unit_number=p.character and p.character.valid and p.character.unit_number or nil,
        position=p.character and p.character.valid and {x=p.character.position.x,y=p.character.position.y} or nil,
        force=p.force_name, created_tick=p.created_tick,
        last_seen_tick=p.last_seen_tick, autonomy=false}
    end)
  end
  local max_agents = (settings.global['ai-player-max-agents'] and settings.global['ai-player-max-agents'].value) or 8
  if #AIAgents.ids() >= max_agents then
    return {ok=false, error='agent limit reached ('..tostring(max_agents)..'); remove an existing role first'}
  end
  local r = AIAgents.create(id, name)
  if not r.ok then return r end
  return AIAgents.with(id, function(p)
    local ok = AICharacter.spawn_ai_player()
    if not ok then storage.ai_agents[id]=nil; return {ok=false, error='spawn failed'} end
    markers(p)
    return summary(p)
  end)
end
local function spawn(id)
  return AIAgents.with(id, function(p)
    if not p.character or not p.character.valid then
      local ok=AICharacter.spawn_ai_player()
      if not ok then return {ok=false,error='spawn failed'} end
    end
    markers(p)
    local s = summary(p)
    s.ok = true
    return s
  end)
end
local function remove(id)
  -- Full cleanup: character, follow tag, overhead label, static chart tags,
  -- and the stored profile. Previously this only destroyed the character, so
  -- "removed" roles kept showing up in list_agents and leaked labels/tags.
  local p = storage.ai_agents and storage.ai_agents[id]
  if not p then return {ok=false, agent_id=id, detail='unknown role'} end
  if p.character and p.character.valid then p.character.destroy() end
  if p.map_tag and p.map_tag.valid then p.map_tag.destroy() end
  if p.label and p.label.valid then p.label.destroy() end
  if p.static_tags then
    for _, t in ipairs(p.static_tags) do if t.valid then t.destroy() end end
  end
  storage.ai_agents[id] = nil
  game.print(string.format('[AI] Removed %s (manual removal)', p.name or id))
  return {ok=true, agent_id=id, detail='removed'}
end
local function delete_role(id, reason)
  local p=storage.ai_agents[id]
  if not p then return false end
  if p.character and p.character.valid then p.character.destroy() end
  if p.map_tag and p.map_tag.valid then p.map_tag.destroy() end
  if p.label and p.label.valid then p.label:destroy() end
  storage.ai_agents[id]=nil
  game.print(string.format('[AI] Removed %s (%s)', p.name or id, reason or 'cleanup'))
  return true
end
local function purge_session_roles()
  local removed = 0
  for id in pairs(storage.ai_agents or {}) do
    if string.sub(id, 1, 8) == 'session-' and delete_role(id, 'manual session cleanup') then
      removed = removed + 1
    end
  end
  return {ok=true, removed=removed}
end
local function cleanup_agents()
  local max_agents = (settings.global['ai-player-max-agents'] and settings.global['ai-player-max-agents'].value) or 8
  local timeout = ((settings.global['ai-player-idle-timeout-minutes'] and settings.global['ai-player-idle-timeout-minutes'].value) or 30) * 60 * 60
  local ids=AIAgents.ids()
  local candidates={}
  for _,id in ipairs(ids) do
    local p=storage.ai_agents[id]
    if p and game.tick-(p.last_seen_tick or p.created_tick or game.tick) >= timeout then
      candidates[#candidates+1]={id=id,tick=p.last_seen_tick or p.created_tick or 0}
    end
  end
  table.sort(candidates,function(a,b) return a.tick < b.tick end)
  for _,entry in ipairs(candidates) do delete_role(entry.id,'idle timeout') end
  ids=AIAgents.ids()
  if #ids > max_agents then
    local excess=#ids-max_agents
    local ranked={}
    for _,id in ipairs(ids) do
      local p=storage.ai_agents[id]
      ranked[#ranked+1]={id=id,tick=p.last_seen_tick or p.created_tick or 0}
    end
    table.sort(ranked,function(a,b) return a.tick < b.tick end)
    for i=1,excess do delete_role(ranked[i].id,'agent limit') end
  end
end
local function refresh_registry(p)
  if p.character and p.character.valid then
    AIRegistry.reconcile(p.character.surface, p.character.force)
  end
end
local BLOCKED_BATCH_ACTIONS = {}
local BLOCKED_ATOMIC_ACTIONS = {destroy=true}
remote.add_interface('ai_player', {
  create_agent = create,
  spawn_agent = spawn,
  remove_agent = remove,
  set_annotation = set_annotation,
  purge_session_roles = purge_session_roles,
  list_agents = function()
    local out = {}
    for _,id in ipairs(AIAgents.ids()) do out[#out+1] = summary(storage.ai_agents[id]) end
    return {tick=game.tick, agents=out}
  end,
  get_state = function(id)
    return AIAgents.with(id, function(p)
      if not p.character or not p.character.valid then return {error='character is not alive'} end
      refresh_registry(p)
      local state = AIPerception.factory_state(p.character)
      state.agent_id=id; state.name=p.name; state.unit_number=p.character.unit_number
      return state
    end)
  end,
  get_perception = function(id)
    return AIAgents.with(id, function(p)
      if not p.character or not p.character.valid then return {error='character is not alive'} end
      refresh_registry(p)
      return AIPerception.gather(p.character)
    end)
  end,
  query = function(id, name, params)
    return AIAgents.with(id, function() return AIQueries.run(name, params or {}) end)
  end,
  list_queries = function() return AIQueries.list() end,
  list_batch_actions = function()
    local names={}
    for n in pairs(AIBatchActions.REGISTRY) do if not BLOCKED_BATCH_ACTIONS[n] then names[#names+1]=n end end
    table.sort(names); return names
  end,
  list_atomic_actions = function() return AIActions.list() end,
  run_batch_action = function(id, action, params)
    if not AIBatchActions.REGISTRY[action] then return {ok=false, detail='unknown batch action: '..tostring(action)} end
    if BLOCKED_BATCH_ACTIONS[action] then return {ok=false, detail='destructive batch action disabled'} end
    return AIAgents.with(id, function(p)
      if not p.character or not p.character.valid then return {ok=false, detail='character is not alive'} end
      local entry = {}
      for k, v in pairs(params or {}) do entry[k] = v end
      entry.action = action
      local ok, detail = AIBatchActions.run(p.character,entry)
      markers(p)
      return {ok=ok, detail=detail or '', agent_id=id, tick=game.tick}
    end)
  end,
  run_atomic_action = function(id, action)
    if type(action)~='table' or not action.action then return {ok=false, detail='action required'} end
    if BLOCKED_ATOMIC_ACTIONS[action.action] then return {ok=false, detail='destructive atomic action disabled'} end
    return AIAgents.with(id, function(p)
      if not p.character or not p.character.valid then return {ok=false, detail='character is not alive'} end
      local ok, detail=AIActions.run(p.character,action)
      markers(p)
      return {ok=ok, detail=detail or '', agent_id=id, tick=game.tick}
    end)
  end,
  -- Externally controlled roles never issue competing bridge requests.
  set_autonomy = function(id, enabled)
    return AIAgents.with(id,function(p)
      if enabled then return {error='autonomous file bridge disabled in this MCP fork'} end
      p.autonomy_enabled=false; return {autonomy=false}
    end)
  end,
  set_coop = function(id, enabled)
    return AIAgents.with(id,function() return AICharacter.set_coop(enabled==true) end)
  end,
  get_chat = function(id, params)
    return AIAgents.with(id,function(p)
      local out={}
      for _,e in ipairs(p.chat_log) do
        if e.tick >= ((params or {}).since or 0) then out[#out+1]=e end
      end
      return {messages=out, latest_tick=game.tick}
    end)
  end,
})
local function init()
  AIAgents.init()
  AICharacter.create_force()
  for _,id in ipairs(AIAgents.ids()) do
    AIAgents.with(id,function(p)
      p.memory=p.memory or AIBrain.init_memory(); p.pending_requests={}
      p.chat_log=p.chat_log or {}; p.machines=p.machines or {}
      p.autonomy_enabled=false
      refresh_registry(p); markers(p)
    end, false)
  end
end
script.on_init(init)
script.on_configuration_changed(init)
script.on_event(defines.events.on_tick,function(event)
  if event.tick % 60 ~= 0 then return end
  if event.tick % 3600 == 0 then cleanup_agents() end
  for _,id in ipairs(AIAgents.ids()) do
    AIAgents.with(id,function(p)
      if p.respawn_tick and event.tick >= p.respawn_tick then
        p.respawn_tick=nil; AICharacter.spawn_ai_player()
      end
      if event.tick % 600 == 0 then refresh_registry(p) end
      markers(p)
    end, false)
  end
end)
script.on_event(defines.events.on_entity_died,function(event)
  for _,id in ipairs(AIAgents.ids()) do
    local p=storage.ai_agents[id]
    if p.character == event.entity then
      p.character=nil
      if settings.global['ai-player-auto-respawn'].value then p.respawn_tick=event.tick+300 end
    end
  end
end)
script.on_event(defines.events.on_console_chat,function(event)
  local player=event.player_index and game.get_player(event.player_index)
  for _,id in ipairs(AIAgents.ids()) do
    local log=storage.ai_agents[id].chat_log
    log[#log+1]={player=player and player.name or 'server',message=event.message,tick=event.tick}
    while #log>100 do table.remove(log,1) end
  end
end)
commands.add_command('spawn-ai-player','Create an independent AI: /spawn-ai-player <name>',function(cmd)
  storage.ai_agent_sequence=storage.ai_agent_sequence+1
  local id='role-'..storage.ai_agent_sequence
  local r=create(id,cmd.parameter and cmd.parameter~='' and cmd.parameter or id)
  game.print(helpers.table_to_json(r))
end)
commands.add_command('ai-list','List independent AI characters',function()
  for _,id in ipairs(AIAgents.ids()) do game.print(helpers.table_to_json(summary(storage.ai_agents[id]))) end
end)
commands.add_command('goto-ai-player','Teleport beside a role: /goto-ai-player <id>',function(cmd)
  local p=game.get_player(cmd.player_index)
  if not p then return end
  AIAgents.with(cmd.parameter,function(role)
    local c=role.character
    if c and c.valid then
      local pos=c.surface.find_non_colliding_position('character',{c.position.x+3,c.position.y},10,0.5)
      if pos then p.teleport(pos,c.surface) end
    end
  end)
end)
