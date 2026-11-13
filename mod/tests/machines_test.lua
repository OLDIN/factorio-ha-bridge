-- Tests for scripts/machines.lua with a stubbed game API (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path

local STATUS = { working = 1, no_ingredients = 2, full_output = 3, no_minable_resources = 4, no_power = 5 }
defines = { entity_status = STATUS, target_type = { entity = 1 } }
script = { register_on_object_destroyed = function() end }
-- JSON stand-in: a label of the encoded table, so published JSON can be looked up as data
local encoded = {}
helpers = { table_to_json = function(t)
  encoded[#encoded + 1] = t
  return "json#" .. #encoded
end }
local function decoded(json)
  local n = type(json) == "string" and tonumber(json:match("^json#(%d+)$"))
  return n and encoded[n] or json
end
storage = {}

local production = require("scripts.logic.production")
local transport = require("scripts.transport")
local machines = require("scripts.machines")

-- Stubbed world ---------------------------------------------------------------------------
local reads            -- property name -> number of reads, over all fake entities
local next_id
local surface = { name = "nauvis", valid = true, planet = { name = "nauvis" } }
local world            -- list of fake entities on the surface

local function fake(data)
  next_id = next_id + 1
  data.valid, data.unit_number, data.force = true, next_id, { name = "player" }
  data.surface = surface
  data.position = data.position or { x = next_id + 0.2, y = 7.6 }
  local e = setmetatable({}, { __index = function(_, k)
    reads[k] = (reads[k] or 0) + 1
    local v = data[k]
    if k == "get_recipe" then return function() return data.recipe end end
    return v
  end, __newindex = function(_, k, v) data[k] = v end })
  world[#world + 1] = e
  return e
end

local function assembler(status, recipe)
  return fake({ type = "assembling-machine", status = STATUS[status], recipe = { name = recipe or "iron-gear-wheel" } })
end
local function drill(status, resource)
  return fake({ type = "mining-drill", status = STATUS[status], mining_target = { valid = true, name = resource or "iron-ore" } })
end

game = {
  tick = 0,
  surfaces = { nauvis = surface },
  get_surface = function(name) return name == "nauvis" and surface or nil end,
}
function surface.find_entities_filtered() return world end

local published
local real_update = transport.update_if_changed
transport.update_if_changed = function(category, data) published[#published + 1] = { category = category, data = decoded(data) } end
local sets
local real_set = production.set
production.set = function(...) sets[#sets + 1] = { ... }; return real_set(...) end

local function reset(enabled)
  storage = { config = { categories = enabled or { machines = true, drills = true } } }
  world, reads, published, sets, next_id = {}, {}, {}, {}, 0
end

local function steps(n) for _ = 1, n do machines.scan_step() end end

-- I3: nothing is published or collected until one full lap after the fill -------------------
do
  reset()
  for i = 1, 450 do assembler(i % 3 == 0 and "no_ingredients" or "working") end
  for _ = 1, 50 do drill("working") end
  -- fill: 500 entities at 200 per step = 3 steps; the lap after it takes ceil(500/100)=20-batch -> 25 steps
  local first
  for i = 1, 200 do
    machines.scan_step()
    if storage.machines.ready then first = i; break end
    assert(#published == 0 and machines.collect_machines() == nil and machines.collect_drills() == nil,
      "no data before the first full lap (step " .. i .. ")")
  end
  assert(first, "ready after the first lap")
  assert(first > 3, "not right after the fill: step " .. first)
  assert(#published == 0, "the publish starts with building the groups")
  machines.scan_step()
  local m = machines.collect_machines()
  assert(m and m.by_planet.nauvis.total == 450, "machines total: " .. tostring(m and m.by_planet.nauvis.total))
  assert(m.by_planet.nauvis.working == 300, "working")
  local d = machines.collect_drills()
  assert(d.by_planet.nauvis.total == 50 and d.by_planet.nauvis.by_resource["iron-ore"].working == 50)
  -- a publish spans three steps: groups built, then trimmed with drills sent, then machines sent
  assert(#published == 1 and published[1].category == "drills", "drills first")
  machines.scan_step()
  local by_cat = {}
  for _, p in ipairs(published) do by_cat[p.category] = p.data end
  assert(by_cat.machines.by_planet.nauvis.total == 450, "first publish is complete")
  assert(by_cat.drills.by_planet.nauvis.total == 50, "first drills publish is complete")
  machines.scan_step()
  assert(#published == 2, "one publish per lap")
end

-- I2: only enabled categories are published ------------------------------------------------
do
  reset({ machines = true })
  for _ = 1, 30 do assembler("working") end
  for _ = 1, 10 do drill("working") end
  steps(300)
  assert(#published > 0)
  for _, p in ipairs(published) do assert(p.category == "machines", "published " .. p.category) end
  reset({ drills = true })
  for _ = 1, 30 do assembler("working") end
  for _ = 1, 10 do drill("working") end
  steps(300)
  assert(#published > 0)
  for _, p in ipairs(published) do assert(p.category == "drills", "published " .. p.category) end
end

-- disabling resets the registry; re-enabling waits for a new full lap ----------------------
do
  reset()
  for _ = 1, 30 do assembler("working") end
  steps(200)
  assert(machines.collect_machines())
  storage.config.categories = { machines = false, drills = false }
  machines.scan_step()
  assert(storage.machines == nil and machines.collect_machines() == nil)
  storage.config.categories = { machines = true, drills = true }
  published = {}
  machines.scan_step()
  assert(machines.collect_machines() == nil and #published == 0, "not ready right after enabling")
  steps(200)
  assert(machines.collect_machines())
end

-- I4: hot path ---------------------------------------------------------------------------
do
  reset()
  local a = {}
  for i = 1, 40 do a[i] = assembler(i <= 10 and "no_ingredients" or "working") end
  local d = drill("working")
  local gone = fake({ type = "furnace", status = STATUS.no_ingredients, recipe = nil,
                      previous_recipe = { name = "iron-plate" } })
  local never = fake({ type = "furnace", status = STATUS.no_ingredients, recipe = nil })
  steps(200)
  local m = machines.collect_machines().by_planet.nauvis
  assert(m.total == 41, "furnace that lost its recipe stays in its previous group, one without any is out: " .. m.total)
  local plate
  for _, g in ipairs(m.groups) do if g.recipe == "iron-plate" then plate = g end end
  assert(plate and plate.total == 1 and plate.no_input == 1, "iron-plate group")
  for _, g in ipairs(m.groups) do assert(#g.at <= 3) end
  local gear
  for _, g in ipairs(m.groups) do if g.recipe == "iron-gear-wheel" then gear = g end end
  assert(gear.at[1][1] == 1 and gear.at[1][2] == 8, "registered rounded position")

  -- a full lap with nothing changing: no position reads, no production.set
  reads, sets = {}, {}
  steps(100)
  assert((reads.position or 0) == 0, "position reads in the hot path: " .. (reads.position or 0))
  assert(#sets == 0, "production.set calls without changes: " .. #sets)
  assert((reads.previous_recipe or 0) <= 2 * 100, "previous_recipe only for recipe-less furnaces")

  -- one change -> exactly one set within the next lap
  a[20].status = STATUS.full_output
  steps(100)
  assert(#sets == 1, "one set for one change: " .. #sets)
  assert(sets[1][5] == "output_full")
  -- drills do not track positions
  d.status = STATUS.no_minable_resources
  sets = {}
  steps(100)
  assert(#sets == 1 and sets[1][6] == nil, "drill set without position")
  assert(machines.collect_drills().by_planet.nauvis.by_resource["iron-ore"].depleted == 1)
  -- the furnace regains a recipe: it moves groups
  gone.recipe = { name = "steel-plate" }
  sets = {}
  steps(100)
  assert(#sets == 1 and sets[1][4] == "steel-plate")
end

-- old save: registry items without the cached fields keep working ---------------------------
do
  reset()
  for i = 1, 30 do assembler(i <= 6 and "no_power" or "working") end
  fake({ type = "furnace", status = STATUS.no_ingredients, recipe = nil, previous_recipe = { name = "iron-plate" } })
  drill("working")
  steps(200)
  local before = machines.collect_machines()
  for _, item in pairs(storage.machines.reg.items) do
    item.at, item.furnace, item.key, item.bucket = nil, nil, nil, nil
  end
  steps(100)
  local after = machines.collect_machines()
  assert(after.by_planet.nauvis.total == before.by_planet.nauvis.total)
  assert(#after.by_planet.nauvis.groups == #before.by_planet.nauvis.groups)
  for _, item in pairs(storage.machines.reg.items) do
    assert(item.at or item.drill, "position cached lazily")
  end
  -- a save from before `ready` existed: filled but not ready -> waits for a lap, no crash
  storage.machines.ready, storage.machines.lap_started = nil, nil
  assert(machines.collect_machines() == nil)
  steps(100)
  assert(machines.collect_machines())
end


-- 2c: machines on space platforms go to by_platform (with the platform's name), not by_planet --
do
  reset()
  local hauler = { index = 3, name = "Hauler 2", valid = true }
  local psurface = { name = "platform-3", valid = true, platform = hauler }
  game.surfaces = { nauvis = surface, ["platform-3"] = psurface }
  game.get_surface = function(name) return game.surfaces[name] end
  game.forces = { player = { platforms = { [3] = hauler } } }
  local function on(s)
    return function()
      local out = {}
      for _, e in ipairs(world) do if e.surface == s then out[#out + 1] = e end end
      return out
    end
  end
  surface.find_entities_filtered, psurface.find_entities_filtered = on(surface), on(psurface)
  for _ = 1, 4 do assembler("working") end
  for _ = 1, 6 do assembler("no_ingredients", "thruster-fuel").surface = psurface end
  for _ = 1, 4 do assembler("working", "thruster-fuel").surface = psurface end
  steps(200)
  local m = machines.collect_machines()
  assert(m.by_planet.nauvis.total == 4, "planet machines only")
  assert(m.by_planet["@3"] == nil, "no platform key in by_planet")
  local p = m.by_platform["3"]
  assert(p and p.name == "Hauler 2" and p.total == 10 and p.working == 4 and p.no_input == 6, "platform summary")
  assert(#p.groups == 1 and p.groups[1].recipe == "thruster-fuel", "platform group")
  for k in pairs(machines.collect_drills().by_planet) do assert(k:sub(1, 1) ~= "@", "no platform in drills") end
  hauler.valid = false -- the platform is gone: its machines are left out
  assert(machines.collect_machines().by_platform["3"] == nil)
end


-- 2c: after a mod update the registry is rebuilt, so machines already on platforms are found --
do
  reset()
  local hauler = { index = 3, name = "Hauler 2", valid = true }
  local psurface = { name = "platform-3", valid = true, platform = hauler }
  game.surfaces = { nauvis = surface } -- the old version filled planet surfaces only
  game.get_surface = function(name) return game.surfaces[name] end
  game.forces = { player = { platforms = { [3] = hauler } } }
  local function on(s)
    return function()
      local out = {}
      for _, e in ipairs(world) do if e.surface == s then out[#out + 1] = e end end
      return out
    end
  end
  surface.find_entities_filtered, psurface.find_entities_filtered = on(surface), on(psurface)
  for _ = 1, 4 do assembler("working") end
  for _ = 1, 3 do assembler("no_ingredients", "thruster-fuel").surface = psurface end
  steps(200)
  assert(machines.collect_machines().by_platform["3"] == nil, "not in the old registry")
  game.surfaces["platform-3"] = psurface
  machines.rebuild()
  assert(machines.collect_machines() == nil, "not ready until the new registry is scanned")
  steps(200)
  local p = machines.collect_machines().by_platform["3"]
  assert(p and p.total == 3, "found after the rebuild")
end

-- a big base: `machines` is trimmed to one datagram with only a few encodes of the whole category
-- (each one is ~0.5 ms on a real base; a short size estimate means one more per missing group)
do
  local function json(x) -- compact JSON stand-in with realistic sizes
    if type(x) == "string" then return '"' .. x .. '"' end
    if type(x) ~= "table" then return tostring(x) end
    if #x > 0 then
      local items = {}
      for i, v in ipairs(x) do items[i] = json(v) end
      return "[" .. table.concat(items, ",") .. "]"
    end
    local keys = {}
    for k in pairs(x) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for i, k in ipairs(keys) do out[i] = '"' .. tostring(k) .. '":' .. json(x[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  local whole = 0
  local stub_json = helpers.table_to_json
  helpers.table_to_json = function(v)
    if v.by_planet or (type(v.machines) == "table" and v.machines.by_planet) then whole = whole + 1 end
    return json(v)
  end
  reset({ machines = true })
  local by_name = {}
  for n = 1, 8 do -- 8 planets x 20 recipes, 4 of 10 machines starving: ~19 KB before the trim
    local s = { name = "p" .. n, index = 10 + n, valid = true, planet = { name = "p" .. n } }
    by_name[s.name] = s
    s.find_entities_filtered = function()
      local out = {}
      for _, e in ipairs(world) do if e.surface == s then out[#out + 1] = e end end
      return out
    end
    for r = 1, 20 do
      for i = 1, 10 do assembler(i <= 4 and "no_ingredients" or "working", "recipe-" .. r).surface = s end
    end
  end
  local real_surfaces, real_get_surface = game.surfaces, game.get_surface
  game.surfaces = by_name
  game.get_surface = function(name) return by_name[name] end
  steps(200)
  whole = 0
  local data, out = machines.collect_machines()
  assert(out == json(data), "the JSON that goes out is the trimmed data")
  local size = #json({ machines = data })
  assert(size <= transport.MAX_DATAGRAM - 200, "the category fits one datagram: " .. size)
  assert(size > transport.MAX_DATAGRAM - 200 - 300, "and is trimmed only as much as needed: " .. size)
  -- once with empty group lists (small), once the result that is sent
  assert(whole <= 2, "whole-category encodes: " .. whole)
  helpers.table_to_json = stub_json
  game.surfaces, game.get_surface = real_surfaces, real_get_surface
end

-- the 60 s snapshot reuses the last published JSON while it is fresh and made with the same rule
do
  reset({ machines = true })
  for i = 1, 30 do assembler(i <= 10 and "no_ingredients" or "working") end
  assert(machines.snapshot_machines() == nil, "nothing before the registry is ready")
  game.tick = 1000
  steps(200)
  local last = published[#published]
  assert(last and last.category == "machines")
  local encodes = #encoded
  local json = machines.snapshot_machines()
  assert(decoded(json) == last.data and #encoded == encodes, "the published JSON, nothing encoded")
  game.tick = 1000 + 600
  assert(machines.snapshot_machines() == json, "still fresh a lap later")
  game.tick = 1000 + 601
  json = machines.snapshot_machines()
  assert(#encoded > encodes and decoded(json) ~= last.data, "older than a lap: collected again")
  game.tick = 1000
  storage.config.line_output_full = true
  encodes = #encoded
  json = machines.snapshot_machines()
  assert(#encoded > encodes and decoded(json).by_planet.nauvis, "another line rule: collected again")
  game.tick = 0
end

-- `machines` turned off between the two halves of a publish: nothing is sent for it
do
  reset()
  for _ = 1, 30 do assembler("working") end
  for _ = 1, 5 do drill("working") end
  repeat machines.scan_step() until #published > 0
  assert(published[1].category == "drills")
  storage.config.categories = { drills = true }
  steps(1)
  assert(#published == 1, "machines dropped with the category")
end

-- the line rule changes in the middle of a publish: the data built with the old rule is not sent
do
  reset()
  for i = 1, 30 do assembler(i <= 10 and "no_ingredients" or "working") end
  repeat machines.scan_step() until storage.machines.ready
  storage.config.line_output_full = true
  steps(2)
  for _, p in ipairs(published) do assert(p.category ~= "machines", "no machines from the old rule") end
  steps(100)
  assert(published[#published].category == "machines", "the next lap publishes with the new rule")
end

-- the registry tells planets where machines and drills are
do
  reset()
  for _ = 1, 5 do drill("working") end
  assert(not machines.has_location("nauvis"))
  steps(200)
  assert(machines.has_location("nauvis") and not machines.has_location("gleba"))
end

transport.update_if_changed, production.set = real_update, real_set
print("machines_test ok")
