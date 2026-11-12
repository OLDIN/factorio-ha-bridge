-- `machines` and `drills` categories: crafting machines grouped by recipe and mining drills
-- grouped by resource, per planet, with status buckets (see logic/production.lua).
-- The registry and the production state live in `storage` and change only from game events /
-- on_nth_tick handlers (identical on every peer). Module-local state only caches lookups.

local transport = require("scripts.transport")
local config = require("scripts.config")
local scanner = require("scripts.logic.scanner")
local fill = require("scripts.logic.fill")
local production = require("scripts.logic.production")

local machines = {}

machines.SCAN_TICKS = 6      -- scanner step interval
machines.LAP_STEPS = 100     -- a full lap takes 100 steps = 600 ticks
machines.TYPES = { "assembling-machine", "furnace", "rocket-silo", "mining-drill" }
local MIN_BATCH = 20
local FILL_PER_STEP = 200    -- entities registered per scanner step during the initial fill
local MIN_SHARE = 0.1        -- a group is sent when >= 10% of its machines stand
local MAX_GROUPS = 20        -- per planet
local MAX_POSITIONS = 3
local MAX_BYTES = transport.MAX_DATAGRAM - 200 -- the `machines` category must fit one datagram
local UNKNOWN_RESOURCE = "unknown"

local TYPE_SET = {}
for _, t in ipairs(machines.TYPES) do TYPE_SET[t] = true end

-- Storage layout (plain data, created lazily so old saves work):
-- storage.machines = {
--   reg = scanner registry of {id, entity, planet, drill, resource, recipe},
--   machines = logic/production state (location = planet, key = recipe),
--   drills = logic/production state (location = planet, key = resource),
--   fill = nil | logic/fill state, filled = bool, steps = scan steps since the last publish,
-- }

local function state()
  local m = storage.machines
  if not m then
    m = { reg = scanner.new(), machines = production.new(), drills = production.new(),
          filled = false, steps = 0 }
    storage.machines = m
  end
  return m
end

-- entity_status value -> name, built once from defines (not game state, so module-local is safe).
local status_names
local function status_name(status)
  if status == nil then return nil end
  if not status_names then
    status_names = {}
    for name, value in pairs(defines.entity_status) do status_names[value] = name end
  end
  return status_names[status]
end

local function round(v) return math.floor(v + 0.5) end

local function planet_name(surface)
  local planet = surface and surface.valid and surface.planet
  return planet and planet.name or nil
end

local function unregister(m, id)
  if not scanner.remove(m.reg, id) then return end
  production.remove(m.machines, id)
  production.remove(m.drills, id)
end

local function register(m, entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not TYPE_SET[entity.type] then return end
  if entity.force.name ~= "player" then return end
  local planet = planet_name(entity.surface)
  if not planet then return end
  local id = entity.unit_number
  if scanner.get(m.reg, id) then return end
  local item = { id = id, entity = entity, planet = planet, drill = entity.type == "mining-drill" }
  scanner.add(m.reg, id, item)
  script.register_on_object_destroyed(entity)
end

local function recipe_name(entity)
  local recipe = entity.get_recipe()
  if not recipe and entity.type == "furnace" then
    local previous = entity.previous_recipe
    local name = previous and previous.name
    return type(name) == "string" and name or (name and name.name) or nil
  end
  return recipe and recipe.name or nil
end

local function scan_item(m, item)
  local entity = item.entity
  if not (entity and entity.valid) then
    unregister(m, item.id) -- defensive: on_object_destroyed normally removes it first
    return
  end
  local bucket = production.bucket(status_name(entity.status))
  local p = entity.position
  local at = { round(p.x), round(p.y) }
  if item.drill then
    local target = entity.mining_target
    if target and target.valid then item.resource = target.name end
    production.set(m.drills, item.id, item.planet, item.resource or UNKNOWN_RESOURCE, bucket, at)
  else
    local recipe = recipe_name(entity)
    if recipe then
      production.set(m.machines, item.id, item.planet, recipe, bucket, at)
    else
      production.remove(m.machines, item.id)
    end
  end
end

-- Initial fill: one find per surface (C++ side), then at most FILL_PER_STEP entities
-- registered per scanner step; the found list and cursor live in storage.
local function start_fill(m)
  local names = {}
  for _, surface in pairs(game.surfaces) do
    if surface.planet then names[#names + 1] = surface.name end
  end
  table.sort(names)
  m.fill = fill.new(names)
end

local function find_entities(name)
  local surface = game.get_surface(name)
  if not (surface and surface.valid) then return {} end
  return surface.find_entities_filtered({ force = "player", type = machines.TYPES })
end

local function fill_step(m)
  fill.step(m.fill, FILL_PER_STEP, find_entities, function(entity)
    if entity.valid then register(m, entity) end -- may have died since the find
  end)
  if fill.is_done(m.fill) then m.fill, m.filled = nil, true end
end

local function sorted_planets(prod)
  local names = {}
  for planet in pairs(prod.locations) do names[#names + 1] = planet end
  table.sort(names)
  return names
end

-- nil while there is no complete registry (disabled, or the initial fill is running).
function machines.collect_machines()
  local m = storage.machines
  if not (m and m.filled) then return nil end
  local by_planet = {}
  for _, planet in ipairs(sorted_planets(m.machines)) do
    local sm = production.summary(m.machines, planet)
    by_planet[planet] = { total = sm.total, working = sm.working,
                          groups = production.groups(m.machines, planet, MIN_SHARE, MAX_GROUPS, MAX_POSITIONS) }
  end
  local data = { by_planet = by_planet }
  production.trim_groups(data, MAX_BYTES, function(d) return helpers.table_to_json({ machines = d }) end)
  return data
end

function machines.collect_drills()
  local m = storage.machines
  if not (m and m.filled) then return nil end
  local by_planet = {}
  for _, planet in ipairs(sorted_planets(m.drills)) do
    local sm = production.summary(m.drills, planet)
    by_planet[planet] = { total = sm.total, working = sm.working,
                          by_resource = production.resources(m.drills, planet) }
  end
  return { by_planet = by_planet }
end

local function publish()
  local data = machines.collect_machines()
  if data then transport.update_if_changed("machines", data) end
  data = machines.collect_drills()
  if data then transport.update_if_changed("drills", data) end
end

-- Called every SCAN_TICKS ticks.
function machines.scan_step()
  if not config.enabled("machines") and not config.enabled("drills") then
    storage.machines = nil -- stop scanning, drop the registry and the state
    return
  end
  local m = state()
  if not m.filled and not m.fill then start_fill(m) end
  if m.fill then fill_step(m) end
  local n = scanner.count(m.reg)
  if n > 0 then
    local batch = math.max(math.ceil(n / machines.LAP_STEPS), MIN_BATCH)
    for _, item in ipairs(scanner.next_batch(m.reg, batch)) do
      scan_item(m, item)
    end
  end
  if m.filled then
    m.steps = m.steps + 1
    if m.steps >= machines.LAP_STEPS then
      m.steps = 0
      publish()
    end
  end
end

function machines.on_built(e)
  if not (config.enabled("machines") or config.enabled("drills")) then return end
  register(state(), e.entity or e.created_entity or e.destination)
end

function machines.on_object_destroyed(e)
  if not storage.machines then return end
  if e.type == defines.target_type.entity and e.useful_id then
    unregister(storage.machines, e.useful_id)
  end
end

return machines
