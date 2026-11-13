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
-- The category goes out as {"machines":...}. trim_groups adds up plain encodings (a group's own
-- JSON is its share of the whole), so the key comes off the budget instead of wrapping every
-- measurement: wrapped, each dropped group was overestimated by these bytes, the estimate fell
-- short by a group every ~10 drops, and each shortfall cost one more encode of the whole category.
local MACHINES_KEY = #'{"machines":}'
local UNKNOWN_RESOURCE = "unknown"

local TYPE_SET = {}
for _, t in ipairs(machines.TYPES) do TYPE_SET[t] = true end

-- The last published `machines` JSON: {json, tick, output_full}. Session-local on purpose: it only
-- decides what the server sends over UDP, never game state, so it cannot desync. The 60 s
-- snapshot reuses it instead of collecting and trimming everything again.
local last_machines

-- Storage layout (plain data, created lazily so old saves work):
-- storage.machines = {
--   reg = scanner registry of {id, entity, planet, drill, resource,
--         at, furnace (machines; cached at registration),
--         key, bucket (last values given to production.set; key == false: not in a group)},
--   machines = logic/production state (location = planet, key = recipe),
--   drills = logic/production state (location = planet, key = resource),
--   fill = nil | logic/fill state, filled = bool, steps = scan steps since the last publish,
--   lap_started = a scanner lap that began after the fill is running or done,
--   ready = that lap is complete: only now are the categories collected and published,
-- }
-- Items registered by older versions lack the cached fields; scan_item fills them lazily.

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

-- Where an entity counts: the planet's name, or "@<index>" on a space platform (prototype names
-- never contain "@", so the two cannot clash). nil elsewhere (factory floors, ...).
local PLATFORM = "@"
local function location_of(surface)
  if not (surface and surface.valid) then return nil end
  local planet = surface.planet
  if planet then return planet.name end
  local platform = surface.platform
  if platform then return PLATFORM .. platform.index end
  return nil
end

local function is_platform(location)
  return string.sub(location, 1, 1) == PLATFORM
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
  local location = location_of(entity.surface)
  if not location then return end
  local id = entity.unit_number
  if scanner.get(m.reg, id) then return end
  -- `planet` holds the location key (a planet or "@<platform index>"); the name stays for old saves.
  local item = { id = id, entity = entity, planet = location, drill = entity.type == "mining-drill" }
  if not item.drill then -- machines cannot move; drills do not report positions
    local p = entity.position
    item.at = { round(p.x), round(p.y) }
    item.furnace = entity.type == "furnace"
  end
  scanner.add(m.reg, id, item)
  script.register_on_object_destroyed(entity)
end

local function recipe_name(entity, furnace)
  local recipe = entity.get_recipe()
  if recipe then return recipe.name end
  if furnace then -- a furnace that lost its recipe stays in its previous group
    local previous = entity.previous_recipe
    local name = previous and previous.name
    return type(name) == "string" and name or (name and name.name) or nil
  end
  return nil
end

-- The hot path: runs for every registered entity once per lap. Reads the status and the
-- recipe / mining target only, and touches production only when the group or bucket changed.
local function scan_item(m, item)
  local entity = item.entity
  if not (entity and entity.valid) then
    unregister(m, item.id) -- defensive: on_object_destroyed normally removes it first
    return
  end
  local bucket = production.bucket(status_name(entity.status))
  if item.drill then
    local target = entity.mining_target
    if target and target.valid then item.resource = target.name end
    local key = item.resource or UNKNOWN_RESOURCE
    if key ~= item.key or bucket ~= item.bucket then
      production.set(m.drills, item.id, item.planet, key, bucket, nil)
      item.key, item.bucket = key, bucket
    end
    return
  end
  if not item.at then -- registered by an older version
    local p = entity.position
    item.at = { round(p.x), round(p.y) }
  end
  if item.furnace == nil then item.furnace = entity.type == "furnace" end
  local recipe = recipe_name(entity, item.furnace)
  if recipe then
    if recipe ~= item.key or bucket ~= item.bucket then
      production.set(m.machines, item.id, item.planet, recipe, bucket, item.at)
      item.key, item.bucket = recipe, bucket
    end
  elseif item.key ~= false then
    production.remove(m.machines, item.id)
    item.key, item.bucket = false, nil
  end
end

