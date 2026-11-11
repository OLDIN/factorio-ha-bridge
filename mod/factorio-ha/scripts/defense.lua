-- `defense` category: turrets (total / no ammo / no power) and damaged walls per planet.
-- Turret registry, wall sets and hysteresis state live in `storage` and change only from
-- game events / on_nth_tick handlers (identical on every peer). Module-local state only
-- throttles UDP.

local transport = require("scripts.transport")
local config = require("scripts.config")
local scanner = require("scripts.logic.scanner")
local hysteresis = require("scripts.logic.hysteresis")

local defense = {}

defense.SCAN_TICKS = 10      -- scanner step interval
defense.LAP_STEPS = 60       -- a full lap takes 60 steps = 600 ticks
local HOLD_TICKS = 600
local MAX_POSITIONS = 5
local TURRET_TYPES = { "ammo-turret", "electric-turret", "fluid-turret", "artillery-turret" }
local WALL_TYPES = { wall = true, gate = true }

-- Storage layout (all plain data, created lazily so old saves work):
-- storage.defense = {
--   turrets = scanner registry of {id, entity, planet, no_ammo, no_power},
--   counts = {planet = {total, no_ammo, no_power}}, no_ammo_ids = {planet = {id = true}},
--   fill = nil | {surfaces = {names...}}, filled = bool,
--   walls = {planet = {n = count, set = {unit_number = entity}}},
--   hysteresis = {},
-- }
local function state()
  local d = storage.defense
  if not d then
    d = { turrets = scanner.new(), counts = {}, no_ammo_ids = {}, walls = {}, hysteresis = {}, filled = false }
    storage.defense = d
  end
  return d
end

local function planet_name(surface)
  local planet = surface and surface.valid and surface.planet
  return planet and planet.name or nil
end

local function counts_for(d, planet)
  local c = d.counts[planet]
  if not c then
    c = { total = 0, no_ammo = 0, no_power = 0 }
    d.counts[planet] = c
  end
  return c
end

local function round(v) return math.floor(v + 0.5) end

local function apply_state(d, id, item, no_ammo, no_power)
  local c = counts_for(d, item.planet)
  if no_ammo ~= item.no_ammo then
    c.no_ammo = c.no_ammo + (no_ammo and 1 or -1)
    local ids = d.no_ammo_ids[item.planet]
    if not ids then ids = {}; d.no_ammo_ids[item.planet] = ids end
    ids[id] = no_ammo or nil
    item.no_ammo = no_ammo
  end
  if no_power ~= item.no_power then
    c.no_power = c.no_power + (no_power and 1 or -1)
    item.no_power = no_power
  end
end

local function unregister(d, id)
  local item = scanner.remove(d.turrets, id)
  if not item then return end
  apply_state(d, id, item, false, false)
  local c = counts_for(d, item.planet)
  c.total = c.total - 1
end

