-- Tests for scripts/machines.lua with a stubbed game API (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path

local STATUS = { working = 1, no_ingredients = 2, full_output = 3, no_minable_resources = 4, no_power = 5 }
defines = { entity_status = STATUS, target_type = { entity = 1 } }
script = { register_on_object_destroyed = function() end }
helpers = { table_to_json = function() return "{}" end }
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
transport.update_if_changed = function(category, data) published[#published + 1] = { category = category, data = data } end
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
    if #published > 0 then first = i; break end
    assert(machines.collect_machines() == nil and machines.collect_drills() == nil,
      "no data before the first full lap (step " .. i .. ")")
  end
  assert(first, "published after the first lap")
  assert(first > 3, "not right after the fill: step " .. first)
  local m = machines.collect_machines()
  assert(m and m.by_planet.nauvis.total == 450, "machines total: " .. tostring(m and m.by_planet.nauvis.total))
  assert(m.by_planet.nauvis.working == 300, "working")
  local d = machines.collect_drills()
  assert(d.by_planet.nauvis.total == 50 and d.by_planet.nauvis.by_resource["iron-ore"].working == 50)
  local by_cat = {}
  for _, p in ipairs(published) do by_cat[p.category] = p.data end
  assert(by_cat.machines.by_planet.nauvis.total == 450, "first publish is complete")
  assert(by_cat.drills.by_planet.nauvis.total == 50, "first drills publish is complete")
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

transport.update_if_changed, production.set = real_update, real_set
print("machines_test ok")