-- Initial fill: one find per surface (C++ side), then at most FILL_PER_STEP entities
-- registered per scanner step; the found list and cursor live in storage.
local function start_fill(m)
  local names = {}
  for _, surface in pairs(game.surfaces) do
    if location_of(surface) then names[#names + 1] = surface.name end
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

-- Planet locations, or platform locations ("@<index>"), sorted.
local function sorted_locations(prod, platforms)
  local names = {}
  for location in pairs(prod.locations) do
    if is_platform(location) == platforms then names[#names + 1] = location end
  end
  table.sort(names)
  return names
end

local function summary_of(m, location, with_output_full)
  local sm = production.summary(m.machines, location)
  local b = production.buckets(m.machines, location)
  return { total = sm.total, working = sm.working,
           no_input = b.no_input, output_full = b.output_full, no_power = b.no_power,
           groups = production.groups(m.machines, location, MIN_SHARE, MAX_GROUPS, MAX_POSITIONS, with_output_full) }
end

-- `machines` of every location with its groups, before the trim (the registry must be ready).
local function build_machines(m, with_output_full)
  local by_planet, by_platform = {}, {}
  for _, planet in ipairs(sorted_locations(m.machines, false)) do
    by_planet[planet] = summary_of(m, planet, with_output_full)
  end
  -- Machines on space platforms, keyed by the platform index as a string, with its current name.
  for _, location in ipairs(sorted_locations(m.machines, true)) do
    local index = tonumber(string.sub(location, 2))
    local platform = game.forces.player.platforms[index]
    if platform and platform.valid then
      local entry = summary_of(m, location, with_output_full)
      entry.name = platform.name
      by_platform[tostring(index)] = entry
    end
  end
  return { by_planet = by_planet, by_platform = by_platform }
end

-- Trimming to one datagram (no encode of the whole), then the one encode of the result.
local function trim_machines(data, with_output_full)
  production.trim_groups(data, MAX_BYTES - MACHINES_KEY, helpers.table_to_json, with_output_full)
end

local function encode_machines(data, with_output_full)
  return production.encode_trimmed(data, MAX_BYTES - MACHINES_KEY, helpers.table_to_json, with_output_full)
end

-- nil until the registry is complete and has been scanned once: disabled, the initial fill
-- is running, or the first full lap after the fill is not done yet. Also returns the data's JSON,
-- so it is sent without encoding again.
function machines.collect_machines()
  local m = storage.machines
  if not (m and m.ready) then return nil end
  local with_output_full = config.line_output_full()
  local data = build_machines(m, with_output_full)
  trim_machines(data, with_output_full)
  return data, encode_machines(data, with_output_full)
end

-- `machines` for the snapshot, as JSON: the last publish while it is at most a lap old and was
-- made with the current line rule (a config change sends a snapshot right away), else collected
-- now. nil when not ready, like collect_machines.
function machines.snapshot_machines()
  local m = storage.machines
  if not (m and m.ready) then return nil end
  local c = last_machines
  if c and game.tick - c.tick <= machines.SCAN_TICKS * machines.LAP_STEPS
    and c.output_full == config.line_output_full() then
    return c.json
  end
  local _, json = machines.collect_machines()
  return json
end

-- Whether the registry holds a counted machine or drill on `location` (a planet name): proof of
-- player buildings there without searching the surface.
function machines.has_location(location)
  local m = storage.machines
  return m ~= nil and (m.machines.locations[location] ~= nil or m.drills.locations[location] ~= nil)
end

function machines.collect_drills()
  local m = storage.machines
  if not (m and m.ready) then return nil end
  local by_planet = {}
  for _, planet in ipairs(sorted_locations(m.drills, false)) do
    local sm = production.summary(m.drills, planet)
    by_planet[planet] = { total = sm.total, working = sm.working,
                          by_resource = production.resources(m.drills, planet) }
  end
  return { by_planet = by_planet }
end

-- A publish is spread over the scanner steps that follow the end of a lap (step 0), so no
-- step carries all of it: 0 builds the `machines` groups, 1 trims them and sends `drills`, 2
-- encodes and sends `machines`. The data waits in `pending`, session-local on purpose: it only
-- feeds the server's UDP (a peer that loads in between skips one publish), never game state.
local pending -- {data, output_full}

local function publish_step(m, step)
  if step == 0 then
    pending = nil
    if config.enabled("machines") then
      local output_full = config.line_output_full()
      pending = { data = build_machines(m, output_full), output_full = output_full }
    end
  elseif step == 1 then
    if pending and config.enabled("machines") then trim_machines(pending.data, pending.output_full) end
    if config.enabled("drills") then
      transport.update_if_changed("drills", machines.collect_drills())
    end
  elseif step == 2 then
    local p = pending
    pending = nil
    if not (p and config.enabled("machines")) then return end
    local json = encode_machines(p.data, p.output_full)
    last_machines = { json = json, tick = game.tick, output_full = p.output_full }
    transport.update_if_changed("machines", json)
  end
end

-- Called every SCAN_TICKS ticks.
function machines.scan_step()
  if not config.enabled("machines") and not config.enabled("drills") then
    storage.machines, pending = nil, nil -- stop scanning, drop the registry and the state
    return
  end
  local m = state()
  if not m.filled and not m.fill then start_fill(m) end
  if m.fill then fill_step(m) end
  if not m.filled then return end -- scanning starts once the registry is complete
  if not m.lap_started then
    m.reg.cursor = 1 -- the lap that makes the data ready starts here, from the first item
    m.lap_started, m.steps = true, 0
  end
  local n = scanner.count(m.reg)
  if n > 0 then
    local batch = math.max(math.ceil(n / machines.LAP_STEPS), MIN_BATCH)
    for _, item in ipairs(scanner.next_batch(m.reg, batch)) do
      scan_item(m, item)
    end
  end
  if not m.ready then
    if m.reg.cursor > #m.reg.ids then -- the first full lap is complete
      m.ready, m.steps = true, 0
      publish_step(m, 0)
    end
    return
  end
  m.steps = m.steps + 1
  if m.steps >= machines.LAP_STEPS then m.steps = 0 end
  publish_step(m, m.steps)
end

-- After a mod or game update: drop the registry, so the next steps refill it from every surface
-- that counts now (2c added platform surfaces, which older versions never registered).
function machines.rebuild()
  storage.machines = nil
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