local function register(d, entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if entity.force.name ~= "player" then return end
  local planet = planet_name(entity.surface)
  if not planet then return end
  local id = entity.unit_number
  if scanner.get(d.turrets, id) then return end
  scanner.add(d.turrets, id, { id = id, entity = entity, planet = planet, no_ammo = false, no_power = false })
  counts_for(d, planet).total = counts_for(d, planet).total + 1
  -- Removal comes as on_object_destroyed (mined, died, destroyed, ...).
  script.register_on_object_destroyed(entity)
end

local function classify(entity)
  local status = entity.status
  local s = defines.entity_status
  return status == s.no_ammo, status == s.no_power or status == s.low_power
end

local function scan_item(d, item)
  local entity = item.entity
  if not (entity and entity.valid) then
    -- defensive: on_object_destroyed normally removes it first
    unregister(d, item.id)
    return
  end
  local no_ammo, no_power = classify(entity)
  apply_state(d, entity.unit_number, item, no_ammo, no_power)
end

-- Initial fill: one surface per step, so a huge multi-surface base is never walked in one tick.
local function start_fill(d)
  local names = {}
  for _, surface in pairs(game.surfaces) do
    if surface.planet then names[#names + 1] = surface.name end
  end
  table.sort(names)
  d.fill = { surfaces = names }
end

local function fill_step(d)
  local name = table.remove(d.fill.surfaces)
  local surface = name and game.get_surface(name)
  local _unused = game.get_surface(name)
  if surface and surface.valid then
    for _, entity in pairs(surface.find_entities_filtered({ force = "player", type = TURRET_TYPES })) do
      register(d, entity)
    end
  end
  if #d.fill.surfaces == 0 then d.fill, d.filled = nil, true end
end

local function emit_events(d, tick)
  local planets = {}
  for planet in pairs(d.counts) do planets[#planets + 1] = planet end
  table.sort(planets)
  for _, planet in ipairs(planets) do
    local c = d.counts[planet]
    local res = hysteresis.update(d.hysteresis, "no_ammo:" .. planet, c.no_ammo > 0, tick, HOLD_TICKS)
    if res == "raised" then
      transport.send({ type = "event", event = "turrets_no_ammo", data = { planet = planet, count = c.no_ammo } })
    elseif res == "cleared" then
      transport.send({ type = "event", event = "turrets_ok", data = { planet = planet } })
    end
  end
end

-- Called every SCAN_TICKS ticks.
function defense.scan_step()
  if not config.enabled("defense") then
    storage.defense = nil -- stop scanning, drop the registry
    return
  end
  local d = state()
  if not d.filled and not d.fill then start_fill(d) end
  if d.fill then fill_step(d) end
  local n = scanner.count(d.turrets)
  if n > 0 then
    for _, item in ipairs(scanner.next_batch(d.turrets, math.ceil(n / defense.LAP_STEPS))) do
      scan_item(d, item)
    end
  end
  emit_events(d, game.tick)
end

function defense.on_built(e)
  if not config.enabled("defense") then return end
  register(state(), e.entity or e.created_entity)
end

function defense.on_object_destroyed(e)
  if not storage.defense then return end
  if e.type == defines.target_type.entity and e.useful_id then
    unregister(storage.defense, e.useful_id)
  end
end

-- Hot path (thousands of calls in a big attack): O(1), only remembers the wall.
function defense.on_entity_damaged(e)
  local entity = e.entity
  if not (entity.valid and entity.force.name == "player" and WALL_TYPES[entity.type]) then return end
  if not config.enabled("defense") then return end
  local planet = planet_name(entity.surface)
  local id = entity.unit_number
  if not (planet and id) then return end
  local d = state()
  local w = d.walls[planet]
  if not w then w = { n = 0, set = {} }; d.walls[planet] = w end
  if not w.set[id] then
    w.set[id] = entity
    w.n = w.n + 1
  end
end

-- Every 600 ticks: drop repaired / destroyed walls from the sets.
function defense.check_walls()
  local d = storage.defense
  if not d then return end
  for planet, w in pairs(d.walls) do
    for id, entity in pairs(w.set) do
      if not entity.valid or entity.health == nil or entity.health >= entity.max_health then
        w.set[id] = nil
        w.n = w.n - 1
      end
    end
    if w.n == 0 then d.walls[planet] = nil end
  end
end

local function pos(entity)
  local p = entity.position
  return { round(p.x), round(p.y) }
end

function defense.collect()
  local out = {}
  local d = storage.defense
  if not d then return { by_planet = out } end
  for planet, c in pairs(d.counts) do
    if c.total > 0 then
      local at = {}
      for id in pairs(d.no_ammo_ids[planet] or {}) do
        if #at >= MAX_POSITIONS then break end
        local item = scanner.get(d.turrets, id)
        if item and item.entity.valid then at[#at + 1] = pos(item.entity) end
      end
      out[planet] = out[planet] or {}
      out[planet].turrets = { total = c.total, no_ammo = c.no_ammo, no_power = c.no_power, no_ammo_at = at }
    end
  end
  for planet, w in pairs(d.walls) do
    local at = {}
    for _, entity in pairs(w.set) do
      if #at >= MAX_POSITIONS then break end
      if entity.valid then at[#at + 1] = pos(entity) end
    end
    out[planet] = out[planet] or {}
    out[planet].walls_damaged = { count = w.n, at = at }
  end
  -- planets with turrets always carry walls_damaged, so consumers see 0 after a repair
  for planet, p in pairs(out) do
    p.walls_damaged = p.walls_damaged or { count = 0, at = {} }
    p.turrets = p.turrets or { total = 0, no_ammo = 0, no_power = 0, no_ammo_at = {} }
  end
  return { by_planet = out }
end

function defense.snapshot()
  return defense.collect()
end

-- Periodic push of changes (every 600 ticks, after check_walls).
function defense.refresh()
  if not config.enabled("defense") then return end
  transport.update_if_changed("defense", defense.collect())
end

defense.TURRET_TYPES = TURRET_TYPES

return defense
