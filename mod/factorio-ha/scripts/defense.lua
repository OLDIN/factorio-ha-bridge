-- `defense` category: turrets (total / no ammo / no power), damaged walls and the running
-- attack per planet.
-- Turret registry, wall sets and hysteresis state live in `storage` and change only from
-- game events / on_nth_tick handlers (identical on every peer). Module-local state only
-- throttles UDP.

local transport = require("scripts.transport")
local config = require("scripts.config")
local scanner = require("scripts.logic.scanner")
local hysteresis = require("scripts.logic.hysteresis")
local fill = require("scripts.logic.fill")
local attacks = require("scripts.logic.attacks")
local walls = require("scripts.logic.walls")

local defense = {}

defense.SCAN_TICKS = 10      -- scanner step interval
defense.LAP_STEPS = 60       -- a full lap takes 60 steps = 600 ticks
local HOLD_TICKS = 600
local FILL_PER_STEP = 200   -- turrets registered per scanner step during the initial fill
local MAX_POSITIONS = 5
-- Damaged-wall repair check: a portion per scanner step, ceil(N / LAP_STEPS) walls with a
-- floor, so a lap over 20 000 walls takes 60 steps = 600 ticks (turrets work the same way).
local WALL_MIN_BATCH = 50
local TURRET_TYPES = { "ammo-turret", "electric-turret", "fluid-turret", "artillery-turret" }
local WALL_TYPES = { wall = true, gate = true }
-- Dying entities of the player force that are not buildings: not a "loss" of the base.
local NOT_LOSSES = { character = true, ["combat-robot"] = true, ["construction-robot"] = true, ["logistic-robot"] = true }

-- Storage layout (all plain data, created lazily so old saves work):
-- storage.defense = {
--   turrets = scanner registry of {id, entity, planet, no_ammo, no_power},
--   counts = {planet = {total, no_ammo, no_power}}, no_ammo_ids = {planet = {id = true}},
--   fill = nil | logic/fill state, filled = bool,
--   walls = logic/walls registry of damaged walls (scanner + per-planet counts and ids),
--   hysteresis = {},
-- }
-- storage.attacks = logic/attacks state (running attacks), dropped when `defense` is turned off.

local function state()
  local d = storage.defense
  if not d then
    d = { turrets = scanner.new(), counts = {}, no_ammo_ids = {}, walls = walls.new(), hysteresis = {}, filled = false }
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

-- Initial fill: one find per surface (C++ side), then at most FILL_PER_STEP turrets
-- registered per scanner step; the found list and cursor live in storage.
local function start_fill(d)
  local names = {}
  for _, surface in pairs(game.surfaces) do
    if surface.planet then names[#names + 1] = surface.name end
  end
  table.sort(names)
  d.fill = fill.new(names)
end

local function find_turrets(name)
  local surface = game.get_surface(name)
  if not (surface and surface.valid) then return {} end
  return surface.find_entities_filtered({ force = "player", type = TURRET_TYPES })
end

local function fill_step(d)
  fill.step(d.fill, FILL_PER_STEP, find_turrets, function(entity)
    if entity.valid then register(d, entity) end -- may have died since the find
  end)
  if fill.is_done(d.fill) then d.fill, d.filled = nil, true end
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

local function wall_done(entity)
  return not entity.valid or entity.health == nil or entity.health >= entity.max_health
end

local function check_walls(d)
  local n = walls.total(d.walls)
  if n > 0 then
    walls.step(d.walls, math.max(WALL_MIN_BATCH, math.ceil(n / defense.LAP_STEPS)), wall_done)
  end
end

-- Called every SCAN_TICKS ticks.
function defense.scan_step()
  if not config.enabled("defense") then
    storage.defense = nil -- stop scanning, drop the registry
    storage.attacks = nil
    return
  end
  local d = state()
  if not d.filled and not d.fill then start_fill(d) end
  if d.fill then fill_step(d) end
  local n = scanner.count(d.turrets)
  check_walls(d)
  if n > 0 then
    for _, item in ipairs(scanner.next_batch(d.turrets, math.ceil(n / defense.LAP_STEPS))) do
      scan_item(d, item)
    end
  end
  emit_events(d, game.tick)
end

function defense.on_built(e)
  if not config.enabled("defense") then return end
  register(state(), e.entity or e.created_entity or e.destination)
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
  walls.add(state().walls, id, entity, planet)
end

local function pos(entity)
  local p = entity.position
  return { round(p.x), round(p.y) }
end

-- Hot path (thousands of calls in a big attack): a few table lookups per loss.
function defense.on_entity_died(e)
  local entity, killer = e.entity, e.force
  if not (killer and entity.valid) then return end
  if entity.force.name ~= "player" or NOT_LOSSES[entity.type] then return end
  if not config.enabled("defense") then return end
  if not game.forces.player.is_enemy(killer) then return end
  local surface = entity.surface
  local planet = planet_name(surface)
  if not planet then return end
  local state = storage.attacks
  if not state then state = attacks.new(); storage.attacks = state end
  local p = entity.position
  local started = attacks.on_loss(state, {
    tick = game.tick, surface = surface.name, planet = planet, x = p.x, y = p.y, name = entity.name,
  })
  if started then
    transport.send({ type = "event", event = "attack_started", data = started })
  end
end

-- Every 300 ticks: end quiet attacks and push the running ones (at most this often).
function defense.tick_attacks()
  local state = storage.attacks
  if not state then return end
  if not config.enabled("defense") then
    storage.attacks = nil
    return
  end
  local ended = attacks.expire(state, game.tick)
  for _, e in ipairs(ended) do
    transport.send({ type = "event", event = "attack_ended", data = e })
  end
  if #ended > 0 or attacks.active(state) then defense.refresh() end
end

function defense.collect()
  local out = {}
  local d = storage.defense
  local astate = storage.attacks
  if not d and not astate then return { by_planet = out } end
  d = d or { counts = {}, no_ammo_ids = {}, walls = walls.new(), turrets = scanner.new() }
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
  for planet, n in pairs(d.walls.counts) do
    local at = {}
    for _, id in ipairs(walls.some_ids(d.walls, planet, MAX_POSITIONS)) do
      local entity = walls.entity(d.walls, id)
      if entity and entity.valid then at[#at + 1] = pos(entity) end
    end
    out[planet] = out[planet] or {}
    out[planet].walls_damaged = { count = n, at = at }
  end
  if astate then
    for _, a in ipairs(astate.list) do
      if not out[a.planet] then
        out[a.planet] = {}
      end
    end
    for planet, p in pairs(out) do
      p.attack = attacks.current(astate, planet)
    end
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

-- Periodic push of changes (every 600 ticks).
function defense.refresh()
  if not config.enabled("defense") then return end
  transport.update_if_changed("defense", defense.collect())
end

defense.TURRET_TYPES = TURRET_TYPES
defense.NOT_LOSSES = NOT_LOSSES -- entity types whose death is not a loss (also for platforms)

return defense
