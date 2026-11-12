-- `platforms` category: the space platforms of the player force, where each one is or flies to,
-- damage on their surfaces, and departure / arrival / damage events (see logic/voyage.lua).
-- The damage state lives in `storage.platform_damage` and changes only from game events and
-- on_nth_tick handlers (identical on every peer).

local transport = require("scripts.transport")
local config = require("scripts.config")
local defense = require("scripts.defense")
local voyage = require("scripts.logic.voyage")

local platforms = {}

-- space_platform_state value -> name, built once from defines (not game state, so module-local is safe).
local state_names
local function state_name(value)
  if value == nil then return nil end
  if not state_names then
    state_names = {}
    for name, v in pairs(defines.space_platform_state) do state_names[v] = name end
  end
  return state_names[value]
end

-- Reads a property that older game versions may not have; nil when it is missing.
local function try(object, key)
  local ok, value = pcall(function() return object[key] end)
  return ok and value or nil
end

local function alive(p)
  return p and p.valid and (p.scheduled_for_deletion or 0) == 0
end

local function route_of(p)
  local conn = p.space_connection
  if not conn then return nil end
  local last = try(p, "last_visited_space_location")
  return voyage.route(conn.from.name, conn.to.name, p.distance, last and last.name)
end

local function describe(p, now)
  local entry = { index = p.index, name = p.name, state = state_name(p.state) }
  local location = p.space_location
  if location then
    entry.location = location.name
  else
    entry.route = route_of(p)
  end
  local damage = storage.platform_damage
  if damage then entry.damage = voyage.damage(damage, p.index, now) end
  return entry
end

function platforms.collect()
  local list = {}
  for _, p in pairs(game.forces.player.platforms) do
    if alive(p) then list[#list + 1] = describe(p, game.tick) end
  end
  table.sort(list, function(a, b) return a.index < b.index end)
  return { list = list }
end

-- Pushes the category when it changed (every 600 ticks and after state changes or damage).
function platforms.refresh()
  if not config.enabled("platforms") then return end
  transport.update_if_changed("platforms", platforms.collect())
end

function platforms.on_state_changed(e)
  if not config.enabled("platforms") then return end
  local p = e.platform
  if not (alive(p) and p.force.name == "player") then return end
  local change = voyage.transition(state_name(e.old_state), state_name(p.state))
  if change == "departed" then
    local route = route_of(p)
    if route then
      transport.send({ type = "event", event = "platform_departed",
                       data = { index = p.index, name = p.name, from = route.from, to = route.to } })
    end
  elseif change == "arrived" and p.space_location then
    transport.send({ type = "event", event = "platform_arrived",
                     data = { index = p.index, name = p.name, location = p.space_location.name } })
  end
  platforms.refresh()
end

-- Any loss of the player force on a platform surface, whatever killed it (asteroids mostly).
function platforms.on_entity_died(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  if not config.enabled("platforms") then return end
  local p = entity.surface.platform
  if not p then return end
  if entity.force.name ~= "player" or defense.NOT_LOSSES[entity.type] then return end
  local damage = storage.platform_damage
  if not damage then damage = voyage.new(); storage.platform_damage = damage end
  if voyage.on_loss(damage, p.index, game.tick, entity.name) then platforms.refresh() end
end

-- Every 300 ticks: forget platforms that are gone, end quiet episodes (platform_damaged),
-- and push the category while some damage is shown.
function platforms.tick()
  local damage = storage.platform_damage
  if not damage then return end
  if not config.enabled("platforms") then
    storage.platform_damage = nil
    return
  end
  local living = {}
  for index, p in pairs(game.forces.player.platforms) do
    if alive(p) then living[index] = p end
  end
  voyage.prune(damage, living)
  for _, ended in ipairs(voyage.expire(damage, game.tick)) do
    local p = living[ended.index]
    transport.send({ type = "event", event = "platform_damaged",
                     data = { index = ended.index, name = p.name, losses = ended.losses, duration_s = ended.duration_s } })
  end
  platforms.refresh()
  if next(damage.by_platform) == nil then storage.platform_damage = nil end
end

return platforms
